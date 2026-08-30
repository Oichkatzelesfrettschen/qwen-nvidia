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

# BAR1 and the host's own mapping counters ride beside the clock row because the
# refusal this device recorded was an NV01_MEMORY_SYSTEM allocation through UVM
# rather than a framebuffer one
# (evidence/quarantine/qwen38-9b-distill-router-load.md), and none of the
# --query-gpu fields reaches the pools that refusal names. BAR1 needs a second
# nvidia-smi process per sample, since --query-gpu carries no BAR1 field, so a
# sample costs two device queries and the interval bounds what that is worth.
bar1_sample() {
    nvidia-smi --id="$device_index" -q -d MEMORY 2>/dev/null |
        awk '/BAR1 Memory Usage/ { inside = 1; next }
             inside && /Total/ { total = $3 }
             inside && /Used/  { used = $3 }
             inside && /Free/  { free = $3; exit }
             END {
                 printf "%s\t%s\t%s\n",
                     (total == "" ? "unavailable" : total),
                     (used == "" ? "unavailable" : used),
                     (free == "" ? "unavailable" : free)
             }'
}

host_mapping_sample() {
    awk '
        $1 == "MemAvailable:" { mem_available = $2 }
        $1 == "Mlocked:"      { mlocked = $2 }
        $1 == "Unevictable:"  { unevictable = $2 }
        $1 == "PageTables:"   { page_tables = $2 }
        $1 == "SUnreclaim:"   { sunreclaim = $2 }
        END {
            printf "%s\t%s\t%s\t%s\t%s\n",
                mem_available + 0, mlocked + 0, unevictable + 0,
                page_tables + 0, sunreclaim + 0
        }' /proc/meminfo 2>/dev/null ||
        printf 'unavailable\tunavailable\tunavailable\tunavailable\tunavailable\n'
}

{
    printf 'utc\tclocks_sm_mhz\tclocks_mem_mhz\ttemperature_c\tpower_draw_w'
    printf '\tutilization_gpu_percent\tutilization_memory_percent'
    printf '\tmemory_used_mib\tmemory_total_mib\tthrottle_reasons_active'
    printf '\tbar1_total_mib\tbar1_used_mib\tbar1_free_mib'
    printf '\tmem_available_kib\tmlocked_kib\tunevictable_kib'
    printf '\tpage_tables_kib\tsunreclaim_kib\tload_average_1m\n'
} >"$output_tsv"
while :; do
    sample=$(nvidia-smi --id="$device_index" \
        --query-gpu="$query_fields" \
        --format=csv,noheader,nounits 2>/dev/null) || sample=''
    load_average=$(awk '{ print $1 }' /proc/loadavg 2>/dev/null) || load_average=''
    if [ -n "$sample" ]; then
        device_columns=$(printf '%s\n' "$sample" | sed 's/, /\t/g')
    else
        device_columns='unavailable	unavailable	unavailable	unavailable	unavailable	unavailable	unavailable	unavailable	unavailable'
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$device_columns" \
        "$(bar1_sample)" \
        "$(host_mapping_sample)" \
        "${load_average:-unavailable}" >>"$output_tsv"
    sleep "$interval_seconds"
done
