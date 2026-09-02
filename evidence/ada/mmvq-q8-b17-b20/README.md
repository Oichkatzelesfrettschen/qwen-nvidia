# Q8_0 MMVQ at seventeen through twenty columns on AD104

## Disposition

This directory retains a rejected candidate. Four gates passed and the
numerical gate failed, so `patches/llama-cuda-mmvq-ncols-19.patch` is retained
as evidence rather than as a production patch, no build or launch in this tree
reaches a Q8_0 threshold above sixteen, and production serves Q8_0 at sixteen
on closure `88681bf4d161`.

```text
candidate=q8_0-mmvq-b19
rate_gate=passed
kernel_gate=passed
compilation_gate=passed
integration_gate=passed
numerical_gate=failed
promotion_status=rejected

decision:
    exact token identity retained for implementation-preserving
    micro-optimizations whose whole-request gain is below the
    measurement floor

0.01-nat proposal:
    refused as underived, retrospectively selected, and insufficiently
    specified

future bounded-numerics class:
    deferred to a separately preregistered design
```

The gate the candidate fails is exact greedy token identity between the two
closures. It is retained as written for an implementation-preserving
micro-optimization whose whole-request gain sits below the measurement floor:
a change that buys nothing a request can read has nothing to trade a changed
reply against. The 0.01-nat aggregate tolerance proposed after the divergence
is refused as underived, retrospectively selected, and insufficiently
specified. The arithmetic refuses the per-logit reading of it as well: a 0.01
per-logit bound admits at most 0.02 nats of pairwise movement between the top
two candidates, and two of the three measured witnesses, 0.024 and 0.096 nats,
already exceed that, with the third at 0.014 nats inside it. A bounded-numerics
admission class, which would state its bound, its estimator, its sample, and
its falsifier ahead of any run, is deferred to a separately preregistered
design and no part of it is decided here.

Two closures differ in one patch and one threshold. The promoted closure
`88681bf4d161` dispatches Q8_0 to MMVQ through sixteen columns and to MMQ
above, at the kernel ceiling `MMVQ_KERNEL_MAX_NCOLS` of sixteen; the subject
closure `8680bc95e989` carries the twenty-column diagnostic form of
`patches/llama-cuda-mmvq-ncols-19.patch`, which raises that ceiling with
cases 17 onward in the launch switch, `calc_nwarps`, and
`calc_rows_per_block`, and it is built with the Q8_0 threshold at twenty and
the Q6_K threshold unchanged at ten (`evidence/ada/mmvq-ncols-19-design.md`).
Every other lever of the promoted configuration is shared. The patch as retained ends the instantiated range at
nineteen, the width the rate campaign reached, and the twenty-column closure
is the boundary arm read beside it.
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
nineteen-column candidate closure `73af02b39194`: it launches
`mul_mat_vec_q<Q8_0, 19>` at nineteen and `mul_mat_q` at twenty where the
control launches `mul_mat_q` at both, so that closure dispatches exactly at
the candidate threshold and MMQ takes over at the first width past the
instantiated range. `boundary-audit-137b2a23a42c/` is the same read on the
twenty-column diagnostic tree built at the same thresholds, the closure the
served tails ran against, with the same four verdicts.

## The nineteen-column closure

`73af02b39194` is the closure the numerical gate is read against: the pinned
commit with the series, the crossover patch, and
`llama-cuda-mmvq-ncols-19.patch`, built `89-real` with Q6_K at ten and Q8_0 at nineteen and every other lever
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
`scripts/run-mmvq-width-request-tails.sh` on the nineteen-column
candidate closure `73af02b39194` against the production closure `88681bf4d161`: both
llama-servers resident on CUDA0 at the row's served tuple, the SM clock
pinned at 2835 MHz, and at each of 512+B, 1024+B, and 2048+B for B of
nineteen and twenty ten alternating pairs of one fixed-seed greedy completion
of 32 tokens, control first on odd pairs and subject first on even ones,
with one uncounted warm-up per length per server: 60 pairs and 120 measured
requests per model, 132 requests with the warm-ups. A prompt of 512+B tokens
fills one ubatch and leaves a tail of B columns, which is where the threshold
acts inside a request. The prompts are cut from the repository's own
`CLAUDE.md`, whose digest `passage-digest.tsv` records. `observations.tsv`
carries every request with its prompt count, prompt and decode milliseconds,
and the SHA-256 of its reply ids and of its reply text; `replies.jsonl` the
ids and text themselves; `tails-summary.tsv` the paired ratios per length
with the first position at which any reply differs from the control's;
`server-digests.tsv` the two binaries; and the load logs the CUDA0 model,
KV, and compute buffers each server placed, read at `-lv 10` because the
buffer banner is an INFO line the default verbosity hides.

The harness requests the ids under `return_tokens`. `server-task.h` defaults
that flag to false and `server-context.cpp` appends to `generated_tokens`
only under it, so a request leaving it unset receives an absent array; the
first retained run of this arm digested that absence, and every one of its
264 digests was the SHA-256 of `[]`. The harness now refuses a reply whose
id count differs from `predicted_n`, and
`scripts/test-mmvq-width-request-tails.sh` runs a copy with the flag removed
against a fixture that honors the contract and requires the refusal.

The second run read real ids over a passage that repeated one paragraph 200
times, and the six digests it produced on the 0.8B were the six the 2B
produced: a greedy continuation of a periodic prompt is a copy of the
prompt, which either model and either kernel reproduces, so that prompt
separates nothing. `periodic-passage-qwen35-08b-summary.tsv` and
`periodic-passage-qwen38-2b-distill-summary.tsv` retain those summaries as
the reason the prompt changed. `design-iterations/` retains the block-order
runs that shaped the paired design, where the subject read slower even on
the 2B, which carries no Q8_0 weight, so those runs measured block order
rather than the kernel; their `tokens_sha256` column is the empty-array
digest throughout, since they predate the `return_tokens` fix, and they
carry rate alone.

| model | length | prefill ratio median | geometric mean | IQR | min | max | decode ratio | control drift | ids identical | first differing position |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 0.8B | 512+19 | 1.054 | 1.032 | 0.160 | 0.913 | 1.235 | 1.013 | 0.053 | no | 31 |
| 0.8B | 512+20 | 0.981 | 0.986 | 0.070 | 0.903 | 1.083 | 1.009 | 0.040 | yes | - |
| 0.8B | 1024+19 | 1.021 | 1.005 | 0.053 | 0.932 | 1.038 | 1.003 | 0.042 | no | 21 |
| 0.8B | 1024+20 | 0.993 | 0.989 | 0.045 | 0.889 | 1.033 | 0.987 | 0.017 | yes | - |
| 0.8B | 2048+19 | 1.010 | 1.014 | 0.035 | 0.979 | 1.053 | 1.015 | 0.005 | no | 0 |
| 0.8B | 2048+20 | 0.996 | 0.991 | 0.030 | 0.936 | 1.029 | 0.971 | 0.007 | yes | - |
| 2B | 512+19 | 1.000 | 0.994 | 0.045 | 0.937 | 1.039 | 1.001 | 0.022 | yes | - |
| 2B | 512+20 | 1.009 | 1.005 | 0.051 | 0.939 | 1.059 | 1.018 | 0.006 | yes | - |
| 2B | 1024+19 | 1.009 | 1.001 | 0.040 | 0.950 | 1.038 | 0.998 | 0.006 | yes | - |
| 2B | 1024+20 | 1.005 | 1.007 | 0.043 | 0.977 | 1.040 | 1.023 | 0.039 | yes | - |
| 2B | 2048+19 | 1.007 | 1.008 | 0.022 | 0.991 | 1.041 | 1.013 | 0.019 | yes | - |
| 2B | 2048+20 | 1.020 | 1.017 | 0.020 | 0.992 | 1.038 | 1.020 | 0.010 | yes | - |

The reply ids differ between the closures at every nineteen-column tail on
the 0.8B and agree at every twenty-column tail, and they agree at every
length on the 2B. Each arm is deterministic on its own: the eleven replies a
server gives at one length carry one digest, so the split at nineteen is two
digests, one per closure. The nineteen-column tail is the one cell where the
two closures run different kernels, `mul_mat_q` on the control and
`mul_mat_vec_q<Q8_0, 19>` on the subject; at twenty both run MMQ, and the 2B
carries no Q8_0 weight, so both closures run identical kernels on it at
every width. `qwen35-08b-logit-margins/` is
`scripts/probe-mmvq-tail-logit-margin.sh` at the three first-differing
positions and at the identical 2048+20 control: the control's top two
candidates sit 0.014, 0.024, and 0.096 nats apart at the three divergent
positions, the subject chooses the control's second candidate at each with
the control's first no lower than third, and at 2048+20 the two closures
return four equal log-probabilities to four decimals with a 0.330-nat margin.
The two kernels sum the same products in different orders and different
widths, and the difference moves an argmax only where the model itself is
near a tie. Both continuations read as fluent prose from the same document.

The paired prefill ratio sits at unity on both models: medians between 0.981
and 1.054 on the 0.8B with the control's own drift inside 5.3%, and between
1.000 and 1.020 on the 2B. Decode ratios hold within 3% of unity on every
row, and neither server log carries a graph fallback, recapture, or CPU
placement line. No length clears the 5.1% floor and the arithmetic says none
can: a tail of nineteen columns is one MMVQ pass, about one weight stream
and therefore about the 3.2 ms of a decode token, against a 531-token prompt
the control answers in about 30 ms, so the 8.8% the paired campaign measured
at nineteen moves the request by about 1%, under the floor and under the 2
to 16% interquartile range the pairs carry. Read the tails as the
integration control they are for rate, and as the refusal they are for
identity: the wider kernel slows no length beyond pair scatter and moves
decode by nothing, and it changes the greedy reply at the width it takes
over.

## Classification

`campaign-status.tsv` states what each run is evidence of, under a
`crossover_rate_evidence` column: a run valid there answers the rate gate
alone, and the candidate is rejected on the numerical gate no run there
addresses. The
three-repetition run is non-promotable: its closing control fell 28% below
its opening control while the pre-arm power rose from 58 W to 136 W, which is
a change of state between the arms rather than scatter inside them. It
establishes that seventeen through twenty compile and execute, that the
twenty-column kernel holds 153 registers with zero local memory, and that
the harness needs a quiescence gate above the ownership lock; the register
count closes the spill falsifier alone and says nothing about resident
warps or latency at the wider count.

The ten-repetition run is repeatability evidence and answers no gate.
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
rule is in the runner and predates the run. `width_admitted` and
`threshold_admitted` in `paired-summary.tsv`, and `clears_floor` in
`width-verdicts.tsv`, report that rate rule alone: the runner sees no token
identity, and the candidate is rejected on the gate that does. Seventeen, eighteen, and
nineteen are admitted; twenty is not, its median 0.2 points over the floor,
its geometric mean under it, and its worst pair at 0.86. The decode ratio
sits at unity on every width, the within-pair control. Nineteen is the width
the rate campaign reaches, and the numerical gate below refuses it.

## Verdict

`Q8_0 = 19` is rejected. Four gates pass and the fifth refuses it.

The rate gate passes: nineteen is the greatest width with every width below
it admitted in the pinned alternating campaign, at a paired ratio median of
1.088. The kernel gate passes: `mul_mat_vec_q<Q8_0, 19>` is read out of the
Nsight capture on closure `73af02b39194` with `mul_mat_q` at twenty. The
compilation gate passes: the instantiation holds 152 registers with zero
local memory and the SASS of Q8_0 one through sixteen is identical to
production. The integration gate passes: 60 alternating pairs and 120
measured requests per model put prefill and decode at unity with no graph
fallback, recapture, or CPU placement line, and the kernel-ring delta is zero
on every run.

The numerical gate fails. The promotion design requires exact token identity
between the closures across every pair on both models, and the 0.8B reply
differs at every nineteen-column tail, at position 31, 21, and 0, where the
subject's MMVQ pass replaces the control's MMQ pass and the model's top two
candidates sit under 0.1 nats apart. The gate stands as preregistered and is
not relaxed after the result, so the threshold is rejected. Production stays
at sixteen on `88681bf4d161`, the promotion sequence of a fresh `89-real`
closure through `promote-llama-build.sh` and `admit-cuda-router-serving.sh`
has not run and does not run under this record, and
`patches/llama-cuda-mmvq-ncols-19.patch` is retained as the diff a rejected
candidate was measured on.

What the result states is narrower than a defect: the two kernels reach
different roundings of the same products, and the served path already crosses
that boundary at sixteen, so a greedy reply whose tail lands on either side
of any MMVQ/MMQ threshold already depends on which kernel ran. Separating
rounding-order divergence at a near tie from a value error needs a bounded
numerics class stating its bound, its estimator, its sample, and its
falsifier before any run, and that design is deferred rather than settled
here. The 0.01-nat aggregate tolerance proposed after this divergence is
refused as underived, retrospectively selected, and insufficiently specified,
and its per-logit reading is refused by arithmetic: 0.01 per logit admits
0.02 nats of pairwise movement, which the 0.024 and 0.096 nat witnesses
already exceed.

MMVQ loses its margin at twenty here, so the rate campaign found nothing
above nineteen to carry into such a design.

## The request-level gate

The promotion design preregistered a request-level gate in these words:
"a request-level prefill improvement, unchanged decode, exact tokens, no
recapture anomaly, strict CUDA0, clean teardown, zero hazard" on the served
tails at 512, 1024, and 2048 plus B and plus B+1, judged against the 5.1%
floor. The request-level prefill improvement is absent, and the arithmetic
says it has to be. At 512+19 the candidate changes one residual
nineteen-column pass and leaves the 512-column ubatch, tokenization, graph
preparation, attention, every non-Q8_0 tensor, the server's own work, decode,
and every other microbatch as they were, so an 8.8% gain on that pass is
about 1% of the request against a 5.1% floor that asked for several times the
saving available. The floor stays at 5.1% and is not lowered to fit the
result. That is why the identity clause decides the candidate: a change whose
whole-request gain sits under the measurement floor offers nothing to trade a
changed reply against.

The "exact tokens" clause of the same gate is retained as written and is
the clause the corrected run fails. The first retained tail run reported it
passed while digesting an absent array, and the second reported it passed
over a periodic prompt that either kernel copies; the run that reads real
ids over prose reports the divergence above.

The claims separate as follows.

```text
Measured:
    B17, B18, B19 kernel-path improvement over MMQ, contiguous, pinned clock
    reply ids differ between the closures at every 19-column tail on the
        0.8B Q8_0 row, first at position 31, 21, and 0; identical at every
        20-column tail and at every length on the 2B control
    top-two logit margin at the three divergent positions 0.014, 0.024,
        and 0.096 nats on the control; four equal log-probabilities at the
        identical 2048+20 control

Observed:
    no request-level prefill or decode regression beyond pair scatter,
        60 alternating pairs and 120 measured requests per model
    no graph fallback, recapture, or CPU placement line
    MMVQ at nineteen and MMQ at twenty on the exact closure

Not established:
    user-visible whole-request latency improvement
    exact token identity between the closures, the preregistered
        numerical gate, which the 0.8B fails at every 19-column tail
```

## Falsifiers

A width where the paired ratio's spread crosses one ends the search at the
previous width, and a threshold is admitted only where every width below it
is admitted in the same campaign. A reply-id digest that differs between the
closures at any length refuses the kernel regardless of rate, and that
falsifier fired at every nineteen-column tail on the 0.8B. A `cuobjdump`
read showing local memory above zero at a wider instantiation is the spill
the design note names, and a served request whose prompt time rises under
the subject beyond the pair scatter at any tail length refutes the
no-regression reading. A digest column whose every value is the SHA-256 of
`[]`, or a set of digests one model shares with another, is a harness
reading its own default rather than the reply.
