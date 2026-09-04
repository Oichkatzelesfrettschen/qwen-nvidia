# The D6 chain on the GPU, through the service

`scripts/admit-physics-runtime.sh` ran once on the RTX 4070 Ti under the GPU
owner lock, with the operator's telemetry llama-server stopped for the window.
`summary.tsv` carries the 26 checks; every one reads `accepted`.

The subject is `physics-d6-chain-a` with its `execution_policy` raised from
`refused` to `validator-gated` in the copied ledger `physics-profiles.tsv`
alone; the row in `scripts/physics-profiles.tsv` still reads `refused`, and
promotion is a separate transition this record informs.

What the record establishes, and where each fact is read from:

- The service and the runtime ran as uid 1000 (`ordinary_user_uid`,
  `service_pid_uid`), the runtime at nice 19 and the idle I/O class
  (`state/runtime-stderr.txt`).
- The service took the compute lease around the job and released it:
  `clients-during.tsv` reads the lease `held` on 14 of 15 ticks and
  `state/vulkan-workload.status` ends on `state=released`; a fresh `flock -n`
  succeeds afterwards.
- The runtime opened its own CUDA context on AD104: the driver's client
  list names `physx-rigid-runtime` on 13 of 15 ticks, at 10 MiB while the
  context came up and 288 MiB through the run, beside the compositor and a
  browser GPU process.
- PhysX ran on the GPU rather than falling back: the reply carries
  `cuda_context_valid=true`, both GPU flags requested, and
  `gpu_dynamics_active=true` read back off the scene after the run, with the
  device name equal to the one `nvidia-smi` reports.
- The chain state is the one the fixture predicts: four bodies, four D6
  joints, none broken, every center below the anchor at y=6 and above the
  0.5 half-extent over the ground plane, consecutive centers 1.198, 1.199,
  and 1.191 apart against the 1.2 joint span, and the chain still swinging
  at step 3600 (`reply.json`).
- 3600 steps of 1/60 s simulated in 1329 ms, 1607 ms of runtime wall time
  including context creation, 1.705 s from request to reply through the
  socket.
- Nothing survived: the service exited clean with an empty stderr, the
  socket is gone, `physics-teardown-check.sh` reads clean, and the client
  list after the run holds the two desktop processes alone
  (`ownership-after.txt`).

Two windows ahead of this one failed on the harness and on the package
rather than on the device, and both are recorded in the commit history
rather than as retained arms. The service's default socket path under an
evidence directory exceeded the 107-byte AF_UNIX bound, so the admission
script now binds under `XDG_RUNTIME_DIR`. Then physx-sdk 5.9.0-3's
`libPhysXGpu_64.so` failed `dlopen` with `undefined symbol:
__cudaLaunchKernel`: nvcc 13 emits a host stub per kernel that calls
`__cudaGetKernel` and `__cudaLaunchKernel`, and the SDK links no CUDA
runtime because `CudaKernelWrangler.cpp` shims registration itself, so
PhysX reported the context invalid and every scene would have run on the
CPU. The service now retains the runtime's stderr, which is what named the
symbol; 5.9.0-4 adds the two entry points to the wrangler's shims and pins
the fatbin to sm_89, and this record ran against it.
