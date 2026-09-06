# The combined session: one application, four admitted lanes

This record preregisters the combined-session admission ahead of any run. It
names the claim, the configuration frozen before the first request, the stages,
and what each stage would have to show to refute it. A run retained beside this
file is read against what is written here rather than against a summary written
after it.

## The claim

One session executes the admitted language, image and review, physics, and
geometry operations under their separate authorization contracts, one GPU
ownership hierarchy, and a bounded residency policy, while preserving
cancellation, result attribution, and recovery.

That is the whole claim. Three readings sit outside it:

A PhysX-to-OptiX scene pipeline is a separate transition. Each sidecar proves
its own bounded fixture -- `d6-chain-4` for physics and `cube-and-plane` under
the `orbit` query set for geometry -- and moving a simulated scene into the
geometry service is typed-data integration this record neither performs nor
licenses.

Composition admits no policy row. Every physics and geometry row stays
`refused` in the checked-in ledgers for the whole campaign, and the run takes
its test permissions from copies it names. Promotion is a policy transition
taken from this record afterward, one profile at a time, and only for the
profiles the record actually exercised.

A lane passing alone is the precondition rather than the finding. Physics
(`evidence/physics/session-integration/run-07/`) and geometry
(`evidence/geometry/session-integration/`) each passed alone, and the finding
here is what repeated use across lanes does to attribution, residency,
cancellation, and recovery.

## The precondition this campaign waits on

The compute lease admits one active device workload among the services that
take it, and llama-server is outside that set: the promoted closure
`88681bf4d161` reads neither `QWEN_GPU_COMPUTE_LEASE` nor the legacy
`QWEN_VULKAN_WORKLOAD_LOCK`, because
`patches/llama-server-vulkan-workload-lease.patch` is a candidate armed under
`QWEN_LLAMA_CANDIDATE_PATCHES=1` alone. The new closure therefore proves two
exclusions rather than extending one: the load, which uploads weights, a draft
context, and a projector to CUDA0, and the ordinary evaluation that follows it.
`evidence/lease-coverage/` is the reading, and
`scripts/test-load-lease-coverage.sh` is the gate.

The one-child transition below crosses a load twice, so the campaign starts
after the extended patch is built, its served arms run, the closure is
promoted, and the coverage test reads `load_lease_coverage=accepted` with the
served stage accepted rather than `not_run`. A combined run on a closure that
fails that test would measure request ordering rather than mutual exclusion,
which is the distinction
`evidence/image-appliance/serialized-review-admission/run-05/` already stands
on.

Promotion of the candidate closure is itself gated on five readings, and the
served arms are one of them:

```text
served lease admission complete            the seven arms, both model sizes
candidate text, multimodal, router pass    strict CUDA0 placement and the picker
serialized image review passes             on the candidate closure, before the pointer moves
source-difference scope resolved           the provenance gap in candidate-build-source-identity.tsv
ordinary teardown policy explicit          drain before destroy, tested apart from the signal arms
```

The last two are open by construction rather than by omission. The candidate
matches the recorded production architecture, payload counts, MMVQ thresholds,
and feature-marker state, and exact source equivalence to the historical
production build remains unresolved; and `destroy()` frees whether or not its
one non-blocking attempt won the lease, so a teardown contended with another
holder is an explicit unprotected-cleanup exception rather than a fourth
exclusion. `evidence/lease-coverage/README.md` carries both. The promoted
closure `88681bf4d161` is the rollback, and its limitation is part of the
record: it supplies the earlier serving behavior rather than the LLM-side lease
guarantee, so rolling back disables the combined behavior that depends on it.

Lease coverage is admitted with inactivity sleeping disabled. The extended
`load_model` refuses a configuration that names a lease and a non-negative
`sleep_idle_seconds` together, ahead of the acquire and of every upload,
because `server_queue::on_sleeping_state` takes a `void` callback whose caller
clears the queue's sleeping flag whatever the wake returned. Router eviction and
a fresh child load are a different mechanism and the campaign exercises them;
recoverable in-process sleep and wake under the lease is a separate queue-state
transition and stays outside this claim.

## The frozen configuration

Every identity is recorded before the first request and repeated in the run
directory. A run whose recorded identity differs from its freeze is read as a
different configuration.

| Identity | Frozen as |
| --- | --- |
| Repository commit | the merge commit the campaign branches from |
| Served closure | the closure carrying load-path lease coverage, by `promote-llama-build.sh` digest |
| Image runtime | `sd-cli` by SHA-256 |
| Physics runtime | `physx-rigid-runtime` by SHA-256 |
| Geometry runtime | `optix-ray-runtime` by SHA-256 |
| Models and projectors | every GGUF and mmproj the preset names, by path and digest |
| Registries | `models.tsv`, `validated-tuples.tsv`, `quarantine.tsv`, `web-profiles.tsv` by SHA-256 |
| Test ledgers | the copied image, physics, and geometry ledgers by path and SHA-256 |
| Lease | one path, and its device and inode as `QWEN_GPU_COMPUTE_LEASE_IDENTITY` |
| Device stack | `scripts/device-environment-identity.sh`'s eight-field block |

These settings hold unchanged, because the campaign admits a composition rather
than measuring a lever:

```text
CUDA-only execution
ordinary KV buffer
graphs, fusion, and speculation at each model's existing policy
device embedding handoff off
loopback listeners
each model's existing context limits
```

Sparse KV residency and the device embedding handoff are admitted, default-off
mechanisms, and enabling either to make the combined memory budget fit would
turn this admission into a multi-feature experiment. A budget that fails is
reported as a budget that fails.

The promoted image tuple `image-sdxs-512-a` is exercised at its ledger
geometry, reviewer, step count, and context. Broadening any of them makes a
different tuple, which this record does not cover.

## Router capacity

The production-intended shape is one resident child, and that is the shape the
campaign runs first. The two-child pairing
`evidence/image-appliance/paired-review-admission/` admitted is a different
configuration and earns its own record; it proves nothing about the transition
below, and the image evidence says that transition has not run.

```text
language coordinator
  -> completed generation
  -> reviewer load, evicting the language child where required
  -> review
  -> language coordinator reload
  -> ordinary answer
```

The selected child's identity is read at each stage from the router's own
`/v1/models` and its spawn log. Eviction has to leave an in-flight tool
response, a pending approval, an artifact reference, and the browser turn
holding them all still valid; a reference that dangles across an eviction is a
finding rather than a retry.

## Stages

| Stage | Exercises | Required result |
| --- | --- | --- |
| Canonical-policy baseline | launch with the checked-in ledgers | the image tuple available; every refused physics and geometry operation unavailable |
| Sequential composition | image, review, PhysX, geometry, ordinary chat in one session | correct result attribution, independent approvals, clean lease handoffs |
| Warm reuse | review the same artifact a second time | the existing reviewer answers, with no stale verdict and no assumption that a reviewer is a newly appearing process |
| Warm second subject | generate a second artifact and review it | an already-resident reviewer distinguished from an actively computing one, with its resident allocation inside the memory record |
| Controlled contention | competing approved operations beside a language or reviewer request | a documented wait or refusal, bounded waits, no unauthorized execution |
| Failure recovery | cancel while waiting and while running; inject a bounded runtime failure | correct terminal status, child reaped, lease released, the next ordinary request served; a cancellation issued while a decode pass waits on the lease is recorded with its observed effect and its bound rather than assumed to take effect |
| Teardown and restoration | stop the session, restore telemetry | no owned residue; telemetry restored to its recorded configuration |

The two warm stages are separate because they ask different questions. Reuse
asks whether a resident reviewer answers again correctly. The second subject
asks whether residency is told apart from execution, and it does not require
the reviewer's process to be absent during the generation: what it requires is
no unauthorized overlapping work and a memory record that counts the reviewer's
resident bytes.

## Authorization across the combined boundaries

Each operation carries its own grant and the refusals extend to every boundary
the combination creates. A geometry grant presented at the physics tool is
refused by the child ahead of any service call, and the reverse; an image grant
authorizes one generation of one argument set; a completed approval authorizes
no automatic retry.

`physics-service.py` and `geometry-service.py` revalidate and consume the grant
before taking the lease, so a lease wait that expires leaves a spent grant and a
request that never ran. That request reports its terminal state explicitly, and
a new attempt takes a new approval rather than replaying the grant it spent.

Every returned result is bound to its originating request and operation: a
reviewer verdict names the artifact digest it read, and sidecar output is data
rather than execution authority.

## Proving serialization

The mechanism is the kernel lock and the sampling corroborates it. `flock` is
advisory and attaches to an open file description, so the proof names every
path that participates and the descriptor lifetime each holds, rather than a
shared pathname. NVML reports which processes are running on the device; it
monitors and schedules nothing, so a client list is corroboration.

An append-only event trace records the real transitions:

```text
request accepted
lease wait begins
lease acquired
runtime or load begins
GPU work completed
runtime reaped or operation completed
lease release begins
lease release completes
request terminates
```

One monotonic clock domain, a per-process sequence number, a job identifier,
and the verified lease identity on every event. Release is recorded as a
bracket, because a log line written after unlocking orders the write rather than
the handoff.

A host-side function returning is not evidence that device work finished: CUDA
launches and asynchronous transfers return before their work completes, so the
release follows a completion the runtime proves rather than a call that
returned.

The language stays sampled where the evidence is sampled. A run states that no
sample listed both runtimes; it does not state that the runtimes could not have
overlapped. Observed separations are separations between samples at the
measured rate, and the measured rate is reported rather than the intended one.

## Residency

A free compute lease is not a free device. The memory record carries the
resident language child, the cached reviewer, the sidecar runtime, the desktop,
and whatever overlaps during a load, and its peaks are observed peaks rather
than guaranteed maxima.

The operator's 9B telemetry server holds about 6.4 GiB and stays out of the
campaign. It is stopped through its owning session during the authorized
handoff alone, by a process identity resolved live rather than by a recorded pid
or a name pattern, and restored to its recorded configuration afterward.

## What refutes the claim

Any of these ends the campaign as incomplete rather than passing:

Result attribution crossing lanes -- a verdict naming the wrong artifact, a
sidecar reply matched to another request, or a result whose identity an
eviction invalidates: a tool response the page can no longer redeem, an
artifact reference that resolves to nothing, or an approval the reload
reattributes. A correctly attributed result outliving the child that produced
it is the required behavior rather than the failure.

A grant reaching past its claim -- one lane's grant accepted at another, a spent
grant replayed, or an approval authorizing a retry.

A wait with no bound and no progress. The bound belongs to the caller rather
than to the lease, so the requirement is stated per admission point rather than
as one deadline:

| Property | Required |
| --- | --- |
| Load admission | a deadline enforced inside the acquiring process, and a named refusal at it |
| Sidecar admission and execution | the lane's existing bounded wait and its runtime deadline |
| Decode progress behind an ordinary holder | resumes on the release without a second HTTP request |
| Service shutdown while a decode waits | bounded termination, with no surviving child and no held lock of its own |
| Per-request cancellation while a decode waits | measured on its own, and open until it is |

A decode pass keeps `flock(LOCK_EX)` on purpose: `server_queue::start_loop`
re-enters `callback_update_slots` only when a task arrives or the process
terminates, so a pass that gave up on the lease would strand its request until
unrelated traffic woke the loop. That blocking acquire is not a bounded request
deadline, and the campaign does not read one into it. What the combined run
requires of that call site is progress -- the waiting request completes on the
release, with no second request sent -- and bounded termination under a
terminating signal, which
`scripts/test-load-lease-coverage.sh`'s `decode_waits` and
`shutdown_while_decode_waits` arms measure ahead of the campaign. Its
`shutdown_while_load_waits` arm measures a different mechanism and is not read
for this one: `server.cpp` installs its handlers at `:489`, after the
`load_model` call at `:465`, so a signal inside the load wait ends the process
by default disposition while a signal inside a decode wait returns `EINTR` from
`flock(LOCK_EX)`.

Per-request cancellation while a decode waits stays open rather than claimed. A
client disconnect or a browser timeout is not evidence that the server discarded
the request: the pass is inside `flock(LOCK_EX)` on the main loop, and nothing
reachable from there reads the cancellation. What closes it is an arm that
cancels a request whose pass is blocked on the lease and reads the slot's own
terminal state after the release -- whether the cancelled request decodes
anyway, and how long the cancellation takes to take effect. If it cannot
complete while the lock is held, the campaign records that bound rather than
treating the requirement as met.

Residue after teardown -- a service, runtime, socket, held lease, or partial
artifact surviving, or telemetry restored to a configuration other than its
recorded one.

A page arm failing the way `#104` records. A combined run that meets that
failure is incomplete until the failure is understood or a separately retained
rerun completes; a successful rerun replaces neither the failed record nor the
missing stages.
