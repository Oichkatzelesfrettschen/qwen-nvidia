#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
test_pid=""

cleanup() {
    if [ -n "$test_pid" ]; then
        kill "$test_pid" 2>/dev/null || true
        wait "$test_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

probe_binary=$temporary_directory/vulkan-graphics-service-probe
positive_log=$temporary_directory/positive.log
negative_log=$temporary_directory/negative.log
radv_icd=${QWEN_RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}

"$script_directory/build-vulkan-graphics-service-probe.sh" "$probe_binary"

env -u AMD_PRIORITY -u DISPLAY -u WAYLAND_DISPLAY \
    VK_DRIVER_FILES="$radv_icd" VK_ICD_FILENAMES="$radv_icd" \
    "$probe_binary" --log "$positive_log" --samples 5 \
    --interval-ms 1 --deadline-us 1000000
grep -F 'global_priority=MEDIUM' "$positive_log" >/dev/null
grep -F 'probe_stop' "$positive_log" >/dev/null
if grep -F 'probe_breach' "$positive_log" >/dev/null; then
    printf 'positive graphics service probe breached its deadline\n' >&2
    exit 1
fi

sleep 30 &
test_pid=$!
set +e
env -u AMD_PRIORITY -u DISPLAY -u WAYLAND_DISPLAY \
    VK_DRIVER_FILES="$radv_icd" VK_ICD_FILENAMES="$radv_icd" \
    "$probe_binary" --log "$negative_log" --watch-pid "$test_pid" \
    --interval-ms 1 --deadline-us 1
probe_status=$?
set -e
if [ "$probe_status" -ne 3 ]; then
    printf 'negative graphics service probe returned %s instead of 3\n' \
        "$probe_status" >&2
    exit 1
fi
wait "$test_pid" 2>/dev/null || true
test_pid=""
grep -F 'probe_breach' "$negative_log" >/dev/null
grep -F 'action=SIGTERM' "$negative_log" >/dev/null

printf 'graphics_service_probe=accepted positive_samples=5 deadline_termination=accepted\n'
