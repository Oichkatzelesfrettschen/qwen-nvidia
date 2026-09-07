#!/bin/sh
# The admission barrier: the mechanism that stops new GPU work from entering
# while a session or a child retires, kept deliberately apart from the compute
# lease.
#
# flock(2) associates a lock with the open file description, so an independent
# open of a path is a separate lock participant. An orchestrator that held the
# compute lease while waiting for a child whose destructor opens and acquires
# that same lease would therefore deadlock: the child cannot take what the
# parent holds while the parent waits for the child. The barrier lives on its
# own pathnames and the orchestrator never takes the lease, so the two subjects
# stay separate -- the orchestrator prevents new work, and the retiring child
# takes the lease for its own teardown.
#
# Two files carry the two questions a drain asks, because one lock cannot
# answer both without starving:
#
#   admission.barrier   holds the state word. A reader takes LOCK_SH and a
#                       writer LOCK_EX, both briefly, so a state flip never
#                       waits on a running job.
#   admission.inflight  holds one LOCK_SH per admitted job for that job's whole
#                       duration. The orchestrator's LOCK_EX on it is the drain
#                       wait itself: it is granted exactly when every job that
#                       was admitted has finished.
#
# Linux grants a pending LOCK_EX no priority over later LOCK_SH requests, so a
# stream of arrivals would starve an exclusive waiter that had nothing else
# stopping them. The state word is what stops them, and the order matters: the
# state is flipped first, so every later admission refuses, and the exclusive
# acquisition that follows waits on a set that can only shrink.
#
# An admitting participant re-reads the state after it holds its in-flight
# share, which closes the window between reading `running` and being counted.
# A participant that passed that second read holds a share the drain waits for;
# one that reaches it after the flip releases and refuses.
set -eu

# The barrier's own pathnames. QWEN_GPU_ADMISSION_BARRIER names the directory
# rather than either file, because the two are one mechanism and a caller that
# could name them separately could point them at different directories.
qwen_barrier_directory() {
    printf '%s' "${QWEN_GPU_ADMISSION_BARRIER:-${QWEN_WEBUI_STATE_DIRECTORY:-${HOME:?}/qwen-webui-state}}"
}

qwen_barrier_state_path() { printf '%s/admission.barrier' "$(qwen_barrier_directory)"; }
qwen_barrier_inflight_path() { printf '%s/admission.inflight' "$(qwen_barrier_directory)"; }

# A barrier whose files are absent reads `running`, so a session that never
# armed one admits work exactly as it did before this mechanism existed.
qwen_barrier_initialize() {
    qwen_barrier_init_directory=$(qwen_barrier_directory)
    [ -d "$qwen_barrier_init_directory" ] || mkdir -p "$qwen_barrier_init_directory"
    [ -e "$(qwen_barrier_state_path)" ] || printf 'running\n' > "$(qwen_barrier_state_path)"
    [ -e "$(qwen_barrier_inflight_path)" ] || : > "$(qwen_barrier_inflight_path)"
}

# Read the state word under a shared lock, so a read never observes a partial
# write. An absent file reads `running` rather than failing, which keeps the
# barrier optional for a caller that armed none.
qwen_barrier_state() {
    qwen_barrier_state_file=$(qwen_barrier_state_path)
    [ -f "$qwen_barrier_state_file" ] || { printf 'running'; return 0; }
    {
        flock -s 8 || { printf 'unreadable'; return 0; }
        head -n 1 <&8 | tr -d '\n'
    } 8< "$qwen_barrier_state_file"
}

# The state word is updated on the locked inode. Shared readers wait through
# truncation and publication under the exclusive lock; replacing the pathname
# would leave an earlier reader attached to an obsolete running state.
qwen_barrier_set_state() {
    qwen_barrier_new_state=$1
    case $qwen_barrier_new_state in
        running | quiescing) ;;
        *) printf 'barrier state takes running or quiescing: %s\n' \
            "$qwen_barrier_new_state" >&2; return 2 ;;
    esac
    qwen_barrier_initialize
    qwen_barrier_state_file=$(qwen_barrier_state_path)
    {
        flock -x 9 || return 1
        printf '%s\n' "$qwen_barrier_new_state" > "$qwen_barrier_state_file"
    } 9<> "$qwen_barrier_state_file"
}

# Admit one job: refuse where the state is quiescing, take the in-flight share,
# then read the state again under that share. The second read is what makes the
# admission atomic against a concurrent flip.
#
# The caller passes the descriptor number the share is held on, and keeps that
# descriptor open for the whole job. Closing it releases the share, which is
# what lets the drain's exclusive acquisition complete.
qwen_barrier_admit() {
    qwen_barrier_admit_fd=$1
    [ "$(qwen_barrier_state)" = running ] || { printf 'refused state=quiescing\n'; return 1; }
    flock -s -n "$qwen_barrier_admit_fd" || { printf 'refused state=draining\n'; return 1; }
    if [ "$(qwen_barrier_state)" != running ]; then
        flock -u "$qwen_barrier_admit_fd"
        printf 'refused state=quiescing_after_share\n'
        return 1
    fi
    printf 'admitted\n'
}

# Wait for every admitted job to finish, bounded. The exclusive acquisition is
# the drain: it is granted when no share remains. A caller reaches this only
# after the state is quiescing, so the set of shares can only shrink.
qwen_barrier_drain() {
    qwen_barrier_drain_fd=$1
    qwen_barrier_drain_deadline=$2
    if [ "$(qwen_barrier_state)" != quiescing ]; then
        printf 'drain_refused reason=state_is_not_quiescing\n' >&2
        return 2
    fi
    qwen_barrier_drain_waited=0
    while :; do
        if flock -x -n "$qwen_barrier_drain_fd"; then
            printf 'drained waited_ms=%s\n' "$qwen_barrier_drain_waited"
            return 0
        fi
        [ "$qwen_barrier_drain_waited" -lt "$qwen_barrier_drain_deadline" ] || {
            printf 'drain_deadline waited_ms=%s\n' "$qwen_barrier_drain_waited"
            return 1
        }
        sleep 0.05
        qwen_barrier_drain_waited=$((qwen_barrier_drain_waited + 50))
    done
}

# The barrier's identity, so a participant handed a path can refuse one that
# differs from the session's rather than serializing against another inode.
# sidecar_runtime.require_lease_identity applies the same rule to the lease.
qwen_barrier_identity() {
    qwen_barrier_identity_file=$1
    [ -e "$qwen_barrier_identity_file" ] || { printf 'absent'; return 1; }
    stat -c '%d:%i' "$qwen_barrier_identity_file"
}

qwen_barrier_require_identity() {
    qwen_barrier_require_file=$1
    qwen_barrier_require_expected=$2
    qwen_barrier_require_actual=$(qwen_barrier_identity "$qwen_barrier_require_file") || {
        printf 'barrier_identity=absent path=%s\n' "$qwen_barrier_require_file" >&2
        return 1
    }
    [ "$qwen_barrier_require_actual" = "$qwen_barrier_require_expected" ] || {
        printf 'barrier_identity=mismatch expected=%s actual=%s\n' \
            "$qwen_barrier_require_expected" "$qwen_barrier_require_actual" >&2
        return 1
    }
    printf 'barrier_identity=match %s\n' "$qwen_barrier_require_actual"
}
