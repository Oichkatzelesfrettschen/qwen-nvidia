#!/bin/sh
set -eu

# Measure prefill and decode for every named checkpoint twice, forward and then
# reverse, through one llama-bench build on the CUDA backend.
#
# The mirrored order is what makes the pair readable. A rate measured once
# carries its position in the sweep: the device warms, the compositor takes the
# card back between arms, and the boost clock falls as the power budget is
# spent. Measuring each checkpoint at position i and again at position n-i puts
# the same checkpoint at both ends of whatever drift the sweep has, so the
# paired mean is the reported figure and the forward-to-reverse span is the
# sweep's own instability rather than a property of the checkpoint.
#
# The default flags name the serving tuple rather than llama-bench's defaults:
# full offload, flash attention on, and the K and V cache types scripts/models.tsv
# serves at, so a rate here is the rate the appliance's own allocation reaches.
# That mixed q8_0/q4_0 pair requires a build carrying GGML_CUDA_FA_ALL_QUANTS.
#
# Every arm samples device telemetry beside its own log, because a rate whose
# clock, power, and utilisation state went unrecorded cannot be compared to a
# later one.
#
# The arm names its tensor placement explicitly. The wrapper exports
# LLAMA_NO_CPU_FALLBACK=1, which patches/llama-no-cpu-fallback.patch turns into
# a refusal to load anything the CPU would hold, and llama-bench at -ngl 99
# alone still places a buffer there and is refused. `-ot .*=DEVICE` is what
# qwen-capacity-policy.sh gives the server, so the bench arm and the serving
# path place tensors the same way.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY MODEL_PATH [MODEL_PATH...]\n' "$0" >&2
    printf '  QWEN_LLAMA_BENCH     llama-bench built with CUDA\n' >&2
    printf '  QWEN_BENCH_DEVICE    llama-bench --device value, default CUDA0\n' >&2
    printf '  QWEN_BENCH_PREFILL   prompt tokens, default 512\n' >&2
    printf '  QWEN_BENCH_GENERATE  generated tokens, default 128\n' >&2
    printf '  QWEN_BENCH_REPEATS   repetitions per arm, default 3\n' >&2
    printf '  QWEN_BENCH_THREADS   host threads, default 6\n' >&2
    printf '  QWEN_CACHE_TYPE_K    K cache type, default q8_0\n' >&2
    printf '  QWEN_CACHE_TYPE_V    V cache type, default q4_0\n' >&2
    printf '  QWEN_FLASH_ATTENTION llama-bench -fa value, default 1\n' >&2
    exit 2
}

[ "$#" -ge 2 ] || usage

output_directory=$1
shift

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bench=${QWEN_LLAMA_BENCH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-bench"}
clock_sampler=${QWEN_CLOCK_SAMPLER:-"$script_directory/sample-nvidia-clocks.sh"}
bench_device=${QWEN_BENCH_DEVICE:-CUDA0}
prefill_tokens=${QWEN_BENCH_PREFILL:-512}
generate_tokens=${QWEN_BENCH_GENERATE:-128}
bench_repeats=${QWEN_BENCH_REPEATS:-3}
bench_threads=${QWEN_BENCH_THREADS:-6}
cache_type_k=${QWEN_CACHE_TYPE_K:-q8_0}
cache_type_v=${QWEN_CACHE_TYPE_V:-q4_0}
flash_attention=${QWEN_FLASH_ATTENTION:-1}
# Every arm runs through the same wrapper the appliance serves under, so a
# QWEN_CUDA_PROFILE arm measures what that profile exports rather than the
# ambient environment: the wrapper scrubs every GGML_CUDA_* name before it
# applies one.
runtime_wrapper=${QWEN_RUNTIME_WRAPPER:-"$script_directory/cuda-runtime-env.sh"}
[ -x "$runtime_wrapper" ] || {
    printf 'runtime wrapper is absent or not executable: %s\n' "$runtime_wrapper" >&2
    exit 2
}

[ -x "$bench" ] || {
    printf 'llama-bench is absent or not executable: %s\n' "$bench" >&2
    exit 2
}
for model_path in "$@"; do
    [ -f "$model_path" ] || {
        printf 'model file is absent: %s\n' "$model_path" >&2
        exit 2
    }
done
if pgrep -x llama-server >/dev/null 2>&1 || pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/baseline-summary.tsv
printf 'slot\tdirection\tmodel_id\tprefill_tok_s\tdecode_tok_s\tstatus\tsm_clock_mhz_max\tmemory_used_mib_max\tpower_w_max\ttemp_c_max\tthrottled_samples\tsamples\n' \
    >"$summary"

# The binary is named and hashed because two build trees of the same commit
# differ by their configure flags, and a rate read later cannot ask which one
# produced it.
printf 'sweep_start_utc=%s device=%s profile=%s bench=%s bench_sha256=%s flags=-ngl 99 -fa %s -ctk %s -ctv %s -p %s -n %s -r %s -t %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$bench_device" \
    "${QWEN_CUDA_PROFILE:-default}" "$bench" \
    "$(sha256sum "$bench" | cut -d ' ' -f 1)" "$flash_attention" \
    "$cache_type_k" "$cache_type_v" "$prefill_tokens" "$generate_tokens" \
    "$bench_repeats" "$bench_threads" | tee "$output_directory/sweep-metadata.txt"

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

slot_index=0
sweep_failed=0

# A row for another token count cannot satisfy the requested arm, so the label
# is matched exactly and a missing or duplicated row stays n/a.
extract_rate() {
    awk -F'|' -v label="$1" '
        $0 ~ ("\\| *" label "( @ d[0-9]+)? *\\|") {
            split($(NF - 1), parts, /[^0-9.]+/)
            for (i = 1; i <= 3; i++) {
                if (parts[i] != "") { rate = parts[i]; break }
            }
            matches++
        }
        END { print (matches == 1 && rate != "") ? rate : "n/a" }
    ' "$2"
}

run_arm() {
    direction=$1
    model_path=$2
    model_id=$(basename "$model_path" .gguf)
    slot_index=$((slot_index + 1))
    arm_label=$(printf '%02d-%s-%s' "$slot_index" "$direction" "$model_id")
    arm_log=$output_directory/$arm_label.log
    arm_samples=$output_directory/$arm_label.clocks.tsv

    printf 'arm_start_utc=%s slot=%s direction=%s model=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slot_index" "$direction" "$model_id"

    "$clock_sampler" "$arm_samples" 1 &
    sampler_pid=$!
    set +e
    "$runtime_wrapper" "$bench" -m "$model_path" --device "$bench_device" \
        -ngl 99 -ot ".*=$bench_device" -fa "$flash_attention" \
        -ctk "$cache_type_k" -ctv "$cache_type_v" \
        -p "$prefill_tokens" -n "$generate_tokens" \
        -r "$bench_repeats" -t "$bench_threads" -o md >"$arm_log" 2>&1
    arm_status=$?
    set -e
    stop_sampler

    prefill=n/a
    decode=n/a
    if [ "$arm_status" -eq 0 ]; then
        prefill=$(extract_rate "pp$prefill_tokens" "$arm_log")
        decode=$(extract_rate "tg$generate_tokens" "$arm_log")
    fi

    telemetry=$(awk -F'\t' '
        { samples++ }
        $1 ~ /^[0-9]+$/ && $1 + 0 > sm_max { sm_max = $1 + 0 }
        $7 ~ /^[0-9]+$/ && $7 + 0 > memory_max { memory_max = $7 + 0 }
        $4 ~ /^[0-9.]+$/ && $4 + 0 > power_max { power_max = $4 + 0 }
        $3 ~ /^[0-9]+$/ && $3 + 0 > temp_max { temp_max = $3 + 0 }
        $9 ~ /^0x0*[1-9a-fA-F]/ { throttled++ }
        END {
            printf "%s\t%s\t%s\t%s\t%d\t%d",
                (samples ? sm_max : "unavailable"),
                (samples ? memory_max : "unavailable"),
                (samples ? sprintf("%.2f", power_max) : "unavailable"),
                (samples ? temp_max : "unavailable"),
                throttled, samples
        }' "$arm_samples")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$slot_index" "$direction" "$model_id" "$prefill" "$decode" \
        "$arm_status" "$telemetry" >>"$summary"
    printf 'arm_stop_utc=%s slot=%s model=%s prefill=%s decode=%s status=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$slot_index" "$model_id" \
        "$prefill" "$decode" "$arm_status"

    if [ "$arm_status" -ne 0 ] || [ "$prefill" = n/a ] || [ "$decode" = n/a ]; then
        sweep_failed=1
    fi
}

for model_path in "$@"; do
    run_arm forward "$model_path"
done

reversed_models=''
for model_path in "$@"; do
    reversed_models="$model_path${reversed_models:+ }$reversed_models"
done
for model_path in $reversed_models; do
    run_arm reverse "$model_path"
done

printf '\npaired means, forward and reverse:\n'
awk -F'\t' 'NR > 1 && $6 == 0 && $4 != "n/a" && $5 != "n/a" {
        prefill[$3] += $4; decode[$3] += $5; count[$3]++
        if (prefill_min[$3] == "" || $4 + 0 < prefill_min[$3]) { prefill_min[$3] = $4 + 0 }
        if (prefill_max[$3] == "" || $4 + 0 > prefill_max[$3]) { prefill_max[$3] = $4 + 0 }
        if (decode_min[$3] == "" || $5 + 0 < decode_min[$3]) { decode_min[$3] = $5 + 0 }
        if (decode_max[$3] == "" || $5 + 0 > decode_max[$3]) { decode_max[$3] = $5 + 0 }
    }
    END {
        printf "%-40s %12s %12s %10s %10s\n", "model_id", "prefill", "decode", "pp_span%", "tg_span%"
        for (id in count) {
            printf "%-40s %12.2f %12.2f %9.1f%% %9.1f%%\n", id,
                prefill[id] / count[id], decode[id] / count[id],
                100 * (prefill_max[id] - prefill_min[id]) / prefill_min[id],
                100 * (decode_max[id] - decode_min[id]) / decode_min[id]
        }
    }' "$summary" | tee "$output_directory/paired-means.txt"

printf 'sweep_stop_utc=%s failed=%s summary=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sweep_failed" "$summary"
exit "$sweep_failed"
