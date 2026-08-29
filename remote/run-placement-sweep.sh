#!/bin/sh
set -eu

# Decode on this APU is bandwidth-bound, and the CPU and the iGPU do not reach
# the same bandwidth. This sweep measures every placement of the same weights
# against the same prompt and generation length: all layers on Vulkan, all on
# the two CPU cores, and the partial offloads between them. llama-bench runs
# without the guarded launch path, so these figures are the hardware's ceiling
# rather than the served rate, and the desktop cost of the winner is measured
# separately through the latency probe.

bench=${QWEN_LLAMA_BENCH:-"${HOME:?}/src/llama.cpp-qwen-apu/build-qwen-vulkan/bin/llama-bench"}
output=${1:-"${HOME:?}/qwen-model-comparison/placement-sweep.txt"}
prompt_tokens=${QWEN_BENCH_PROMPT:-512}
generate_tokens=${QWEN_BENCH_GENERATE:-64}
repetitions=${QWEN_BENCH_REPETITIONS:-2}

base_model=${QWEN_BASE_MODEL:-"${HOME:?}/models/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf"}
distill_model=${QWEN_DISTILL_MODEL:-"${HOME:?}/models/Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf"}
large_model=${QWEN_LARGE_MODEL:-"${HOME:?}/models/Qwen3.8-9B-Distill-GGUF/Qwen3.8-9B-Q4_K_M.gguf"}

if [ ! -x "$bench" ]; then
    printf 'llama-bench is not built at %s\n' "$bench" >&2
    exit 2
fi
if pgrep -x llama-server >/dev/null 2>&1; then
    printf 'a llama-server is running and would contend for the device\n' >&2
    exit 2
fi

mkdir -p "$(dirname -- "$output")"
: >"$output"

run_case() {
    case_label=$1
    case_model=$2
    shift 2
    if [ ! -f "$case_model" ]; then
        printf 'case=%s status=model_absent path=%s\n' \
            "$case_label" "$case_model" >>"$output"
        return 0
    fi
    printf '\n===== %s =====\n' "$case_label" >>"$output"
    "$bench" -m "$case_model" -p "$prompt_tokens" -n "$generate_tokens" \
        -r "$repetitions" "$@" 2>&1 |
        grep -E '^\| (model|qwen)' >>"$output" || true
}

# Placement ladder on the deployed checkpoint. -ngl 0 is CPU only, 99 is every
# layer on Vulkan, and the values between split the model across both.
run_case 'base placement ladder, 1 thread' "$base_model" \
    -ngl 0,9,18,27,99 -t 1
run_case 'base placement ladder, 2 threads' "$base_model" \
    -ngl 0,9,18,27,99 -t 2

# The three candidates under full Vulkan offload, which is the placement the
# guarded launch path deploys.
run_case 'qwen3.5-4B base, full Vulkan' "$base_model" -ngl 99 --device Vulkan0 -t 2
run_case 'qwen3.8-4B distill, full Vulkan' "$distill_model" -ngl 99 --device Vulkan0 -t 2
run_case 'qwen3.8-9B distill, full Vulkan' "$large_model" -ngl 99 --device Vulkan0 -t 2

printf '\nplacement_sweep=completed output=%s\n' "$output" >>"$output"
