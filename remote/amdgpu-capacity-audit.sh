#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'amdgpu-capacity-audit: run as root' >&2
    exit 1
fi

dmesg_log=$(mktemp)
trap 'rm -f "$dmesg_log"' EXIT HUP INT TERM
dmesg --color=never > "$dmesg_log"

printf '%s\n' '[system]'
uname -a
sed -n '1,12p' /etc/os-release
printf 'cmdline='
cat /proc/cmdline

printf '%s\n' '[memory-modules]'
dmidecode --type 16 --type 17

printf '%s\n' '[amdgpu-module-parameters]'
for parameter_path in /sys/module/amdgpu/parameters/*; do
    parameter_name=${parameter_path##*/}
    if [ -r "$parameter_path" ]; then
        printf '%s=' "$parameter_name"
        tr -d '\n' < "$parameter_path"
        printf '\n'
    fi
done

printf '%s\n' '[ttm-module-parameters]'
for parameter_path in /sys/module/ttm/parameters/*; do
    parameter_name=${parameter_path##*/}
    if [ -r "$parameter_path" ]; then
        printf '%s=' "$parameter_name"
        tr -d '\n' < "$parameter_path"
        printf '\n'
    fi
done

printf '%s\n' '[drm-memory-domains]'
for memory_path in /sys/class/drm/card1/device/mem_info_*; do
    if [ -r "$memory_path" ]; then
        printf '%s=' "${memory_path##*/}"
        tr -d '\n' < "$memory_path"
        printf '\n'
    fi
done

printf '%s\n' '[drm-device-properties]'
for property_name in power_dpm_force_performance_level pp_dpm_sclk pp_dpm_mclk gpu_busy_percent mem_busy_percent; do
    property_path=/sys/class/drm/card1/device/$property_name
    if [ -r "$property_path" ]; then
        printf -- '-- %s --\n' "$property_name"
        sed -n '1,80p' "$property_path"
    fi
done

printf '%s\n' '[amdgpu-initialization-log]'
grep -Ei 'amdgpu|drm|ttm|vram|gtt|gart|firmware' "$dmesg_log" | sed -n '1,360p'

printf '%s\n' '[amdgpu-initialization-warnings]'
if ! grep -Ei \
    'amdgpu.*(failed to load ucode|psp gfx command .* failed|Failed to setup vendor infoframe)|workqueue: dm_irq_work_func \[amdgpu\] hogged CPU' \
    "$dmesg_log"; then
    printf '%s\n' 'none'
fi

printf '%s\n' '[amdgpu-runtime-hazards]'
if grep -Ei \
    'amdgpu.*(device lost|ring[^:]*timeout|ring[^:]*stalled|GPU reset|ASIC reset|VM fault|page fault|GPU fault|GPU recovery|job_timedout|fatal error|out of memory)|amdgpu_job_timedout' \
    "$dmesg_log"; then
    exit 2
else
    printf '%s\n' 'none'
fi

printf '%s\n' 'amdgpu-capacity-audit: complete'
