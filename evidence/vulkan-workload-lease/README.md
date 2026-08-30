# The Vulkan workload lease, both sides

## The invariant

The appliance admits one active qwen-owned Vulkan compute workload. Residency is
outside it: an idle loaded llama-server reserves device memory while it executes
no graphs, so it competes with nothing. Active prompt processing, active decode,
an image generation, and a vision review are the workloads the invariant orders,
and `~/qwen-webui-state/vulkan-workload.lock` is the kernel object that orders
them.

## The mechanism

Two processes take `flock(LOCK_EX)` on one file.

`scripts/image-service.py` holds it from job start to artifact rename. Every
refusal above the lease runs before the `flock`, so a request the service
declines leaves the lock untouched. The acquisition waits rather than refusing
at once: `QWEN_IMAGE_LEASE_WAIT_S` bounds the wait at 60 seconds by default and
zero makes one non-blocking attempt, because the chat turn that emitted the
approved tool call is still releasing when the generation request arrives. The
refusal past the deadline keeps the `lease_unavailable` reason a held lease
always carried. The wait is a non-blocking poll against a monotonic deadline
rather than a blocking descriptor call, since the service runs threads and a
blocked request thread would hold the `cancel` and `status` routes.

`patches/llama-server-vulkan-workload-lease.patch` holds it across the span in
which slots submit graphs. `server_context_impl::update_slots` already opens on
an all-idle check; the patch releases where that check finds every slot idle and
acquires where it finds one busy, so the lease covers exactly the passes that
decode. `QWEN_VULKAN_WORKLOAD_LOCK` names the file, an unset variable leaves the
descriptor closed and every lease call inert, and a named path that cannot be
opened fails `init()` rather than serving with the guard silently absent. The
descriptor carries `O_CLOEXEC`, so nothing the process spawns inherits the open
file description `flock` binds to.

`scripts/qwen-capacity-policy.sh` exports the path on every launch, derived from
`QWEN_WEBUI_STATE_DIRECTORY`, which `scripts/qwen-webui-session.sh` sets to the
same state directory it hands `image-service.py` as `--state-dir`.
`scripts/vulkan-runtime-env.sh` scrubs the `GGML_VK_*`, display, AMD-named, and
VK layer variables ahead of its own profile case, so the workload-lock
variable crosses the exec boundary untouched.

In router mode the child holds the lease. `tools/server/server.cpp` calls
`ctx_server.load_model` -- and therefore `init()` -- only in its non-router
branch, so the router parent opens nothing. `tools/server/server-models.cpp`
snapshots `environ` into `base_env` at `server_models_routes` construction and
spawns each child with that copy plus `LLAMA_SERVER_ROUTER_PORT`, so the
variable reaches the process that owns the context and the graphs verbatim.

## The release window

The release trails the final decode by one `update_slots` pass. A non-idle pass
posts `SERVER_TASK_TYPE_NEXT_RESPONSE`, so the pass that observes the newly idle
slots is guaranteed and immediate, and the lease is returned at its top. A run
measured that gap at 13 microseconds between the slot release and the lease
release line. The claim is therefore "released on the pass after the last slot
idles" rather than "released at slot completion".

## A stalled lease in the log

The acquire tries `LOCK_EX | LOCK_NB` first, so the waiting line reaches the log
before the block rather than after it:

```text
srv  workload_lea: vulkan workload lease waiting: path=.../vulkan-workload.lock
srv  workload_lea: vulkan workload lease acquired: path=.../vulkan-workload.lock waited_ms=5894
```

A turn that met a free lease writes the acquire line alone, with `waited_ms=0`.
A terminating signal during the block returns `EINTR`, because `server.cpp`
registers SIGINT and SIGTERM with `sa_flags = 0` and no `SA_RESTART` covers it;
the acquire then writes

```text
srv  workload_lea: vulkan workload lease wait ended without the lease: path=... waited_ms=... reason=Interrupted system call
```

and returns false. `update_slots` then leaves the pass without posting
`NEXT_RESPONSE`, so no graph reaches the device in a pass that holds no lease,
and the task queue observes the termination it was told about. Any other
`errno` from the lock is refused the same way and logged as `vulkan workload
lease failed`, which trades liveness for the invariant: a pass that ran
without the lease is the state the lease exists to exclude, and a server whose
main thread stalls on a refused lock is what `qwen-teardown.sh` reports as
residue rather than what runs beside a generation. Looping on `EINTR` instead
would leave that residue for a server whose main thread can never unblock.

A CPU-only build of the fixed patch, started against a lock another process
held, wrote `lease waiting` on its first completion request, received SIGTERM
two seconds later, wrote `lease wait ended without the lease ... Interrupted
system call`, and exited 0 with no `lease acquired` line and an empty reply,
so the terminating signal leaves the pass before any submission and the
server ends cleanly.

## Falsifiers

- A generation runs while a slot is active. The service holds the lock across
  the whole job and the server holds it across every decoding pass, so an
  artifact whose provenance timestamps overlap a slot's `launch_slot_` and
  `release` lines in the same session falsifies the exclusion.
- A lease is still held after the last slot idles. `flock -n` on the lock file
  succeeds once the release line is written; a lock that stays taken past that
  line falsifies the release side.
- The two writers name different files. `scripts/test-vulkan-workload-lease.sh`
  compares the basename `qwen-capacity-policy.sh` exports against
  `image-service.py`'s `LEASE_FILE_NAME` and requires the session to hand both
  sides one state directory.
- The variable is scrubbed before the exec. The same test requires
  `vulkan-runtime-env.sh` to leave `QWEN_VULKAN_WORKLOAD_LOCK` alone.

## What ran on the workstation

`scripts/test-vulkan-workload-lease.sh` against a CPU-only build of the patched
tree admits all ten checks:

```text
ok lock_basename=vulkan-workload.lock shared by the policy and the service
ok both writers resolve the lock under the session state directory
ok the workload lock variable survives the environment scrub
ok patch_applies=yes sha256=179391b17c8c24a3e7de0a3e7ccf91c5dfec2015f14fce63bf0665fea4516a9e
ok the server arms the lease at startup
ok an idle loaded server leaves the lease free
ok the reply waits for the holder: elapsed=6s hold=6s
ok the acquire names the wait: waited_ms=5894
ok the completion answers after the lease is taken
ok the lease returns once every slot is idle
served_lease=admitted waited_ms=5894 elapsed_s=6
```

The lease lives in `tools/server/server-context.cpp` and reads no backend, so a
CPU-only build proves the state machine whole rather than approximating it. What
a CPU build leaves unmeasured is the device: whether excluding the two workloads
changes decode rate, generation latency, or the kernel-hazard signature on this
host's own device is a measurement this host has not yet run.

## Admitting it on the device

The prior host built and served from a separate checkout reached over `rsync`
and SSH; this tree builds and serves from the one checkout the patch lives in,
so admission needs no transfer step between a build machine and a runtime
host.

```sh
scripts/verify-llama-patch-series.sh
QWEN_LLAMA_CANDIDATE_PATCHES=1 scripts/verify-llama-patch-series.sh
git -C SOURCE_DIRECTORY apply patches/llama-server-vulkan-workload-lease.patch
scripts/build-llama-cuda.sh SOURCE_DIRECTORY
scripts/promote-llama-build.sh PRESET SOURCE_DIRECTORY
scripts/test-vulkan-workload-lease.sh   # path and patch halves
QWEN_LEASE_TEST_SERVER=$HOME/bin/llama-server \
QWEN_LEASE_TEST_MODEL=$HOME/models/Qwen3.8-2B-Distill-GGUF/Qwen3.8-2B-Q4_K_M.gguf \
    scripts/test-vulkan-workload-lease.sh
scripts/admit-image-router.sh OUTPUT_DIRECTORY
```

`admit-image-router.sh` replays the image lane alone, so the arm the lease
exists for is one the harness still needs: a chat completion posted against the
router port while the approved generation is in flight. The generation's own
`flock` holds the lock, so the chat turn writes the waiting line, its reply
arrives after the artifact rename, and the audit row and the server log
together carry the ordering. A run that shows the chat reply arriving before
the rename with no waiting line in between falsifies the LLM side on the
device.

## What the second holder changes about teardown

`qwen-teardown.sh` ends with `image-teardown-check.sh`, which requires
`flock -n` on the lock file to succeed. `flock` releases when the process exits,
and `qwen-webui-control.sh stop` signals llama-server and waits ten seconds for
the tmux session to end before it calls `tmux kill-session`. A server signalled
mid-decode therefore has ten seconds to leave; one that outlives that window is
orphaned and keeps the lease, and the residue proof reports a held lease naming
the file rather than the process. Before this patch only `image-service.py`
could produce that line. What removes the ambiguity is a teardown that proves
the server gone the way it already proves the broker and the service gone,
comparing a recorded `/proc/PID/stat` start time and waiting for the pid to
leave; the check itself would then name which writer holds the lock.

The blocking acquire runs on the task-queue thread, so a generation holding the
lease stalls every route that posts a task for as long as the service's 330 s
job deadline allows. The session's service-latency watchdog is
`vulkan-graphics-service-probe`, which submits its own graphics work and polls
no HTTP route, and `monitor-qwen-runtime.sh` reads `/proc` and sysfs rather than
the server, so neither watchdog observes the stall. `GET /health` answers from
the HTTP thread without posting a task, so readiness stays truthful while a turn
waits.
