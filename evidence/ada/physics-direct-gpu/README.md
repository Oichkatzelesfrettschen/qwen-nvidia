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

A finish event is recorded at the end of the call it is given to, so the three
reads take three events rather than one. One event shared across them records
three times and reports only the last; waiting on it would prove the earlier
copies complete only if PhysX dispatched all three on a single stream, which
the interface does not state.

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

## What the paired run measured

Both arms ran on the RTX 4070 Ti at 3600 steps of `d6-chain-4`, 30 of 30 checks
accepted each, retained under `readback/` and `direct/`. Protocol 5.

| | readback | direct-gpu |
| --- | --- | --- |
| `direct_gpu_active` read off the scene | false | true |
| transfers counted | unmeasured | 3 device reads, 3 device-to-host copies, 224 bytes |
| `cuda_last_error` after the reads | unmeasured | 0 |
| `physx_messages` total / invalidating | 0 / 0 | 0 / 0 |
| `cpu_accessor_position_max` | unmeasured | 6.39245 m |
| `cpu_accessor_linear_velocity_max` | unmeasured | 3.82818 m/s |
| link spans | 1.198, 1.199, 1.191 | 1.198, 1.199, 1.191 |

**The two paths agree exactly on the state they both measure.** The maximum
distance between the arms' final body positions is 0.000000; the link spans are
identical to three decimals. Raising `eENABLE_DIRECT_GPU_API` on both rows --
which forces `eDISABLE_SLEEPING`, so both raise it -- left the simulation
identical, and the device buffers carry what the readback path reports.

**The CPU accessors go stale, by more than the scene is long.** The direct
arm's `getGlobalPose` disagrees with the device value by 6.39 m on a chain that
hangs about 5 m, and `getLinearVelocity` by 3.83 m/s. They answer from whatever
the last copy left, which is the initial pose. An existing accessor cannot
remain a verification path on this configuration.

**The joint angle accessors report a simulation that did not happen.** Before
this was corrected, the direct arm reported `twist_rad`, `swing_y_rad` and
`swing_z_rad` as 0.0000 on every joint where the readback arm reported swing_z
of -1.8470, -0.1159, -0.1548 and -0.2537 radians. They return without error, so
the header's rule that a function without a direct counterpart "will continue
to work" holds in the narrow sense and not in the useful one: the angles derive
from the two actors' poses, and those are the poses the flag stopped copying.
`joints_unbroken` passed on those zeros. The runtime now reports all four joint
fields as null on the direct path and the harness reads `unmeasured` rather
than `yes`. `PxD6JointGPUAPIReadType` carries joint force and torque, so a
direct path that measures a joint reads those.

**The two paths are not separable in step time at this scene size.** Five
back-to-back admissions per arm, retained in `repeats.tsv`:

| arm | `simulate_ms` mean | sd | min | max |
| --- | --- | --- | --- | --- |
| readback | 1386.69 | 19.24 | 1360.71 | 1410.37 |
| direct-gpu | 1372.58 | 24.88 | 1353.49 | 1415.90 |

The direct arm's mean is 14.11 ms lower, 1.02 percent, which is 0.63 pooled
standard deviations: the arms overlap. Its explicit state read costs 0.453 ms
more than the readback arm's accessor loop, 0.033 percent of one run, and the
21.33 ms this reported on the direct arm's first run of the session was
first-call CUDA initialization rather than transfer cost.

Scattered runs taken while the tree was being edited spread `simulate_ms` from
1266.61 to 1635.25 and read as a 25 percent noise floor. That was machine state,
not the measurement: back to back on an idle card the spread within one
configuration is 3.6 and 4.5 percent. Either way the difference between the
configurations is smaller, so four bodies cannot answer which path is faster.
A scene where per-step readback is a measurable share of the step would;
4 bodies move 224 bytes, which is not one.

The direct arm still copies its device buffers to host memory for the JSON
reply, so this admits the state-access API rather than a GPU-resident path.

## Status

The arms ran after `scripts/qwen-drain-controller.sh resume
--barrier-identity ID` reopened the barrier a session shutdown had left
`quiescing`; that is the operation rather than `qwen_barrier_set_state`, which
writes the state word with neither the retirement nor the in-flight reference
held. Both rows in `scripts/physics-profiles.tsv` stay
`execution_policy=refused`: the harness raises its own copy for one run and
records both readings, so nothing here lets a model start a simulation. Raising
a row is a separate transition that this proof informs.
