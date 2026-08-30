#!/bin/sh
set -eu

# Sample the NVIDIA device state while a measurement runs, one row per interval.
#
# A rate on this host carries an operating state or it is not comparable to
# another rate. The device clocks itself against a power and thermal budget --
# `nvidia-smi --query-gpu=clocks_throttle_reasons.active` names which limit is
# in force -- and the desktop compositor holds device memory and issues graphics
# work beside the measurement, so utilisation and memory occupancy belong beside
# every recorded number rather than in a note about the day.
#
# The columns are `sm_clock_mhz`, `memory_clock_mhz`, `temperature_celsius`,
# `power_draw_watts`, `utilization_gpu_percent`, `utilization_memory_percent`,
# `memory_used_mib`, `memory_total_mib`, `throttle_reasons_hex`, and
# `loadavg_1min`. `memory_used_mib` is device-global: it sums every process's
# allocation, so a reading names how full the device is rather than what one
# measurement privately holds. An unreadable field writes `unavailable`;
# numeric zero remains a hardware observation rather than a missing value.
#
# The caller runs this in the background and kills it when the measurement ends.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s OUTPUT_TSV [INTERVAL_SECONDS]\n' "$0" >&2
    exit 2
fi

output_tsv=$1
interval_seconds=${2:-2}
device_index=${QWEN_NVIDIA_DEVICE_INDEX:-0}

if ! awk -v interval="$interval_seconds" 'BEGIN {
        exit !(interval ~ /^[0-9]+([.][0-9]+)?$/ && interval > 0)
    }'; then
    printf 'interval must be a positive number: %s\n' "$interval_seconds" >&2
    exit 2
fi

command -v nvidia-smi >/dev/null 2>&1 || {
    printf 'nvidia-smi is absent from PATH\n' >&2
    exit 1
}

query_fields=clocks.sm,clocks.mem,temperature.gpu,power.draw,utilization.gpu,utilization.memory,memory.used,memory.total,clocks_throttle_reasons.active

: >"$output_tsv"
while :; do
    sample=$(nvidia-smi --id="$device_index" \
        --query-gpu="$query_fields" \
        --format=csv,noheader,nounits 2>/dev/null) || sample=''
    load_average=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null) || load_average=''
    if [ -n "$sample" ]; then
        printf '%s\t%s\n' \
            "$(printf '%s\n' "$sample" | sed 's/, /\t/g')" \
            "${load_average:-unavailable}" >>"$output_tsv"
    else
        printf 'unavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\tunavailable\t%s\n' \
            "${load_average:-unavailable}" >>"$output_tsv"
    fi
    sleep "$interval_seconds"
done
