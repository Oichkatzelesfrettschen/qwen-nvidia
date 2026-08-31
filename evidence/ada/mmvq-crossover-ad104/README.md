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

Against the 5.1% closing-control drift floor the calibration registered, the
Q6_K advantage clears the floor through ten columns and sits inside it at
eleven and twelve, so ten is the largest defensible Q6_K threshold and the
eleven-to-twelve span stays unresolved. The Q8_0 advantage clears the floor at
every measured point, so twelve is a floor rather than an optimum and the
crossover past twelve stays open.

## Verdict

The upstream Ada branch of ggml_cuda_should_use_mmvq keeps Q4_K and Q5_K on
MMVQ through seven columns and everything else through eight, tuned on an RTX
4090. On AD104 the measured Q6_K crossover sits at twelve and the Q8_0
crossover past twelve. The Q4_K and Q5_K pins stay correct
(../b789-clean-calibration/). Serving prefill runs at ubatch 512 and plain
decode at one column, so the seven-to-twelve window pays in speculative
verification batches and small parallel slots rather than in the served
headline rates.

## Q8_0 past twelve: sixteen is the new floor

mmvq16-experimental.patch raises MMVQ_KERNEL_MAX_NCOLS to 16 over the
applied series and instantiates ncols_dst 13 through 16 with the same
launch parameters, leaving Q4_K, Q5_K, and Q6_K dispatch untouched. Control
is the promoted threshold-12 binary; subject is configuration 88681bf4d161
at Q8_0 threshold 16. Both ran the 0.8B Q8_0 at ne11 12 through 16,
mirrored forward and reverse, three repetitions per point, served flags,
with a closing control at twelve (mmvq16-*.csv).

| ne11 | Q8_0 stock (MMQ from 13) | Q8_0 MMVQ-16 | advantage |
| ---: | ---: | ---: | ---: |
| 12 | 2268.4 | 2494.8 | tie by dispatch |
| 13 | 2288.8 | 2737.8 | +19.6% |
| 14 | 2510.7 | 2785.8 | +11.0% |
| 15 | 2761.8 | 2990.7 | +8.3% |
| 16 | 2756.8 | 3138.3 | +13.8% |

The closing control at twelve (2548.2) agrees with the opening forward run
(2510.4) inside 1.5%, licensing the paired reads; the control-pp12 reverse
run alone dipped 20% below its forward twin, a one-off excursion the paired
means at 13 through 16 do not depend on. Both binaries dispatch MMVQ at
twelve, and the 12-row difference sits inside that excursion. MMVQ clears
the 5.1% floor at every extended point, so sixteen is the largest tested
threshold under the promotion rule and the true crossover remains above the
instantiated range.

## Production candidate

`patches/llama-cuda-mmvq-crossover-ad104.patch` carries the production
shape: kernel ceiling sixteen, per-type defaults still eight, serving
thresholds Q6_K ten and Q8_0 sixteen selected at build time.
MMVQ_MAX_BATCH_SIZE stays 8, so every other architecture and the mul_mat_id
static assert keep stock behavior; a kernel-side MMVQ_KERNEL_MAX_NCOLS of 12
carries the instantiations; and the Ada dispatch reads two cache settings,
GGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE and
GGML_CUDA_ADA_MMVQ_Q8_0_MAX_BATCH_SIZE, both defaulting to the upstream
eight, so a control and a subject differ by one named threshold and a
static_assert bounds each by the kernel ceiling. The measured production
values are ten for Q6_K and twelve for Q8_0. The verification build at those
values runs Q6_K on MMVQ at nine (72.2 per token), on MMQ at eleven (64.6,
the stock rate), and Q8_0 on MMVQ at twelve (206.7), so each knob reaches its
own type alone. `QWEN_LLAMA_CANDIDATE_PATCHES=1
scripts/verify-llama-patch-series.sh` accepts the series with the candidate
applied third.
