# Research claim and evidence methodology

This repository is the source record for one offline inference appliance: an
AMD Athlon Silver 3050U Raven2 APU with two Zen+ cores, two Vega compute units,
and shared DDR4. It carries the executable policy, measurement programs,
sanitized target observations, derived analyses, and the falsifiers that bound
each conclusion. It does not stand in for Raven2 as a population, another
kernel or Mesa build, or another checkpoint revision.

## Architecture and authority

| Layer | Authority in this repository | Observation surface | Claim boundary |
| --- | --- | --- | --- |
| DRAM and fabric | UMC SMN registers, SPD records, SMU-selected FCLK | `evidence/hp14-dk1xxx-memory-registers.log`, `pp_dpm_mclk`, host bandwidth | DIMM training and selected fabric state on this machine |
| GPU and memory manager | Ubuntu amdgpu kernel, firmware identity, sysfs accounting, kernel log | ring resets, VM faults, VRAM and GTT counters, coredump excerpts | allocation, recovery, and faults under the recorded kernel |
| Vulkan driver | Mesa RADV and loader identities | device selection, queue priority, tensor-placement logs | behavior of the pinned installed userspace stack |
| Inference engine | pinned llama.cpp source plus the replayed patch series | command line, tensor census, server timings, strict placement checks | the exact build and GGUF files named by hashes |
| Appliance policy | `remote/models.tsv`, `qwen-capacity-policy.sh`, launch and teardown scripts | resolved arguments, session status, health and teardown proofs | the served configuration rather than a harness default |
| Measurement | `remote/measure-*.sh`, `remote/run-*.sh`, fixed request suites | arm inputs, raw logs, clock and load samples, terminal state | the intervention and controls encoded by each harness |
| Retention | `ARTIFACTS.md`, `evidence/SHA256SUMS`, pre-sanitization manifests | tracked path, digest, provenance, sanitization class | clone-visible evidence and its exact-target origin |

Hardware behavior enters through the target observation surfaces. Source
reading explains a mechanism and defines a falsifier; it does not convert a
source-level expectation into silicon evidence. A generated inventory describes
what a file or registry contains and does not establish that the hardware
executes it successfully.

## Claim record

A decision-grade claim carries these fields in its owning evidence document:

1. The subject names the checkpoint, build, kernel, driver, machine state, and
   operating profile that make the result specific.
2. The evidence class is measured, derived, estimated, documented, or untested.
3. The hypothesis and its falsifier exist before the run where prediction could
   bias interpretation.
4. The intervention names the one mechanism that changes, while controls and
   measured covariates expose the mechanisms that can move with it.
5. The raw record preserves arm order, exact flags, observed runtime state,
   process status, and hardware faults. Unreadable sensors carry `unavailable`;
   numeric zero remains a measurement.
6. The transform from raw values to a table or coefficient is executable or
   written as explicit arithmetic. A fitted coefficient names its denominator,
   assumptions, and residuals.
7. The terminal state distinguishes `completed`, `failed`, and an expected
   experimental rejection. A failed transport, parser, priority readback, or
   teardown cannot print `completed`.
8. The conclusion states the smallest claim the data support, followed by the
   residual uncertainty and the next probe that closes it.

`remote/repository-quality-gates.sh` checks the clone-local implementation and
evidence invariants. GPU execution, model-file identity, kernel observations,
and remote deployment remain target gates because a hosted runner has none of
those authorities. `remote/test-radv-low-priority-env.sh`, the Vulkan probe
tests, the GGUF census cross-check, and the llama.cpp patch verifier therefore
run on the laptop or against their pinned external source rather than in hosted
CI.

## Experimental design

Single-arm rates describe one machine state. They do not estimate an effect.
Comparative measurements use adjacent pairs, reverse or randomize order, repeat
the control at the block boundary, and record load, clocks, temperature, memory
accounting, and faults through the same interval. A run that cannot read a
required covariate remains usable only with that limitation stated beside the
result.

A null-direction result and an equivalence result are different claims. A
comparison establishes equivalence only after it declares an acceptable effect
margin and both one-sided uncertainty bounds land inside that margin. A small
mean with a wide interval states unresolved direction, not zero cost.

Depth, batch size, microbatch size, cache type, Flash Attention, submission
node count, scheduling priority, and machine load are separate factors. A run
that changes more than one records the confounding explicitly and routes the
next measurement through a factorial or matched control that separates them.

## Paper-oriented claim map

| Claim | Class | Owning record | Result | Falsifier or residual |
| --- | --- | --- | --- | --- |
| The installed DRAM trains at the SPD DDR4-2133 profile | measured register decode | `hp14-dk1xxx-memory-firmware-rca.md` | both UMC channels decode to 2133.33 MT/s and 15-15-15-36 | a boot or channel whose retained UMC ratio or timings differ |
| Decode rate does not scale proportionally with streamed bytes | measured paired comparison | `decode-bound-analysis.md` | Q2_K streams 29.4% fewer bytes and does not beat Q4_K_M in four paired blocks | an independently repeated Q2_K arm above the registered 3.5 tok/s floor |
| Bulk tensor format tracks two achieved-rate groups in the measured ladder | exploratory association | `decode-bound-analysis.md` | Q4_K and Q6_K trunks group near 8.1 GB/s while Q5_K groups near 5.9 GB/s | IQ4_XS or Q3_K_M landing outside the group predicted by its operation mix |
| Nice 19 has no resolved directional decode cost under the measured desktop load | measured paired comparison | `scheduling-priority-cost.md` | mean favours nice 19 by 1.10%; nominal interval spans -6.1% to +3.9% | a randomized equivalence run or a host-critical workload resolves a stable effect |
| The 16K wedge is attributable to depth, batch geometry, or their interaction | untested registered decomposition | `depth-versus-submission-geometry.md` | result pending | the three registered geometries at 8K and 16K separate the alternatives |
| A configured context allocation proves occupied-cache execution | refuted interpretation | `depth-versus-submission-geometry.md` | allocation and near-full execution remain separate capabilities | a served near-depth decode with clean control and kernel delta closes the gap |

## Publication gate

An article-facing table cites the retained raw path and digest, the source and
binary identities, the exact command, the evidence class, the transform, and
the claim boundary. The table excludes superseded runs only from the decision
surface; `ARTIFACTS.md` retains their provenance and explains why they lost
authority. Every figure states the sample count, order, central statistic,
spread or interval, and missing-data rule. Every causal sentence names an
intervention that separates the proposed mechanism from its alternatives.
