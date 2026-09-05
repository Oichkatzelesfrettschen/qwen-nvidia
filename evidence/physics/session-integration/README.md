# The PhysX lane inside the served session, under one lease contract

`evidence/physics/d6-runtime-proof/` admitted the runtime: one D6 chain
simulated on the GPU through `physics-service.py` behind the compute lease,
with the proof read off the reply. That record says the runtime runs where
it claims to. This record is the application integration: the same
service inside the served session, reached by the model through one MCP
tool, authorized by one human approval, and held to one lease contract
shared with the image and geometry lanes. "Runtime admitted" and
"application execution authorized" stay two claims: the first is the prior
record, the second is what a validator-gated ledger row would state, and
every checked-in row still reads refused.

## The contract

- **One lease, proven at launch.** `QWEN_GPU_COMPUTE_LEASE` names the
  file; the session passes `QWEN_GPU_COMPUTE_LEASE_IDENTITY` as the file's
  device and inode, and `sidecar_runtime.require_lease_identity` stats the
  path and refuses the launch on a missing variable or a differing
  identity. A service serializing against a file the server does not hold
  cannot start.
- **One bounded operation per lane.** `physics_simulate_rigid` over a
  profile and a step count; the profile's own ceiling bounds the count in
  the tool schema, the grant, the child, and the service.
- **One single-use grant, bound whole.** `qwen-sidecar-run-v1` carries the
  service, the operation, both profiles, the runtime digest, the scene, a
  digest of the normalized arguments, the ceiling, the conversation
  generation, expiry, and a nonce. The broker signs it at `/grant-physics`
  for the one profile it armed; the child verifies and enforces it, opens
  the socket, spends it under the ledger, and sends; the service
  revalidates the same token against the same key ahead of the lease. A
  geometry grant at the physics lane, a grant for another profile, another
  runtime, another scene, or another count each refuse before any lease
  acquire.
- **Output collection is bounded.** `sidecar_runtime.collect_output`
  drains stdout and stderr under separate limits, ends the process group
  on overflow, and reaps it; `communicate()` is gone from both services.
- **The page approves through the same dialog discipline.** The device
  toggle offers the lane's tool for one turn; a proposal opens a dialog
  naming the lane, profile, scene, runtime digest, and count against the
  ceiling; approval posts the grant and one `POST /tools`.

## Preregistration

`scripts/admit-sidecar-session.sh` runs the chain on the device with the
ledger row raised to validator-gated in a copy, its deadline set to 2 s
and its ceiling to 100000 steps, the protocol maximum, so one arm can cross the deadline. Each
outcome below is stated ahead of the run.

- The listing carries the built runtime's digest, the scene, and the
  ceiling; the broker's health names the physics profile and no geometry
  one.
- One 600-step run completes with `gpu_dynamics_active` true and the
  built runtime's digest, and the tool result carries counts, the proof,
  and digests alone. `nvml_compute_visibility` is reported as observed or
  `not_observed_during_sample`: at ten hertz a run of under a second may
  fall between samples, and a `/proc` sighting is never a launch proof.
- The replayed grant refuses as spent; the ungranted call refuses; a
  count one above the approved one refuses with `arguments differ`; a
  geometry body at the physics endpoint and any body at the unarmed
  geometry endpoint refuse at the broker.
- A lease held from outside for the whole call refuses with
  `lease_unavailable` and starts no runtime.
- A 100000-step run under the 2 s deadline reports the runtime exceeded
  its deadline, and no runtime process survives one second later.
- The page turn posts exactly one physics grant and at least one tool
  call, reaches the router and broker origins alone, and its tool message
  carries `"status": "completed"`; a model answering in prose is a model
  finding, recorded against the 4B distill the image lane already found
  proposes schema-valid calls.
- The teardown proves the session, the service, the socket, the lease,
  and the session secret gone.

A refusal at any step keeps the ledger row refused. The geometry lane
follows this record under the same contract, and a contention arm running
both lanes against one lease is its own record.

## Run 07

`run-07/` is the retained run on the RTX 4070 Ti, with the operator's
telemetry server stopped for the window and the appliance's ordinary
desktop as the client set. Runs 01 to 05 were the same campaign with
harness defects, each corrected on the committed form ahead of the next:
the preset generator refused a configuration on a ui-mediated section
under a sidecar tag, the timeout arm's ceiling exceeded the protocol
maximum, the session's graphics probe path and the sidecar variables
were not forwarded across the tmux boundary, the page read the
proposal's arguments as an object where llama-server streams them as
text, and the harness read the tool message's status at a byte offset.
Run 05 accepted every arm but that last one, run 06 accepted every arm
on the pre-review form, and run 07 repeats it on the reviewed form,
where the service spends each grant in its own ledger, the collector
reads the runtime over a select loop, and the launcher hands the session
the key, state directory, and socket the preset names.

The runtime compiled in the run digests to the value the preset carried,
the service announced, the listing stated, and every grant bound. The
served model was the 4B distill, which proposed
`physics_simulate_rigid({"profile_id":"physics-d6-chain-a","count":600})`
on the first round.

| arm | outcome |
| --- | --- |
| listing binds runtime, scene, ceiling | accepted: `d6-chain-4`, ceiling 100000 |
| broker signs the physics profile, no geometry one | accepted |
| 600-step run through the child | accepted: `gpu_dynamics_active` true, the built runtime's digest, 4 bodies, 4 joints, `simulate_ms` 472.3, wall 2.10 s through the router, child, service, and runtime |
| result carries counts, proof, and digests alone | accepted |
| driver client list during the run | observed: `physx-rigid-runtime` at 12 to 196 MiB in 11 samples, the lease held in 83, at ten hertz |
| replayed grant | refused as spent |
| ungranted call | refused |
| count one above the approved one | refused: `arguments differ` |
| geometry body at the physics endpoint | refused at the broker |
| any body at the unarmed geometry endpoint | refused at the broker |
| lease held from outside | refused: `another workload holds the lease`, no runtime started |
| 100000 steps under the 2 s deadline | failed as `runtime exceeded 2 s; exit_s=2.232 sigterm_s=2.015`, the reply landing at 16.6 s of wall through the router, and no runtime process survived one second later |
| page turn | accepted: one `POST /grant-physics`, one `POST /tools`, origins the router and broker alone, the tool message `status: completed` with the proof, and the model's reply naming 600 steps, 4 bodies, and 4 joints |
| teardown | accepted: no server, session, probe, broker, or service; physics residue clean; session secret gone |

**What this settles.** The physics lane runs inside the served session
under the lease contract: the service proves the lease it holds is the
session's file, one approval buys one run bound to the runtime, the scene,
the profile, and the count, and every departure from the grant, the lease,
or the deadline refuses or fails where the design says it does. The
application execution stays unauthorized in the checked-in ledger, since a
served run under a copied row is an admission and a policy change is its
own transition.

**What it leaves open.** The deadline arm's reply time is stated with
the service's own timeline, the offsets at which SIGTERM, SIGKILL where it
was needed, and the leader's exit followed the deadline; what the runtime
does between the signal and its exit is the runtime's, and a runtime that
reads a stop between steps is a runtime change rather than a service one.
The geometry lane and a contention arm running both lanes against one
lease are the next record.
