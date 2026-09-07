# Drain before destroy, and what a fixture has to reach before the device does

The lease contract's third and fourth lines are a policy rather than a
measurement:

```text
orderly teardown exclusion   holds where the teardown owns the lease
contended teardown           explicit unprotected-cleanup exception
```

`destroy()` synchronizes and frees whether its one non-blocking attempt won the
lease or lost it, so an orderly teardown frees inside the lease and a contended
one frees beside another holder. Closing that is a transition policy: ordinary
router eviction and orderly session teardown drain the active holder before
destroying an idle child, and unleased cleanup stays reserved for an emergency
termination the record names. This directory is that policy's preregistration,
written before any implementation, so the arms are fixed ahead of the readings.

## Observing a free lease is not draining

The refuted design is the cheap one: sample the lease, find it free, signal the
server. Between the sample and the signal another admitted request acquires the
lease, and the teardown that follows is the contended case the policy exists to
remove. A drain is therefore a state machine whose transitions each carry an
executable condition, and the condition on entering destruction is that no
participant *can* acquire, rather than that none *did* at one instant.

```text
RUNNING            work is admitted and executes
  -> QUIESCING     new work is refused at the request entry points
  -> DRAINING      accepted work completes or is cancelled through a tested path
  -> READY_TO_DESTROY  accepted work is done and none can enter
  -> DESTROYING    the retiring process takes its own teardown lease and frees
  -> STOPPED       process, socket, artifact, credential, and lock residue absent
```

## The barrier is not the lease

`flock(2)` associates a lock with the open file description, so an independent
`open` of the same path is a separate participant. An orchestrator that held the
compute lease while waiting for a child whose destructor opens and acquires that
same lease would deadlock by construction: the child cannot get what the parent
is holding while the parent waits for the child.

The admission barrier is therefore a separate mechanism on a separate pathname,
and the two carry different subjects:

```text
orchestrator   holds the admission barrier and the top-level owner claim,
               and prevents new work from entering
retiring child acquires the compute lease for its own teardown
```

The barrier is released only after the intended transition completes, or the
session stays refused where recovery fails.

## What honors the barrier, and what cannot

The tree's own services read their entry points and can refuse there:
`image-service.py`, `physics-service.py`, and `geometry-service.py` each accept
one job at a time over a socket this repository owns. llama-server is upstream
and reads no barrier of this tree's invention, so a claim that it refuses new
work under QUIESCING would be false. What holds for it is narrower and is stated
as such: the session stops admitting requests to it and drains every sidecar
before signalling, and the request entry point that can be closed is the one in
front of it rather than one inside it. Teaching llama-server the barrier is a
patch and a separate transition; this record does not assume one.

## The emergency exception stays

A drain deadline does not become an unbounded wait. On expiry the transition is
recorded as unsuccessful, the established bounded escalation runs -- signal,
poll for absence inside a named deadline, escalate to `SIGKILL`, read absence
back -- and the result is classified rather than absorbed:

```text
shutdown_mode=emergency
orderly_drain=failed
teardown_exclusion=not_established
```

`teardown: held=no` is a successful termination and never an orderly-exclusion
pass. The first normal-drain admission uses bounded jobs that can finish;
request cancellation behind a held lease stays a separate obligation rather than
an assumption this test rests on.

Full-session quiescence and single-child eviction are separate cases. A session
drained whole proves nothing about a capacity-one router retiring one child
while keeping its own listener and service lanes alive, so the two carry their
own arms.

## What the existing fixture could reach before the controller existed

The table below is the preregistration: it was written against
`scripts/test-fixtures/fake-lease-llama-server.py` alone, before the barrier
and the drain controller existed, and it is retained as written. The reading
after it states what the implemented controller reaches, so the two together
show which capability each arm gained rather than replacing a prediction with
a result.

`scripts/test-fixtures/fake-lease-llama-server.py` was written for the signal
arms, and the eight discriminations this policy needs are mostly outside it.
Enumerating that before writing the lifecycle is deliberate: this harness has
three times shipped an arm no fixture shape could enter, and each time the
branch was found after the run rather than before it.

| Discrimination | Reachable today | What is missing |
| --- | --- | --- |
| an active holder finishes normally, and destruction starts only afterwards | no | the fixture has no drain state and announces no destruction boundary |
| a request arriving during quiescence is refused or deferred and cannot reopen execution | no | every `do_POST` is accepted; there is no barrier to consult |
| an idle child is evicted while another lane is active | no | the fixture models one process, with no lane or child roster |
| a client attached to completed work is told from an unanswered request | partial | `in_flight_count` and the two stall modes reach the unanswered case; an idle keep-alive connection is not distinguished from it |
| a request that cannot reach a terminal state takes the drain deadline's named failure path | no | no deadline exists on either side |
| a child that cannot obtain its teardown lease is not reported as an orderly teardown | partial | the `held=yes`/`held=no` line exists; the classification that refuses to read `no` as a pass does not |
| a holder or child surviving escalation retains its identity and reports residue | partial | `test-load-lease-coverage.sh` already implements the bounded escalation and the counted-failure residue policy, and it is reusable whole |
| a lease pathname change is refused rather than serialized against another inode | partial | `sidecar_runtime.require_lease_identity` does exactly this for the sidecars; the drain controller and the llama-server side have no counterpart |

Five of eight need new capability and three are partial, so the fixture work is
the majority of this transition rather than a step after it.

## What the controller reaches, read after implementing it

`scripts/qwen-drain-controller.sh` and `scripts/qwen-admission-barrier.sh`
supply the state word, the in-flight share, and the destroy boundary the table
above names as missing. Four suites read them and they read different
subjects: `scripts/test-qwen-drain-controller.sh` drives the lifecycle,
`scripts/test-admission-barrier.py` holds the Python participants to the shell
library's semantics, `scripts/test-drain-client-attachment.py` reads the
server stand-in, because one discrimination is about what an attached socket
means rather than about what the barrier holds, and
`scripts/test-drain-failure-boundaries.py` reads the paths a failure takes. Every row is joined to the
readings that decide it, since a label is not a claim:

| Discrimination | Reached | The readings that decide it |
| --- | --- | --- |
| an active holder finishes normally, and destruction starts only afterwards | yes | `drain_completed`, `destroy_follows_drain`, `destroy_saw_orderly_mode`, `retire_exit_orderly`, `teardown_orderly` |
| a request arriving during quiescence is refused or deferred and cannot reopen execution | yes | `quiescing_refuses_admission`, `quiescing_names_state`, `quiescing_ran_no_job`, `test_quiescing_refuses_admission`, and `test_a_flip_between_the_two_reads_refuses_after_the_share` for the reopening half |
| an idle child is evicted while another lane is active | partial | `eviction_waits_for_active_lane` and `idle_participant_releases` establish that a second lane delays the retirement and that a released share reads idle; both lanes are marker commands, so no idle child and no surviving listener are modelled |
| a client attached to completed work is told from an unanswered request | yes | `test_a_client_on_completed_work_does_not_hold_the_process` against `test_a_client_on_an_unanswered_task_holds_the_process`, and `idle_participant_releases` at the barrier |
| a request that cannot reach a terminal state takes the drain deadline's named failure path | yes | `deadline_refuses`, `deadline_mode`, `deadline_drain`, `deadline_exclusion`, `deadline_names_emergency_mode` |
| a child that cannot obtain its teardown lease is not reported as an orderly teardown | yes | `held_no_not_exclusion`, `held_no_exit_refuses_strict`, `silent_teardown_unattributed`, `failed_destroy_not_exclusion` |
| a holder or child surviving escalation retains its identity and reports residue | partial | `residue_holder_retained` and `residue_cleared_before_next_arm` establish that a surviving holder is retained and named, and `test_expired_drain_keeps_admission_closed` establishes that the expired path leaves admission closed rather than reopening it behind the survivor; the arms reach the survivor through a deadline rather than through a signal escalation, so the escalation itself is unexercised here and stays `test-load-lease-coverage.sh`'s |
| a lease pathname change is refused rather than serialized against another inode | yes | `swapped_admit_refuses`, `swapped_admit_names_identity`, `swapped_retire_not_exclusion`, `identity_mismatch_refuses`, `test_identity_reads_device_and_inode` |

Six of eight are reached and two are partial. An earlier reading of this table
said all eight, and it was wrong in a way worth recording rather than
overwriting: four rows named readings that existed and did not decide them.
Row 6's arm substituted a failing exit status for a step that cannot take the
lease, which left the case the row exists for -- a step that succeeds, holds
nothing, and is certified anyway -- untested. Row 8's readings called the
identity function directly while neither the admission path nor the retirement
consulted it. Row 4's control arm held a socket object against a stand-in
answering HTTP/1.0, so its attached client had already been closed by the
peer. Row 2's refusal was tested and its reopening half was not. Rows 3 and 7
remain partial and say so here.

`scripts/test-drain-failure-boundaries.py` reads a dimension the eight rows do
not name, which is what the lifecycle does after a transition fails rather than
what it does when one succeeds. A failed destroy and an expired drain each
called `qwen_barrier_set_state running`, reopening admission into a session
whose teardown had just failed; both preserve quiescence, and `resume` is the
explicit recovery, refused while an exclusive in-flight reference cannot be
taken. Those paths are the emergency-termination exception the
drain-before-destroy policy reserves, so a reading of them is a reading of what
the exception leaves behind rather than of the orderly path.

The fourth took two mechanisms rather than one, because the barrier's notion of
in flight is a held share and a server's is an unanswered task inside an HTTP
worker, and an orchestrator reading an open socket as work in flight would
refuse to retire a server with nothing left to do.
`scripts/test-drain-client-attachment.py` supplies the server half against
`scripts/test-fixtures/fake-lease-llama-server.py`: two arms differing in
whether the compute lease is held when the request arrives, so the uncontended
one is answered and its process leaves with the client still attached, and the
contended one is abandoned by the interrupted acquire and its process is held
until the client departs. The stand-in answers HTTP/1.1 for that arm to mean
anything, since the `BaseHTTPRequestHandler` default of HTTP/1.0 closes an
answered connection whatever the client asked for, and the arm establishes the
connection is open by waiting for a FIN that never comes rather than by peeking
once at an instant the FIN races.

Its arms assert on the server's own event lines -- the acquire's wait and that
wait's interrupted end -- and then on an outcome, since a first draft that
asserted on a settle interval read a held process as departed while a quality
gate loaded the machine beside it. The hold is checked as a negative claim over
a bound, which load can delay an event past and cannot make one appear: three
runs under twelve spinning threads agree with the idle runs.

## What each mutation established

A suite that passes under a mutation of the thing it names decides nothing, and
this harness has shipped that defect before. Each row reverts one mechanism and
names the arms that refuse the result; every mutation was restored and the file
compared byte for byte afterwards. The seven failure-boundary rows are calibrated
against the merged implementation rather than against the tree they were first
measured on, and each refuses exactly the one arm that names it;
`evidence/lease-coverage/drain-review-hardening/merged-mutation-summary.tsv`
retains that run and its own README scopes the per-file counts it reports to
commit `35a27e1`.

| Mutation | Caught by |
| --- | --- |
| the exclusion is emitted unconditionally, as the first implementation did | `held_no_not_exclusion`, `held_no_exit_refuses_strict`, `silent_teardown_unattributed`, `silent_exit_refuses_strict`, `swapped_retire_not_exclusion`, `swapped_retire_exit_refuses_strict` |
| the admitter runs its job in the foreground and exits on the signal | `orphan_share_held_after_signal` |
| the admission takes no identity reading | `swapped_admit_refuses`, `swapped_admit_names_identity` |
| `InFlightShare.__enter__` loses its second state read | `test_a_flip_between_the_two_reads_refuses_after_the_share` |
| the share is acquired blocking rather than `LOCK_NB` | `test_an_exclusive_holder_refuses_admission`, inside its own deadline rather than by hanging |
| the stand-in answers 503 where the interrupted acquire stalls | `test_a_client_on_an_unanswered_task_holds_the_process` |
| the stand-in answers HTTP/1.0 | `test_a_client_on_completed_work_does_not_hold_the_process`, on the control condition rather than the outcome |
| a service maps every barrier refusal onto the `quiescing_` prefix, as the first implementation did | `test_a_barrier_fault_reason_does_not_claim_quiescence`, on `draining` |
| a service keeps the state-word test and prefixes a fault `quiescing_` | `test_a_barrier_fault_reason_does_not_claim_quiescence`, on `barrier_identity_mismatch` |
| the state word is published by renaming a temporary file over the state path | `test_state_transition_preserves_locked_inode` |
| a failed destroy calls `qwen_barrier_set_state running` | `test_failed_destroy_keeps_admission_closed` |
| an expired drain calls `qwen_barrier_set_state running` | `test_expired_drain_keeps_admission_closed` |
| `resume` reopens admission without taking the exclusive in-flight reference | `test_resume_refuses_while_work_remains` |
| the destroy child inherits descriptor 9 | `test_destroy_child_does_not_inherit_drain_lock` |
| `InFlightShare.__enter__` closes its share on the two named refusals rather than on any raise | `test_second_read_failure_closes_acquired_share` |
| `InFlightShare.__exit__` closes after the unlock rather than in a `finally` | `test_unlock_failure_still_closes_descriptor` |
| the share descriptor loses its explicit `O_CLOEXEC` | nothing, and the arm says so: PEP 446 makes every `os.open` descriptor non-inheritable, measured as `FD_CLOEXEC` set under `O_RDONLY` alone on CPython 3.14.7, so the edit changes no behavior. The arm reads the property, which holds from two sources. |

Every reading above is a file, a lock, and a loopback socket on a host with no
GPU. None of them states that the policy holds on the device, and the arms that
would are the combined-session ones this record preregisters.

Assertions are on event ordering and operation identity rather than on sleeps.
Each participant records monotonic instants, a per-process event sequence
number, and the lease identity it verified, so an arm states which event
preceded which rather than that enough time passed.

## What is implemented, and what each piece is held to

`scripts/qwen-admission-barrier.sh` and `scripts/admission_barrier.py` are one
mechanism for the two kinds of participant, and
`scripts/test-admission-barrier.py` drives both against one barrier so a
disagreement between them fails rather than letting a drain complete while a
service still admits. Ten readings: an absent barrier admits, the state word
agrees across the pair, `quiescing` refuses, an exclusive holder refuses with
`draining`, a held share blocks the exclusive acquisition while a released one
does not, two shares coexist, the share is close-on-exec so a spawned runtime
cannot inherit it, a flip landing between the two state reads refuses after
the share and releases it, the identity reads device and inode, and every
refusal reason the barrier can raise is classified by the three services as
either a session state or a barrier fault.

That last reading exists because a refusal reason lands in an audit row and is
read later as a claim. The barrier refuses for two different reasons: the
session reached `quiescing`, `quiescing_after_share`, or `draining`, which are
positions on the lifecycle path and reach the reply unchanged; or the barrier
detected a fault while the session was still running, which reads
`barrier_<detail>`. `identity_mismatch` is the case that separates them, since
the in-flight file was replaced under a live session, and the first
implementation reported it as `quiescing_identity_mismatch` -- a quiescence
that never began. The arm reads the class out of each of the three services'
own source rather than importing them, so a copy that drifts fails there.

`scripts/test-drain-failure-boundaries.py` holds the lifecycle's failure paths
to eight readings: a failed destroy and an expired drain each leave admission
closed, `resume` refuses while an exclusive in-flight reference cannot be taken
and reopens once it can, a state flip lands on the locked inode rather than a
replacement, the share is closed when the second state read raises and when the
unlock raises, the destroy child holds none of the controller's descriptors,
and a spawned runtime cannot inherit the share even with `close_fds` disabled.

`scripts/qwen-drain-controller.sh` drives the lifecycle, and
`scripts/test-qwen-drain-controller.sh` holds it to thirty-six readings, each
asserting event order or an operation identity out of the controller's own
record rather than waiting an interval. Destruction follows the holder's
completion instant; a request arriving during quiescence is refused and runs no
job; two lanes both delay the retirement, so eviction waits on the declared
policy rather than on an incidental free-lock sample; a released share with the
process still alive reads idle, which is the distinction between an attached
connection and an unanswered request; a job that cannot finish takes the
deadline path and the outcome reads
`shutdown_mode=emergency orderly_drain=failed teardown_exclusion=not_established`
with its holder retained and named; a destroy step that fails drains and still
refuses `teardown_exclusion`; the barrier reopens whatever the outcome, so a
failure leaves the session admitting rather than wedged shut; and a barrier file
whose inode changed is refused at the admission and at the retirement rather
than serialized against.

`teardown_exclusion=orderly` is emitted from positive readings alone. Three
sources have to agree -- the admitted job was waited for by the process holding
its share, the inode drained is the one the barrier was armed with, and the
destroy step reported that it held the compute lease -- and anything else names
which source was not positive. The teardown reading takes the three values the
tree already reads a served arm by: held, `not_established` where the step
reports `held=no`, which is a successful termination rather than exclusion, and
`unattributed` where the step wrote no such line at all. Exit status carries the
same distinction, 0 for orderly and 4 for a transition that completed with the
exclusion unproven, so a caller testing for 0 gets the strict reading.

The first implementation emitted `orderly` from a destroy step's exit status
alone, which certified exactly the reading this record forbids two sections
above: a step that printed `teardown: held=no` and exited 0 was an orderly
exclusion pass. Its arm substituted a failing exit status for a step that cannot
take the lease, so the case the arm existed for went untested. The three faces
of that defect -- a signalled admitter's share released with its child alive, a
replaced inode drained trivially, and a successful exit read as exclusion -- are
one classification emitting a positive verdict from the absence of a negative
signal, and they are corrected as one rather than patched at three sites.

The three services consult the barrier at their own request entry points --
`image-service.py` around `run_job`, `physics-service.py` and
`geometry-service.py` around their `run` -- and each raises `ServiceQuiescing`,
whose audit row is a refusal rather than a failure. The share is taken outside
the compute lease and released after it, so a drain never waits on a lease a
service still holds.

Two implementation details are findings rather than choices, and they are the
two horns of one fork. The controller first ran its job command with the share's
descriptor inherited, and a job whose admitter was signalled left an orphan
holding the barrier: the next arm's drain then expired on a deadline with no
live job behind it. Closing that descriptor produced the opposite wrong answer,
since the kernel releases a flock when the last descriptor referring to it
closes: a signalled admitter exited and handed the drain a free lock with its
child still running. Neither residue is closed by the descriptor alone, so the
admitter supervises -- the job is a background child, a terminating signal is
forwarded to it, and the share is held until the child actually leaves. A
SIGKILL to the admitter still drops the share with the child alive, which is the
emergency exception the policy already reserves rather than a case this closes.

The identity is the same shape of finding. The controller compared the inode it
found when the retirement began, which a replacement landing before that point
would have re-recorded as the subject. The comparison is against the identity
the barrier was armed with instead, written once at creation, and both the
admission path and the retirement read it. A replacement that predates the
arming is its own consistent session; closing that needs every participant to
carry the identity it admitted against into a session-wide record, which is an
obligation this controller alone cannot discharge and which is stated here
rather than assumed away.

## What stays unmeasured

Every reading above is a file and a lock on a host with no GPU. What the
controller does is settled; what a served llama-server does inside these
transitions is not, and neither is what the lifecycle costs a live session. The
device arms belong to the combined-session campaign and are named there rather
than assumed here.

## What this does not reopen

The served lease campaign is accepted and is not re-run to raise a test count.
An arm is repeated only where the executable or the mechanism under it changes.
