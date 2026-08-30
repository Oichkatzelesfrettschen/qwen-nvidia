# The 9B distill kills the router when it loads behind a resident child

`qwen38-9b-distill` is admitted as a standalone checkpoint and refused as a
router child. Two switches into it ended the whole server with SIGKILL, and the
driver named the cause: `NVRM: GPU0 nvCheckOkFailedNoLog: Check failed: Out of
memory [NV_ERR_NO_MEMORY] returned from _memdescAllocInternal`.

## Mechanism

The router brings a child up before it releases the one it replaces, so peak
device occupancy during a switch is the sum of two children rather than the
`--models-max` count. The 9B carries 5.37 GiB of weights and reaches about 6.3
GiB with its 16384-token cache; the 4B distill at 65536 measures 4100 MiB. The
switch therefore asks for roughly 10.4 GiB while the compositor holds 1.4, on a
12282 MiB carve-out, and the allocation the driver refuses is the one that ends
the process.

`--models-max 1` does not avoid it. A sweep at that setting answered fourteen
checkpoints in sequence with a peak of 6010 MiB and then died on the switch into
the 9B, which is the same failure the two-child setting produced.

## Scope

The quarantine is profile scope against the router path. The checkpoint loads
and serves standalone: `evidence/ada/baseline-sweep-02/` measures it at 4410.81
prefill and 67.91 decode tok/s, and `evidence/ada/context-depth-64k/` loads it
at 32768 and 49152 alone. Nothing here says the 9B is unserviceable; it says the
picker cannot switch into it beside a resident child of this size.

## Re-entry gate

Any one of these admits it back:
- a router that releases the outgoing child before it allocates the incoming
  one, which removes the two-child peak;
- a measured pair whose sum leaves headroom at the largest admitted depth, with
  every other row's depth lowered to fit it;
- a smaller quantization of the 9B whose weights leave room for the peak.

The measurement that would settle the first is unrun: no arm here reads device
occupancy across a switch at a sampling rate that separates release from
allocation.
