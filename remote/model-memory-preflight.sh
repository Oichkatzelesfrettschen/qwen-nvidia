#!/bin/sh
set -eu

# Report host and device memory headroom for a load, and admit it either way.
#
# The device here is discrete, so its memory is its own rather than a carve-out
# of system RAM: NVML reports total and used bytes over
# `nvidia-smi --query-gpu=memory.total,memory.used`, and what is free for a
# model is the difference less the margin a compositor and a driver context
# need beyond the arithmetic. That inverts the APU arithmetic this file carried,
# where the Vulkan heap and MemAvailable named the same memory and charging both
# counted the weights twice.
#
# The host side charges the mapping rather than the weights. A discrete load
# streams the file into device memory through a mapping whose pages are
# reclaimable and which MemAvailable already counts, so DESKTOP_RESERVE_MIB is
# what the launch asks the host to keep free rather than a second copy of the
# model.
#
# These figures are reported and never withheld from a launch. A prediction that
# a model will not fit is a prediction, and the APU's version of this file was
# wrong in exactly that way: it refused a 9B on arithmetic that charged the
# weights twice, and the refusal read as a hardware limit rather than as the
# bug it was. The load itself is the honest test, and a load that fails says so
# at once and says why. A caller that needs a gate reads
# `device_budget_headroom` and makes the refusal its own.

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    printf 'usage: %s MODEL_PATH REQUIRED_DEVICE_MIB [DESKTOP_RESERVE_MIB [DEVICE_MARGIN_MIB]]\n' "$0" >&2
    exit 2
fi

model_path=$1
required_device_mib=$2
desktop_reserve_mib=${3:-4096}
device_margin_mib=${4:-768}
device_index=${QWEN_NVIDIA_DEVICE_INDEX:-0}

case $required_device_mib:$desktop_reserve_mib:$device_margin_mib in
    *[!0-9:]* | :* | *::*)
        printf 'memory arguments must be non-negative integer MiB values\n' >&2
        exit 2
        ;;
esac

if [ ! -f "$model_path" ]; then
    printf 'model is not a regular file: %s\n' "$model_path" >&2
    exit 2
fi

command -v nvidia-smi >/dev/null 2>&1 || {
    printf 'nvidia-smi is absent from PATH\n' >&2
    exit 1
}

device_report=$(nvidia-smi --id="$device_index" \
    --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits)
device_name=$(printf '%s' "$device_report" | awk -F', *' '{ print $1 }')
device_total_mib=$(printf '%s' "$device_report" | awk -F', *' '{ print $2 }')
device_used_mib=$(printf '%s' "$device_report" | awk -F', *' '{ print $3 }')

case $device_total_mib:$device_used_mib in
    *[!0-9:]* | :* | *::*)
        printf 'NVML did not report integer memory figures: %s\n' \
            "$device_report" >&2
        exit 1
        ;;
esac

mib_bytes=1048576
mem_available_kib=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)
swap_total_kib=$(awk '$1 == "SwapTotal:" { print $2 }' /proc/meminfo)
swap_free_kib=$(awk '$1 == "SwapFree:" { print $2 }' /proc/meminfo)
model_bytes=$(wc -c < "$model_path")
mem_available_bytes=$((mem_available_kib * 1024))
swap_used_bytes=$(((swap_total_kib - swap_free_kib) * 1024))

device_total_bytes=$((device_total_mib * mib_bytes))
device_used_bytes=$((device_used_mib * mib_bytes))
device_available_bytes=$((device_total_bytes - device_used_bytes))
required_device_bytes=$((required_device_mib * mib_bytes))
device_margin_bytes=$((device_margin_mib * mib_bytes))
required_device_with_margin_bytes=$((required_device_bytes + device_margin_bytes))
required_host_bytes=$((desktop_reserve_mib * mib_bytes))

printf 'device_name=%s\n' "$device_name"
printf 'device_total_bytes=%s\n' "$device_total_bytes"
printf 'device_used_bytes=%s\n' "$device_used_bytes"
printf 'device_available_bytes=%s\n' "$device_available_bytes"
printf 'model_bytes=%s\n' "$model_bytes"
printf 'mem_available_bytes=%s\n' "$mem_available_bytes"
printf 'required_host_bytes=%s\n' "$required_host_bytes"
printf 'required_device_bytes=%s\n' "$required_device_bytes"
printf 'device_margin_bytes=%s\n' "$device_margin_bytes"
printf 'required_device_with_margin_bytes=%s\n' "$required_device_with_margin_bytes"
printf 'swap_used_bytes=%s\n' "$swap_used_bytes"

if [ "$mem_available_bytes" -lt "$required_host_bytes" ]; then
    printf 'host_memory_headroom=short shortfall_bytes=%s\n' \
        "$((required_host_bytes - mem_available_bytes))"
else
    printf 'host_memory_headroom=ample surplus_bytes=%s\n' \
        "$((mem_available_bytes - required_host_bytes))"
fi

if [ "$device_available_bytes" -lt "$required_device_with_margin_bytes" ]; then
    printf 'device_budget_headroom=short shortfall_bytes=%s\n' \
        "$((required_device_with_margin_bytes - device_available_bytes))"
else
    printf 'device_budget_headroom=ample surplus_bytes=%s\n' \
        "$((device_available_bytes - required_device_with_margin_bytes))"
fi

printf 'model_memory_preflight=observe\n'
