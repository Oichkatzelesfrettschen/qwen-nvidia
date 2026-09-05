# The OptiX lane inside the served session, and both lanes against one lease

`evidence/geometry/optix-ray-runtime-proof/` admitted the runtime: one orbit
query traced on the GPU through `geometry-service.py` behind the compute
lease, with the device answer held to a host reference for every ray. This
record is the application integration under the contract
`evidence/physics/session-integration/README.md` states: the same service
inside the served session, reached by the model through one MCP tool,
authorized by one human approval, holding the one lease the physics and
image lanes hold. The record has two parts. `alone-02/` admits the geometry
lane by itself, the shape the physics record used. `shared-lease-01/` arms
both lanes in one session and adds the two arms that belong to the pair: a
grant signed for one service presented at the other's tool, and one run per
lane released from one barrier against the one lease. "Runtime admitted"
and "application execution authorized" stay two claims, and every
checked-in `scripts/geometry-profiles.tsv` row reads refused.

## What the geometry lane changes

The contract holds as written for physics, with three lane facts in place
of the physics ones. The operation is `geometry_ray_query` over a profile
and a ray count, bounded by the profile's `max_rays`; the proof the reply
has to carry is `launch_completed` with `reference_disagreement` at zero,
which is the device answer agreeing with the host reference on every ray;
and the deadline arm is observed rather than required. The protocol ceiling
of 1048576 rays traces in about 0.3 s when the built runtime runs
standalone under the priority wrapper, and `timeout_s` is bounded below at
1 s by the service, so no real run can cross the floor the ledger admits.
The arm therefore records which side of the deadline the run landed on and
still requires the runtime reaped; the deadline path itself is proven on
the physics lane on the device and on both lanes under the fake runtimes in
`scripts/test-geometry-service.py`.

`admit-sidecar-session.sh` takes `QWEN_ADMISSION_LANES` and runs one chain
for every armed lane through a lane table: the builder and binary, the
ledger columns the copy raises, the tool, the grant route, the counts, the
proof, and the page prompt. An unarmed lane keeps the shipped ledger, whose
every row reads refused, so the generator emits no server for it and the
broker signs nothing at its route. With both lanes armed the session
starts both services under one lease identity, the preset section carries
both MCP servers, and the listing names both tools.

## Preregistration

Each outcome below was stated ahead of the runs. The physics record's
outcomes hold per lane under lane-prefixed names; these are the ones the
geometry lane and the pair add.

- The listing carries the built runtime's digest, `cube-and-plane`, and
  the 1048576 ceiling; alone, the broker's health names the geometry
  profile and no physics one, and a physics body at either route refuses.
- One 262144-ray run completes with `launch_completed` true,
  `reference_disagreement` 0, and the built runtime's digest, and the tool
  result carries counts, the proof, and digests alone.
- A 1048576-ray run under the 1 s deadline reads observed on whichever
  side it lands, and no runtime process survives one second later.
- With both lanes armed, a geometry grant presented at the physics tool
  refuses at the child with no runtime sample and no lease sample held.
- Under contention both runs complete with their proofs, no sample of the
  driver's client list names both runtimes, and exactly two holders write
  the status line, the second with a `waited_ms` above zero.
- One page turn per lane posts exactly one grant at that lane's route and
  at least one tool call, reaches the router and broker origins alone, and
  its tool message carries `"status": "completed"` with the lane's proof.
- The teardown proves the session, both services, both sockets, the
  lease, and the session secret gone.

## Run alone-02

`alone-02/` is the geometry lane by itself on the RTX 4070 Ti, the
operator's telemetry server stopped for the window and the ordinary
desktop as the client set. Run 01 was the same campaign with two harness
defects. The placeholder digest for the unbuilt physics lane was four
characters, so the broker refused the physics body on its format ahead of
the route binding the arm exists to read. The held-lease arm started its
holder as `flock` running `sh -c 'sleep 75'` and released it by killing
the `flock` pid, which leaves the forked child holding the inherited lock
descriptor for the rest of the 75 s; the service's held-lease refusal
returns after its 60 s wait, so the next arm waited about 14.5 s on the
lease and the deadline run read 15.3 s of wall around a runtime whose own
clock read 0.685 s. That leak is also why `evidence/physics/session-integration/run-07/`
reads 16.6 s on its deadline arm, and its README says so. The harness now
runs `flock FILE sleep 75`, ends the holder's children ahead of the
leader, and records the lease free before the next arm.

| arm | outcome |
| --- | --- |
| listing binds runtime, scene, ceiling | accepted: `cube-and-plane`, ceiling 1048576 |
| broker signs the geometry profile, no physics one | accepted |
| physics body at the geometry route | refused: the route received a grant request naming service `physics` |
| any body at the unarmed physics route | refused: the broker serves no physics profile |
| 262144-ray run through the child | accepted: `launch_completed` true, agreement 262144 of 262144, 177170 hits, `launch_ms` 2.392, wall 0.503 s through the router, child, service, and runtime |
| driver client list during the run | observed: `optix-ray-runtime` in 2 samples, the lease held in 2, at ten hertz |
| replayed grant | refused as spent |
| ungranted call | refused |
| count one above the approved one | refused: `arguments differ` |
| lease held from outside | refused: `another workload holds the lease`, no runtime started; the lease reads free once the holder is released |
| 1048576 rays under the 1 s deadline | observed: completed at 1.053 s of wall, agreement 1048576 of 1048576, and no runtime process one second later |
| page turn | accepted: one `POST /grant-geometry`, one `POST /tools`, origins the router and broker alone, the tool message `status: completed` with the proof, and the model's reply naming 177170 hits of 262144 |
| teardown | accepted: no server, session, probe, broker, or service; geometry residue clean; session secret gone |

## Run shared-lease-01

`shared-lease-01/` arms both lanes in one session. Every per-lane arm of
the physics record and of the run above holds again under the pair, the
physics deadline arm crossing at `exit_s=2.068 sigterm_s=2.005` and
2.1 s of wall now that the lease is released ahead of it, and the geometry
deadline arm completing at 0.421 s. The pair's own arms:

| arm | outcome |
| --- | --- |
| both services share the session lease | accepted: one `vulkan-workload.lock` under the state directory in both identities |
| listing names both tools | accepted: `geometry_ray_query`, `physics_simulate_rigid` |
| geometry grant at the physics tool | refused at the child: `the grant names another sidecar service than the executing one`; no runtime sample, no lease sample held |
| contention, both complete | accepted: 0.826 s of wall for both; physics `simulate_ms` 242.8 with 4 bodies and 4 joints, geometry 177170 hits with agreement 262144 of 262144 |
| contention, runtimes never coresident | accepted: `optix-ray-runtime` in 2 samples, `physx-rigid-runtime` in 4, no sample naming both |
| contention, the second holder waited | accepted: `geometry-service` held first at `waited_ms=0`, `physics-service` after it at `waited_ms=300` |
| page turn, physics | accepted: one `POST /grant-physics`, the tool message completed with `gpu_dynamics_active` true |
| page turn, geometry | accepted: one `POST /grant-geometry`, the tool message completed with `launch_completed` true, the reply naming 177170 of 262144 |
| teardown | accepted: no server, session, probe, broker, or service; physics and geometry residue clean; session secret gone |

**What this settles.** Both device sidecars run inside the served session
under one lease contract. Each service proves the lease it holds is the
session's file, one approval buys one run bound to its own service, and a
grant carried across services refuses at the child before any socket
opens. Under contention the lease serializes the two runtimes: the driver
never lists both, the second acquirer states the wait it paid on its own
status line, and both runs complete with their proofs. Application
execution stays unauthorized in both checked-in ledgers, since a served
run under a copied row is an admission and a policy change is its own
transition.

**What it leaves open.** The contention arm releases two runs and reads a
300 ms wait; a queue deeper than two, and a runtime long enough to push a
waiter past the service's 60 s bound, are unmeasured. The geometry
deadline stays unobserved on the real runtime because the ledger's floor
and the runtime's ceiling do not meet; a longer fixture or a lower floor
is a separate change. The vision lane and the language model beside these
two under one lease is the combination `TASK_TRACKER.md` names next.
