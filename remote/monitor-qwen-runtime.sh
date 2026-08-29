#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
    printf 'usage: %s SERVER_PID TELEMETRY_LOG RUNTIME_PROFILE LATENCY_WATCHDOG_PID KERNEL_HAZARD_WATCHDOG_PID\n' \
        "$0" >&2
    exit 2
fi

server_pid=$1
telemetry_log=$2
runtime_profile=$3
latency_watchdog_pid=$4
kernel_hazard_watchdog_pid=$5

case $server_pid in
    '' | *[!0-9]*)
        printf 'server PID must be a positive integer\n' >&2
        exit 2
        ;;
esac

case $latency_watchdog_pid in
    '' | *[!0-9]*)
        printf 'latency watchdog PID must be a positive integer\n' >&2
        exit 2
        ;;
esac

case $kernel_hazard_watchdog_pid in
    '' | *[!0-9]*)
        printf 'kernel hazard watchdog PID must be a positive integer\n' >&2
        exit 2
        ;;
esac

case $runtime_profile in
    paced-60)
        maximum_gpu_busy_percent=75
        ;;
    low-serialized)
        # The graphics-family latency watchdog replaces aggregate busy as the
        # responsiveness stop condition for the continuously submitted profile.
        maximum_gpu_busy_percent=100
        ;;
    low-async | custom)
        maximum_gpu_busy_percent=100
        ;;
    default | no-graphs | no-fusion | pdl | unified)
        # The CUDA profiles submit continuously and the card is discrete, so
        # aggregate busy is recorded rather than enforced and the latency
        # watchdog carries the responsiveness stop condition alone.
        maximum_gpu_busy_percent=100
        ;;
    *)
        printf 'unknown runtime profile: %s\n' "$runtime_profile" >&2
        exit 2
        ;;
esac

if ! kill -0 "$server_pid" 2>/dev/null; then
    printf 'server PID is not running: %s\n' "$server_pid" >&2
    exit 2
fi

server_start_ticks=$(awk '{ print $22 }' "/proc/$server_pid/stat" 2>/dev/null || true)
case $server_start_ticks in
    '' | *[!0-9]*)
        printf 'server process start time is unavailable: %s\n' "$server_pid" >&2
        exit 2
        ;;
esac

initial_guard_nice=$(ps -o ni= -p $$ | tr -d ' ')
if ! renice -n 0 -p $$ >/dev/null 2>&1; then
    printf 'runtime guard cannot normalize CPU priority from nice %s\n' \
        "$initial_guard_nice" >&2
    exit 2
fi
guard_nice=$(ps -o ni= -p $$ | tr -d ' ')
if [ "$guard_nice" != 0 ]; then
    printf 'runtime guard requires normal CPU priority, found nice %s\n' \
        "$guard_nice" >&2
    exit 2
fi
taskset -pc 1 $$ >/dev/null
ionice -c 3 -p $$
guard_affinity=$(awk '$1 == "Cpus_allowed_list:" { print $2 }' /proc/self/status)

sample_seconds=1
minimum_mem_available_kib=4194304
maximum_swapin_bytes_per_sample=67108864
# The SMU throttles the DPM clock ladder as junction temperature rises and the
# hardware carries its own shutdown well above anything this sampler observes,
# so silicon protection does not depend on a one-second shell poll. Terminating
# a run here would discard hours of prefill for a condition the firmware
# resolves by clocking down, so temperature is recorded and reported rather
# than enforced.
report_temperature_millicelsius=90000
gpu_device_directory=${QWEN_GPU_DEVICE_DIRECTORY:-/sys/class/drm/card1/device}
nvidia_device_index=${QWEN_NVIDIA_DEVICE_INDEX:-0}
gpu_telemetry_source=${QWEN_GPU_TELEMETRY_SOURCE:-}
if [ -z "$gpu_telemetry_source" ]; then
    if [ -r "$gpu_device_directory/gpu_busy_percent" ]; then
        gpu_telemetry_source=amdgpu_sysfs
    else
        gpu_telemetry_source=nvml
    fi
fi
case $gpu_telemetry_source in
    amdgpu_sysfs) ;;
    nvml)
        command -v nvidia-smi >/dev/null 2>&1 || {
            printf 'NVML telemetry needs nvidia-smi and it is absent from PATH\n' >&2
            exit 2
        }
        ;;
    *)
        printf 'QWEN_GPU_TELEMETRY_SOURCE takes amdgpu_sysfs or nvml: %s\n' \
            "$gpu_telemetry_source" >&2
        exit 2
        ;;
esac
if [ "$gpu_device_directory" != /sys/class/drm/card1/device ] && \
   [ "${QWEN_GUARD_TEST_MODE:-0}" != 1 ]; then
    printf 'GPU device override requires QWEN_GUARD_TEST_MODE=1\n' >&2
    exit 2
fi
# The policy the monitor enforces is the one the runtime wrapper applied, and
# the session exports both values before starting this process.
case ${QWEN_SERVING_BACKEND:-cuda} in
    vulkan)
        expected_affinity=${QWEN_INFERENCE_CPU:-0}
        expected_nice=19
        ;;
    *)
        expected_affinity=${QWEN_SERVING_CPU_LIST:-$(cat /sys/devices/system/cpu/online 2>/dev/null || echo 0)}
        expected_nice=${QWEN_SERVING_NICE:-0}
        ;;
esac

page_size=$(getconf PAGESIZE)
previous_pswpin=$(awk '$1 == "pswpin" { print $2 }' /proc/vmstat)
temperature_reported=0

server_is_original_process() {
    if [ ! -r "/proc/$server_pid/stat" ]; then
        return 1
    fi
    current_start_ticks=$(awk '{ print $22 }' "/proc/$server_pid/stat" 2>/dev/null || true)
    [ "$current_start_ticks" = "$server_start_ticks" ]
}

terminate_server() {
    reason=$1
    printf 'abort_utc=%s reason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" \
        >>"$telemetry_log"
    if server_is_original_process; then
        kill -TERM "$server_pid" 2>/dev/null || true
    fi
    termination_attempt=0
    while server_is_original_process && [ "$termination_attempt" -lt 20 ]; do
        termination_attempt=$((termination_attempt + 1))
        sleep 0.1
    done
    if server_is_original_process; then
        kill -KILL "$server_pid" 2>/dev/null || true
        printf 'termination_utc=%s action=SIGKILL grace_milliseconds=2000\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$telemetry_log"
    else
        printf 'termination_utc=%s action=SIGTERM\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$telemetry_log"
    fi
    exit 3
}

{
    printf 'monitor_start_utc=%s server_pid=%s sample_seconds=%s profile=%s latency_watchdog_pid=%s kernel_hazard_watchdog_pid=%s guard_affinity=%s guard_nice=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$server_pid" "$sample_seconds" \
        "$runtime_profile" "$latency_watchdog_pid" "$kernel_hazard_watchdog_pid" \
        "$guard_affinity" "$guard_nice"
    printf 'threshold_mem_available_kib=%s threshold_swapin_bytes_per_sample=%s report_temperature_millicelsius=%s\n' \
        "$minimum_mem_available_kib" "$maximum_swapin_bytes_per_sample" \
        "$report_temperature_millicelsius"
    printf 'threshold_maximum_gpu_busy_percent=%s enforcement=terminate_on_sample_above_threshold\n' \
        "$maximum_gpu_busy_percent"
} >"$telemetry_log"

while server_is_original_process; do
    if ! kill -0 "$latency_watchdog_pid" 2>/dev/null; then
        terminate_server graphics_latency_watchdog_unavailable
    fi
    if ! kill -0 "$kernel_hazard_watchdog_pid" 2>/dev/null; then
        terminate_server kernel_hazard_watchdog_unavailable
    fi
    affinity=$(awk '$1 == "Cpus_allowed_list:" { print $2 }' "/proc/$server_pid/status" 2>/dev/null) || break
    nice_value=$(ps -o ni= -p "$server_pid" | tr -d ' ') || break
    rss_kib=$(awk '$1 == "VmRSS:" { print $2 }' "/proc/$server_pid/status" 2>/dev/null) || break
    peak_rss_kib=$(awk '$1 == "VmHWM:" { print $2 }' "/proc/$server_pid/status" 2>/dev/null) || break
    mem_available_kib=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)
    current_pswpin=$(awk '$1 == "pswpin" { print $2 }' /proc/vmstat)
    swapin_pages=$((current_pswpin - previous_pswpin))
    swapin_bytes=$((swapin_pages * page_size))
    previous_pswpin=$current_pswpin

    # NVML answers where amdgpu's sysfs files do, and the sample keeps its
    # column names across both: utilisation is the busy percent, device memory
    # is the vram figure, and a discrete card maps nothing onto GTT, which is
    # an APU's system-memory aperture. A device that reports nothing ends the
    # run, because a guard that cannot see the device is not guarding it.
    if [ "$gpu_telemetry_source" = nvml ]; then
        gpu_sample=$(nvidia-smi --id="$nvidia_device_index" \
            --query-gpu=utilization.gpu,memory.used,clocks.sm,clocks.mem \
            --format=csv,noheader,nounits 2>/dev/null) || gpu_sample=''
        if [ -z "$gpu_sample" ]; then
            terminate_server gpu_telemetry_unavailable
        fi
        gpu_busy_percent=$(printf '%s' "$gpu_sample" | awk -F', *' '{ print $1 }')
        vram_used_bytes=$(printf '%s' "$gpu_sample" |
            awk -F', *' '{ printf "%d", $2 * 1048576 }')
        gtt_used_bytes=unavailable
        sclk=$(printf '%s' "$gpu_sample" | awk -F', *' '{ print $3 }')
        mclk=$(printf '%s' "$gpu_sample" | awk -F', *' '{ print $4 }')
    else
        if [ ! -r "$gpu_device_directory/gpu_busy_percent" ] || \
           [ ! -r "$gpu_device_directory/mem_info_gtt_used" ] || \
           [ ! -r "$gpu_device_directory/mem_info_vram_used" ]; then
            terminate_server gpu_telemetry_unavailable
        fi

        gpu_busy_percent=$(cat "$gpu_device_directory/gpu_busy_percent")
        gtt_used_bytes=$(cat "$gpu_device_directory/mem_info_gtt_used")
        vram_used_bytes=$(cat "$gpu_device_directory/mem_info_vram_used")
        sclk=$(tr '\n' ';' <"$gpu_device_directory/pp_dpm_sclk")
        mclk=$(tr '\n' ';' <"$gpu_device_directory/pp_dpm_mclk")
    fi

    maximum_observed_temperature=0
    for temperature_path in /sys/class/hwmon/hwmon*/temp*_input; do
        if [ ! -r "$temperature_path" ]; then
            continue
        fi
        temperature=$(cat "$temperature_path")
        if [ "$temperature" -gt "$maximum_observed_temperature" ]; then
            maximum_observed_temperature=$temperature
        fi
    done

    printf 'sample_utc=%s affinity=%s nice=%s rss_kib=%s peak_rss_kib=%s mem_available_kib=%s swapin_bytes=%s max_temp_millicelsius=%s gpu_busy_percent=%s gtt_used_bytes=%s vram_used_bytes=%s sclk=%s mclk=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$affinity" "$nice_value" \
        "$rss_kib" "$peak_rss_kib" "$mem_available_kib" "$swapin_bytes" \
        "$maximum_observed_temperature" "$gpu_busy_percent" "$gtt_used_bytes" \
        "$vram_used_bytes" "$sclk" "$mclk" >>"$telemetry_log"

    if [ "$affinity" != "$expected_affinity" ]; then
        terminate_server process_affinity_changed
    fi
    if [ "$nice_value" != "$expected_nice" ]; then
        terminate_server process_nice_changed
    fi
    if [ "$mem_available_kib" -lt "$minimum_mem_available_kib" ]; then
        terminate_server memory_reserve_breached
    fi
    if [ "$swapin_bytes" -gt "$maximum_swapin_bytes_per_sample" ]; then
        terminate_server swapin_rate_breached
    fi
    if [ "$maximum_observed_temperature" -ge "$report_temperature_millicelsius" ] && \
       [ "$temperature_reported" -eq 0 ]; then
        temperature_reported=1
        printf 'temperature_report_utc=%s max_temp_millicelsius=%s threshold_millicelsius=%s action=observe\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$maximum_observed_temperature" \
            "$report_temperature_millicelsius" >>"$telemetry_log"
    fi
    case $gpu_busy_percent in
        '' | *[!0-9]*)
            terminate_server gpu_busy_percent_invalid
            ;;
    esac
    if [ "$gpu_busy_percent" -gt "$maximum_gpu_busy_percent" ]; then
        terminate_server gpu_busy_percent_breached
    fi

    sleep "$sample_seconds"
done

printf 'monitor_stop_utc=%s reason=server_exited\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$telemetry_log"
