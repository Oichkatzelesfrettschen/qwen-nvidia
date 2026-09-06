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

The predicate answers six synthetic files before it answers this one: an
acquire and open inside `load_model` ahead of the upload reads `covered`, while
the same pair placed after the upload, a line comment naming them, a block
comment naming them, a string literal carrying both names, and an acquire ahead
of its own open each read `uncovered`. That is what separates reading executed
order from reading hunk membership.

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

The served stage reports `not_run reason=no_patched_server`. Its arms hold the
lease with a fixture owner under `setsid`, start the server against a model it
has yet to load, and read the observation window by wall clock while proving
the hold outlasted it, since an observation drawn after the lease went free
measures nothing. A server that exits inside the window counts as a refusal
only where its log names the acquire ending without the lease, because the
patch writes `vulkan workload lease armed` before it loads anything and a CUDA
or allocation failure after that line carries the word too. The release then
has to admit the load and the model has to answer. Both a patched binary and a
device window are still outstanding.

## What the extension reads

`extended-patch-reach.log` is the same test against the extended patch:

```text
load_path load_model=1178..1555 weights=1290 projector=1353
ok load_path_covered covered open=1191 acquire=1194 calls=workload_lease_acquire_bounded weights=1290
ok resume_skips_init guard=1546 init_call=1547
ok lease_wait_bounded workload_lease_acquire_bounded=977..1028 blocks on no flock
load_lease_coverage=partial reach=accepted served=not_run
```

The open sits at 1191 and the acquire at 1194, both inside `load_model` and
ninety-six lines ahead of the weights upload. The bound is read from the
function the load path names rather than from the file, because the two call
sites take two acquires: swapping `workload_lease_acquire_bounded` for the
blocking `workload_lease_acquire` at that call site keeps `load_path_covered`
passing and fails `lease_wait_bounded` on one `flock` call, so the two checks
discriminate independently.

The terminal state reads `partial` rather than `accepted`, because the served
stage still has no patched binary to drive: the reach stage settles which
change to make and settles nothing about what a request behind a held lease
receives.

`QWEN_LLAMA_CANDIDATE_PATCHES=1 scripts/verify-llama-patch-series.sh` applies
the whole candidate stack on top of it, so the extension composes with
`llama-cuda-mmvq-crossover-ad104`, `llama-cuda-paged-kv-buffer`, and
`llama-mtmd-device-embd` rather than displacing them.

## What closes it
The extension is written and its reach is read; the build and the served arms
remain. The open moves ahead of the acquire and both move to the top of
`load_model`. Order is the whole of it: an acquire returns true while
`workload_lease_descriptor` is negative, so an acquire moved on its own past a
descriptor still opened in `init()` admits every load while reporting success.
`scripts/test-load-lease-coverage.sh` proves its own predicate against that
case before it reads the real file.

The wait bound belongs to the caller rather than to the lease, so the two call
sites take two acquires. A load has a caller that carries a refusal, and the
owner lock above this one refuses at once with status 75, so an unbounded
acquire beneath it turns that refusal into a stall:
`workload_lease_acquire_bounded` polls `LOCK_EX | LOCK_NB` every 50 ms under a
`QWEN_GPU_COMPUTE_LEASE_WAIT_S` deadline, 300 seconds by default. A decode pass
keeps the blocking acquire, because `server_queue::start_loop` re-enters
`callback_update_slots` only when a task arrives or the process terminates, so
a pass that gave up on the lease would strand its request until unrelated
traffic woke the loop, and a chat turn waiting behind a generation is what the
lease is for. Polling bounds a wait and buys no cancellation: `server_queue`
keeps its running flag private with no accessor and `server.cpp`'s
`is_terminating` is file static, while the blocking acquire's `EINTR` under
`sa_flags = 0` is a cancellation the bounded one cannot reach.

`handle_sleeping_state` reaches `load_model` on a wake, so the resume path is
covered by the same pair with no second lock, and a wake that reaches the
deadline returns false into that function's `GGML_ABORT`. Leaving the server
asleep instead needs `server_queue::on_sleeping_state` to carry a result rather
than `void`, since the queue sets its own sleeping flag to false around a void
callback and would then admit requests against a destroyed context.
`common/common.h` defaults `sleep_idle_seconds` to -1 and no script in this tree
sets it, so no served configuration enters that state; the queue signature is a
separate transition rather than part of this one.

The `all_idle` release keeps handing the lease back unchanged while the per-pass
acquire becomes a no-op under a load-path hold, and a warmup decode inside
`common_init_from_params` sits inside the same hold by construction.
