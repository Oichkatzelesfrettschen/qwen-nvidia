#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s SERVER_PID HAZARD_LOG [TEST_INPUT]\n' "$0" >&2
    exit 2
fi

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

hazard_pattern='ring[^[:cntrl:]]*timeout|GPU reset|amdgpu[^[:cntrl:]]*reset|VM fault|device loss|device lost|out of memory|oom-kill'
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
            printf 'hazard_utc=%s action=SIGTERM server_pid=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$server_pid" >>"$hazard_log"
            kill -TERM "$server_pid" 2>/dev/null || true
            return 3
        fi
    done <"$input_path"
    return 0
}

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

if ! dmesg --color=never >/dev/null 2>&1; then
    printf 'unprivileged dmesg access is required for the kernel hazard watcher\n' >&2
    exit 1
fi

kernel_stream=$temporary_directory/kernel-stream.log
kernel_error=$temporary_directory/kernel-stream.err
kernel_batch=$temporary_directory/kernel-batch.log
: >"$kernel_stream"
: >"$kernel_error"
dmesg --follow-new --color=never >"$kernel_stream" 2>"$kernel_error" &
kernel_reader_pid=$!

sleep 0.1
if ! kill -0 "$kernel_reader_pid" 2>/dev/null; then
    printf 'dmesg follow-new reader failed to start\n' >&2
    cat "$kernel_error" >&2
    exit 1
fi
printf 'watch_ready_utc=%s source=dmesg_follow_new reader_pid=%s guard_affinity=%s guard_nice=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kernel_reader_pid" \
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
