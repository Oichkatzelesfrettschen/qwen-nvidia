#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

evidence_directory=${1:-"${HOME:?}/qwen-apu/evidence"}
kernel_log=$evidence_directory/kernel-post-runtime.log
hazard_log=$evidence_directory/kernel-post-runtime-hazards.log
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

if ! dmesg --color=never >"$temporary_directory/kernel.log"; then
    printf 'unprivileged dmesg access is required for kernel capture\n' >&2
    exit 1
fi

hazard_pattern='ring[^[:cntrl:]]*timeout|GPU reset|amdgpu[^[:cntrl:]]*reset|VM fault|device loss|device lost|out of memory|oom-kill'
hazard_status=0
grep -Eai "$hazard_pattern" "$temporary_directory/kernel.log" \
    >"$temporary_directory/hazards.log" || hazard_status=$?
if [ "$hazard_status" -gt 1 ]; then
    printf 'kernel hazard scan failed with status %s\n' "$hazard_status" >&2
    exit "$hazard_status"
fi

install -d -m 0755 "$evidence_directory"
{
    printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'source=dmesg\n'
    cat "$temporary_directory/kernel.log"
} >"$kernel_log"
{
    printf 'hazard_pattern=%s\n' "$hazard_pattern"
    printf 'hazard_count=%s\n' "$(wc -l <"$temporary_directory/hazards.log")"
    cat "$temporary_directory/hazards.log"
} >"$hazard_log"

printf 'kernel_log=%s hazard_log=%s hazard_count=%s\n' \
    "$kernel_log" "$hazard_log" "$(wc -l <"$temporary_directory/hazards.log")"
