# The direct-GPU state path, and what the installed SDK permits

PhysX 5.9.0 at `/opt/nvidia/physx` exposes `PxDirectGPUAPI`, so the migration
targets the installed headers rather than an older example. Reading them
settles four constraints that shape the comparison before any of it runs.

`PxSceneFlag::eENABLE_DIRECT_GPU_API` is not mutable and is set in
`PxSceneDesc` at scene creation, so the path belongs to a profile row rather
than to a request. `PxSceneDesc::isValid()` refuses it without
`eENABLE_GPU_DYNAMICS` and `PxBroadPhaseType::eGPU`, both of which the fixture
already raises, and refuses it beside `eENABLE_CCD`, which the fixture does not
use.

The flag forces `eDISABLE_SLEEPING`. A solver that can retire a body on one
path and not on the other simulates something different, so both rows raise
that flag and differ in the transfer path alone. The fixture's
`setSleepThreshold(0.0f)` already prevented sleep, which the readback row's own
`sleeping` field reports.

`PxDirectGPUAPI` answers only after a first simulation step, because the scene
sizes its GPU structures from the actors it holds; the header directs setup to
the CPU API. The scene is therefore built as before and read differently after.

`getRigidDynamicData` returns a boolean whose documentation states it "might not
include asynchronous CUDA errors", so the runtime reads
`PxCudaContext::getLastError()` after the copies and the protocol refuses a
reply carrying a nonzero one.

## What the direct path cannot answer

`PxRigidDynamicGPUAPIReadType` carries global pose, linear and angular
velocity, and -- under `eENABLE_BODY_ACCELERATIONS` -- accelerations. It
carries no sleep state. The direct row therefore reports `sleeping` as null and
the validator requires that null rather than tolerating one from either path;
answering `false` would report a flag as a measurement.

`PxD6JointGPUAPIReadType` carries joint force and joint torque alone, and the
header states that they replace `PxConstraint::getForce()`, "which will not work
properly anymore if direct GPU API is used". The joint angle accessors have no
counterpart, and the header's general rule is that an API function without one
"will continue to work". Whether `PxD6Joint::getTwistAngle()` keeps answering
correctly when the actor poses behind it are no longer copied back is not
settled by the headers. It is left as a measurement: the two rows run the same
scene for the same steps, and a divergence in the reported angles is the answer.

## A step that completed without the contacts it was asked for

PhysX reports a GPU buffer that ran out of room through the error callback and
then completes the step: the result returns and the contacts that did not fit
are absent. `strings` over
`/opt/nvidia/physx/bin/linux.x86_64/release/libPhysXGpu_64.so` carries the
reports verbatim, among them "Contact buffer overflow detected, please increase
its size in the scene desc!" and
"PxGpuDynamicsMemoryConfig::collisionStackSize buffer overflow detected, please
increase its size to at least %u in the scene desc! Contacts have been
dropped." PhysX raises them at warning severity, which a callback filtering on
`PxErrorCode::eABORT` and its neighbours never sees, so the runtime counted
zero errors and returned a result describing a simulation it did not run.

`scripts/physics-runtime/physx-message-policy.h` carries the predicate that
reads the message text instead, and the runtime refuses such a run as
`simulation_state_dropped`. The count travels in the result as
`physx_messages`, so a reader can tell a run the policy cleared from one that
predates the policy, and the protocol refuses a completed reply carrying a
nonzero `invalidating`.

`scripts/test-physx-message-policy.sh` drives the predicate with the library's
own sentences on both sides -- eleven overflow reports with their placeholders
filled, against benign lines from the same library including
"PxgConstraintPartition: attempting to remove an edge from an empty partition.
Skipping." -- and reads each policy substring back out of the shipped library,
so an SDK upgrade that rewords a report fails the gate rather than passing a
run whose contacts were dropped. Emptying two entries from the predicate fails
the first check with all nine reports it then admits.

## The measurement, and its falsifiers

Both rows simulate `d6-chain-4` at the same timestep, gravity and step count and
differ in `state_path` alone. `scripts/admit-physics-runtime.sh` records, per
row: `state_path`, `direct_gpu_active` read back off the scene, the transfer
counts and bytes, `cuda_last_error`, `state_read_ms` beside `simulate_ms`, and
the divergence between the CPU accessors and the device values.

| prediction | falsifier |
| --- | --- |
| the direct row's CPU accessors answer stale, so `cpu_accessor_position_max` is large | a value near zero, which would leave the accessors a valid verification path |
| `direct_gpu_active` reads true only where the row says direct-gpu | the scene declining a descriptor PhysX accepted, which the runtime refuses by name |
| the direct row's `simulate_ms` is at or below the readback row's, because `fetchResults` no longer copies state each step | the direct row slower, which would make the migration cost rather than save |
| the two rows agree on final body positions within solver noise | a divergence, which would mean the extra flag changes what is simulated |
| the two rows agree on joint angles | a divergence, which settles the `getTwistAngle()` question against the accessor |

## Status

The device arms have not run. `scripts/qwen-admission-barrier.sh` reads
`quiescing` on this host, which a session shutdown leaves deliberately in place
until an owned startup resumes it, and flipping that shared state was refused by
the permission harness. Nothing here reports a device measurement, and both rows
in `scripts/physics-profiles.tsv` stay `execution_policy=refused`; raising one is
a separate transition that this proof would inform.
