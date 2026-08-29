#!/bin/sh
set -eu

# Establish whether a depth-0 llama-bench rate is repeatable across invocations
# before any comparison rests on one. The Nanbeige ladder recorded 3.31 tok/s
# for Qwen3.8-4B at depth 0 with an f16 cache; the cache factorial recorded 3.08
# for the same cell. Both ran `-ngl 99 -t 2 -r 3 -p 0 -n 64` on the same build
# and the same file, and they differ by 7.5%, which is larger than every effect
# the factorial set out to measure.
#
# Two candidates separate here. The ladder printed no `fa` column, so it ran the
# `auto` default while the factorial forced a value; arm one repeats the ladder's
# flag set. The factorial's f16 cells ran four minutes into sustained load on a
# 15 W part; arms two and three repeat the same cell hot and after an idle
# interval. A spread across arms two and three makes invocation order a
# confound in every depth-0 figure this tree holds.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s MODEL_PATH [OUTPUT_DIRECTORY]\n' "$0" >&2
    exit 2
fi

model_path=$1
output_directory=${2:-"${HOME:?}/qwen-bench-repeatability"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bench=${QWEN_LLAMA_BENCH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-bench"}
clock_sampler=${QWEN_CLOCK_SAMPLER:-"$script_directory/sample-gpu-clocks.sh"}
idle_seconds=${QWEN_IDLE_SECONDS:-600}

if [ ! -x "$bench" ] || [ ! -f "$model_path" ]; then
    printf 'llama-bench and the model must both exist\n' >&2
    exit 2
fi
if pgrep -x llama-server >/dev/null 2>&1 || pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/repeatability-summary.tsv
printf 'arm\tflags\tdecode_tok_s\tstatus\tmclk_mhz_modal\tsclk_mhz_max\ttemp_c_max\tsamples\n' \
    >"$summary"

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

measurement_failed=0

run_arm() {
    arm_label=$1
    shift
    arm_log=$output_directory/$arm_label.log
    arm_samples=$output_directory/$arm_label.clocks.tsv
    printf 'arm_start_utc=%s arm=%s flags=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$*"
    "$clock_sampler" "$arm_samples" &
    sampler_pid=$!
    set +e
    nice -n 19 ionice -c 3 "$bench" -m "$model_path" \
        -ngl 99 -t 2 -r 3 -p 0 -n 64 -o md "$@" >"$arm_log" 2>&1
    arm_status=$?
    set -e
    stop_sampler
    if [ "$arm_status" -eq 0 ]; then
        decode=$(awk -F'|' '$0 ~ /\| *tg[0-9]+( @ d[0-9]+)? *\|/ {
                                split($(NF - 1), parts, /[^0-9.]+/)
                                for (i = 1; i <= 3; i++) {
                                    if (parts[i] != "") { rate = parts[i]; break }
                                }
                                spread = parts[i + 1]
                            }
                            END {
                                if (rate == "") { print "n/a" }
                                else { printf "%s+/-%s\n", rate, (spread == "" ? "0" : spread) }
                            }' "$arm_log")
    else
        decode=n/a
    fi
    clock_report=$(awk -F'\t' '
        { samples++ }
        $1 ~ /^[0-9]+([.][0-9]+)?$/ { count[$1]++; clock_samples++ }
        $2 ~ /^[0-9]+([.][0-9]+)?$/ {
          if ($2 + 0 > sclk_max) { sclk_max = $2 + 0 }
          sclk_samples++
        }
        $3 ~ /^[0-9]+([.][0-9]+)?$/ {
          if ($3 + 0 > temp_max) { temp_max = $3 + 0 }
          temperature_samples++
        }
        END {
            for (step in count) {
                if (count[step] > best) { best = count[step]; modal = step }
            }
            printf "%s\t%s\t%s\t%d",
                (clock_samples ? modal : "unavailable"),
                (sclk_samples ? sclk_max : "unavailable"),
                (temperature_samples ? sprintf("%.1f", temp_max / 1000) : "unavailable"),
                samples
        }' "$arm_samples")
    printf '%s\t%s\t%s\t%s\t%s\n' "$arm_label" "$*" "$decode" \
        "$arm_status" "$clock_report" >>"$summary"
    printf 'arm_stop_utc=%s arm=%s decode=%s status=%s clocks=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$decode" "$arm_status" \
        "$(printf '%s' "$clock_report" | tr '\t' ' ')"

    if [ "$arm_status" -ne 0 ] || [ "$decode" = n/a ]; then
        return 1
    fi
    return 0
}

# The ladder's flag set: cache types left at their f16 default and flash
# attention left at `auto`, which is why its table printed neither column.
run_arm ladder-flags || measurement_failed=1
run_arm hot-f16-fa-off -ctk f16 -ctv f16 -fa off || measurement_failed=1
run_arm hot-f16-fa-auto -ctk f16 -ctv f16 || measurement_failed=1

printf 'idle_start_utc=%s seconds=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$idle_seconds"
sleep "$idle_seconds"
printf 'idle_stop_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

run_arm cold-f16-fa-off -ctk f16 -ctv f16 -fa off || measurement_failed=1
run_arm cold-ladder-flags || measurement_failed=1

if [ "$measurement_failed" -ne 0 ]; then
    printf 'bench_repeatability=failed output_directory=%s\n' \
        "$output_directory" >&2
    cat "$summary"
    exit 1
fi

printf 'bench_repeatability=completed output_directory=%s\n' "$output_directory"
cat "$summary"
