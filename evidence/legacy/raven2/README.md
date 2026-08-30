    source_repository=qwen-apu
    source_commit=55d8c73268d8c6496e77baaad732e1aea7a6183b
    evidence_class=prior-host
    performance_authority=none
    current_defaults_authority=none

## The prior host

`evidence/rocm-feasibility-audit.md` and `evidence/kv-cache-policy-factorial.md`
name the device: an AMD Athlon Silver 3050U carrying two Vega compute units at
`gfx902`, 29 GiB of DDR4 shared between the CPU and the iGPU (UMA, no discrete
VRAM), and Mesa RADV as the sole Vulkan driver. `evidence/decode-bound-analysis.md`
measures achieved streaming at 5.5 to 10.4 GB/s across the checkpoints it
covers, well under the roughly 34 GB/s DDR4 bandwidth ceiling the platform
advertises, so the gap between achieved and theoretical bandwidth is itself
part of what the retained findings below explain.

## What this directory is

Every measurement under `evidence/` in this tree that predates the RTX 4070 Ti
retarget was taken on that Raven2 host. About 1300 raw files carry those
measurements at full detail, and they are deleted from this repository because
the authoritative copies remain in `qwen-apu` at the commit named above. This
directory is what survives the deletion: one README stating what the prior
host was and why its findings still matter, and one table of the individual
conclusions worth carrying forward.

Every row in `comparative-findings.tsv` is prior-host evidence. It sets no
default on the RTX 4070 Ti, it enters no prediction band here, and no script
in `scripts/` reads it. A default in this tree changes only when a measurement
under `evidence/ada/` moves it, per `CLAUDE.md`. The complete raw records --
logs, kernel traces, per-arm clock samples, and the narrative evidence files
this table summarizes -- remain in `qwen-apu` at commit
`55d8c73268d8c6496e77baaad732e1aea7a6183b`, reachable from this tree as the
`apu` Git remote.

## Why the conclusions are still worth carrying

The two hosts are the contrast case for each other. The APU was
memory-bandwidth-bound, ran a Vulkan-only backend, and reported an integer dot
product that RADV advertises as functional but every `*Accelerated` capability
flag as false, so its K-quant and Q8_0 tensors never reached a `_q8_1`
pipeline and executed through the FP16-dequantize-then-dot family instead. The
4070 Ti is device-memory-bound rather than bandwidth-bound, serves through a
CUDA backend with the full quantized mat-mul kernel set, and falls back to
Vulkan through the same binary rather than depending on it. That is not a
faster version of the same machine; it is a different bottleneck answered by
a different kernel set.

Several verdicts measured true on the APU invert on the 4070 Ti, and a few
figures -- notably the forward-to-reverse repeat span the APU carried at up to
30.6% against 0.0 to 2.4% here -- change by an order of magnitude rather than
direction. Re-deriving each of these from a blank slate would spend device
time re-discovering what the prior host already answered. Reading them cold
without the inversion flagged would instead re-adopt a Raven2 default by habit
-- a batch/microbatch ceiling set by an amdgpu ring wedge, a K-quant ladder
closed on a 34 GB/s bandwidth ceiling, a speculation verdict set by an
unaccelerated dot product -- on a device where the mechanism that produced it
does not apply. `comparative-findings.tsv` exists to name, for each retained
conclusion, whether the RTX 4070 Ti has measured the same direction, the
opposite direction, or nothing at all yet.
