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
`QWEN_LLAMA_CANDIDATE_PATCHES=1` alone. Even applied, that patch acquires in
the busy-slot branch of `update_slots` and arms its descriptor in `init()`,
which `load_model` reaches after `common_init_from_params` and
`mtmd_init_from_file` have already uploaded to CUDA0.
`evidence/lease-coverage/` is the reading, and
`scripts/test-load-lease-coverage.sh` is the gate.

The one-child transition below crosses an uncovered load twice, so the campaign
starts after the acquire moves to `load_model` on a bounded deadline, the
closure is rebuilt and promoted, and the coverage test reads
`load_lease_coverage=accepted`. A combined run on a closure that fails that
test would measure request ordering rather than mutual exclusion, which is the
distinction `evidence/image-appliance/serialized-review-admission/run-05/`
already stands on.

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
| Failure recovery | cancel while waiting and while running; inject a bounded runtime failure | correct terminal status, child reaped, lease released, the next ordinary request served |
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

An unbounded wait -- a request stalled on a lease with no deadline and no
terminal state, which is the failure `flock(LOCK_EX)` without a deadline
produces.

Residue after teardown -- a service, runtime, socket, held lease, or partial
artifact surviving, or telemetry restored to a configuration other than its
recorded one.

A page arm failing the way `#104` records. A combined run that meets that
failure is incomplete until the failure is understood or a separately retained
rerun completes; a successful rerun replaces neither the failed record nor the
missing stages.
