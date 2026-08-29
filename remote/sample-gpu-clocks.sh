#!/bin/sh
set -eu

# Sample the amdgpu DPM state while a measurement runs, one row per interval.
#
# Decode on this part is bandwidth-bound and the memory controller runs on a
# DPM ladder: `pp_dpm_mclk` offers 933 MHz and 1067 MHz as its top two steps, a
# 12.6% span, and the star marks the step in force. The step moves under
# sustained load, so two rates measured minutes apart can differ by more than
# every effect a sweep is trying to resolve. A rate carries its clock state or
# it is not comparable to another rate.
#
# Desktop load is recorded rather than excluded. The appliance serves at nice 19
# underneath whatever the user is doing, so a rate measured on a quiet machine
# describes a machine that never serves. The fourth column carries the
# one-minute load average, which makes the operating condition a covariate of
# the rate instead of a reason to discard it.
#
# Device memory is sampled from amdgpu's own accounting rather than parsed from
# a log, because llama-bench prints no buffer sizes at default verbosity and a
# depth that fails prints nothing at all. `mem_info_vram_used` covers the 2 GiB
# carve-out and `mem_info_gtt_used` covers the system memory the driver maps for
# the device, which is where a Q4_K_M trunk and a deep KV cache actually live.
# Both counters are device-global: they sum every process's allocation on the
# GPU, not the sampled process's model and KV cache alone, so a reading names
# how full the device is rather than what one measurement privately holds.
#
# The caller runs this in the background and kills it when the measurement ends.
# Rows are `mclk_mhz`, `sclk_mhz`, `millidegrees`, `loadavg_1min`,
# `vram_used_bytes`, `gtt_used_bytes`. An unreadable sensor writes
# `unavailable`; numeric zero remains a hardware observation rather than a
# missing-value sentinel.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s OUTPUT_TSV [INTERVAL_SECONDS]\n' "$0" >&2
    exit 2
fi

output_tsv=$1
interval_seconds=${2:-2}
drm_device=${QWEN_DRM_DEVICE:-/sys/class/drm/card1/device}
hwmon_root=${QWEN_HWMON_ROOT:-/sys/class/hwmon}

if ! awk -v interval="$interval_seconds" 'BEGIN {
        exit !(interval ~ /^[0-9]+([.][0-9]+)?$/ && interval > 0)
    }'; then
    printf 'interval must be a positive number: %s\n' "$interval_seconds" >&2
    exit 2
fi

amdgpu_hwmon=''
for candidate in "$hwmon_root"/hwmon*; do
    if [ "$(cat "$candidate/name" 2>/dev/null)" = amdgpu ]; then
        amdgpu_hwmon=$candidate
        break
    fi
done

: >"$output_tsv"
while :; do
    mclk=$(awk '/\*/ { gsub(/Mhz|:/, "", $2); print $2; exit }' \
        "$drm_device/pp_dpm_mclk" 2>/dev/null) || mclk=''
    sclk=$(awk '/\*/ { gsub(/Mhz|:/, "", $2); print $2; exit }' \
        "$drm_device/pp_dpm_sclk" 2>/dev/null) || sclk=''
    temperature=''
    if [ -n "$amdgpu_hwmon" ]; then
        temperature=$(cat "$amdgpu_hwmon/temp1_input" 2>/dev/null) || temperature=''
    fi
    load_average=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null) || load_average=''
    vram_used=$(cat "$drm_device/mem_info_vram_used" 2>/dev/null) || vram_used=''
    gtt_used=$(cat "$drm_device/mem_info_gtt_used" 2>/dev/null) || gtt_used=''
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${mclk:-unavailable}" "${sclk:-unavailable}" \
        "${temperature:-unavailable}" "${load_average:-unavailable}" \
        "${vram_used:-unavailable}" "${gtt_used:-unavailable}" \
        >>"$output_tsv"
    sleep "$interval_seconds"
done
