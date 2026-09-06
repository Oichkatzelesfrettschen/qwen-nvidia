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

The reading stays textual over the patched file. A call reached through a
preprocessor branch this host compiles out would still count as present, and no
part of the reach stage observes a running process, so it settles which change
to make and settles nothing about what a request behind a held lease receives.
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
load_path load_model=1218..1612 weights=1347 projector=1410
ok load_path_covered covered open=1226 acquire=1251 calls=workload_lease_acquire_bounded weights=1347
ok load_allocations_ordered weights=1347 projector=1410 spec=1380
ok sleep_refused_before_acquire refuses refusal=1245 acquire=1251
ok release_after_device_completion synchronized releases=2
ok release_failure_preserves_hold preserved unlock=1124 refusal=1130 cleared=1133
ok resume_skips_init guard=1603 init_call=1604
ok lease_wait_bounded workload_lease_acquire_bounded=978..1029 blocks on no flock
load_lease_coverage=partial reach=accepted served=not_run
```

The open sits at 1226 and the acquire at 1251, both inside `load_model` and
ninety-six lines ahead of the weights upload, with the sleeping refusal between
them at 1245. `load_allocations_ordered` is what lets one comparison cover three
uploads: the weights at 1347 precede the draft context at 1380 and the projector
at 1410, so an acquire ahead of the first is ahead of all of them, and a
reordering upstream fails the check rather than silently narrowing the claim.

Fourteen synthetic files answer before the real one. Each predicate carries a
body that satisfies it and a body that does not, so an ordering read over line
numbers is proved to discriminate rather than assumed to: an acquire after the
upload, in a line comment, in a block comment, in a string literal, or ahead of
its own open all read `uncovered`; a sleeping refusal beneath the acquire or
absent reads `admits`; a release without a preceding synchronize, or a second
release under one synchronize, reads `unsynchronized`; and a release body that
assigns `workload_lease_held = false` on the path a refused unlock takes reads
`cleared`.

Four mutations of the real patched file confirm the same split end to end, each
caught by its own predicate and by no other: removing the synchronize ahead of
the idle release reads `unsynchronized 3005`; removing the sleeping refusal
reads `admits refusal=absent`; letting the refused unlock fall through to the
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
refusal avoids is a state the patch cannot report through:
`handle_sleeping_state` reaches `load_model` on the wake, and
`server_queue::on_sleeping_state` takes a `void` callback whose caller clears the
queue's sleeping flag whatever the wake did, so a wake refused for the lease
would leave the queue admitting requests against a destroyed context.
Recoverable sleep and wake under the lease needs that callback to carry a
result, which is a queue-state transition of its own. Router eviction and a
fresh child load are a different mechanism and stay supported.

## What the served stage measures

Six arms, each naming its own hold, its own deadline, and its own required
outcome, because a refusal and a successful wait are two behaviors and one arm
that accepts either measures neither. Elapsed time reads `/proc/uptime` rather
than the wall clock, since a clock step under NTP moves a deadline the kernel
does not honor.

| Arm | Hold | Required outcome |
| --- | --- | --- |
| `load_after_wait` | released inside the deadline | no health under the hold, then the same process loads, answers, and frees the lease at its first idle pass |
| `decode_waits` | taken after the load, released later | no completion inside the hold, then the same request completes with no second request sent |
| `refused_on_deadline` | outlives the deadline | the server ends naming the deadline, with no loader line ahead of it |
| `recovery_after_refusal` | released | an explicit fresh attempt loads and answers |
| `shutdown_while_waiting` | outlives the wait | `SIGTERM` ends the waiting server inside 30 s with the holder's lock intact |
| `projector_load` | released inside the deadline | the projector-bearing load obeys the same admission |

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
