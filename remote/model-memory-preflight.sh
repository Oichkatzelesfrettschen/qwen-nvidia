#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
    printf 'usage: %s MODEL_PATH REQUIRED_VULKAN_MIB [DESKTOP_RESERVE_MIB [VULKAN_MARGIN_MIB]]\n' "$0" >&2
    exit 2
fi

model_path=$1
required_vulkan_mib=$2
desktop_reserve_mib=${3:-4096}
vulkan_margin_mib=${4:-512}

case $required_vulkan_mib:$desktop_reserve_mib:$vulkan_margin_mib in
    *[!0-9:]* | :* | *::*)
        printf 'memory arguments must be non-negative integer MiB values\n' >&2
        exit 2
        ;;
esac

if [ ! -f "$model_path" ]; then
    printf 'model is not a regular file: %s\n' "$model_path" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
budget_probe=$temporary_directory/vulkan-memory-budget-probe

cc -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
    "$script_directory/vulkan-memory-budget-probe.c" -lvulkan -o "$budget_probe"

radv_icd=${QWEN_RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}
budget_output=$(
    env DISPLAY= WAYLAND_DISPLAY= VK_DRIVER_FILES="$radv_icd" VK_ICD_FILENAMES="$radv_icd" \
        "$budget_probe"
)
printf '%s\n' "$budget_output"
printf '%s\n' "$budget_output" | grep -F 'device_name=AMD Radeon Graphics (RADV RAVEN2)' >/dev/null

aggregate_available_bytes=$(printf '%s\n' "$budget_output" | awk -F= '$1 == "aggregate_available_bytes" { print $2 }')
if [ -z "$aggregate_available_bytes" ]; then
    printf 'Vulkan budget probe did not report aggregate availability\n' >&2
    exit 1
fi

mem_available_kib=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)
swap_total_kib=$(awk '$1 == "SwapTotal:" { print $2 }' /proc/meminfo)
swap_free_kib=$(awk '$1 == "SwapFree:" { print $2 }' /proc/meminfo)
model_bytes=$(wc -c < "$model_path")

mib_bytes=1048576
required_vulkan_bytes=$((required_vulkan_mib * mib_bytes))
desktop_reserve_bytes=$((desktop_reserve_mib * mib_bytes))
vulkan_margin_bytes=$((vulkan_margin_mib * mib_bytes))
mem_available_bytes=$((mem_available_kib * 1024))
# The Vulkan heap on an APU is carved from system RAM, so required_vulkan_bytes
# already covers the resident weights. The file reaches those buffers through a
# mapping whose pages are reclaimable and which MemAvailable already counts.
# Measured on a live server holding 2.74 GB of weights: 229 MB resident, no
# swap. Charging model_bytes on top counted the weights a second time.
required_host_bytes=$((required_vulkan_bytes + desktop_reserve_bytes))
required_vulkan_with_margin_bytes=$((required_vulkan_bytes + vulkan_margin_bytes))
swap_used_bytes=$(((swap_total_kib - swap_free_kib) * 1024))

printf 'model_bytes=%s\n' "$model_bytes"
printf 'mem_available_bytes=%s\n' "$mem_available_bytes"
printf 'required_host_bytes=%s\n' "$required_host_bytes"
printf 'desktop_reserve_bytes=%s\n' "$desktop_reserve_bytes"
printf 'required_vulkan_bytes=%s\n' "$required_vulkan_bytes"
printf 'vulkan_margin_bytes=%s\n' "$vulkan_margin_bytes"
printf 'required_vulkan_with_margin_bytes=%s\n' "$required_vulkan_with_margin_bytes"
printf 'swap_used_bytes=%s\n' "$swap_used_bytes"

# These figures are reported and never withheld from a launch. A prediction that
# a model will not fit is a prediction, and this one was wrong: it refused
# Qwen3.8-9B on arithmetic that charged the weights twice, and the refusal read
# as a hardware limit rather than as the bug it was. The load itself is the
# honest test, and a load that fails says so at once and says why.
if [ "$mem_available_bytes" -lt "$required_host_bytes" ]; then
    printf 'host_memory_headroom=short shortfall_bytes=%s\n' \
        "$((required_host_bytes - mem_available_bytes))"
else
    printf 'host_memory_headroom=ample surplus_bytes=%s\n' \
        "$((mem_available_bytes - required_host_bytes))"
fi

if [ "$aggregate_available_bytes" -lt "$required_vulkan_with_margin_bytes" ]; then
    printf 'vulkan_budget_headroom=short shortfall_bytes=%s\n' \
        "$((required_vulkan_with_margin_bytes - aggregate_available_bytes))"
else
    printf 'vulkan_budget_headroom=ample surplus_bytes=%s\n' \
        "$((aggregate_available_bytes - required_vulkan_with_margin_bytes))"
fi

printf 'model_memory_preflight=observe\n'
