#!/usr/bin/env bash
set -eu
set -o pipefail

# Measure achieved streaming rate per checkpoint, in bytes rather than tokens.
#
# Decode reads every weight once per token, so tokens per second and streamed
# bytes per token give an achieved GB/s that is comparable across checkpoints of
# different sizes. The 2B reaches 11.95 GB/s where the 4B reaches 8.28, so the
# lower figure is not a device ceiling, and what separates them is 24 layers
# against 32 rather than any property of the memory system.
#
# Each checkpoint runs twice, once in each direction of the model order, and the
# priority arms of one checkpoint run back to back. Identical flags at identical
# priority measured 9.60 and 7.08 tok/s fifteen minutes apart on a loaded
# desktop, a 26% spread that decays as the part settles into its 86 to 88 C
# band, so an arm separated from its comparison by five other arms reports its
# position in the queue rather than its flags.
#
# Streamed bytes come from the census rather than from the file size, because
# decode skips the multi-token-prediction block and reads a tied embedding once
# for the lookup and once for the projection.
#
# Scheduling priority is fixed at nice 19, the appliance's desktop-safe
# operating condition. The I/O class stays at idle, and llama-bench reads its
# weights through mmap before the timed repetitions. Each arm records the load
# average it ran under, because a rate measured against an idle machine
# describes a machine that never serves.

if [ "$#" -lt 1 ]; then
    printf 'usage: %s MODEL_PATH [MODEL_PATH...]\n' "$0" >&2
    printf 'output directory comes from QWEN_BANDWIDTH_OUTPUT\n' >&2
    exit 2
fi

output_directory=${QWEN_BANDWIDTH_OUTPUT:-"${HOME:?}/qwen-bandwidth-ladder"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bench=${QWEN_LLAMA_BENCH:-"${HOME:?}/src/llama.cpp-qwen-apu/build-qwen-vulkan/bin/llama-bench"}
census=${QWEN_TENSOR_CENSUS:-"$script_directory/gguf-tensor-census.py"}
clock_sampler=${QWEN_CLOCK_SAMPLER:-"$script_directory/sample-gpu-clocks.sh"}
generate_tokens=${QWEN_BENCH_GENERATE:-64}
case $generate_tokens in
    '' | *[!0-9]* | 0)
        printf 'decode length must be a positive integer: %s\n' \
            "$generate_tokens" >&2
        exit 2
        ;;
esac
# Prefill is off by default so the retained decode series stays comparable: an
# arm that prefills first meets the device in a different thermal and clock
# state than one that decodes cold. Setting a positive length adds a pp row to
# the same arm, which is what makes a cross-checkpoint sweep carry both halves
# from one queue position instead of two.
prefill_tokens=${QWEN_BENCH_PREFILL:-0}
case $prefill_tokens in
    '' | *[!0-9]*)
        printf 'prefill length must be a non-negative integer: %s\n' \
            "$prefill_tokens" >&2
        exit 2
        ;;
esac
repetitions=${QWEN_BENCH_REPETITIONS:-3}
nice_levels=${QWEN_BENCH_NICE_LEVELS:-19}
if [ "$nice_levels" != 19 ]; then
    printf 'bandwidth ladder requires nice 19: %s\n' "$nice_levels" >&2
    exit 2
fi
nice_level_values=(19)
model_paths=("$@")

if [ ! -x "$bench" ]; then
    printf 'llama-bench is not built at %s\n' "$bench" >&2
    exit 2
fi
for model_path in "${model_paths[@]}"; do
    if [ ! -f "$model_path" ]; then
        printf 'model file is absent: %s\n' "$model_path" >&2
        exit 2
    fi
done
if pgrep -x llama-server >/dev/null 2>&1 || pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/bandwidth-summary.tsv
printf 'pass\tnice_observed\tmodel\tstreamed_bytes\tdecode_tok_s\tprefill_tok_s\tachieved_gb_s\tmclk_modal\ttemp_c_max\tload_mean\tload_max\n' \
    >"$summary"

# A killed run leaves its sampler writing once a second into a file the next run
# recreates, which contaminates that run and hides the orphan behind a plausible
# name. The trap ends the sampler with the script that started it.
sampler_pid=''
stop_sampler() {
    [ -n "$sampler_pid" ] || return 0
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=''
}
trap 'stop_sampler' EXIT
trap 'stop_sampler; exit 130' INT
trap 'stop_sampler; exit 143' TERM

arm_index=0
measurement_failed=0

parse_rate_for_label() {
    rate_log=$1
    expected_label=$2
    # A bench log carries lines that hold no pipe at all -- the Vulkan device
    # banner's first line and the trailing build line -- and mawk treats a
    # negative field index as a fatal run-time error rather than an empty
    # string. Without the guard awk aborts on line 1, END never runs, and the
    # arm records an empty rate instead of the n/a a genuine miss produces.
    # The table rows split into nine fields, so NF >= 3 is exactly what the
    # $(NF - 2) and $(NF - 1) references require.
    awk -F'|' -v expected="$expected_label" '
        NF >= 3 {
            label = $(NF - 2)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", label)
            label_found = label == expected ||
                label ~ ("^" expected " @ d[0-9]+$")
            if (label_found) {
                matches++
                split($(NF - 1), parts, /[^0-9.]+/)
                row_rate = ""
                for (part = 1; part <= 3; part++) {
                    if (parts[part] != "") {
                        row_rate = parts[part]
                        break
                    }
                }
                if (row_rate != "") rate = row_rate
            }
        }
        END { print (matches == 1 && rate != "" ? rate : "n/a") }
    ' "$rate_log"
}

run_model() {
    pass_label=$1
    arm_nice=$2
    model_path=$3
    model_name=$(basename "$model_path" .gguf)
    # The sequence number keeps every arm's log and clock samples separate. A
    # priority list that repeats a level gives two arms the same pass, level,
    # and model, and the clock sampler appends, so a shared name pools two arms'
    # temperature and load into one row.
    arm_index=$((arm_index + 1))
    arm_label=$(printf '%02d-%s-nice%s-%s' "$arm_index" "$pass_label" \
        "$arm_nice" "$model_name")
    arm_log=$output_directory/$arm_label.log
    arm_samples=$output_directory/$arm_label.clocks.tsv

    streamed=$(sh -c '
        renice -n 19 -p $$ >/dev/null
        exec "$@"
    ' sh python3 "$census" --skip-hash "$model_path" 2>/dev/null |
        awk -F'\t' '$1 == "streamed_bytes_per_token" { print $2 }')
    case $streamed in
        '' | *[!0-9]*)
            printf 'census reported no streamed byte count for %s\n' \
                "$model_path" >&2
            return 1
            ;;
    esac

    printf 'arm_start_utc=%s label=%s nice=%s streamed_bytes=%s load=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$arm_nice" "$streamed" \
        "$(awk '{ print $1 }' /proc/loadavg)"
    "$clock_sampler" "$arm_samples" 1 &
    sampler_pid=$!
    set +e
    sh -c '
        renice -n "$1" -p $$ >/dev/null
        shift
        exec ionice -c 3 "$@"
    ' sh "$arm_nice" "$bench" -m "$model_path" -ngl 99 -t 2 \
        -r "$repetitions" -p "$prefill_tokens" -n "$generate_tokens" -o md \
        >"$arm_log" 2>&1 &
    bench_pid=$!
    # Read the priority the kernel gave the child. A column that restates the
    # request survives an invocation that drops it, which is how twenty arms
    # once reported two priorities while every one of them ran at nice 19.
    # The wrapper applies an absolute priority and then execs, so the read waits
    # for the command name to become llama-bench; before that it would return
    # the wrapper's state rather than the benchmark's observed state.
    observed_nice=unread
    settle=0
    while [ "$settle" -lt 20 ]; do
        child_state=$(cat "/proc/$bench_pid/stat" 2>/dev/null) || break
        case $child_state in
            *'(llama-bench)'*)
                observed_nice=$(printf '%s\n' "$child_state" | awk '{ print $19 }')
                break
                ;;
        esac
        settle=$((settle + 1))
        sleep 1
    done
    wait "$bench_pid"
    arm_status=$?
    set -e
    stop_sampler

    priority_matches=1
    if [ "$observed_nice" != "$arm_nice" ]; then
        printf 'arm_priority_mismatch label=%s requested=%s observed=%s\n' \
            "$arm_label" "$arm_nice" "$observed_nice" >&2
        priority_matches=0
    fi

    decode=n/a
    if [ "$arm_status" -eq 0 ]; then
        decode=$(parse_rate_for_label "$arm_log" "tg$generate_tokens")
    fi
    prefill=n/a
    if [ "$arm_status" -eq 0 ] && [ "$prefill_tokens" -gt 0 ]; then
        prefill=$(parse_rate_for_label "$arm_log" "pp$prefill_tokens")
    fi
    prefill_complete=1
    if [ "$arm_status" -eq 0 ] && [ "$prefill_tokens" -gt 0 ] &&
       [ "$prefill" = n/a ]; then
        printf 'arm_prefill_missing label=%s requested_tokens=%s\n' \
            "$arm_label" "$prefill_tokens" >&2
        prefill_complete=0
    fi
    achieved=n/a
    case $decode in
        n/a) ;;
        *) achieved=$(awk -v r="$decode" -v b="$streamed" \
            'BEGIN { printf "%.2f", r * b / 1000000000 }') ;;
    esac
    clock_report=$(awk -F'\t' '
        $1 ~ /^[0-9]+([.][0-9]+)?$/ { count[$1]++; clock_samples++ }
        $3 ~ /^[0-9]+([.][0-9]+)?$/ {
          if ($3 + 0 > temp_max) { temp_max = $3 + 0 }
          temperature_samples++
        }
        $4 ~ /^[0-9]+([.][0-9]+)?$/ {
          load_sum += $4 + 0
          if ($4 + 0 > load_max) { load_max = $4 + 0 }
          load_samples++
        }
        END {
            for (step in count) {
                if (count[step] > best) { best = count[step]; modal = step }
            }
            printf "%s\t%s\t%s\t%s",
                (clock_samples ? modal : "unavailable"),
                (temperature_samples ? sprintf("%.1f", temp_max / 1000) : "unavailable"),
                (load_samples ? sprintf("%.2f", load_sum / load_samples) : "unavailable"),
                (load_samples ? sprintf("%.2f", load_max) : "unavailable")
        }' "$arm_samples")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pass_label" "$observed_nice" \
        "$model_name" "$streamed" "$decode" "$prefill" "$achieved" \
        "$clock_report" >>"$summary"
    printf 'arm_stop_utc=%s label=%s nice_observed=%s decode=%s prefill=%s achieved_gb_s=%s clocks_load=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$observed_nice" "$decode" \
        "$prefill" "$achieved" \
        "$(printf '%s' "$clock_report" | tr '\t' ' ')"

    if [ "$arm_status" -ne 0 ] || [ "$decode" = n/a ] || \
       [ "$prefill_complete" -ne 1 ] || [ "$priority_matches" -ne 1 ]; then
        return 1
    fi
    return 0
}

for model_path in "${model_paths[@]}"; do
    for nice_level in "${nice_level_values[@]}"; do
        run_model forward "$nice_level" "$model_path" || measurement_failed=1
    done
done

# The reverse pass gives every checkpoint an early slot and a late one, and it
# holds nice 19 in both directions, so model position cannot stand in for a
# result that survives both.
for ((model_index = ${#model_paths[@]} - 1; model_index >= 0; model_index--)); do
    model_path=${model_paths[$model_index]}
    for ((level_index = ${#nice_level_values[@]} - 1; level_index >= 0; level_index--)); do
        nice_level=${nice_level_values[$level_index]}
        run_model reverse "$nice_level" "$model_path" || measurement_failed=1
    done
done

if [ "$measurement_failed" -ne 0 ]; then
    printf 'bandwidth_ladder=failed output_directory=%s\n' \
        "$output_directory" >&2
    cat "$summary"
    exit 1
fi

printf 'bandwidth_ladder=completed output_directory=%s\n' "$output_directory"
cat "$summary"
