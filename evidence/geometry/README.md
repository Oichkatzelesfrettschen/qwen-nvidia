# OptiX geometry lane

## Claim

A bounded ray query runs through OptiX on the device behind the same
service shape, lease, and ledger discipline the physics lane holds, and
every ray's answer agrees with a host reference intersector.

## Preregistration

`scripts/admit-geometry-runtime.sh` compiles `optix-ray-runtime`, raises
`geometry-cube-orbit-a` to `validator-gated` in a copied ledger, starts
`geometry-service.py` under the owner lock holding the compute lease, sends
one `geometry_ray_query` for 262144 rays, samples the driver's client list
and the lease at ten hertz through the job, and reads the reply. Written
ahead of the first run:

| check | holds when | refutes when |
| --- | --- | --- |
| proof block | `context_created`, `gas_built`, `pipeline_created`, `launch_completed` all true and `gas_bytes` above zero | any false; the runtime then exits nonzero ahead of a result, and a result without the proof reads `gpu_fallback` |
| device | `device_name` equals the `nvidia-smi` name of device 0 | any other name |
| ray count | `rays` in the result equals the request | a shortfall |
| coverage | hits and misses both present; the two ground triangles hit; 14 primitives reported | the orbit set fails to reach the ground or to miss above the cube, which says the fixture or the launch is wrong |
| reference | `reference_disagreement` is 0 and `reference_agreement` equals the ray count | any ray where the device's closest hit and the host's differ in presence, or in distance beyond 1e-3 relative |
| client set | the runtime appears in the compute-client list while the lease reads held, and neither survives the job | a reply without an observed client, a lease still held, or residue at teardown |

A disagreement between the device and the host reference is the finding
the run exists to surface: two intersectors over one triangle list agree
where both are right, and the count of rays they part on is reported
rather than averaged. The launch time is recorded and gates nothing.

## Run: accepted

`optix-ray-runtime-proof/` is `scripts/admit-geometry-runtime.sh` on the
device at 262144 rays under the `orbit` set over `cube-and-plane`, 26 of 26
checks accepted.

| record | reading |
| --- | --- |
| proof block | context created, GAS built at 3328 bytes, pipeline created, launch completed; OptiX header 90100 |
| device | `NVIDIA GeForce RTX 4070 Ti`, the `nvidia-smi` name |
| rays | 262144 traced; 177170 hits and 84974 misses |
| coverage | 8 of 12 cube faces hit, both ground triangles hit, distances 1.72 to 2.61 |
| reference | 262144 of 262144 rays agree with the host intersector, 0 disagree |
| launch | 2.498 ms for the launch, 242 ms for the runtime end to end |
| lease and process | the lease read held and the runtime held a `/dev/nvidia*` descriptor with `libnvoptix.so` mapped on the tick the sampler caught it; nothing survives the teardown |

A first run of the same harness refused on two checks and its fixes are in
the committed form. The orbit set aimed no lower than y = -0.6, and a ray
from height 0.25 three units out reaches the cube's near face at
y = 0.25 + (ty - 0.25) * 2.5 / 3, so no aim crossed the ground ahead of the
cube; the sweep now runs from -1.2 to 1.4, and the ground triangles read
hits. The second refusal is a finding about the observation rather than the
runtime: `nvidia-smi --query-compute-apps` listed the runtime on none of the
ticks across that run, a diagnostic of three back-to-back runs sampled at
twenty hertz over about 1.2 s of runtime execution, and the accepted run,
where the process held a device descriptor and the OptiX library in its
mappings while the lease read held. NVML's compute-client list is a driver
report whose admission rule for a short-lived context this record does not
establish; the admission therefore observes the runtime through `/proc`,
the kernel's own view of the process, and records the NVML count beside it
as observed. The three diagnostic runs at 1048576 rays returned one digest,
`58c38d25afa35af3`, across all three, so a launch over the fixture is
deterministic from run to run.

`geometry-cube-orbit-a` stays `refused` in the tree. The MCP wrapper and
the session integration are separate transitions this record informs.
