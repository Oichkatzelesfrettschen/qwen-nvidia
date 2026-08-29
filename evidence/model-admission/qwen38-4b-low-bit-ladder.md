# The published low-bit ladder for the balanced-text checkpoint

The 4B distill decodes at 3.07 tok/s and the interactive target is 4.5, a factor
of 1.466. Speculation reached 1.13 to 1.16 through the embedded MTP head at one
draft token and lost at every deeper draft, so the remaining published lever is
byte count. `mradermacher/Qwen3.8-4B-Distill-i1-GGUF` carries the imatrix ladder
below Q4_K_M and `remote/download-qwen38-4b-distill-i1-q2k.sh` and
`remote/download-qwen38-4b-distill-i1-iq3s.sh` pin two rungs of it.

The imatrix build is taken over the static one at Q2_K. The two differ by 256
bytes, 1,959,168,512 against 1,959,168,256. The published sizes suggest the
same tensor recipe, while the static file remains uncensused and unmeasured.
The calibrated build removes a missing imatrix as one explanation for a quality
failure without asserting a rate comparison that did not run.

| rung | file | bytes | role in the ladder |
| --- | --- | ---: | --- |
| L0 | Qwen3.8-4B-Q4_K_M | 2,783,446,304 | the served reference |
| L1 | Qwen3.8-4B-i1-Q2_K | 1,959,168,512 | the speed falsifier |
| L2 | Qwen3.8-4B-i1-IQ3_S | 2,191,729,152 | the quality compromise |

## Registered before the first rung runs

**Proportional scaling.** Q4_K_M streams 2.698 GB per token at 3.07 tok/s, which
is 8.28 GB/s. Q2_K holding its per-byte rate predicts 4.34 tok/s once its own
multi-token-prediction block is excluded from the streamed total, which the
census measures rather than assumes. The falsifier is two-sided and wide: below
3.5 or above 5.5 refutes proportional scaling. It is wide because this tree has
refuted two byte-count models already -- the 2B streams 44.3% faster per byte
than the 4B, and a two-parameter fit over the 32-layer pair returns a negative
fixed term when the 2B is added to it. Decode here is not purely bandwidth-bound
and Q2_K dequantization is more arithmetic per byte than Q4_K, so fewer bytes
converting to proportionally more tokens is the claim under test rather than the
assumption behind it.

**Quality falls and the fall is measurable.** The five-prompt screen separates
the 4B from the 9B no further, so `remote/quality-suite.tsv` grades 55 rows
across seven categories. The prediction is that Q2_K loses arithmetic and
multi-step word problems first, since those carry a single correct token
sequence, and holds format compliance and retrieval, which tolerate a wider
distribution. The falsifier is a uniform fall across categories, which would
make the loss a decode-quality effect rather than a reasoning one.

**Q2_K does not inherit the balanced-text role by crossing 4.5.** The 2B already
reaches 9.46 tok/s and is wrong on elementary arithmetic, which is why the roster
separates fast-text from balanced-text. A Q2_K that crosses the threshold and
regresses on arithmetic takes the fast-text role at best, and the 2B holds that
role at more than twice the rate.

## Admission gates

Each rung passes four gates before it enters `remote/models.tsv`.

**Structural identity.** `remote/gguf-tensor-census.py` records the source
revision, the file SHA-256, `block_count`, `qwen35.nextn_predict_layers`, the
tied-embedding state, bytes by ggml type, bytes by operation family, the MTP
block size, streamed bytes per token, the chat-template SHA-256, and the
tokenizer identity. A shared quantization label names a recipe rather than a
layout, and a requantizer copies metadata, so two files that agree tensor for
tensor still answer differently when one carries a different template.

**Runtime correctness.** Every target tensor resolves to Vulkan with no CPU
fallback, no `ErrorDeviceLost`, no VM fault, no GPU reset, and no new swap or
reclaim event. Repeated launches produce the same token sequence. Token identity
against Q4_K_M is not required: quantization legitimately moves low-margin
logits, and requiring it would refuse every rung by construction.

**Performance.** pp512, tg64 at depth 0, decode at 4096, 16384, and 24576, a
32768 allocation with a near-depth decode, served throughput through the guarded
path at a fixed generation length, and desktop frame latency at p50, p90, and
p99. Each rate carries the modal `pp_dpm_mclk` step it ran at, because the
memory ladder's top two steps span 12.6% and that exceeds several of the effects
being resolved.

**Quality.** The 55-row suite at temperature 0, reporting correctness on
completed rows apart from completion rate, empty-answer rate, truncation rate,
reasoning words, total generated tokens, and wall time to the final answer.

## Results

**L1 i1-Q2_K passes the structural gate and fails on performance.** Its chat
template hashes to
`a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715` across 7756
bytes, byte-identical to Q4_K_M, with the same tokenizer model and the same
248,320-entry vocabulary. The tied Q6_K vocabulary projection is byte-identical
at 521,472,000 bytes, so the requantizer compressed the trunk and left the
projection untouched.

Performance refuses it. `evidence/decode-bound-analysis.md` sweeps both
checkpoints four times, alternating the model order, and Q4_K_M leads in every
sweep: 3.28 against 3.18, 2.93 against 2.67, 2.68 against 2.62, and 3.13 against
3.13. The registered falsifier was a rate below 3.5 and the highest Q2_K arm
measured 3.18. Achieved streaming fell from 8.11 GB/s to 5.53, a 31.8% drop that
cancels a 29.4% byte saving.

The quality suite did not run on L1. Grading 55 rows costs about an hour on this
part, and the performance failure alone prevents admission for the role this
ladder targets. The scope cut leaves its quality unmeasured rather than assuming
the magnitude or category of a quantization loss.

**The two upper K-quant rungs are withdrawn from admission.** i1-Q6_K and
i1-Q5_K_M extend the series upward, and Q4_K_M leads both in every sweep by 28%
and 55% on paired means. IQ3_S remains unmeasured and cannot be interpolated
from those K-quant endpoints because its codebook reconstruction is a different
kernel mechanism. Its fetch script stays pinned at
`remote/download-qwen38-4b-distill-i1-iq3s.sh` for the one purpose that survives:
IQ formats reconstruct through a codebook rather than a scaled field, and an
IQ4_XS or Q3_K_M arm is the measurement that would discriminate the conjecture in
`evidence/decode-bound-analysis.md` about what separates the 8 GB/s group from
the 5.9 GB/s group.

**BF16 plus local quantization stays unbuilt.** The decision that opened this
ladder named it the instrument for repairing a measured quality gap rather than
the tool for discovering one. No quality gap was measured, and the performance
gap it would have been aimed at is closed across the tested K-quant ladder.
