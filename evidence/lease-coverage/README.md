# Compute lease coverage of the model load path

`scripts/test-load-lease-coverage.sh` states one claim: the compute lease that
admits one active device workload also admits the load that uploads a model and
a projector to CUDA0. This directory retains the reading taken before any
extension, so the change that closes the gap is measured against a recorded
starting state rather than against a remembered one.

## What the reading says

`promoted-closure-88681bf4d161.log` is the run against the tree as the
promoted closure serves it:

```text
load_path load_model=1078..1436 weights=1171 projector=1234
load_lease_coverage=refused reach=refused served=not_run failures=2
```

The reach stage applies the patch to a copy of the pinned
`tools/server/server-context.cpp` and reads the result, so every position is a
line the compiler would see rather than a line a hunk carried. In the patched
file `load_model` spans 1078 to 1436, `common_init_from_params` uploads the
weights at 1171 and `mtmd_init_from_file` the projector at 1234, while the
descriptor opens at 1440 inside `init()` and the acquire sits at 2842 inside
`update_slots`, so both device allocations complete before either lease call
executes. The `if (!is_resume)` guard at 1427 skips the `init()` call at 1428,
so a wake returns at 1435 and re-uploads every weight under whatever state the
first load left.

The coverage predicate answers six synthetic files before it answers this one:
an acquire and open inside `load_model` ahead of the upload reads `covered`,
while the same pair placed after the upload, a line comment naming them, a
block comment naming them, a string literal carrying both names, and an acquire
ahead of its own open each read `uncovered`. That is what separates reading
executed order from reading hunk membership.

The reading stays textual over the patched file, and the three added predicates
inherit that scope exactly. None of them follows control flow: a synchronize
inside a branch that does not run still arms the release after it, a statement
of the right shape in the right window still reads as the sleeping refusal, and
a return that a sibling condition guards still reads as leaving the unlock
failure. What they exclude is the class of change this patch could plausibly
receive -- a call moved, removed, renamed, or demoted to a comment -- and the
four mutations above are that class. A call reached through a preprocessor
branch this host compiles out would still count as present, and no part of the
reach stage observes a running process, so the stage settles which change to
make and settles nothing about what a request behind a held lease receives.
The served stage is what measures that, and it reports `not_run` here.

Two properties fail:

| Property | Reading | Consequence |
| --- | --- | --- |
| `load_path_covered` | no | a router child's model and projector upload beside an image generation the lease separates them from |
| `lease_wait_bounded` | no | `flock(LOCK_EX)` blocks until signalled, so a load behind a 300 s generation stalls its HTTP request without a deadline |

## What the reading does not say

The promoted closure `88681bf4d161` carries no lease patch at all:
`scripts/verify-llama-patch-series.sh:85` lists
`llama-server-vulkan-workload-lease.patch` among the candidates, armed under
`QWEN_LLAMA_CANDIDATE_PATCHES=1` alone. The two failures above therefore
describe the candidate's reach, and what production serves is a llama-server
outside the lease at every point. `image-service.py`, `physics-service.py`, and
`geometry-service.py` are the three participants that hold it today.

The served stage reports `not_run reason=no_patched_server`. Its arms are
described below; both a patched binary and a device window are still
outstanding.

## What the extension reads

`extended-patch-reach.log` is the same test against the extended patch:

```text
load_path load_model=1234..1631 weights=1366 projector=1429
ok load_path_covered covered open=1242 acquire=1270 calls=workload_lease_acquire_bounded weights=1366
ok load_allocations_ordered weights=1366 projector=1429 spec=1399
ok sleep_refused_before_acquire refuses refusal=1264 returns=1267 acquire=1270
ok release_after_device_completion synchronized releases=2
ok release_failure_preserves_hold preserved unlock=1125 refusal=1131 cleared=1134
ok resume_skips_init guard=1622 init_call=1623
ok lease_wait_bounded workload_lease_acquire_bounded=980..1030 blocks on no flock
load_lease_coverage=partial reach=accepted served=not_run
```

The open sits at 1242 and the acquire at 1270, both inside `load_model` and
ninety-six lines ahead of the weights upload, with the sleeping refusal between
them at 1264. `load_allocations_ordered` is what lets one comparison cover three
uploads: the weights at 1366 precede the draft context at 1399 and the projector
at 1429, so an acquire ahead of the first is ahead of all of them, and a
reordering upstream fails the check rather than silently narrowing the claim.

Fifteen synthetic files answer before the real one. Each predicate carries a
body that satisfies it and bodies that do not, so an ordering read over line
numbers is proved to discriminate rather than assumed to: an acquire after the
upload, in a line comment, in a block comment, in a string literal, or ahead of
its own open all read `uncovered`; a sleeping refusal beneath the acquire or
absent reads `admits`; a release without a preceding synchronize, or a second
release under one synchronize, reads `unsynchronized`; and a release body that
clears `workload_lease_held` on the path a refused unlock takes reads `cleared`,
whether the clearing is unguarded or reached by falling out of a latch that
returns only the first time.

Each predicate is written against a demonstrated false positive rather than
against its intent. `(void) params.sleep_idle_seconds;` names the field and
refuses nothing, so the refusal is admitted only where a `return false` sits
inside its own block ahead of the acquire. A synchronize in `destroy()` covers
no release in `update_slots`, so the call sites carry their enclosing function
and a release answers `unsynchronized` unless the synchronize shares it. A
`return false` nested inside the error latch leaves the second failure falling
through to the assignment, so the return is read at the depth the failure block
opens rather than anywhere inside it.

Four mutations of the real patched file confirm the same split end to end, each
caught by its own predicate and by no other: removing the synchronize ahead of
the idle release reads `unsynchronized`; removing the sleeping refusal reads
`admits refusal=absent`; letting the refused unlock fall through to the
assignment reads `cleared refusal=absent`; and swapping
`workload_lease_acquire_bounded` for the blocking `workload_lease_acquire` at
the load call site keeps `load_path_covered` passing and fails
`lease_wait_bounded` on one `flock` call.

The reading stays textual over the patched file. A call reached through a
preprocessor branch this host compiles out would still count as present, and no
part of the reach stage observes a running process, so it settles which change
to make and settles nothing about what a request behind a held lease receives.

The terminal state reads `partial` rather than `accepted`, because the served
stage still has no patched binary to drive.

`QWEN_LLAMA_CANDIDATE_PATCHES=1 scripts/verify-llama-patch-series.sh` applies
the whole candidate stack on top of it, so the extension composes with
`llama-cuda-mmvq-crossover-ad104`, `llama-cuda-paged-kv-buffer`, and
`llama-mtmd-device-embd` rather than displacing them.

## The lifetime the extension claims

The acquire precedes every device allocation the load performs: the weights
through `common_init_from_params`, the draft context through
`common_speculative_init_from_params`, the projector through
`mtmd_init_from_file`, and the warmup decode inside the first of those. One
device step stays outside the hold and the evidence names it rather than
leaving it to be found: `common/arg.cpp` calls `ggml_backend_load_all()` while
parsing argv, ahead of `load_model`, which under `GGML_BACKEND_DL=OFF` registers
the statically linked backends and enumerates the device. That step allocates no
device memory and submits no graph.

A host function returning is not device completion. `llama_decode` queues its
graph on the backend stream and returns, so `workload_lease_sync_device` calls
`llama_synchronize` on the target context and on the draft context where one
exists, and every release site runs it first. `destroy()` synchronizes while
`ctx_tgt` and `ctx_dft` still name the contexts, frees, and releases last,
because tearing a context down is device work of this server's own; the idle
transition in `update_slots` synchronizes and releases in the same order. The
call sits at the ownership transition rather than in the token loop, so an idle
transition pays it once and a decoded token pays nothing.

The release reports what the kernel confirmed. `flock(LOCK_UN)` fails before it
changes anything -- `EBADF` or `EINVAL` on the descriptor, never a partial
release -- so a failure leaves the lock held and `workload_lease_held` stays
true to say so. Clearing it would let the next acquire return true on an
in-memory assertion the kernel refused, which is the one state the lease exists
to exclude; keeping it costs fairness instead, since every other holder waits on
a lock this process still owns until the descriptor closes with the process. The
idle transition repeats on every pass, so `workload_lease_release_failed` latches
that error line to one.

Lease coverage is admitted with inactivity sleeping disabled, and `load_model`
refuses the configuration that asks for both ahead of the acquire and of every
upload. `server_context::start_loop` passes `params_base.sleep_idle_seconds *
1000` to `server_queue::start_loop`, whose `should_sleep()` returns false for a
negative interval alone, so sleeping is on at zero as well as above it and the
field's own "if >0" comment in `common/common.h` understates the range. What the
refusal avoids is a wake `load_model` cannot decline: `handle_sleeping_state`
calls it and turns a false return into
`GGML_ABORT("failed to reload model after sleeping")` at
`server-context.cpp:919`, so under sleeping a lease an image generation holds
past the deadline ends the server rather than waiting for it. Declining the wake
and staying asleep instead needs `server_queue::on_sleeping_state` to carry a
result rather than `void`, since its caller clears the queue's sleeping flag
whatever the callback did; that is a queue-state transition of its own. Router
eviction and a fresh child load are a different mechanism and stay supported.

An idle server released the lease at its last `all_idle` pass, so a teardown
from `~server_context_impl` arrives holding nothing and takes it back for the
frees. The attempt is one non-blocking try -- `workload_lease_acquire_bounded`
takes its deadline as an argument and 0 names exactly that -- rather than the
load's deadline, because a shutdown blocked behind a 300 second generation would
outlive the absence `qwen-teardown.sh` proves. The attempt's result gates
nothing: `destroy()` synchronizes and frees whether it won the lease or lost it,
and the teardown line names which of the two happened.

That is an exception in the contract rather than a fourth claim, and it is
stated as one because the measurements here do not establish what the overlap
costs. The CUDA driver documentation permits a deallocation to synchronize
implicitly; a permission is not an application-level guarantee that this
teardown participates in the shared lease, so the overlap is neither
demonstrated harmless nor demonstrated harmful. Two processes freeing their own
allocations is also not by itself memory corruption. What the lease claims is
therefore four things:

```text
load, upload, and warmup exclusion   candidate claim, awaiting device admission
evaluation exclusion                 candidate claim, awaiting device admission
orderly teardown exclusion           holds where the teardown owns the lease
contended teardown                   explicit unprotected-cleanup exception
```

The seven arms measure the current behavior against a fixture holder that opens
no CUDA context, so a shutdown arm reading `teardown_held=no` is a successful
termination rather than successful teardown exclusion. The third reading is
`unattributed`, and it is unattributed because the patch writes that line inside
`if (!workload_lease_held)`: a teardown arriving with the lease already held
writes nothing there and frees inside it, a process ended by default disposition
never reaches `destroy()` at all, and the log separates those two in no way,
since the idle release and the teardown release print the same string. The
patch's own comment at that site asserts that a free overlapping a holder costs
that holder a device synchronize rather than correctness; that assertion is not
established by anything measured here, this record governs over it, and the
comment is corrected at the next rebuild rather than now, because the built
closure's `source_diff_sha256` is the identity the admission runs under. Closing the exception is a
policy rather than a longer wait, since an emergency exit that blocked
indefinitely would trade a bounded shutdown for a diagram: ordinary router
eviction and orderly session teardown drain the active holder before destroying
an idle child, and unleased cleanup stays reserved for an emergency termination
the record names. That policy is a combined-session promotion gate and its test
is separate from the signal arms, which measure a bound rather than a policy.

## What the served stage measures

Seven arms, each naming its own hold, its own deadline, and its own required
outcome, because a refusal and a successful wait are two behaviors and one arm
that accepts either measures neither. Elapsed time reads `/proc/uptime` rather
than the wall clock, since a clock step under NTP moves a deadline the kernel
does not honor.

| Arm | Hold | Required outcome |
| --- | --- | --- |
| `load_after_wait` | outlives the observation, released explicitly | no health under the hold, the hold proved still held when the window closed, the log naming the wait and the acquire, then the same process loads, answers, and frees the lease at its first idle pass |
| `decode_waits` | taken after the load, released later | no completion inside the hold, then the same request completes with no second request sent |
| `shutdown_while_decode_waits` | outlives the request | `SIGTERM` reaches a server blocked in the decode acquire and the server ends inside 30 s of its client's departure, with the holder's lock intact. The client leaves first because a llama-server at this pin completes no shutdown while a client is attached to a request no pass will answer, on the promoted closure as well as this one; `shutdown-stall/` measures that and the arm records the attached interval rather than grading it |
| `refused_on_deadline` | outlives the deadline | the server ends naming the deadline, with no loader line ahead of it |
| `recovery_after_refusal` | released | an explicit fresh attempt loads and answers |
| `shutdown_while_load_waits` | outlives the wait | `SIGTERM` ends the waiting server inside 30 s with the holder's lock intact |
| `projector_load` | outlives the observation, released explicitly | the projector-bearing load obeys the same admission |

The two shutdown arms are separate because two mechanisms end the process.
`server.cpp` installs its `SIGINT` and `SIGTERM` handlers at `:489`, after the
`load_model` call at `:465`, so a signal inside the load path's own wait carries
the default disposition while a signal inside a decode wait returns `EINTR` from
`flock(LOCK_EX)` under `sa_flags = 0`. Each arm measures the bound and the
residue; neither claims the other's path.

Health staying absent under a hold is also what a server that ignored the lease
and uploaded slowly produces, so `load_after_wait` and `projector_load` read the
wait itself out of the log -- the `waiting` line the acquire writes before it
blocks, and the `acquired ... bound=deadline` line it writes after -- rather
than treating absence of health as proof of admission. Those two lines are not
enough on their own either: a holder that expired under the observation window
produces one `EWOULDBLOCK` and both lines while measuring nothing. The holder
therefore outlives the window by a wide margin, the arm proves with `flock -n`
that the lock was still held when the window closed, and the explicit release is
the event that admits the load, so the arrival is attributable to the release
rather than to a timer.

An arm that cannot run is a partial stage rather than an accepted one: without
`QWEN_LEASE_TEST_MMPROJ` the projector arm reports `not_run` and the stage reads
`partial`, so a six-arm run never states a seven-arm result. Two runs reach
`partial` for two different reasons and `served_reason` is what separates them.
`QWEN_LEASE_PROJECTOR_POLICY` carries the registry's own `projector` field:
under `none` the projector arm reports `projector_none_declared` and the stage
reads `text_arms_only_projector_none`, which is the whole admission that
checkpoint's tuple allows, and under any other value an absent projector reads
`projector_arm_not_run`, which is an incomplete admission of a row that requires
one. A text-path result is therefore never read later as a multimodal one, and
neither reading is promoted to `accepted`.

`shutdown_while_decode_waits` requires the bound and the residue rather than one
of the two mechanisms, so it records which one ran: the blocking acquire writes
its own line on `EINTR`, and the absence of that line names the default
disposition instead. The arm reports `by=eintr` or `by=signal` beside its
elapsed time.

The seven arms start the server without speculation, so `ctx_dft` is null in
every one of them and `workload_lease_sync_device`'s draft-context branch goes
unexecuted. A measured MTP-capable production row under router admission is what
reaches it, read the established way through the absence of the `model has
unused tensor` lines an ordinary load prints, so the generic arms state nothing
about that path.

An unpatched `llama-server` handed a lease path loads and answers exactly as one
that skipped the lease would, because the open returns true on an unset name and
every acquire returns true while the descriptor is closed. The `vulkan workload
lease armed` line is therefore the positive control the stage reads before any
arm, and it doubles as proof that `QWEN_LLAMA_CANDIDATE_PATCHES=1` armed the
patch in the closure under test.

Each arm prints the three terms its allowance is built from -- the configured
lease wait, the admitted load time, and the readiness margin -- so a later
failure is diagnosed from recorded budgets rather than by raising a timeout. The
allowance never falls under the arm's own deadline, which is what keeps a
correctly waiting child from being killed by the guard above it.

Every termination the harness performs runs the same bounded escalation: signal,
poll for absence inside the deadline the caller names, escalate to `SIGKILL`,
and read absence back from the kernel. The two shutdown arms poll on their own,
because the elapsed time between the signal and the absence is what they
measure, and they hand the escalation to that same path. Each signal names itself with `-s`, because a bare `kill -1234` is read as a
signal specification rather than as the process group `-1234` and never reaches
the kernel, and the holder writes its own pid once its lock is taken, since
`setsid` execs into the child where the caller has no job control and forks
where it does. A blocking `wait` is precisely what an ignored
`SIGTERM` turns into an unbounded stall, which is unusable in a harness whose
own purpose includes testing a blocked shutdown, so the wait is a poll against
`/proc/uptime` and the reap follows the confirmed absence. A fixture holder that
outlived the escalation is a counted failure that refuses the stage, since every
arm after it would measure a lock this harness left behind rather than one its
own fixture took; the temporary state is retained and named rather than removed,
because removing a lock pathname under a live holder reports a device free that
no reading proved free. The bounded path answers a child that traps `SIGTERM`
and sleeps before any arm trusts it, and the counted path is answered through
the residue policy itself, since a child in uninterruptible sleep is the case
that reading exists for and no ordinary process reproduces it on demand.

`scripts/test-fixtures/fake-lease-llama-server.py` is what makes those arms
testable off the device. It performs the transitions the patch performs -- open
at load, bounded acquire ahead of the upload, blocking acquire per decode pass,
release at the idle transition, and the teardown line on the reacquire path --
and serves `/health` and `/completion`, so all ten served readings execute their
real control flow on a host with no GPU: the arms that need a wait to have
happened read one, the shutdown arms read `by=eintr` and the default
disposition, and the teardown classifier reads `yes` and `no` from a server that
takes both paths. It allocates nothing on a device and prints no loader line,
which is what arm C reads to separate a refusal that preceded an upload from one
that followed it. A passing run against it states that the harness reads what it
claims to read and states nothing about the closure under test.

`QWEN_LEASE_EVIDENCE_DIR` names a fresh directory -- the harness refuses a
non-empty one with a usage error ahead of the device -- that the served stage
retains its record into: one sanitized server log per launch with the home
prefix, the private hostname, and MAC addresses replaced, every completion body
the arms graded, one `outcomes.tsv` row per decision, one `timeline.tsv` row per
termination with its monotonic instant, the teardown state read out of each log,
and a `summary.tsv` carrying the terminal fields and the harness's own exit
status. Retention runs on the way out rather than at the terminal line, so a run
that ended inside an arm keeps the same record a run that reached the end does.

## What closes it

The source is written, its reach is read, the mutation controls discriminate,
and `candidate-build-source-identity.tsv` records the closure the arms run
against. The served arms remain, and `served=accepted` requires the positive
control in place, so `partial` is the honest terminal state until a device
window runs them.

Promotion needs more than those arms. The candidate matches the recorded
production architecture, payload counts, MMVQ thresholds, and specified
feature-marker state, and exact source equivalence to the historical production
build remains unresolved: matching counts of 187 cubins state that two builds
emitted the same number of objects rather than the same kernels. Resolving that
gap takes one of two routes -- recover the historical production source snapshot
and name the complete difference against the candidate, or build a clearly named
reconstructed lease-off companion from the candidate's own source and toolchain
and isolate the lease change against it, keeping the promoted binary as a
separate behavioral reference. A companion built that way is not the original
production source and carries no such label. The contended-teardown policy is
the other gate, and a passing functional arm is behavioral evidence rather than
a substitute for either.

The served stage's own refusal is a third item and it has moved.
`served-admission/` refused the closure on `shutdown_while_decode_waits`, and
`shutdown-stall/` names that bound as llama.cpp's own: the shutdown sits in
`ctx_http.thread.join()` while a worker waits inside
`server_response::recv_with_timeout` for a task the interrupted pass never
answered, and it ends at the client's departure one polling interval later, on
the promoted closure at 30.9 s held and 1.34 s to leave with no lease compiled
into it. The criterion was wrong rather than the closure, the arm now ends its
client before reading the bound, and the served stage needs one re-run under
that criterion before it reads `served=accepted`. That re-run is a device
window and no result stands in for it.
