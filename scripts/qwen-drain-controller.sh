#!/bin/sh
# gpu-ownership: delegated to the caller. This controller takes the admission
# barrier and never the compute lease, because the process it retires acquires
# that lease in its own destructor and a parent holding it would deadlock the
# child it is waiting for.
#
# Drive one retirement through the lifecycle the lease contract's teardown
# policy names, with an executable condition on every transition:
#
#   RUNNING            work is admitted and executes
#   QUIESCING          the barrier state is flipped, so every later admission
#                      refuses at the participant's own entry point
#   DRAINING           the exclusive in-flight acquisition waits on the shares
#                      already admitted, bounded by a deadline
#   READY_TO_DESTROY   the state reads quiescing and no share remains
#   DESTROYING         the retiring process runs its own teardown, taking the
#                      compute lease itself
#   STOPPED            process, socket, artifact, and lock residue proved absent
#
# Observing a free lease and then signalling is the design this replaces: an
# admitted request acquires between the observation and the signal, and the
# teardown that follows is the contended case the policy exists to remove. The
# drain is a wait on a set that can only shrink rather than a sample.
#
# A deadline never becomes an unbounded wait. On expiry the transition is
# recorded as unsuccessful, the bounded escalation runs, and the outcome is
# classified rather than absorbed, because `teardown: held=no` is a successful
# termination and never an orderly-exclusion pass.
set -eu

usage() {
    printf 'usage: %s retire [--deadline MS] [--record FILE] -- COMMAND [ARGUMENT...]\n' "$0" >&2
    printf '       %s admit [--record FILE] -- COMMAND [ARGUMENT...]\n' "$0" >&2
    printf '       %s status|resume\n' "$0" >&2
    printf '  retire  quiesce, drain, then run COMMAND as the destroy step\n' >&2
    printf '  admit   run COMMAND holding one in-flight share, refused while quiescing\n' >&2
    exit 2
}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$script_directory/qwen-admission-barrier.sh"

drain_deadline_ms=${QWEN_DRAIN_DEADLINE_MS:-30000}
# The escalation bound belongs to the destroy step, which is what signals and
# polls, so the controller names it and exports it rather than applying it here.
QWEN_DRAIN_ESCALATION_MS=${QWEN_DRAIN_ESCALATION_MS:-10000}
export QWEN_DRAIN_ESCALATION_MS
record_file=

# Monotonic milliseconds. /proc/uptime rather than the wall clock, because a
# clock step under NTP moves a deadline the kernel does not honor.
monotonic_ms() {
    awk '{ printf "%d\n", $1 * 1000 }' /proc/uptime
}

# One record line per transition, carrying its monotonic instant and a
# per-process sequence number, so an arm states which event preceded which
# rather than that enough time passed.
event_sequence=0
record() {
    event_sequence=$((event_sequence + 1))
    record_line=$(printf 'drain\tseq=%s\tmonotonic_ms=%s\tstate=%s\t%s' \
        "$event_sequence" "$(monotonic_ms)" "$1" "$2")
    printf '%s\n' "$record_line"
    [ -z "$record_file" ] || printf '%s\n' "$record_line" >> "$record_file"
}

[ $# -ge 1 ] || usage
subcommand=$1
shift

case $subcommand in
    status)
        qwen_barrier_initialize
        printf 'barrier_state\t%s\n' "$(qwen_barrier_state)"
        printf 'barrier_state_path\t%s\n' "$(qwen_barrier_state_path)"
        printf 'barrier_inflight_path\t%s\n' "$(qwen_barrier_inflight_path)"
        printf 'barrier_identity\t%s\n' "$(qwen_barrier_identity "$(qwen_barrier_inflight_path)")"
        # A share still held reads as work in flight; the non-blocking exclusive
        # attempt is the reading, and it is taken on its own open so it reports
        # rather than changes what any holder has.
        if flock -x -n "$(qwen_barrier_inflight_path)" true 2>/dev/null; then
            printf 'inflight\tnone\n'
        else
            printf 'inflight\theld\n'
        fi
        exit 0
        ;;
    resume)
        # Recovery is explicit and takes the drain reference before reopening.
        # A holder or retiring controller keeps this transition refused.
        qwen_barrier_initialize
        exec 9< "$(qwen_barrier_inflight_path)"
        if ! flock -x -n 9; then
            printf 'resume_refused reason=work_or_retirement_inflight\n' >&2
            exit 1
        fi
        qwen_barrier_set_state running
        flock -u 9
        exec 9<&-
        printf 'barrier_state\trunning\n'
        exit 0
        ;;
    admit | retire) ;;
    *) usage ;;
esac

while [ $# -gt 0 ]; do
    case $1 in
        --deadline) [ $# -ge 2 ] || usage; drain_deadline_ms=$2; shift 2 ;;
        --record) [ $# -ge 2 ] || usage; record_file=$2; shift 2 ;;
        --) shift; break ;;
        *) usage ;;
    esac
done
[ $# -ge 1 ] || usage

case $drain_deadline_ms in
    '' | *[!0-9]*) printf 'deadline takes milliseconds: %s\n' "$drain_deadline_ms" >&2; exit 2 ;;
esac

qwen_barrier_initialize
inflight_path=$(qwen_barrier_inflight_path)

if [ "$subcommand" = admit ]; then
    # The share is held on descriptor 8 for the command's whole duration, so a
    # drain waiting on the exclusive lock is waiting on this job. exec keeps the
    # descriptor across the command where the caller wants that; here the
    # command is a child and inherits it.
    exec 8< "$inflight_path"
    admit_result=$(qwen_barrier_admit 8) || {
        record refused "admission=$admit_result"
        exit 1
    }
    record running "admission=$admit_result"
    admit_status=0
    # The command runs with the share's descriptor closed, so the share belongs
    # to this process alone and its lifetime is the job's. An inherited
    # descriptor would keep the barrier held by a child that outlived its
    # admitter, which is the residue qwen-webui-session.sh closes with `9>&-`
    # for the owner claim: a drain would then wait on a claim no live job backs.
    "$@" 8<&- || admit_status=$?
    record running "job_complete status=$admit_status"
    flock -u 8
    exec 8<&-
    exit "$admit_status"
fi

# retire: the whole lifecycle, one transition at a time.
record running 'retire_begin'

qwen_barrier_set_state quiescing
record quiescing "admission_closed state=$(qwen_barrier_state)"

exec 9< "$inflight_path"
drain_result=$(qwen_barrier_drain 9 "$drain_deadline_ms") || drain_status=$?
drain_status=${drain_status:-0}

if [ "$drain_status" -ne 0 ]; then
    # The orderly transition failed. The escalation is the established bounded
    # one and the classification is explicit, because an emergency exit that
    # waited indefinitely would trade a bounded shutdown for a diagram.
    record draining "drain_failed $drain_result"
    record destroying 'emergency_escalation'
    escalation_status=0
    QWEN_DRAIN_MODE=emergency "$@" 9<&- || escalation_status=$?
    record stopped "shutdown_mode=emergency orderly_drain=failed teardown_exclusion=not_established escalation_status=$escalation_status"
    printf 'shutdown_mode=emergency\norderly_drain=failed\nteardown_exclusion=not_established\n'
    flock -u 9 2>/dev/null || true
    exec 9<&-
    # Failure preserves the closed admission state for explicit recovery.
    exit 1
fi

record draining "$drain_result"
record ready_to_destroy "state=$(qwen_barrier_state) inflight=none"

# The retiring process takes the compute lease in its own destructor. This
# controller holds the barrier and never that lease, so the child can.
destroy_status=0
QWEN_DRAIN_MODE=orderly "$@" 9<&- || destroy_status=$?
record destroying "destroy_status=$destroy_status"

if [ "$destroy_status" -ne 0 ]; then
    record stopped "shutdown_mode=orderly orderly_drain=completed destroy=failed status=$destroy_status"
    printf 'shutdown_mode=orderly\norderly_drain=completed\nteardown_exclusion=not_established\n'
    flock -u 9
    exec 9<&-
    # Failure preserves the closed admission state for explicit recovery.
    exit 1
fi

record stopped 'shutdown_mode=orderly orderly_drain=completed teardown_exclusion=orderly'
printf 'shutdown_mode=orderly\norderly_drain=completed\nteardown_exclusion=orderly\n'
flock -u 9
exec 9<&-
qwen_barrier_set_state running
