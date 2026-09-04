# What a projection fan-out merge can reach, and the one number that decides it

Every mat-mul on the MMVQ path quantizes its own second operand.
`ggml/src/ggml-cuda/mmvq.cu:1332` calls `quantize_row_q8_1_cuda` into a fresh
`ggml_cuda_pool_alloc` on every `ggml_cuda_mul_mat_vec_q` call, with no cache
keyed on the activation, and that function ends on `GGML_UNUSED(type_src0)`
(`quantize.cu:571`), so the MMVQ q8_1 encoding is independent of the weight
type. Several mat-muls reading one activation therefore produce byte-identical
buffers and issue one quantize launch each.

`src/models/qwen35.cpp` fans one activation out three times per layer.

| fan-out | site | members | state |
| --- | --- | --- | --- |
| linear attention | `build_qkvz` lines 237, 241 and lines 362, 369 | `wqkv`, `wqkv_gate`, `ssm_beta`, `ssm_alpha` | open |
| full attention | lines 270, 282, 285 | `wq`, `wk`, `wv` | open |
| feed-forward | gate and up | `ffn_gate`, `ffn_up` | already collapsed |

The feed-forward pair is the one `ggml_cuda_can_fuse` already reaches through
`mul_mat_glu_ops` (`ggml-cuda.cu:3043`), and the retained counters confirm the
fusion fires rather than merely existing: `../ncu-decode-baseline/` measures
`mul_mat_vec_q<Q4_K, 1, has_fusion=1>` at 32.38 us and 444.7 GB/s, which is
14.40 MB of traffic against the 14.16 MB that `ffn_gate` and `ffn_up` hold
together on the 2B. That launch reads 90.6% of the 442.61 GB/s this device
sustains while the unfused `<Q4_K, 1, 0>` class reads 39.5%, so the FFN merge is
the measured precedent this arm proposes to repeat on the other two fan-outs.

## The architecture bounds it before any kernel is written

All four checkpoints this tree serves declare `qwen35.full_attention_interval`
of 4, so a full-attention layer -- the one carrying the `wq`/`wk`/`wv` fan-out
the task was written against -- is one layer in four:

| model | blocks | linear-attention layers | full-attention layers |
| --- | ---: | ---: | ---: |
| qwen35-08b | 25 | 18 | 7 |
| qwen38-2b-distill | 25 | 18 | 7 |
| qwen38-4b-distill | 33 | 24 | 9 |
| qwen38-9b-distill | 33 | 24 | 9 |

The four-way linear-attention fan-out is the larger one and the wider target.
What bounds it is the weight type rather than its width: `mul_mat_vec_q` is
templated on one `ggml_type` (`mmvq.cu:544`), so a merged launch reaches only
the largest same-type subset of a group. `attn_qkv` is Q6_K on the 2B, 4B, and
9B while the other three members are Q4_K, which splits a four-member group into
a three-member merge. The 0.8B is Q8_0 throughout and merges all four. The
full-attention group splits the same way on the 4B and 9B, where `attn_v` is
Q6_K against Q4_K for `attn_q` and `attn_k`.

## The saving is a launch count, and the launch cost is unmeasured

A group of N mat-muls whose largest same-type subset is M issues N mat-mul and N
quantize launches now, and N - M + 1 mat-mul launches and one quantize after the
merge, so the merge removes N + M - 2 kernel launches.
`scripts/derive-projection-fan-out-bound.py` reads that off the GGUF headers:

| model | launches removed per token | decode token | t0 reaching 5.1% |
| --- | ---: | ---: | ---: |
| qwen35-08b | 136 | 3220.6 us | 1.21 us |
| qwen38-2b-distill | 123 | 4322.1 us | 1.79 us |
| qwen38-4b-distill | 163 | 8807.5 us | 2.76 us |
| qwen38-9b-distill | 163 | 14725.4 us | 4.61 us |

Every removed launch is worth exactly the per-launch fixed cost t0, since the
bytes moved are unchanged, and t0 is the number this tree has not measured. Two
readings bracket it and they disagree by six times.

The lower end is measured: `../decode-node-trace/run-02/decode-2b-q4k/` reports
`median_idle_between_device_rows_ns` of 165361 over roughly 767 kernels per
token, which is 216 ns of device idle per kernel boundary. That is the gap
alone, and it excludes whatever ramp and drain a launch spends inside its own
recorded duration.

The upper end is fitted rather than measured. Taking `time = t0 + bytes/442.61
GB/s` against four `../ncu-decode-baseline/` launches -- the 0.8B at 2.245 MB
and 6.68 MB, the 2B Q6_K at 10.32 MB and the fused Q4_K pair at 14.16 MB --
returns t0 near 1.4 us within 5%. `ncu` serializes and replays each kernel, so
that fit is biased upward and 1.4 us is a ceiling on t0 rather than an estimate
of it.

At 216 ns the 0.8B saving is 0.91% of its token; at 1.4 us it is 5.9%. The
promotion floor sits inside that bracket, so the bracket decides nothing.

## Preregistration

**Hypothesis.** t0 is below 1.21 us, so removing every fan-out launch the
architecture allows falls under the 5.1% promotion floor on all four
checkpoints and no kernel is written.

**Instrument.** One node-granularity Nsight Systems capture of a batch-1 decode
on the 2B, read per kernel symbol.

**Two independent estimators of t0 out of that one capture.**

`ssm_alpha` and `ssm_beta` are 2048 by 16 Q4_K, 18432 bytes each, which is 0.04
us of traffic at the sustained rate. Their `mul_mat_vec_q` launches are 16
output rows, far under one wave, so the whole recorded duration is t0 to within
that rounding.

`quantize_q8_1` is the kernel the merge removes. Its decode launch is 8 blocks
on 60 multiprocessors, also far under one wave, so its duration is the second
estimator and it comes from the kernel actually at issue.

Neither launch carries a tail-wave effect, which is what makes both clean reads
of fixed cost rather than of small-launch efficiency.

**Direction of instrument bias.** Node granularity inflated the token span by
20% on the 2B in `../decode-node-trace/run-02/`, so a per-kernel duration read
from it is an upper bound on t0. The 2B arm is the subject for that reason; the
same capture on the 0.8B inflated 2.4 times and is read as corroboration alone.

**Falsification.** A median duration above 1.21 us on either estimator, read
from an instrument biased upward, refutes the hypothesis for the 0.8B and the
arm proceeds to a merged-launch design for that class. Agreement between the two
estimators within a few hundred nanoseconds is what licenses reading either as
t0; a disagreement wider than that leaves t0 unmeasured and the capture reports
that rather than an average of the two.

**Numerics if the arm proceeds.** A merged launch keeps each output row's
K-reduction order, since one block still computes one output row from one weight
matrix by the same accumulation. The claim is bit-identity by construction, and
this tree's precedent is that construction is not the gate: `../mmq-fixup-pipeline/`
holds a change that was bit-identical by construction and still ran 18 prompt
comparisons before saying so. Exact greedy token identity on all three runtime
classes is the gate, ahead of any rate reading.

**What no reading here decides.** The bound is computed at `ne11` of 1. A
concurrent-sequence or speculative-accept workload moves these mat-muls to MMQ
with a different geometry, which recomputes the whole table, and this arm makes
no claim about that regime.
