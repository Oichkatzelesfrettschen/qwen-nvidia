# Research claim and evidence methodology

This repository is the source record for one offline inference appliance: an
AMD Ryzen 5 5600X3D workstation with one NVIDIA GeForce RTX 4070 Ti. It carries
the executable policy, measurement programs, sanitized target observations,
derived analyses, and the falsifiers that bound each conclusion. It does not
stand in for this exact device as a population, another kernel or driver
build, or another checkpoint revision. The prior host that produced an earlier
such record, a laptop-class AMD APU, is a separate repository; its findings
are retained as history in `evidence/legacy/raven2/` and are not restated here
as claims about this device.

## Architecture and authority

| Layer | Authority in this repository | Observation surface | Claim boundary |
| --- | --- | --- | --- |
| DRAM and fabric | SPD records, host memory controller state | host bandwidth measurement | DIMM training and selected memory state on this machine |
| GPU and memory manager | the installed NVIDIA kernel driver, firmware identity, NVML accounting, kernel log | Xid faults, ECC and device-memory counters, coredump excerpts | allocation, recovery, and faults under the recorded driver |
| Vulkan driver | the installed Vulkan ICD and loader identities | device selection, queue priority, tensor-placement logs | behavior of the pinned installed userspace stack |
| Inference engine | pinned llama.cpp source plus the replayed patch series | command line, tensor census, server timings, strict placement checks | the exact build and GGUF files named by hashes |
| Appliance policy | `scripts/models.tsv`, `qwen-capacity-policy.sh`, launch and teardown scripts | resolved arguments, session status, health and teardown proofs | the served configuration rather than a harness default |
| Measurement | the `measure-` and `run-` scripts under `scripts/`, fixed request suites | arm inputs, raw logs, clock and load samples, terminal state | the intervention and controls encoded by each harness |
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

`scripts/repository-quality-gates.sh` checks the clone-local implementation and
evidence invariants. GPU execution, model-file identity, kernel observations,
and remote deployment remain target gates because a hosted runner has none of
those authorities. `scripts/test-vulkan-submit-limit.sh`, `scripts/test-vulkan-pacing-math.sh`, the
other Vulkan probe tests, the GGUF census cross-check, and the llama.cpp patch
verifier therefore run on the appliance or against their pinned external
source rather than in hosted CI.

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
| Decode rate does not scale proportionally with streamed bytes | measured on the prior host, paired comparison | `evidence/legacy/raven2/comparative-findings.tsv` finding `4b-kquant-ladder-exhausted`; raw record in the qwen-apu repository | Q2_K streams 29.4% fewer bytes and does not beat Q4_K_M in four paired blocks | an arm on this device repeating the comparison, since the finding is not re-asserted here |
| Bulk tensor format tracks two achieved-rate groups in the measured ladder | exploratory association, measured on the prior host | `evidence/legacy/raven2/comparative-findings.tsv` finding `streaming-two-groups`; raw record in the qwen-apu repository | Q4_K and Q6_K trunks group near 8.1 GB/s while Q5_K groups near 5.9 GB/s | an arm on this device landing outside the group predicted by its operation mix |
| Nice 19 has no resolved directional decode cost under the measured desktop load | measured on the prior host, paired comparison | `evidence/legacy/raven2/comparative-findings.tsv` finding `nice19-no-directional-cost`; raw record in the qwen-apu repository | mean favours nice 19 by 1.10%; nominal interval spans -6.1% to +3.9% | a randomized equivalence run on this device resolves a stable effect |
| Submission geometry rather than depth alone explains a serialized-submission wedge | measured on the prior host | `evidence/legacy/raven2/comparative-findings.tsv` finding `depth16384-submission-geometry`; raw record in the qwen-apu repository | batch 128 / ubatch 32 passed at depth 16384 where the harness-default batch 2048 / ubatch 512 wedged the compute ring under the same cache triple | an arm on this device separating depth from batch geometry at a comparable depth |

## Publication gate

An article-facing table cites the retained raw path and digest, the source and
binary identities, the exact command, the evidence class, the transform, and
the claim boundary. The table excludes superseded runs only from the decision
surface; `ARTIFACTS.md` retains their provenance and explains why they lost
authority. Every figure states the sample count, order, central statistic,
spread or interval, and missing-data rule. Every causal sentence names an
intervention that separates the proposed mechanism from its alternatives.
