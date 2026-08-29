#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
    printf 'usage: %s COMMAND [ARG ...]\n' "$0" >&2
    exit 2
fi

renice -n 19 -p $$ >/dev/null
# Inference holds one core and the desktop keeps the other. Which core is
# measurable rather than obvious: /proc/interrupts puts the keyboard, touchpad,
# and GPIO controller entirely on CPU0, and amdgpu's own completion interrupts
# three-to-one on CPU1. Input latency and GPU-completion latency therefore pull
# in opposite directions, and QWEN_INFERENCE_CPU lets the probe decide.
inference_cpu=${QWEN_INFERENCE_CPU:-0}
taskset -pc "$inference_cpu" $$ >/dev/null
ionice -c 3 -p $$

radv_icd=${QWEN_RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}
if [ ! -r "$radv_icd" ]; then
    printf 'RADV ICD is not readable: %s\n' "$radv_icd" >&2
    exit 1
fi

# The unset block below scrubs the ambient environment so a named profile
# always means one thing. `custom` still needs its inputs, so record them
# before the scrub and restore them from these copies afterwards.
requested_max_nodes_per_submit=${GGML_VK_MAX_NODES_PER_SUBMIT:-}
requested_serialize_submissions=${GGML_VK_SERIALIZE_SUBMISSIONS:-}
requested_allow_graphics_queue=${GGML_VK_ALLOW_GRAPHICS_QUEUE:-}
requested_submit_trace=${GGML_VK_SUBMIT_TRACE:-}

unset DISPLAY
unset WAYLAND_DISPLAY
unset QWEN_ONE_CORE_ACTIVE
unset QWEN_GUARD_CPU_ACTIVE
unset AMD_PRIORITY
unset AMD_DEBUG
unset DRI_PRIME
unset MESA_VK_DEVICE_SELECT
unset RADV_DEBUG
unset RADV_PERFTEST
unset VK_ADD_LAYER_PATH
unset VK_INSTANCE_LAYERS
unset VK_LAYER_PATH
unset VK_LOADER_LAYERS_ENABLE
unset GGML_VK_ALLOW_GRAPHICS_QUEUE
unset GGML_VK_ALLOW_SYSMEM_FALLBACK
unset GGML_VK_ASYNC_USE_TRANSFER_QUEUE
unset GGML_VK_DEBUG_MARKERS
unset GGML_VK_DISABLE_ASYNC
unset GGML_VK_DISABLE_BFLOAT16
unset GGML_VK_DISABLE_COOPMAT
unset GGML_VK_DISABLE_COOPMAT2
unset GGML_VK_DISABLE_COOPMAT2_DECODE_VECTOR
unset GGML_VK_DISABLE_DOT2
unset GGML_VK_DISABLE_F16
unset GGML_VK_DISABLE_FUSION
unset GGML_VK_DISABLE_GRAPH_OPTIMIZE
unset GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM
unset GGML_VK_DISABLE_INTEGER_DOT_PRODUCT
unset GGML_VK_DISABLE_MMVQ
unset GGML_VK_DISABLE_MULTI_ADD
unset GGML_VK_DISABLE_OCP_FP4
unset GGML_VK_DUTY_CYCLE_PERCENT
unset GGML_VK_ENABLE_MEMORY_PRIORITY
unset GGML_VK_FORCE_MAX_ALLOCATION_SIZE
unset GGML_VK_FORCE_MAX_BUFFER_SIZE
unset GGML_VK_FORCE_MMVQ
unset GGML_VK_MEMORY_LOGGER
unset GGML_VK_SERIALIZE_SUBMISSIONS
unset GGML_VK_MAX_NODES_PER_SUBMIT
unset GGML_VK_PERF_LOGGER
unset GGML_VK_PERF_LOGGER_CONCURRENT
unset GGML_VK_PERF_LOGGER_FREQUENCY
unset GGML_VK_PIPELINE_STATS
unset GGML_VK_PREFER_HOST_MEMORY
unset GGML_VK_SUBALLOCATION_BLOCK_SIZE
unset GGML_VK_SUBMIT_TRACE
unset GGML_VK_SYNC_LOGGER
unset GGML_VK_VISIBLE_DEVICES

export VK_DRIVER_FILES="$radv_icd"
export VK_ICD_FILENAMES="$radv_icd"
export GGML_VK_LOW_PRIORITY=1
export LLAMA_NO_CPU_FALLBACK=1

vulkan_profile=${QWEN_VULKAN_PROFILE:-low-serialized}
case $vulkan_profile in
    paced-60)
        export GGML_VK_DUTY_CYCLE_PERCENT=60
        export GGML_VK_SERIALIZE_SUBMISSIONS=1
        export GGML_VK_MAX_NODES_PER_SUBMIT=32
        ;;
    low-serialized)
        export GGML_VK_SERIALIZE_SUBMISSIONS=1
        export GGML_VK_MAX_NODES_PER_SUBMIT=32
        ;;
    low-async)
        export GGML_VK_MAX_NODES_PER_SUBMIT=16
        ;;
    custom)
        # The named profiles fix both submission settings together, which makes
        # them useless for measuring either one alone. `custom` restores only
        # what the caller asked for, so a sweep can vary node count and
        # serialization independently and attribute the result.
        if [ -n "$requested_max_nodes_per_submit" ]; then
            export GGML_VK_MAX_NODES_PER_SUBMIT=$requested_max_nodes_per_submit
        fi
        if [ -n "$requested_serialize_submissions" ]; then
            export GGML_VK_SERIALIZE_SUBMISSIONS=$requested_serialize_submissions
        fi
        if [ -n "$requested_allow_graphics_queue" ]; then
            export GGML_VK_ALLOW_GRAPHICS_QUEUE=$requested_allow_graphics_queue
        fi
        if [ -n "$requested_submit_trace" ]; then
            export GGML_VK_SUBMIT_TRACE=$requested_submit_trace
        fi
        ;;
    *)
        printf 'unknown Vulkan profile: %s\n' "$vulkan_profile" >&2
        exit 2
        ;;
esac
export QWEN_VULKAN_PROFILE=$vulkan_profile

exec "$@"
