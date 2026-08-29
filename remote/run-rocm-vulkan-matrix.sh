#!/bin/sh
set -eu

# Measure the HIP and Vulkan backends from one binary, one phase at a time.
#
# `build-llama-dual.sh` configures both backends against one source commit, so
# `llama-bench --device` selects between them and a difference between two rows
# is a difference between two backends. Prompt processing and token generation
# run as separate invocations with the unused side set to zero, because a
# combined run reports one elapsed time for two mechanisms and a change that
# moves only one of them stays invisible.
#
# Every HIP arm exports HSA_ENABLE_SDMA=0. With the copy engine enabled,
# `llama_model_loader::load_all_data` parks in `hipEventSynchronize` and never
# returns; evidence/rocm-h0-operational-failure.md records that stall and the
# 19-second run that the same binary completes once the variable is set.
#
# Each phase carries a timeout. A backend an order of magnitude outside the
# serving range answers the operational question by exceeding it, and a run that
# cannot finish inside the limit has already lost to the reference.

usage() {
    printf 'usage: %s [OUTPUT]\n' "$0" >&2
    printf '  QWEN_MODEL_PATH     checkpoint under test\n' >&2
    printf '  QWEN_MATRIX_TIMEOUT seconds per phase, default 600\n' >&2
    printf '  QWEN_MATRIX_REPS    repetitions per phase, default 1\n' >&2
    exit 2
}

[ "$#" -le 1 ] || usage

output_path=${1:-"${HOME:?}/qwen-model-comparison/rocm-vulkan-matrix.txt"}
model_path=${QWEN_MODEL_PATH:-"${HOME:?}/models/Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf"}
phase_timeout=${QWEN_MATRIX_TIMEOUT:-600}
repetitions=${QWEN_MATRIX_REPS:-1}
binary_directory=${QWEN_DUAL_BIN:-"${HOME:?}/src/llama.cpp-qwen-apu/build-qwen-dual/bin"}
rocm_path=${ROCM_PATH:-"${HOME:?}/.venvs/rocm-gfx900/lib/python3.12/site-packages/_rocm_sdk_devel"}

[ -f "$model_path" ] || { printf 'checkpoint is absent: %s\n' "$model_path" >&2; exit 1; }
[ -x "$binary_directory/llama-bench" ] || {
    printf 'dual-backend llama-bench is absent: %s\n' "$binary_directory" >&2
    printf 'build it with remote/build-llama-dual.sh\n' >&2
    exit 1
}

mkdir -p "$(dirname -- "$output_path")"

# Measurement runs under the policy the appliance serves under. The launch chain
# puts inference at nice 19 with idle I/O so the desktop's own work preempts it,
# and a benchmark at normal priority measures a machine the service never
# becomes. The laptop is in use while these run, which is the same reason.
renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true

model_digest=$(sha256sum "$model_path" | cut -d' ' -f1)
# llama-bench prints its `build:` line with the result table rather than under a
# version flag, so provenance reads from the source tree the binary came from.
# The patch series this repository applies means the revision alone names a
# different tree, and the worktree state travels with it.
source_directory=${QWEN_LLAMA_SOURCE:-"${HOME:?}/src/llama.cpp-qwen-apu"}
source_commit=$(git -C "$source_directory" rev-parse HEAD 2>/dev/null || echo unknown)
source_worktree=clean
if [ -n "$(git -C "$source_directory" status --porcelain 2>/dev/null)" ]; then
    source_worktree=dirty
fi

{
    printf 'matrix_run model=%s\n' "$(basename -- "$model_path")"
    printf 'model_sha256=%s\n' "$model_digest"
    printf 'llama_commit=%s worktree=%s\n' "$source_commit" "$source_worktree"
    printf 'phase_timeout_seconds=%s repetitions=%s\n' "$phase_timeout" "$repetitions"
    printf 'scheduling=nice_19_idle_io\n'
} | tee "$output_path"

# One arm is a label, a binary, a device, a ggml thread count, and the
# environment that selects its kernels. The phase pair is identical across arms
# so the rows compare directly.
run_arm() {
    arm_label=$1
    arm_binary=$2
    arm_device=$3
    arm_threads=$4
    arm_phases=$5
    shift 5

    if [ ! -x "$arm_binary" ]; then
        printf '\narm=%s state=absent binary=%s\n' "$arm_label" "$arm_binary" |
            tee -a "$output_path"
        return 0
    fi

    for phase_arguments in $arm_phases; do
        phase_arguments=$(echo "$phase_arguments" | tr '_' ' ')
        {
            printf '\n===== %s %s =====\n' "$arm_label" "$phase_arguments"
        } | tee -a "$output_path"

        start_seconds=$(date +%s)
        if env "$@" timeout "$phase_timeout" \
            "$arm_binary" \
            -m "$model_path" --device "$arm_device" -ngl 99 \
            $phase_arguments -t "$arm_threads" -r "$repetitions" 2>&1 |
            grep -vE '^(ggml_cuda_init|ggml_vulkan|  Device)' | tee -a "$output_path"
        then
            elapsed_seconds=$(( $(date +%s) - start_seconds ))
            printf 'arm=%s phase="%s" threads=%s state=completed seconds=%s\n' \
                "$arm_label" "$phase_arguments" "$arm_threads" "$elapsed_seconds" |
                tee -a "$output_path"
        else
            elapsed_seconds=$(( $(date +%s) - start_seconds ))
            printf 'arm=%s phase="%s" threads=%s state=timeout seconds=%s\n' \
                "$arm_label" "$phase_arguments" "$arm_threads" "$elapsed_seconds" |
                tee -a "$output_path"
        fi
    done
}

hip_library_path=$rocm_path/lib:$rocm_path/lib64:${LD_LIBRARY_PATH:-}
mmq_binary=${QWEN_MMQ_BIN:-"${HOME:?}/src/llama.cpp-qwen-apu/build-qwen-dual-gfx900-mmq/bin"}/llama-bench

both_phases='-p_512_-n_0 -p_0_-n_64'
decode_phase='-p_0_-n_64'

run_arm 'V  RADV Vulkan reference' \
    "$binary_directory/llama-bench" Vulkan0 2 "$both_phases"

run_arm 'H0 gfx900 override, automatic kernels' \
    "$binary_directory/llama-bench" ROCm0 2 "$both_phases" \
    "ROCM_PATH=$rocm_path" "LD_LIBRARY_PATH=$hip_library_path" \
    HSA_OVERRIDE_GFX_VERSION=9.0.0 HSA_ENABLE_SDMA=0

# HSA parks the calling thread in BusyWaitSignal rather than sleeping on the
# completion signal, so a HIP arm holds one of this machine's two cores before
# ggml asks for any. Asking for one thread instead of two removes the
# oversubscription that the RADV arm never has, which separates host contention
# from kernel quality in the decode deficit.
run_arm 'H0t1 gfx900 override, one ggml thread' \
    "$binary_directory/llama-bench" ROCm0 1 "$decode_phase" \
    "ROCM_PATH=$rocm_path" "LD_LIBRARY_PATH=$hip_library_path" \
    HSA_OVERRIDE_GFX_VERSION=9.0.0 HSA_ENABLE_SDMA=0

# GGML_CUDA_FORCE_MMQ is compiled in, so the kernel-policy arm is its own tree.
# It routes batched quantized matrix multiplication through ggml's kernels
# rather than dequantize plus rocBLAS, which reaches prefill; decode at batch
# one goes through mul_mat_vec_q either way.
run_arm 'H1 gfx900 override, forced MMQ kernels' \
    "$mmq_binary" ROCm0 2 "$both_phases" \
    "ROCM_PATH=$rocm_path" "LD_LIBRARY_PATH=$hip_library_path" \
    HSA_OVERRIDE_GFX_VERSION=9.0.0 HSA_ENABLE_SDMA=0

printf '\nmatrix_run=completed output=%s\n' "$output_path" | tee -a "$output_path"
