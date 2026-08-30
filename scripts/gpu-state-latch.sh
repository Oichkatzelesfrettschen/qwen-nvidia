#!/bin/sh
# The latch that stands between a driver-level failure and the next launch.
#
# An NVRM allocation refusal ends the server: scripts/watch-qwen-kernel-hazards.sh
# matches `out of memory` in the ring and signals it. Relaunching inside the same
# minute then meets a device whose counters read free while the driver has not
# finished reclaiming, and the second load fails wider than the first --
# evidence/quarantine/qwen38-9b-distill-router-load.md records a sweep that lost
# every row that way. The latch makes that relaunch impossible rather than
# discouraged: a taint file in the session state directory refuses
# scripts/qwen-launch.sh until the recovery gate passes.
#
# The severity decides whether a gate can clear it at all. A refused allocation
# leaves the device answering and its own reclaim is what the gate waits on, so
# `allocation-refusal` clears on measurement. A mapping failure, an invalid
# state, a partial-progress abort, an Xid, or a reset names driver state this
# tree has no measurement for, so `reboot-required` clears on a boot and on
# nothing else: the boot id recorded in the taint file is compared against the
# running one.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: gpu-state-latch.sh status
       gpu-state-latch.sh taint CLASS REASON
       gpu-state-latch.sh require-clear
       gpu-state-latch.sh recover

CLASS is allocation-refusal or reboot-required.

status         prints the latch state; exits 0 clear, 3 tainted-recoverable,
               4 tainted-reboot-required.
taint          records a taint with the running boot id and the kernel
               signature count that stood when it was written.
require-clear  exits 0 when the latch is clear and non-zero with the reason
               otherwise. This is what a launch calls.
recover        runs the recovery gate and clears an allocation-refusal taint.
               A reboot-required taint clears when the boot id changes.
USAGE
    exit 2
}

[ "$#" -ge 1 ] || usage

state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
taint_file=$state_directory/gpu-state-tainted
nvidia_smi=${QWEN_NVIDIA_SMI:-nvidia-smi}
# The gate reads the ring through the same path the hazard watcher takes.
dmesg_command=${QWEN_DMESG_COMMAND:-}
cooldown_seconds=${QWEN_GPU_RECOVERY_COOLDOWN_S:-20}
quiet_seconds=${QWEN_GPU_RECOVERY_QUIET_S:-15}
stability_samples=${QWEN_GPU_RECOVERY_STABILITY_SAMPLES:-4}
stability_interval_seconds=${QWEN_GPU_RECOVERY_STABILITY_INTERVAL_S:-2}

running_boot_id() {
    if [ -r /proc/sys/kernel/random/boot_id ]; then
        cat /proc/sys/kernel/random/boot_id
    else
        printf 'unknown\n'
    fi
}

resolve_dmesg_command() {
    [ -z "$dmesg_command" ] || return 0
    if dmesg --color=never >/dev/null 2>&1; then
        dmesg_command='dmesg'
    elif sudo -n dmesg --color=never >/dev/null 2>&1; then
        dmesg_command='sudo -n dmesg'
    else
        dmesg_command=''
    fi
}

# The same signatures the hazard watcher acts on, so the gate waits for silence
# in the ring the watcher would have fired on.
hazard_pattern='NV_ERR_NO_MEMORY|NV_ERR_INVALID_STATE|dmaAllocMapping|mapping_reuse|mmuWalkMap|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed|GPU reset|ring[^[:cntrl:]]*timeout'

kernel_signature_count() {
    resolve_dmesg_command
    [ -n "$dmesg_command" ] || { printf 'unavailable\n'; return 0; }
    # grep -c prints its count and still exits 1 when that count is zero, which
    # is the state a clean boot is in, so the status is discarded and the count
    # is read from the output alone.
    signature_count=$($dmesg_command --color=never 2>/dev/null |
        grep -Eac "$hazard_pattern" 2>/dev/null || :)
    case $signature_count in
        '' | *[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$signature_count" ;;
    esac
}

taint_field() {
    [ -r "$taint_file" ] || return 1
    awk -F'=' -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; found = 1 }
        END { exit found ? 0 : 1 }' "$taint_file"
}

latch_state() {
    [ -r "$taint_file" ] || { printf 'clear\n'; return 0; }
    taint_class=$(taint_field class) || taint_class=reboot-required
    if [ "$taint_class" = reboot-required ]; then
        taint_boot=$(taint_field boot_id) || taint_boot=unknown
        if [ "$taint_boot" != "$(running_boot_id)" ]; then
            printf 'stale\n'
            return 0
        fi
    fi
    printf '%s\n' "$taint_class"
}

command_name=$1
shift

case $command_name in
    status)
        [ "$#" -eq 0 ] || usage
        state=$(latch_state)
        case $state in
            clear)
                printf 'gpu_state_latch=clear taint=%s\n' "$taint_file"
                exit 0
                ;;
            stale)
                printf 'gpu_state_latch=stale reason=boot_id_changed taint=%s\n' \
                    "$taint_file"
                exit 0
                ;;
            allocation-refusal)
                cat "$taint_file"
                printf 'gpu_state_latch=tainted class=allocation-refusal recovery=gate\n'
                exit 3
                ;;
            *)
                cat "$taint_file"
                printf 'gpu_state_latch=tainted class=%s recovery=reboot\n' "$state"
                exit 4
                ;;
        esac
        ;;
    taint)
        [ "$#" -eq 2 ] || usage
        taint_class=$1
        taint_reason=$2
        case $taint_class in
            allocation-refusal | reboot-required) ;;
            *)
                printf 'taint class must be allocation-refusal or reboot-required: %s\n' \
                    "$taint_class" >&2
                exit 2
                ;;
        esac
        mkdir -p "$state_directory"
        {
            printf 'utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'class=%s\n' "$taint_class"
            printf 'reason=%s\n' "$taint_reason"
            printf 'boot_id=%s\n' "$(running_boot_id)"
            printf 'kernel_signatures=%s\n' "$(kernel_signature_count)"
        } >"$taint_file"
        printf 'gpu_state_latch=tainted class=%s reason=%s\n' \
            "$taint_class" "$taint_reason"
        exit 0
        ;;
    require-clear)
        [ "$#" -eq 0 ] || usage
        state=$(latch_state)
        case $state in
            clear | stale)
                exit 0
                ;;
            allocation-refusal)
                printf 'the GPU state latch is set from an allocation refusal\n' >&2
                sed 's/^/  /' "$taint_file" >&2
                printf 'clear it with: scripts/gpu-state-latch.sh recover\n' >&2
                exit 3
                ;;
            *)
                printf 'the GPU state latch is set and clears on a reboot alone\n' >&2
                sed 's/^/  /' "$taint_file" >&2
                exit 4
                ;;
        esac
        ;;
    recover)
        [ "$#" -eq 0 ] || usage
        state=$(latch_state)
        case $state in
            clear)
                printf 'gpu_state_latch=clear\n'
                exit 0
                ;;
            stale)
                rm -f "$taint_file"
                printf 'gpu_state_recovery=cleared reason=boot_id_changed\n'
                exit 0
                ;;
            allocation-refusal) ;;
            *)
                printf 'a %s taint clears on a reboot rather than on this gate\n' \
                    "$state" >&2
                exit 4
                ;;
        esac
        ;;
    *)
        usage
        ;;
esac

# The recovery gate. Each stage is an observation of the device or the ring
# rather than a wait, and the stage that fails names itself.
gate_failed=0
report() {
    printf 'gpu_state_recovery %s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || gate_failed=1
}

remaining_servers=$(pgrep -f 'llama-server' 2>/dev/null | tr '\n' ' ' || :)
if [ -z "$remaining_servers" ]; then
    report no_server accepted
else
    report no_server "rejected:$remaining_servers"
fi

compute_clients=$("$nvidia_smi" --query-compute-apps=pid --format=csv,noheader \
    2>/dev/null | tr -d ' ' | tr '\n' ' ' || :)
if [ -z "$compute_clients" ]; then
    report no_compute_clients accepted
else
    report no_compute_clients "rejected:$compute_clients"
fi

if "$nvidia_smi" -q >/dev/null 2>&1; then
    report device_answers accepted
else
    report device_answers rejected
fi

# Framebuffer and BAR1 occupancy have to stop moving before the device is
# called settled, because the counters read free while the driver is still
# reclaiming and that is the window a relaunch loses a whole roster in.
occupancy_sample() {
    "$nvidia_smi" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null |
        head -1
}
bar1_sample() {
    "$nvidia_smi" -q -d MEMORY 2>/dev/null |
        awk '/BAR1 Memory Usage/ { inside = 1; next }
             inside && /Used/ { print $3; exit }'
}
previous_occupancy=''
previous_bar1=''
stable=1
sample_index=0
while [ "$sample_index" -lt "$stability_samples" ]; do
    current_occupancy=$(occupancy_sample || :)
    current_bar1=$(bar1_sample || :)
    if [ -n "$previous_occupancy" ]; then
        [ "$current_occupancy" = "$previous_occupancy" ] || stable=0
        [ "$current_bar1" = "$previous_bar1" ] || stable=0
    fi
    previous_occupancy=$current_occupancy
    previous_bar1=$current_bar1
    sample_index=$((sample_index + 1))
    [ "$sample_index" -lt "$stability_samples" ] &&
        sleep "$stability_interval_seconds"
done
if [ "$stable" -eq 1 ]; then
    report counters_stable "accepted:fb=${previous_occupancy}MiB:bar1=${previous_bar1}MiB"
else
    report counters_stable rejected
fi

# A quiet ring is what separates a refusal that has finished from one still
# arriving. The count is taken twice across the interval rather than tailed,
# because the reader may be the sudo path and a follow would outlive the gate.
signatures_before=$(kernel_signature_count)
sleep "$quiet_seconds"
signatures_after=$(kernel_signature_count)
if [ "$signatures_before" = unavailable ]; then
    # An allocation-refusal taint survives a boot by design and a fresh boot
    # holds no sudo timestamp, so the gate names the unblock rather than
    # leaving the appliance latched with no visible exit.
    report ring_quiet "rejected:unreadable"
    printf 'the kernel ring answers neither directly nor through sudo -n\n' >&2
    printf 'grant the timestamp with: sudo -v\n' >&2
elif [ "$signatures_before" = "$signatures_after" ]; then
    report ring_quiet "accepted:$signatures_after"
else
    report ring_quiet "rejected:$signatures_before->$signatures_after"
fi

sleep "$cooldown_seconds"
report cooldown "accepted:${cooldown_seconds}s"

if [ "$gate_failed" -eq 0 ]; then
    rm -f "$taint_file"
    printf 'gpu_state_recovery=cleared\n'
    exit 0
fi
printf 'gpu_state_recovery=refused\n' >&2
exit 1
