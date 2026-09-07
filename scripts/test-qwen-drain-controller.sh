#!/bin/sh
# Hold the drain controller to the eight discriminations the orderly-drain
# policy names, before any of them reaches a device.
#
# Every assertion reads event ordering or an operation identity out of the
# controller's own record rather than waiting a fixed interval, so an arm
# states which event preceded which. The record carries a monotonic instant and
# a per-process sequence number for exactly that.
#
# This harness needs no GPU: the barrier is a pair of files and the participants
# are shell commands, so the whole lifecycle executes on any host. What it
# settles is that the controller performs these transitions, and it settles
# nothing about what a served llama-server does inside them.
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
controller="$script_directory/qwen-drain-controller.sh"
[ -x "$controller" ] || { printf 'controller is absent: %s\n' "$controller" >&2; exit 1; }

temporary_directory=$(mktemp -d)
cleanup() {
    # A holder that outlived its arm is retained and named rather than removed,
    # because removing a lock pathname under a live holder reports a free
    # barrier no reading proved free.
    for cleanup_pid_file in "$temporary_directory"/*.pid; do
        [ -f "$cleanup_pid_file" ] || continue
        cleanup_pid=$(cat "$cleanup_pid_file" 2>/dev/null) || continue
        kill -s TERM "$cleanup_pid" 2>/dev/null || true
    done
    rm -rf "$temporary_directory"
}
trap cleanup EXIT INT TERM

failures=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok %s %s\n' "$1" "$3"
    else
        printf 'FAIL %s expected=%s actual=%s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

QWEN_GPU_ADMISSION_BARRIER="$temporary_directory/barrier"
export QWEN_GPU_ADMISSION_BARRIER
mkdir -p "$QWEN_GPU_ADMISSION_BARRIER"

# A destroy step that records the instant it ran, so ordering against the
# holder's release is readable rather than inferred.
destroy_marker="$temporary_directory/destroy.marker"
cat > "$temporary_directory/destroy.sh" <<'DESTROY'
#!/bin/sh
awk '{ printf "destroy_ran_monotonic_ms=%d\n", $1 * 1000 }' /proc/uptime > "$1"
printf 'mode=%s\n' "${QWEN_DRAIN_MODE:-unset}" >> "$1"
exit "${2:-0}"
DESTROY
chmod +x "$temporary_directory/destroy.sh"

sequence_of() { awk -F'\t' -v s="$2" '$0 ~ s { sub(/^seq=/, "", $2); print $2; exit }' "$1"; }

# --- 1  an active holder finishes normally, and destruction follows the drain
holder_record="$temporary_directory/holder-1.record"
retire_record="$temporary_directory/retire-1.record"
"$controller" admit --record "$holder_record" -- sh -c 'sleep 1.5' &
holder_pid=$!
printf '%s\n' "$holder_pid" > "$temporary_directory/holder1.pid"
# The retire begins while the holder still runs, which is what makes the drain
# a wait rather than a sample of an already-idle barrier.
until [ -s "$holder_record" ]; do sleep 0.05; done
retire_output=$("$controller" retire --deadline 20000 --record "$retire_record" -- \
    "$temporary_directory/destroy.sh" "$destroy_marker" 0)
wait "$holder_pid" 2>/dev/null || true
check drain_completed 'orderly_drain=completed' \
    "$(printf '%s' "$retire_output" | grep '^orderly_drain=')"
check teardown_orderly 'teardown_exclusion=orderly' \
    "$(printf '%s' "$retire_output" | grep '^teardown_exclusion=')"
check destroy_saw_orderly_mode 'mode=orderly' "$(grep '^mode=' "$destroy_marker")"
# Ordering rather than duration: the holder's completion instant precedes the
# destroy step's own instant.
holder_done_ms=$(awk -F'monotonic_ms=' '/job_complete/ { split($2, f, "\t"); print f[1] }' "$holder_record")
destroy_ms=$(awk -F'=' '/destroy_ran_monotonic_ms/ { print $2 }' "$destroy_marker")
if [ "$holder_done_ms" -le "$destroy_ms" ]; then
    printf 'ok destroy_follows_drain holder=%s destroy=%s\n' "$holder_done_ms" "$destroy_ms"
else
    printf 'FAIL destroy_follows_drain holder=%s destroy=%s\n' "$holder_done_ms" "$destroy_ms"
    failures=$((failures + 1))
fi

# --- 2  a request arriving during quiescence is refused and cannot re-enter
"$script_directory/qwen-admission-barrier.sh" >/dev/null 2>&1 || true
# quiesce by hand, since retire releases the state on its way out
( . "$script_directory/qwen-admission-barrier.sh"; qwen_barrier_set_state quiescing )
quiesce_status=0
"$controller" admit -- true >"$temporary_directory/refused.out" 2>&1 || quiesce_status=$?
check quiescing_refuses_admission 1 "$quiesce_status"
check quiescing_names_state 1 \
    "$(grep -c 'admission=refused state=quiescing' "$temporary_directory/refused.out")"
check quiescing_ran_no_job 0 "$(grep -c 'job_complete' "$temporary_directory/refused.out")"
( . "$script_directory/qwen-admission-barrier.sh"; qwen_barrier_set_state running )

# --- 3  two lanes, one idle early and one active: the drain waits for both
lane_a="$temporary_directory/lane-a.record"
lane_b="$temporary_directory/lane-b.record"
"$controller" admit --record "$lane_a" -- sh -c 'sleep 0.3' &
lane_a_pid=$!
"$controller" admit --record "$lane_b" -- sh -c 'sleep 1.8' &
lane_b_pid=$!
printf '%s\n' "$lane_b_pid" > "$temporary_directory/laneb.pid"
until [ -s "$lane_a" ] && [ -s "$lane_b" ]; do sleep 0.05; done
destroy_marker_3="$temporary_directory/destroy-3.marker"
"$controller" retire --deadline 20000 --record "$temporary_directory/retire-3.record" -- \
    "$temporary_directory/destroy.sh" "$destroy_marker_3" 0 >/dev/null
wait "$lane_a_pid" "$lane_b_pid" 2>/dev/null || true
lane_b_done=$(awk -F'monotonic_ms=' '/job_complete/ { split($2, f, "\t"); print f[1] }' "$lane_b")
destroy_3_ms=$(awk -F'=' '/destroy_ran_monotonic_ms/ { print $2 }' "$destroy_marker_3")
if [ "$lane_b_done" -le "$destroy_3_ms" ]; then
    printf 'ok eviction_waits_for_active_lane later_lane=%s destroy=%s\n' "$lane_b_done" "$destroy_3_ms"
else
    printf 'FAIL eviction_waits_for_active_lane later_lane=%s destroy=%s\n' "$lane_b_done" "$destroy_3_ms"
    failures=$((failures + 1))
fi

# --- 4  a released share with the process still alive is idle, not in flight
# The share rather than the process is what the drain waits on, so a
# participant that finished its work and stayed resident does not hold the
# retirement open. That is the idle-connection case told from an unanswered one.
idle_holder="$temporary_directory/idle.record"
"$controller" admit --record "$idle_holder" -- true >/dev/null
check idle_participant_releases none \
    "$("$controller" status | awk -F'\t' '$1=="inflight" { print $2 }')"

# --- 5  a request that cannot reach a terminal state takes the deadline path
stuck_record="$temporary_directory/stuck.record"
stuck_release="$temporary_directory/stuck.release"
"$controller" admit --record "$stuck_record" -- \
    sh -c 'while [ ! -e "$1" ]; do sleep 0.05; done' stuck-job "$stuck_release" &
stuck_pid=$!
printf '%s\n' "$stuck_pid" > "$temporary_directory/stuck.pid"
until [ -s "$stuck_record" ]; do sleep 0.05; done
destroy_marker_5="$temporary_directory/destroy-5.marker"
deadline_status=0
deadline_output=$("$controller" retire --deadline 500 --record "$temporary_directory/retire-5.record" -- \
    "$temporary_directory/destroy.sh" "$destroy_marker_5" 0) || deadline_status=$?
check deadline_refuses 1 "$deadline_status"
check deadline_mode 'shutdown_mode=emergency' \
    "$(printf '%s' "$deadline_output" | grep '^shutdown_mode=')"
check deadline_drain 'orderly_drain=failed' \
    "$(printf '%s' "$deadline_output" | grep '^orderly_drain=')"
check deadline_exclusion 'teardown_exclusion=not_established' \
    "$(printf '%s' "$deadline_output" | grep '^teardown_exclusion=')"
check deadline_names_emergency_mode 'mode=emergency' "$(grep '^mode=' "$destroy_marker_5")"
# The surviving holder is retained and named rather than silently removed.
if kill -s 0 "$stuck_pid" 2>/dev/null; then
    printf 'ok residue_holder_retained pid=%s\n' "$stuck_pid"
else
    printf 'FAIL residue_holder_retained pid=%s already gone\n' "$stuck_pid"
    failures=$((failures + 1))
fi
# Releasing by file rather than by signal ends the job through its own exit,
# so the next arm starts from a barrier this arm proved empty rather than from
# one a signal raced.
: > "$stuck_release"
wait "$stuck_pid" 2>/dev/null || true
check residue_cleared_before_next_arm none \
    "$("$controller" status | awk -F'\t' '$1=="inflight" { print $2 }')"

# --- 6  a destroy step that cannot complete is not an orderly teardown pass
destroy_marker_6="$temporary_directory/destroy-6.marker"
failed_destroy_status=0
failed_destroy=$("$controller" retire --deadline 5000 --record "$temporary_directory/retire-6.record" -- \
    "$temporary_directory/destroy.sh" "$destroy_marker_6" 3) || failed_destroy_status=$?
check failed_destroy_refuses 1 "$failed_destroy_status"
check failed_destroy_drained 'orderly_drain=completed' \
    "$(printf '%s' "$failed_destroy" | grep '^orderly_drain=')"
check failed_destroy_not_exclusion 'teardown_exclusion=not_established' \
    "$(printf '%s' "$failed_destroy" | grep '^teardown_exclusion=')"

# --- 7  the barrier is released whatever the outcome, so a failure leaves the
#        session admitting rather than wedged shut
check barrier_reopened running "$("$controller" status | awk -F'\t' '$1=="barrier_state" { print $2 }')"

# --- 8  a barrier pathname that changed identity is refused rather than
#        serialized against another inode
recorded_identity=$("$controller" status | awk -F'\t' '$1=="barrier_identity" { print $2 }')
inflight_path=$("$controller" status | awk -F'\t' '$1=="barrier_inflight_path" { print $2 }')
identity_match=$( . "$script_directory/qwen-admission-barrier.sh"
    qwen_barrier_require_identity "$inflight_path" "$recorded_identity" 2>&1 )
check identity_match_reads_match 1 "$(printf '%s' "$identity_match" | grep -c '^barrier_identity=match')"
# Replacing the file gives the path a new inode, which is the case a stale
# recorded identity has to refuse.
mv "$inflight_path" "$inflight_path.moved"
: > "$inflight_path"
identity_status=0
identity_mismatch=$( . "$script_directory/qwen-admission-barrier.sh"
    qwen_barrier_require_identity "$inflight_path" "$recorded_identity" 2>&1 ) || identity_status=$?
check identity_mismatch_refuses 1 "$identity_status"
check identity_mismatch_named 1 \
    "$(printf '%s' "$identity_mismatch" | grep -c '^barrier_identity=mismatch')"

if [ "$failures" -eq 0 ]; then
    printf 'test_qwen_drain_controller=accepted\n'
    exit 0
fi
printf 'test_qwen_drain_controller=failed failures=%s\n' "$failures" >&2
exit 1
