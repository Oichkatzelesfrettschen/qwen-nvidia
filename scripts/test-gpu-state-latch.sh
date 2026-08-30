#!/bin/sh
# The latch decides whether a launch runs after a driver-level failure, so every
# arm here is about what it refuses. The recovery gate itself reads the device
# and is exercised on the appliance rather than here; these arms cover the taint
# vocabulary, the boot-id rule that makes a reboot-required taint clear on a
# boot alone, the launch refusal, and the classifier the hazard watcher applies
# to a ring line.
set -eu

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
latch=$script_directory/gpu-state-latch.sh
watcher=$script_directory/watch-qwen-kernel-hazards.sh
failures=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

state=$work/state
mkdir -p "$state"
run_latch() {
    QWEN_WEBUI_STATE_DIRECTORY=$state "$latch" "$@"
}

# A state directory carrying no taint file admits a launch.
if run_latch require-clear >/dev/null 2>&1; then
    report clear_admits_launch accepted
else
    report clear_admits_launch rejected
fi

# The taint vocabulary is closed, because a class the latch cannot read would
# fall through to whichever branch its default names.
if run_latch taint sort-of-bad reason >/dev/null 2>&1; then
    report taint_vocabulary rejected
else
    report taint_vocabulary accepted
fi

run_latch taint allocation-refusal fixture >/dev/null
if run_latch require-clear >/dev/null 2>&1; then
    report allocation_taint_refuses_launch rejected
else
    allocation_status=$?
    if [ "$allocation_status" -eq 3 ]; then
        report allocation_taint_refuses_launch accepted
    else
        report allocation_taint_refuses_launch "status-$allocation_status"
    fi
fi

run_latch status >/dev/null 2>&1 || status_exit=$?
if [ "${status_exit:-0}" -eq 3 ]; then
    report allocation_status_code accepted
else
    report allocation_status_code "status-${status_exit:-0}"
fi

# A reboot-required taint carrying the running boot id refuses every launch and
# refuses the gate itself, which is what separates the two severities.
run_latch taint reboot-required fixture >/dev/null
if run_latch recover >/dev/null 2>&1; then
    report reboot_taint_refuses_gate rejected
else
    recover_status=$?
    if [ "$recover_status" -eq 4 ]; then
        report reboot_taint_refuses_gate accepted
    else
        report reboot_taint_refuses_gate "status-$recover_status"
    fi
fi

# The same taint carrying a boot id that is not the running one is stale, so a
# boot clears it without any measurement of the device.
sed 's/^boot_id=.*/boot_id=00000000-0000-0000-0000-000000000000/' \
    "$state/gpu-state-tainted" >"$state/gpu-state-tainted.next"
mv "$state/gpu-state-tainted.next" "$state/gpu-state-tainted"
if run_latch require-clear >/dev/null 2>&1; then
    report stale_reboot_taint_admits_launch accepted
else
    report stale_reboot_taint_admits_launch rejected
fi
run_latch recover >/dev/null 2>&1
if [ ! -e "$state/gpu-state-tainted" ]; then
    report stale_taint_removed accepted
else
    report stale_taint_removed rejected
fi

# An allocation-refusal taint whose boot id is stale still stands: only the
# reboot-required class is answered by a boot, and a refused allocation is
# answered by the gate's own measurement whenever it runs.
run_latch taint allocation-refusal fixture >/dev/null
sed 's/^boot_id=.*/boot_id=00000000-0000-0000-0000-000000000000/' \
    "$state/gpu-state-tainted" >"$state/gpu-state-tainted.next"
mv "$state/gpu-state-tainted.next" "$state/gpu-state-tainted"
if run_latch require-clear >/dev/null 2>&1; then
    report allocation_taint_survives_boot rejected
else
    report allocation_taint_survives_boot accepted
fi
rm -f "$state/gpu-state-tainted"

# The wiring rather than the latch alone: qwen-launch.sh has to refuse. The
# latch check runs ahead of the already-running process check, so this arm holds
# while the appliance serves, and the launch is expected to end on the latch's
# own status rather than on anything further down the chain.
launch=$script_directory/qwen-launch.sh
launch_state=$work/launch-state
mkdir -p "$launch_state"
QWEN_WEBUI_STATE_DIRECTORY=$launch_state "$latch" taint reboot-required fixture \
    >/dev/null
if QWEN_WEBUI_STATE_DIRECTORY=$launch_state "$launch" default \
    >"$work/launch.stdout" 2>"$work/launch.stderr"; then
    report launch_refuses_tainted_state rejected
else
    launch_status=$?
    if [ "$launch_status" -eq 4 ] &&
        grep -q 'clears on a reboot alone' "$work/launch.stderr"; then
        report launch_refuses_tainted_state accepted
    else
        report launch_refuses_tainted_state \
            "status-$launch_status:$(head -1 "$work/launch.stderr" 2>/dev/null)"
    fi
fi

# The hazard watcher classifies the ring line it fired on. A refused allocation
# with no mapping or Xid signature beside it is recoverable; a line naming an
# Xid is not. The watcher signals the pid it is given, so the arm runs against a
# process it owns and can lose.
watch_state=$work/watch-state
mkdir -p "$watch_state"
classify() {
    ring_line=$1
    expected_class=$2
    arm_directory=$work/arm-$expected_class-$3
    mkdir -p "$arm_directory"
    printf '%s\n' "$ring_line" >"$arm_directory/ring"
    sh -c 'while :; do :; done' &
    victim_pid=$!
    QWEN_WEBUI_STATE_DIRECTORY=$arm_directory \
        "$watcher" "$victim_pid" "$arm_directory/hazard.log" \
        "$arm_directory/ring" >/dev/null 2>&1 || :
    kill -KILL "$victim_pid" 2>/dev/null || :
    wait "$victim_pid" 2>/dev/null || :
    observed_class=$(awk -F'=' '$1 == "class" { print $2 }' \
        "$arm_directory/gpu-state-tainted" 2>/dev/null || :)
    if [ "$observed_class" = "$expected_class" ]; then
        report "hazard_class_$3" accepted
    else
        report "hazard_class_$3" "observed-${observed_class:-none}"
    fi
}
classify 'NVRM: GPU0 nvCheckOkFailedNoLog: Check failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from _memdescAllocInternal(pMemDesc) @ mem_desc.c:1338' \
    allocation-refusal no_memory
classify 'NVRM: Xid (PCI:0000:0a:00): 79, pid=1, GPU has fallen off the bus.' \
    reboot-required xid
# The ring-timeout signature is device-neutral in the watcher's pattern, so the
# arm drives it with a line naming NVRM rather than one naming another vendor's
# driver, which scripts/check-nvidia-authority.sh refuses in this tree.
classify 'NVRM: GPU0 compute ring timeout detected on channel 0x18' \
    reboot-required ring_timeout

if [ "$failures" -eq 0 ]; then
    report gpu_state_latch accepted
    exit 0
fi
report gpu_state_latch "rejected failures=$failures"
exit 1
