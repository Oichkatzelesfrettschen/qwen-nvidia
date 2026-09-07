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
#
# `teardown_exclusion=orderly` is emitted from positive readings alone, never
# from the absence of a complaint. Three sources have to agree, because each
# names a way the transition can succeed while excluding nothing:
#
#   supervision  the admitted job is waited for by the process holding its
#                share, so a signalled admitter does not hand the drain a free
#                lock with live work behind it
#   identity     the inode drained is the one this retirement began against,
#                so a replaced pathname is refused rather than trivially
#                drained while a share on the old inode is still held
#   teardown     the destroy step reported that it held the compute lease
#
# The teardown reading takes the three values the tree already reads a served
# arm by: held, `not_established` where the step reports `held=no`, which is a
# successful termination rather than exclusion, and `unattributed` where the
# step's output carries no such line at all.
#
# Exit status: 0 where the exclusion reads orderly, 4 where the transition
# completed with the exclusion unproven, and 1 where the drain or the destroy
# step failed. A caller testing for 0 therefore gets the strict reading.
set -eu

usage() {
    printf 'usage: %s retire [--deadline MS] [--record FILE] -- COMMAND [ARGUMENT...]\n' "$0" >&2
    printf '       %s admit [--record FILE] -- COMMAND [ARGUMENT...]\n' "$0" >&2
    printf '       %s status|resume\n' "$0" >&2
    printf '  retire  quiesce, drain, then run COMMAND as the destroy step\n' >&2
    printf '  admit   run COMMAND holding one in-flight share, refused while quiescing\n' >&2
    printf '  exit    0 orderly, 4 transition complete with exclusion unproven, 1 failed\n' >&2
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
    #
    # The job is a supervised background child rather than a foreground command,
    # because the share has to outlive a signal to this admitter. The kernel
    # releases a flock when the last descriptor referring to it closes, so an
    # admitter that exited on SIGTERM while its child kept running would leave
    # the drain a free lock with live GPU work behind it -- the opposite residue
    # to the inherited descriptor, and the same wrong answer.
    "$@" 8<&- &
    job_pid=$!
    record running "job_started pid=$job_pid"
    # A terminating signal is forwarded to the child, and the share is held
    # until the child actually leaves. SIGKILL to this admitter drops the share
    # with the child alive; that is the emergency exception the policy already
    # reserves rather than a case this supervision closes.
    trap 'record running "signal_forwarded pid=$job_pid"; kill -TERM "$job_pid" 2>/dev/null || true' TERM INT HUP
    # `wait` returns above 128 when a trapped signal interrupts it, with the
    # child still alive, so the loop waits again rather than reading that as the
    # job's own status. The status kept is the one `wait` reported when it
    # actually reaped, and the child's absence is what ends the loop.
    while :; do
        admit_status=0
        wait "$job_pid" || admit_status=$?
        kill -0 "$job_pid" 2>/dev/null || break
    done
    record running "job_complete status=$admit_status"
    flock -u 8
    exec 8<&-
    exit "$admit_status"
fi

# retire: the whole lifecycle, one transition at a time.
# The identity compared against is the one the barrier was armed with rather
# than the one this retirement happens to find, because a replacement that
# landed before the retirement began would otherwise re-record itself as the
# subject and drain an inode no participant holds a share on.
record running "retire_begin inflight_identity=$(qwen_barrier_session_identity)"

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

# The drain was granted on descriptor 9. Whether that is still the inode this
# retirement began against is a separate question, and an exclusive lock on a
# replacement inode says nothing about a share held on the original.
identity_reading=$(qwen_barrier_verify_session_identity) || identity_reading=mismatch
record ready_to_destroy "state=$(qwen_barrier_state) inflight=none inflight_identity=$identity_reading"

# The retiring process takes the compute lease in its own destructor. This
# controller holds the barrier and never that lease, so the child can.
destroy_status=0
# The step's output is retained so its teardown line can be read. A successful
# exit says the process left, and the exclusion asks whether it held the lease
# while it freed, which is a different claim carried on a different line.
#
# Descriptor 9 is this controller's exclusive in-flight reference and it is
# closed in the child, because a destroy child that outlived the controller
# would hold the barrier closed against every later admission.
destroy_log=$(mktemp "${TMPDIR:-/tmp}/qwen-drain-destroy.XXXXXX")
trap 'rm -f "$destroy_log"' EXIT
QWEN_DRAIN_MODE=orderly "$@" 9<&- >"$destroy_log" 2>&1 || destroy_status=$?
cat "$destroy_log"

# The three readings the tree already gives a served arm: held, a reported
# `held=no` which is a successful termination rather than exclusion, and
# `unattributed` where no such line was written at all.
if grep -qE 'teardown[:_ ]+held=yes' "$destroy_log"; then
    teardown_reading=held
elif grep -qE 'teardown[:_ ]+held=no' "$destroy_log"; then
    teardown_reading=not_held
else
    teardown_reading=unattributed
fi
record destroying "destroy_status=$destroy_status teardown_reading=$teardown_reading"

if [ "$destroy_status" -ne 0 ]; then
    record stopped "shutdown_mode=orderly orderly_drain=completed destroy=failed status=$destroy_status"
    printf 'shutdown_mode=orderly\norderly_drain=completed\nteardown_exclusion=not_established\n'
    flock -u 9
    exec 9<&-
    # Failure preserves the closed admission state for explicit recovery.
    exit 1
fi

# The exclusion is emitted from the readings rather than from the absence of a
# failure. Every source has to be positive; anything else names which one was
# not, and a caller testing for exit 0 gets the strict reading.
if [ "$identity_reading" != match ] && [ "$identity_reading" != unrecorded ]; then
    exclusion=not_established
    exclusion_status=4
elif [ "$teardown_reading" = held ]; then
    exclusion=orderly
    exclusion_status=0
elif [ "$teardown_reading" = unattributed ]; then
    exclusion=unattributed
    exclusion_status=4
else
    exclusion=not_established
    exclusion_status=4
fi
record stopped "shutdown_mode=orderly orderly_drain=completed teardown_exclusion=$exclusion inflight_identity=$identity_reading teardown_reading=$teardown_reading"
printf 'shutdown_mode=orderly\norderly_drain=completed\nteardown_exclusion=%s\n' "$exclusion"
flock -u 9
exec 9<&-
qwen_barrier_set_state running
exit "$exclusion_status"
