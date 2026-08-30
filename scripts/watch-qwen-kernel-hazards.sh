#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s SERVER_PID HAZARD_LOG [TEST_INPUT]\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
server_pid=$1
hazard_log=$2
test_input=${3:-}

case $server_pid in
    '' | *[!0-9]*)
        printf 'server PID must be a positive integer\n' >&2
        exit 2
        ;;
esac

if ! kill -0 "$server_pid" 2>/dev/null; then
    printf 'server PID is not running: %s\n' "$server_pid" >&2
    exit 2
fi

initial_guard_nice=$(ps -o ni= -p $$ | tr -d ' ')
if ! renice -n 0 -p $$ >/dev/null 2>&1; then
    printf 'kernel guard cannot normalize CPU priority from nice %s\n' \
        "$initial_guard_nice" >&2
    exit 2
fi
guard_nice=$(ps -o ni= -p $$ | tr -d ' ')
if [ "$guard_nice" != 0 ]; then
    printf 'kernel guard requires normal CPU priority, found nice %s\n' \
        "$guard_nice" >&2
    exit 2
fi
taskset -pc 1 $$ >/dev/null
ionice -c 3 -p $$
guard_affinity=$(awk '$1 == "Cpus_allowed_list:" { print $2 }' /proc/self/status)

# The signatures cover both backends because one tree serves on CUDA and falls
# back to Vulkan on the same card. NVRM Xid lines name the fault: Xid 13, 31,
# and 43 name a faulting channel, Xid 79 names a card that stopped answering,
# and RmInitAdapter failure names a device that never came up.
hazard_pattern='ring[^[:cntrl:]]*timeout|GPU reset|VM fault|device loss|device lost|out of memory|oom-kill|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed|nvidia[^[:cntrl:]]*GPU at PCI[^[:cntrl:]]*has fallen'
# A hazard that names mapping, invalid state, partial progress, an Xid, or a
# reset leaves the latch waiting for a boot rather than for the recovery gate.
reboot_required_pattern='NV_ERR_INVALID_STATE|dmaAllocMapping|mapping_reuse|mmuWalkMap|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed|GPU reset|ring[^[:cntrl:]]*timeout|VM fault|device los[ts]'
temporary_directory=$(mktemp -d)
kernel_reader_pid=""

cleanup() {
    if [ -n "$kernel_reader_pid" ]; then
        kill "$kernel_reader_pid" 2>/dev/null || true
        wait "$kernel_reader_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

process_lines() {
    input_path=$1
    while IFS= read -r kernel_line; do
        printf '%s\n' "$kernel_line" >>"$hazard_log"
        if printf '%s\n' "$kernel_line" | grep -Eai "$hazard_pattern" >/dev/null; then
            # The severity decides whether the next launch can be gated back in
            # by measurement or waits for a boot. A refused allocation leaves
            # the device answering, so its own reclaim is what
            # scripts/gpu-state-latch.sh waits on; a mapping failure, an
            # invalid state, an Xid, or a reset names driver state this tree
            # has no measurement for.
            if printf '%s\n' "$kernel_line" |
                grep -Eai "$reboot_required_pattern" >/dev/null; then
                hazard_class=reboot-required
            else
                hazard_class=allocation-refusal
            fi
            printf 'hazard_utc=%s action=SIGTERM server_pid=%s class=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$server_pid" \
                "$hazard_class" >>"$hazard_log"
            "$script_directory/gpu-state-latch.sh" taint "$hazard_class" \
                kernel-hazard >>"$hazard_log" 2>&1 || true
            kill -TERM "$server_pid" 2>/dev/null || true
            return 3
        fi
    done <"$input_path"
    return 0
}

# The watcher truncates its log at every start, so the run that ended the last
# server would leave no record of which ring line it fired on. One generation is
# retained beside it, which is what makes an unexplained stop readable after the
# next launch has already happened.
if [ -s "$hazard_log" ]; then
    cp -- "$hazard_log" "$hazard_log.previous" 2>/dev/null || :
fi

{
    printf 'watch_start_utc=%s server_pid=%s guard_affinity=%s guard_nice=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$server_pid" \
        "$guard_affinity" "$guard_nice"
    printf 'hazard_pattern=%s\n' "$hazard_pattern"
} >"$hazard_log"

if [ -n "$test_input" ]; then
    process_lines "$test_input"
    exit $?
fi

# kernel.dmesg_restrict hides the ring buffer from unprivileged readers on this
# distribution, so the watcher reads it through the same passwordless sudo rule
# that administers the host and says which path it took. A host that grants
# neither has no kernel evidence to watch and the launch fails here rather than
# serving with a blind guard.
dmesg_command='dmesg'
if ! dmesg --color=never >/dev/null 2>&1; then
    if sudo -n dmesg --color=never >/dev/null 2>&1; then
        dmesg_command='sudo -n dmesg'
    else
        printf 'the kernel hazard watcher reads dmesg directly or through sudo -n, and neither answers\n' >&2
        printf 'grant one with: sudo sysctl -w kernel.dmesg_restrict=0\n' >&2
        exit 1
    fi
fi

kernel_stream=$temporary_directory/kernel-stream.log
kernel_error=$temporary_directory/kernel-stream.err
kernel_batch=$temporary_directory/kernel-batch.log
: >"$kernel_stream"
: >"$kernel_error"
$dmesg_command --follow-new --color=never >"$kernel_stream" 2>"$kernel_error" &
kernel_reader_pid=$!

sleep 0.1
if ! kill -0 "$kernel_reader_pid" 2>/dev/null; then
    printf 'dmesg follow-new reader failed to start\n' >&2
    cat "$kernel_error" >&2
    exit 1
fi
printf 'watch_ready_utc=%s source=%s reader_pid=%s guard_affinity=%s guard_nice=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$dmesg_command" | tr ' ' '_')_follow_new" "$kernel_reader_pid" \
    "$guard_affinity" "$guard_nice" >>"$hazard_log"

next_line=1
while kill -0 "$server_pid" 2>/dev/null; do
    complete_lines=$(wc -l <"$kernel_stream")
    if [ "$complete_lines" -ge "$next_line" ]; then
        sed -n "${next_line},${complete_lines}p" "$kernel_stream" >"$kernel_batch"
        process_status=0
        process_lines "$kernel_batch" || process_status=$?
        if [ "$process_status" -ne 0 ]; then
            exit "$process_status"
        fi
        next_line=$((complete_lines + 1))
    fi
    if ! kill -0 "$kernel_reader_pid" 2>/dev/null; then
        printf 'hazard_stream_ended_while_server_running=yes\n' >>"$hazard_log"
        cat "$kernel_error" >>"$hazard_log"
        kill -TERM "$server_pid" 2>/dev/null || true
        exit 1
    fi
    sleep 0.25
done

complete_lines=$(wc -l <"$kernel_stream")
if [ "$complete_lines" -ge "$next_line" ]; then
    sed -n "${next_line},${complete_lines}p" "$kernel_stream" >"$kernel_batch"
    process_lines "$kernel_batch"
fi
printf 'watch_stop_utc=%s reason=server_exited\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$hazard_log"
