#!/bin/sh
set -eu

# Run probe-depth-wedge.sh once per checkpoint in sequence, on one device.
#
# A chain that only waits for the previous llama process to exit starts the
# next checkpoint against a device that has not finished what the last one
# did to it: the amdgpu ring can still be draining a submission, and the
# previous checkpoint's own recovery control is the evidence that the device
# came back rather than a hazard this probe never confirmed. Before each
# checkpoint after the first, this script waits for all four: the previous
# checkpoint's summary carries at least one complete arm row, every recorded
# control in that summary passed, no llama-server or llama-bench process is
# running, and the device's gpu_busy_percent sysfs node reads at or below the
# idle threshold for several consecutive samples.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ "$#" -lt 1 ]; then
    printf 'usage: %s MODEL_ID:REL_PATH [MODEL_ID:REL_PATH...]\n' "$0" >&2
    printf 'REL_PATH resolves under $HOME unless it begins with /\n' >&2
    printf 'each checkpoint runs %s/probe-depth-wedge.sh into\n' "$script_directory" >&2
    printf 'OUTPUT_ROOT/MODEL_ID (default $HOME/qwen-depth-chain)\n' >&2
    printf 'QWEN_DEPTH_CHAIN_OUTPUT_ROOT overrides OUTPUT_ROOT\n' >&2
    printf 'QWEN_DEPTH_CHAIN_PROBE overrides the probe-depth-wedge.sh path\n' >&2
    printf 'QWEN_DEPTH_CHAIN_IDLE_THRESHOLD_PERCENT overrides the busy\n' >&2
    printf 'ceiling a sample must be at or below, default 5\n' >&2
    printf 'QWEN_DEPTH_CHAIN_IDLE_SAMPLES overrides how many consecutive\n' >&2
    printf 'samples must read idle, default 3\n' >&2
    printf 'QWEN_DEPTH_CHAIN_IDLE_INTERVAL_S overrides the seconds between\n' >&2
    printf 'idle samples, default 2\n' >&2
    printf 'QWEN_DEPTH_CHAIN_IDLE_TIMEOUT_S overrides the seconds this\n' >&2
    printf 'script waits for the process and idle conditions, default 120\n' >&2
    exit 2
fi

probe=${QWEN_DEPTH_CHAIN_PROBE:-"$script_directory/probe-depth-wedge.sh"}
output_root=${QWEN_DEPTH_CHAIN_OUTPUT_ROOT:-"${HOME:?}/qwen-depth-chain"}
drm_device=${QWEN_DRM_DEVICE:-/sys/class/drm/card1/device}
idle_threshold_percent=${QWEN_DEPTH_CHAIN_IDLE_THRESHOLD_PERCENT:-5}
idle_samples_required=${QWEN_DEPTH_CHAIN_IDLE_SAMPLES:-3}
idle_interval_s=${QWEN_DEPTH_CHAIN_IDLE_INTERVAL_S:-2}
idle_timeout_s=${QWEN_DEPTH_CHAIN_IDLE_TIMEOUT_S:-120}

case $idle_threshold_percent in
    '' | *[!0-9]*)
        printf '%s: idle threshold must be a non-negative integer: %s\n' \
            "$0" "$idle_threshold_percent" >&2
        exit 2
        ;;
esac
case $idle_samples_required in
    '' | *[!0-9]* | 0)
        printf '%s: idle sample count must be a positive integer: %s\n' \
            "$0" "$idle_samples_required" >&2
        exit 2
        ;;
esac
case $idle_interval_s in
    '' | *[!0-9]* | 0)
        printf '%s: idle interval seconds must be a positive integer: %s\n' \
            "$0" "$idle_interval_s" >&2
        exit 2
        ;;
esac
case $idle_timeout_s in
    '' | *[!0-9]* | 0)
        printf '%s: idle timeout seconds must be a positive integer: %s\n' \
            "$0" "$idle_timeout_s" >&2
        exit 2
        ;;
esac
if [ ! -x "$probe" ]; then
    printf '%s: probe-depth-wedge.sh must be executable: %s\n' "$0" "$probe" >&2
    exit 2
fi

wait_for_no_llama_process() {
    waited=0
    while pgrep -x llama-server >/dev/null 2>&1 ||
          pgrep -x llama-bench >/dev/null 2>&1; do
        if [ "$waited" -ge "$idle_timeout_s" ]; then
            printf '%s: a llama process held the device past the %ss wait\n' \
                "$0" "$idle_timeout_s" >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# gpu_busy_percent is an instantaneous sample, so one reading below the
# threshold can be a trough between two loaded moments rather than the device
# actually settling. Several consecutive idle samples, spaced by
# idle_interval_s, are what this waits for; any sample above the threshold or
# unreadable resets the streak to zero rather than counting toward it.
wait_for_gpu_idle() {
    busy_file=$drm_device/gpu_busy_percent
    if [ ! -r "$busy_file" ]; then
        printf 'chain_gpu_idle=unavailable file=%s\n' "$busy_file" >&2
        return 1
    fi
    consecutive_idle=0
    waited=0
    while [ "$consecutive_idle" -lt "$idle_samples_required" ]; do
        busy=$(cat "$busy_file" 2>/dev/null) || busy=''
        case $busy in
            '' | *[!0-9]*)
                consecutive_idle=0
                ;;
            *)
                if [ "$busy" -le "$idle_threshold_percent" ]; then
                    consecutive_idle=$((consecutive_idle + 1))
                else
                    consecutive_idle=0
                fi
                ;;
        esac
        [ "$consecutive_idle" -lt "$idle_samples_required" ] || break
        if [ "$waited" -ge "$idle_timeout_s" ]; then
            printf '%s: the device did not stay at or below %s%% busy for %s consecutive samples within %ss\n' \
                "$0" "$idle_threshold_percent" "$idle_samples_required" \
                "$idle_timeout_s" >&2
            return 1
        fi
        sleep "$idle_interval_s"
        waited=$((waited + idle_interval_s))
    done
    return 0
}

# A summary with no arm rows is a checkpoint that never ran; a summary
# carrying a failed control is a checkpoint whose device recovery this probe
# never confirmed. Either blocks the chain rather than starting the next
# checkpoint against a device state this script cannot vouch for.
require_previous_checkpoint_complete() {
    previous_output=$1
    previous_summary=$previous_output/wedge-summary.tsv
    if [ ! -s "$previous_summary" ]; then
        printf '%s: no summary recorded for the previous checkpoint: %s\n' \
            "$0" "$previous_summary" >&2
        return 1
    fi
    if ! awk -F'\t' 'NR > 1 { found = 1 } END { exit !found }' \
        "$previous_summary"; then
        printf '%s: the previous checkpoint recorded no arms: %s\n' \
            "$0" "$previous_summary" >&2
        return 1
    fi
    if awk -F'\t' 'NR > 1 && $15 != 0 { failed = 1 } END { exit !failed }' \
        "$previous_summary"; then
        printf '%s: the previous checkpoint left a failed recovery control: %s\n' \
            "$0" "$previous_summary" >&2
        return 1
    fi
    return 0
}

previous_output=''
checkpoint_index=0
# Validate the complete argument set before the first checkpoint can allocate
# memory or submit work. A malformed or absent later model therefore refuses
# the chain while the device remains untouched.
for entry in "$@"; do
    checkpoint_index=$((checkpoint_index + 1))
    case $entry in
        *:*) ;;
        *)
            printf '%s: checkpoint %s is not MODEL_ID:REL_PATH: %s\n' \
                "$0" "$checkpoint_index" "$entry" >&2
            exit 2
            ;;
    esac
    model_id=${entry%%:*}
    rel_path=${entry#*:}
    if [ -z "$model_id" ] || [ -z "$rel_path" ]; then
        printf '%s: checkpoint %s carries an empty id or path: %s\n' \
            "$0" "$checkpoint_index" "$entry" >&2
        exit 2
    fi
    case $rel_path in
        /*) model_path=$rel_path ;;
        *) model_path=${HOME:?}/$rel_path ;;
    esac
    if [ ! -f "$model_path" ]; then
        printf '%s: checkpoint %s model is absent: %s\n' \
            "$0" "$checkpoint_index" "$model_path" >&2
        exit 2
    fi
done

previous_output=''
for entry in "$@"; do
    model_id=${entry%%:*}
    rel_path=${entry#*:}
    case $rel_path in
        /*) model_path=$rel_path ;;
        *) model_path=${HOME:?}/$rel_path ;;
    esac
    checkpoint_output=$output_root/$model_id

    if [ -n "$previous_output" ]; then
        require_previous_checkpoint_complete "$previous_output"
        wait_for_no_llama_process
        wait_for_gpu_idle
    fi

    printf 'chain_start_utc=%s model_id=%s model_path=%s output=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model_id" "$model_path" \
        "$checkpoint_output"
    "$probe" "$model_path" "$checkpoint_output"
    printf 'chain_stop_utc=%s model_id=%s output=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model_id" "$checkpoint_output"

    previous_output=$checkpoint_output
done

printf 'depth_chain=completed output_root=%s\n' "$output_root"
