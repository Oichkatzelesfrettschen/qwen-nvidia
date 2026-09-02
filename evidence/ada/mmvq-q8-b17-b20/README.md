# Q8_0 MMVQ at seventeen through twenty columns on AD104

Two closures differ in one patch and one threshold. The promoted closure
`88681bf4d161` dispatches Q8_0 to MMVQ through sixteen columns and to MMQ
above, at the kernel ceiling `MMVQ_KERNEL_MAX_NCOLS` of sixteen; the subject
closure `8680bc95e989` carries the twenty-column diagnostic form of
`patches/llama-cuda-mmvq-ncols-19.patch`, which raises that ceiling with
cases 17 onward in the launch switch, `calc_nwarps`, and
`calc_rows_per_block`, and it is built with the Q8_0 threshold at twenty and
the Q6_K threshold unchanged at ten (`evidence/ada/mmvq-ncols-19-design.md`).
Every other lever of the promoted configuration is shared. The shipped patch
ends the instantiated range at nineteen, the width this campaign selects, and
the twenty-column closure is retained here as the rejected boundary arm.
`scripts/ad104-q8-b17-b20-matrix.tsv` states the
eight arms, control and subject alternating at each width, and
`scripts/run-ad104-b789-calibration.sh` ran them through the served flags on
CUDA0 mirrored forward and reverse with the opening arm repeated last.

## The kernel exists without spilling

`kernel-resources.tsv` reads `cuobjdump --dump-resource-usage` on both
closures' `libggml-cuda.so`. The unfused Q8_0 `mul_mat_vec_q` instantiation
takes 136 registers at sixteen columns and 146, 148, 152, and 153 at
seventeen through twenty, with local memory at zero on every one, so the
wider accumulator array is held in registers and the register-pressure
falsifier the design note registered does not fire. Shared memory grows with
the column count from 4096 to 5120 bytes.

## The paired matrix

`repeats-3/` is the first run at three repetitions per arm and `repeats-10/`
the second at ten; `paired-means.tsv` carries every arm's forward and reverse
prefill rate and their paired mean, and `width-verdicts.tsv` reads each width
against the run's own drift floor, the span between the opening control and
its closing repeat.

| width | control tok/s | subject tok/s | gain | floor | clears |
| ---: | ---: | ---: | ---: | ---: | --- |
| 17 | 3241.3 | 3629.4 | 12.0% | 6.3% | yes |
| 18 | 3363.3 | 3706.9 | 10.2% | 6.3% | yes |
| 19 | 3583.8 | 3832.8 | 6.9% | 6.3% | yes |
| 20 | 3537.9 | 3893.4 | 10.0% | 6.3% | yes |

Those are the ten-repetition figures. The three-repetition run put the
subject ahead at every width as well, by 12.8% at seventeen and 1.4 to 3.9%
at the others, and its closing control fell 28% below the opening arm: the
clock log of that closing arm reads 136 W at 47% utilization before the arm's
own work began against 58 W at the opening, so another desktop client was
active through it, and a floor that wide licenses no reading. Ten repetitions
narrowed the floor to 6.3% with the same desktop clients resident on every
read (`resident-compute-clients.txt`), which is the workstation's daily state
rather than a condition the campaign excludes. Decode at one column is the
within-arm control and stays between 288 and 297 tok/s on every arm of the
ten-repetition run. The harness halts on a new kernel-ring signature and
both runs completed, so the ring delta is zero.

The nineteen-column gain of 6.9% sits 0.6 points over the floor and is the
one reading inside the floor's own uncertainty; seventeen, eighteen, and
twenty clear it by four to six points.

## The executed kernel

`path-audit/` is `scripts/run-ad104-path-audit.sh` over the bracketing arms,
one short profiled prefill each under the sanitized environment, with the
launches read out of the Nsight Systems capture and the capture itself left
outside the tree. The control at seventeen and at twenty launches
`mul_mat_q<Q8_0, 24>` and `mul_mat_q<Q8_0, 32>` for the prefill and
`mul_mat_vec_q<Q8_0, 1>` for the decode token; the subject launches
`mul_mat_vec_q<Q8_0, 17>` and `mul_mat_vec_q<Q8_0, 20>` for the prefill, 186
launches each, which is every trunk weight of the 0.8B once. All four arms
agree with the matrix expectation. `boundary-audit/` repeats the read on the
shipped nineteen-column closure `73af02b39194`: it launches
`mul_mat_vec_q<Q8_0, 19>` at nineteen and `mul_mat_q` at twenty where the
control launches `mul_mat_q` at both, so that closure dispatches exactly at
the selected threshold and MMQ takes over at the first width past the
instantiated range. `boundary-audit-137b2a23a42c/` is the same read on the
twenty-column diagnostic tree built at the same thresholds, the closure the
served tails ran against, with the same four verdicts.

## The shipped closure

`73af02b39194` is the closure the pull request names: the pinned commit
with the series, the crossover patch, and `llama-cuda-mmvq-ncols-19.patch`,
built `89-real` with Q6_K at ten and Q8_0 at nineteen and every other lever
at the production value. `kernel-resources.tsv` reads its Q8_0
instantiations from `cuobjdump -res-usage`: nineteen columns hold 152
registers with zero local memory and 4864 bytes of shared memory, the same
figures the twenty-column diagnostic tree produced for that width, and the
library carries no twenty-column instantiation of any type.
`sass-identity-q8_0-1-16.tsv` compares the SASS of `mul_mat_vec_q<Q8_0, N>`
for N of one through sixteen between the production closure `88681bf4d161`
and this one with the instruction addresses stripped: 10288 instruction
lines on each side and every function identical, so the wider ceiling
changes no kernel a production request already runs. Q6_K stays at ten and
the Q4_K, Q5_K, and Q2_K crossovers are untouched, since the patch adds
cases and moves one constant and the thresholds enter through the build
alone.

## Served request tails

`request-tails/qwen35-08b/` and `request-tails/qwen38-2b-distill/` are
`scripts/run-mmvq-width-request-tails.sh` on the nineteen-threshold
closure `137b2a23a42c`, the twenty-column diagnostic tree built with Q8_0 at
nineteen, against the production closure `88681bf4d161`: both
llama-servers resident on CUDA0 at the row's served tuple, the SM clock
pinned at 2835 MHz, and at each of 512+B, 1024+B, and 2048+B for B of
nineteen and twenty ten alternating pairs of one fixed-seed greedy completion
of 32 tokens, control first on odd pairs and subject first on even ones,
with one uncounted warm-up per length per server. A prompt of 512+B tokens
fills one ubatch and leaves a tail of B columns, which is where the threshold
acts inside a request. `observations.tsv` carries every request with its
prompt count, prompt and decode milliseconds, and the SHA-256 of its reply
tokens; `tails-summary.tsv` the paired ratios per length;
`server-digests.tsv` the two binaries; and the load logs the CUDA0 model,
KV, and compute buffers each server placed, read at `-lv 10` because the
buffer banner is an INFO line the default verbosity hides.
`design-iterations/` retains the block-order runs that shaped this design,
where the subject read slower even on the 2B, which carries no Q8_0 weight,
so those runs measured block order rather than the kernel.

| model | length | prefill ratio median | geometric mean | IQR | min | max | decode ratio | control drift |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.8B | 512+19 | 0.980 | 0.998 | 0.058 | 0.956 | 1.078 | 1.004 | 0.013 |
| 0.8B | 512+20 | 1.037 | 1.043 | 0.060 | 1.002 | 1.084 | 1.004 | 0.019 |
| 0.8B | 1024+19 | 1.014 | 1.016 | 0.071 | 0.975 | 1.068 | 0.988 | 0.008 |
| 0.8B | 1024+20 | 0.991 | 0.992 | 0.033 | 0.962 | 1.042 | 0.996 | 0.028 |
| 0.8B | 2048+19 | 1.012 | 1.010 | 0.046 | 0.969 | 1.048 | 0.998 | 0.023 |
| 0.8B | 2048+20 | 1.005 | 1.005 | 0.027 | 0.973 | 1.032 | 0.995 | 0.014 |
| 2B | 512+19 | 0.998 | 0.973 | 0.090 | 0.809 | 1.051 | 0.959 | 0.079 |
| 2B | 512+20 | 0.975 | 0.981 | 0.092 | 0.920 | 1.122 | 0.982 | 0.116 |
| 2B | 1024+19 | 1.007 | 0.989 | 0.070 | 0.887 | 1.042 | 1.013 | 0.092 |
| 2B | 1024+20 | 0.999 | 1.011 | 0.043 | 0.982 | 1.070 | 0.988 | 0.136 |
| 2B | 2048+19 | 0.994 | 1.009 | 0.065 | 0.906 | 1.152 | 1.010 | 0.064 |
| 2B | 2048+20 | 0.999 | 0.985 | 0.090 | 0.909 | 1.047 | 0.974 | 0.023 |

The reply tokens agree between the closures in all 120 pairs on each model,
so the wider kernel preserves exact output at every served length. The
paired prefill ratio sits at unity on both models: medians between 0.980
and 1.037 on the 0.8B with the control's own drift inside 2.8%, and between
0.975 and 1.007 on the 2B, which carries no Q8_0 weight and therefore runs
the same kernels on both closures, with the control drifting to 13.6% under
the desktop. Decode ratios hold unity on every row, and neither server log
carries a graph fallback, recapture, or CPU placement line. No length
clears the 5.1% floor and the arithmetic says none can: a tail of nineteen
columns is one MMVQ pass, about one weight stream and therefore about the
3.2 ms of a decode token, against a 531-token prompt the control answers in
29.7 ms, so the 8.8% the paired campaign measured at nineteen moves the
request by about 1%, under the floor and under the 3 to 7% interquartile
range the pairs carry. Read the tails as the no-regression control they
are: the wider kernel changes no token, slows no length beyond pair scatter,
and moves decode by nothing, and the 2B rows show the harness reading unity
where the two closures execute identical kernels.

## Classification

`campaign-status.tsv` states what each run is evidence of. The
three-repetition run is non-promotable: its closing control fell 28% below
its opening control while the pre-arm power rose from 58 W to 136 W, which is
a change of state between the arms rather than scatter inside them. It
establishes that seventeen through twenty compile and execute, that the
twenty-column kernel holds 153 registers with zero local memory, and that
the harness needs a quiescence gate above the ownership lock; the register
count closes the spill falsifier alone and says nothing about resident
warps or latency at the wider count.

The ten-repetition run is repeatability evidence and not promotion evidence.
Ten repetitions shrank the within-arm scatter and every gate but one holds:
the same three desktop clients on every read, decode agreeing across builds,
exact tokens, a zero ring delta, and a clear latch. Its opening-to-closing
span of 6.3% exceeds the preregistered 5.1% floor of
`evidence/ada/b789-clean-calibration/`, and a floor set after the result is
no floor, so no width is admitted from it. Under the contiguous rule a
threshold of twenty needs seventeen, eighteen, nineteen, and twenty all to
clear the floor inside one controlled campaign; the point estimates here are
all positive and that is not the same thing.

## The alternating paired campaign

`paired-pinned/` is `scripts/run-mmvq-paired-crossover.sh`: for each width
ten pairs of single observations, control then subject on odd pairs and
subject then control on even ones, every observation one llama-bench process
whose first timed run is uncounted and whose second is the reading, admitted
by `scripts/gpu-quiescence-gate.sh` against a baseline of the exact client
set, power, temperature, clocks, and the four utilization counters, with the
SM clock pinned at 2835 MHz for the whole campaign and released at its end.
Three control observations open the campaign and three close it.
`design-iterations/` retains the two runs that shaped the design: one timed
run per process reads llama-bench's cold first run, 543 tok/s on an idle
card and 900 to 1350 pinned against 3100 to 3500 for every run after it,
and a baseline registered at 45 C before any load refused the card's 51 C
operating state after the settling window. The baseline is therefore
registered after the opening controls, in the state the campaign holds.

`paired-summary.tsv` reads the pairs. 86 observations, zero refusals, the
same three desktop clients on every read, and an opening-to-closing control
span of 2.3% against the preregistered 5.1% floor.

| width | pairs | ratio median | geometric mean | MAD | IQR | min | max | decode ratio | admitted |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 17 | 10 | 1.136 | 1.148 | 0.066 | 0.146 | 1.023 | 1.263 | 0.974 | yes |
| 18 | 10 | 1.137 | 1.136 | 0.036 | 0.081 | 1.057 | 1.223 | 1.032 | yes |
| 19 | 10 | 1.088 | 1.080 | 0.032 | 0.072 | 0.966 | 1.167 | 0.994 | yes |
| 20 | 10 | 1.053 | 1.022 | 0.034 | 0.132 | 0.860 | 1.119 | 1.018 | no |

A width is admitted where the median and the geometric mean of its paired
ratios both clear the floor and the lower quartile sits above unity, and a
threshold where every width below it is admitted in the same campaign; the
rule is in the runner and predates the run. Seventeen, eighteen, and
nineteen are admitted; twenty is not, its median 0.2 points over the floor,
its geometric mean under it, and its worst pair at 0.86. The decode ratio
sits at unity on every width, the within-pair control. The selected
threshold is nineteen.

## Verdict

`Q8_0 = 19` is the threshold this campaign selects: the greatest width with
every width below it admitted, `mul_mat_vec_q<Q8_0, 19>` observed on the
shipped closure `73af02b39194` with MMQ at twenty, registers held without a spill, and a
zero kernel-ring delta on every run. The nineteen-threshold diagnostic closure passes the served
tail controls on the 0.8B and on the 2B production control as a
no-regression control with exact tokens and unchanged decode; the
request-level prefill gain the promotion design asked for is bounded by the
tail's share of the request to about 1% and is unreadable against a 5.1%
floor, so the gain rests on the pinned paired campaign alone. Production
stays at sixteen: promotion is a fresh `89-real` closure from merged main at Q6_K ten and
Q8_0 nineteen through `promote-llama-build.sh` and
`admit-cuda-router-serving.sh`, and it has not run. MMVQ loses its margin at twenty here, so the search ends at
nineteen rather than extending to twenty-four.

## Protocol amendment

The promotion design preregistered a request-level gate in these words:
"a request-level prefill improvement, unchanged decode, exact tokens, no
recapture anomaly, strict CUDA0, clean teardown, zero hazard" on the served
tails at 512, 1024, and 2048 plus B and plus B+1, judged against the 5.1%
floor. The preregistered request-level gain criterion was not met and is
retired for this threshold decision because the changed pass contributes
less than that floor to total request time. At 512+19 the candidate changes
one residual nineteen-column pass and leaves the 512-column ubatch,
tokenization, graph preparation, attention, every non-Q8_0 tensor, the
server's own work, decode, and every other microbatch as they were, so an
8.8% gain on that pass is about 1% of the request and a 5.1% whole-request
floor asked for several times the saving available. The floor stays at 5.1%
and is not lowered to fit the result; the retained request-level experiment
is interpreted only as a bounded no-regression and integration control, and
the promotion case rests on the pinned alternating kernel-level campaign.

The claims separate as follows.

```text
Measured:
    B17, B18, B19 kernel-path improvement over MMQ, contiguous, pinned clock

Observed:
    exact token identity across 120 alternating pairs per model
    no request-level prefill or decode regression beyond pair scatter
    no graph fallback, recapture, or CPU placement line
    MMVQ at nineteen and MMQ at twenty on the exact closure

Not established:
    user-visible whole-request latency improvement
```

## Falsifiers

A width where the paired ratio's spread crosses one ends the search at the
previous width, and a threshold is admitted only where every width below it
is admitted in the same campaign. A reply-token digest that
differs between the closures at any length refuses the kernel regardless of
rate. A `cuobjdump` read showing local memory above zero at a wider
instantiation is the spill the design note names, and a served request whose
prompt time rises under the subject beyond the pair scatter at any tail
length refutes the no-regression reading.
