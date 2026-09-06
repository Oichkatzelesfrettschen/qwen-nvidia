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

## What closes it

The open moves ahead of the acquire and both move to the top of `load_model`.
Order is the whole of it: `workload_lease_acquire` returns true while
`workload_lease_descriptor` is negative, so an acquire moved on its own past a
descriptor still opened in `init()` admits every load while reporting success.
`scripts/test-load-lease-coverage.sh` proves its own predicate against that
case before it reads the real file.

The wait takes a deadline, because `flock(LOCK_EX)` blocks until signalled
where `image-service.py` bounds its own wait with `QWEN_IMAGE_LEASE_WAIT_S`,
and the refusal past it needs a caller that can carry it: `load_model` returning
false ends the launch on the first load, while `handle_sleeping_state` reaches
`GGML_ABORT("failed to reload model after sleeping")` on the resume path, so a
wake that loses the lease would kill the server rather than answer its request.
Closing the gap therefore changes that path's failure handling as well as the
acquire's placement, and the served arms measure what a request behind a held
lease actually receives.

Because `load_model` runs on wake, the placement covers the resume path with no
second lock, and the `all_idle` release keeps handing the lease back unchanged
while the per-pass acquire becomes a no-op under a load-path hold. A warmup
decode inside `common_init_from_params` sits inside the same hold by
construction.
