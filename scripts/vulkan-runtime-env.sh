#!/bin/sh
set -eu

# Configure the environment for the Vulkan fallback backend and exec the server.
#
# CUDA is this host's serving backend and Vulkan is the fallback the same binary
# reaches: scripts/build-llama-cuda.sh puts both in one llama-server, which
# enumerates CUDA0 and Vulkan0 for the same card. Naming the device is what
# keeps the two apart, so qwen-capacity-policy.sh passes `--device Vulkan0` with
# this wrapper and `--device CUDA0` with cuda-runtime-env.sh.
#
# The ICD pin narrows the Vulkan loader to one driver. A loader left to search
# enumerates every installed ICD, and a software rasterizer answering as a
# device is a fallback that allocates on the host and reports success.
#
# Scheduling matches cuda-runtime-env.sh rather than the wrapper this file
# replaces: nice 0 across the online CPU set. Pinning one core at nice 19 was
# the policy of a two-core part whose desktop needed the other core, and it
# costs throughput on twelve threads beside a discrete card.

if [ "$#" -eq 0 ]; then
    printf 'usage: %s COMMAND [ARG ...]\n' "$0" >&2
    exit 2
fi

serving_nice=${QWEN_SERVING_NICE:-0}
serving_cpu_list=${QWEN_SERVING_CPU_LIST:-$(cat /sys/devices/system/cpu/online 2>/dev/null || echo 0)}

renice -n "$serving_nice" -p $$ >/dev/null 2>&1 || {
    printf 'renice to %s failed\n' "$serving_nice" >&2
    exit 1
}
taskset -pc "$serving_cpu_list" $$ >/dev/null 2>&1 || {
    printf 'taskset to %s failed\n' "$serving_cpu_list" >&2
    exit 1
}
export QWEN_SERVING_NICE="$serving_nice"
export QWEN_SERVING_CPU_LIST="$serving_cpu_list"

vulkan_icd=${QWEN_VULKAN_ICD:-/usr/share/vulkan/icd.d/nvidia_icd.json}
if [ ! -r "$vulkan_icd" ]; then
    printf 'Vulkan ICD is not readable: %s\n' "$vulkan_icd" >&2
    exit 1
fi

# The unset block below scrubs the ambient environment so a named profile
# always means one thing. `custom` still needs its inputs, so record them
# before the scrub and restore them from these copies afterwards.
requested_max_nodes_per_submit=${GGML_VK_MAX_NODES_PER_SUBMIT:-}
requested_serialize_submissions=${GGML_VK_SERIALIZE_SUBMISSIONS:-}
requested_allow_graphics_queue=${GGML_VK_ALLOW_GRAPHICS_QUEUE:-}
requested_submit_trace=${GGML_VK_SUBMIT_TRACE:-}
requested_low_priority=${GGML_VK_LOW_PRIORITY:-}
requested_submit_trace_buffers=${GGML_VK_SUBMIT_TRACE_BUFFERS:-}
requested_submit_trace_ring_size=${GGML_VK_SUBMIT_TRACE_RING_SIZE:-}
requested_submit_trace_name_size=${GGML_VK_SUBMIT_TRACE_NAME_SIZE:-}
requested_duty_cycle_percent=${GGML_VK_DUTY_CYCLE_PERCENT:-}

unset DISPLAY
unset WAYLAND_DISPLAY
unset QWEN_ONE_CORE_ACTIVE
unset QWEN_GUARD_CPU_ACTIVE
unset AMD_PRIORITY
unset AMD_DEBUG
unset DRI_PRIME
unset MESA_VK_DEVICE_SELECT
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
unset GGML_VK_LOW_PRIORITY
unset GGML_VK_MAX_DEVICES
unset GGML_VK_NAME
unset GGML_VK_SUBMIT_TRACE_BUFFERS
unset GGML_VK_SUBMIT_TRACE_NAME_SIZE
unset GGML_VK_SUBMIT_TRACE_RING_SIZE
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

export VK_DRIVER_FILES="$vulkan_icd"
export VK_ICD_FILENAMES="$vulkan_icd"
export LLAMA_NO_CPU_FALLBACK=1

# The profile vocabulary is the CUDA wrapper's: `default` exports nothing beyond
# the scrub and `custom` restores what the caller asked for. The submission
# profiles this wrapper carried -- paced-60, low-serialized, low-async -- were
# measured against the prior host's Vulkan driver on a two-compute-unit part
# and name settings no run on this device has moved.
vulkan_profile=${QWEN_VULKAN_PROFILE:-default}
case $vulkan_profile in
    default)
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
        # patches/llama-vulkan-low-priority.patch reads this name to request a
        # LOW global queue priority. No arm on this device has measured it, so
        # `default` leaves it absent and only a caller asking for it gets it.
        if [ -n "$requested_low_priority" ]; then
            export GGML_VK_LOW_PRIORITY=$requested_low_priority
        fi
        # patches/llama-vulkan-submit-trace.patch sizes its ring from these
        # three, which are useless without GGML_VK_SUBMIT_TRACE above and are
        # restored beside it so one arm sets the whole tuple.
        if [ -n "$requested_submit_trace_buffers" ]; then
            export GGML_VK_SUBMIT_TRACE_BUFFERS=$requested_submit_trace_buffers
        fi
        if [ -n "$requested_submit_trace_ring_size" ]; then
            export GGML_VK_SUBMIT_TRACE_RING_SIZE=$requested_submit_trace_ring_size
        fi
        if [ -n "$requested_submit_trace_name_size" ]; then
            export GGML_VK_SUBMIT_TRACE_NAME_SIZE=$requested_submit_trace_name_size
        fi
        # patches/llama-vulkan-duty-cycle.patch reads this name and refuses a
        # value without GGML_VK_SERIALIZE_SUBMISSIONS, so the two travel
        # together through `custom` or neither reaches the server.
        if [ -n "$requested_duty_cycle_percent" ]; then
            export GGML_VK_DUTY_CYCLE_PERCENT=$requested_duty_cycle_percent
        fi
        ;;
    *)
        printf 'unknown Vulkan profile: %s\n' "$vulkan_profile" >&2
        exit 2
        ;;
esac
export QWEN_VULKAN_PROFILE=$vulkan_profile

exec "$@"
