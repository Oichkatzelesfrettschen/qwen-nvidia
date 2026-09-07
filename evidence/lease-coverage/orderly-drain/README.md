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
above names as missing, and `scripts/test-qwen-drain-controller.sh` and
`scripts/test-admission-barrier.py` are the arms that read them. Every row is
joined to the readings that decide it, since a label is not a claim:

| Discrimination | Reached | The readings that decide it |
| --- | --- | --- |
| an active holder finishes normally, and destruction starts only afterwards | yes | `drain_completed`, `destroy_follows_drain`, `destroy_saw_orderly_mode`, `teardown_orderly` |
| a request arriving during quiescence is refused or deferred and cannot reopen execution | yes | `quiescing_refuses_admission`, `quiescing_names_state`, `quiescing_ran_no_job`, `test_quiescing_refuses_admission` |
| an idle child is evicted while another lane is active | yes | `eviction_waits_for_active_lane`, `idle_participant_releases` |
| a client attached to completed work is told from an unanswered request | yes | `idle_participant_releases` at the barrier, and `test_a_client_on_completed_work_does_not_hold_the_process` against `test_a_client_on_an_unanswered_task_holds_the_process` at the server |
| a request that cannot reach a terminal state takes the drain deadline's named failure path | yes | `deadline_refuses`, `deadline_mode`, `deadline_drain`, `deadline_exclusion`, `deadline_names_emergency_mode` |
| a child that cannot obtain its teardown lease is not reported as an orderly teardown | yes | `failed_destroy_refuses`, `failed_destroy_drained`, `failed_destroy_not_exclusion` |
| a holder or child surviving escalation retains its identity and reports residue | yes | `residue_holder_retained`, `residue_cleared_before_next_arm` |
| a lease pathname change is refused rather than serialized against another inode | yes | `identity_match_reads_match`, `identity_mismatch_refuses`, `identity_mismatch_named`, `test_identity_reads_device_and_inode` |

All eight are reached. The fourth took two mechanisms rather than one,
because the barrier's notion of in flight is a held share and a server's is an
unanswered task inside an HTTP worker, and an orchestrator reading an open
socket as work in flight would refuse to retire a server with nothing left to
do. `scripts/test-drain-client-attachment.py` supplies the server half against
`scripts/test-fixtures/fake-lease-llama-server.py`: two arms differing in
whether the compute lease is held when the request arrives, so the uncontended
one is answered and its process leaves with the client still attached, and the
contended one is abandoned by the interrupted acquire and its process is held
until the client departs.

Its arms assert on the server's own event lines -- the acquire's wait and that
wait's interrupted end -- and then on an outcome, since a first draft that
asserted on a settle interval read a held process as departed while a quality
gate loaded the machine beside it. The hold is checked as a negative claim over
a bound, which load can delay an event past and cannot make one appear: three
runs under twelve spinning threads agree with the idle runs. Reverting the
fixture's stall to a 503 fails
`test_a_client_on_an_unanswered_task_holds_the_process` on the half that names
the refutation, and leaves the other two arms passing, so that arm alone
carries the discrimination and the other two carry the uncontended control and
the one-changed-dimension claim.

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
service still admits. Eight readings: an absent barrier admits, the state word
agrees across the pair, `quiescing` refuses, an exclusive holder refuses with
`draining`, a held share blocks the exclusive acquisition while a released one
does not, two shares coexist, the share is close-on-exec so a spawned runtime
cannot inherit it, and the identity reads device and inode.

`scripts/qwen-drain-controller.sh` drives the lifecycle, and
`scripts/test-qwen-drain-controller.sh` holds it to twenty-four readings, each
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
whose inode changed is refused rather than serialized against.

The three services consult the barrier at their own request entry points --
`image-service.py` around `run_job`, `physics-service.py` and
`geometry-service.py` around their `run` -- and each raises `ServiceQuiescing`,
whose audit row is a refusal rather than a failure. The share is taken outside
the compute lease and released after it, so a drain never waits on a lease a
service still holds.

One implementation detail is a finding rather than a choice. The controller
first ran its job command with the share's descriptor inherited, and a job whose
admitter was signalled left an orphan holding the barrier: the next arm's drain
then expired on a deadline with no live job behind it. The command now runs with
that descriptor closed, which is the residue rule `qwen-webui-session.sh`
already applies to the owner claim with `9>&-`, and the Python share is opened
`O_CLOEXEC` for the same reason.

## What stays unmeasured

Every reading above is a file and a lock on a host with no GPU. What the
controller does is settled; what a served llama-server does inside these
transitions is not, and neither is what the lifecycle costs a live session. The
device arms belong to the combined-session campaign and are named there rather
than assumed here.

## What this does not reopen

The served lease campaign is accepted and is not re-run to raise a test count.
An arm is repeated only where the executable or the mechanism under it changes.
