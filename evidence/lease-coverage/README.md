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
load's deadline, because a shutdown blocked behind a 300 second generation
would outlive the absence `qwen-teardown.sh` proves, while a free that overlaps
a holder costs that holder a device synchronize rather than correctness. The
teardown line names which of the two happened, so a free outside the lease is
recorded rather than assumed away.

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
| `shutdown_while_decode_waits` | outlives the request | `SIGTERM` ends a server blocked in the decode acquire inside 30 s, with the holder's lock intact |
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
`partial`, so a six-arm run never states a seven-arm result.

`shutdown_while_decode_waits` requires the bound and the residue rather than one
of the two mechanisms, so it records which one ran: the blocking acquire writes
its own line on `EINTR`, and the absence of that line names the default
disposition instead. The arm reports `by=eintr` or `by=signal` beside its
elapsed time.

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

## What closes it

The source is written, its reach is read, and the mutation controls
discriminate. The build and the served arms remain, and `served=accepted`
requires the positive control in place, so `partial` is the honest terminal
state until a device window runs them.
