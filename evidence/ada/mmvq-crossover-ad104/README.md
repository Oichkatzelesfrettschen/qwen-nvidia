# MMVQ crossover on AD104: Q6_K belongs at twelve columns and Q8_0 past it

One worktree at f280b2698, two builds differing by one variable. The stock
build carries the upstream dispatch; the subject build raises
MMVQ_MAX_BATCH_SIZE to 12, instantiates ncols_dst 9 through 12 with the 5-8
launch parameters, and pins the mul_mat_id gate to MMVF_MAX_BATCH_SIZE so the
MoE path keeps stock behavior (mmvq12-experimental.patch, binaries.sha256).
Both builds ran Q6_K (4B distill) and Q8_0 (0.8B) at ne11 7 through 12,
mirrored forward and reverse, three repetitions per point, through the served
flags `-ngl 99 -fa 1 -ctk q8_0 -ctv q4_0 -t 6` on CUDA0.

## Per-token prefill throughput, paired means

| ne11 | Q6_K stock | Q6_K MMVQ-12 | Q8_0 stock | Q8_0 MMVQ-12 |
| ---: | ---: | ---: | ---: | ---: |
| 7 | 73.2 | 74.5 | 229.1* | 229.0 |
| 8 | 72.9 | 71.1 | 230.4* | 230.4 |
| 9 | 62.4 | 70.2 | 173.6* | 216.3 |
| 10 | 62.6 | 66.8 | 173.6 | 227.6 |
| 11 | 64.5 | 66.9 | 178.3 | 195.5 |
| 12 | 62.7 | 63.0 | 178.7 | 204.0 |

Stock runs MMVQ at 7-8 and MMQ from 9; the subject runs MMVQ throughout. The
starred Q8_0 rows at 7-9 come from the production binary in the same session
(../../..: the representation sweep), whose 7-8 values agree with the subject
build inside 1%, the cross-build control. MMVQ wins 12.5% at nine columns on
Q6_K and 25-31% at nine and ten on Q8_0, and it loses nowhere in the range,
ending in a tie at twelve on Q6_K while still ahead 14% on Q8_0.

## Verdict

The upstream Ada branch of ggml_cuda_should_use_mmvq keeps Q4_K and Q5_K on
MMVQ through seven columns and everything else through eight, tuned on an RTX
4090. On AD104 the measured Q6_K crossover sits at twelve and the Q8_0
crossover past twelve. The Q4_K and Q5_K pins stay correct
(../b789-clean-calibration/). Serving prefill runs at ubatch 512 and plain
decode at one column, so the seven-to-twelve window pays in speculative
verification batches and small parallel slots rather than in the served
headline rates.
