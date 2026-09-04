# Concurrency is the amortization lever, and it beats every launch lever measured here

Eleven concurrent sequences buy 3.89 times the aggregate decode throughput of
one on the 2B and 3.88 times on the 0.8B. Every per-launch lever this tree
refuted was bounded between 1.2% and 4.6% of a batch-1 token, and each of those
bounds shrinks by a further 2.83 times in this regime, because the cost each
lever removes is paid once per iteration and an iteration at eleven slots
carries eleven tokens.

Both sweeps ran on the promoted closure `88681bf4d161` with the SM clock pinned
at 2835 MHz, four measured bursts per level after an uncounted warm-up, per-slot
depth fixed at 4096, and every request carrying one prompt, `n_predict` 128, and
`ignore_eos`. Burst-to-burst spread is 0.08% to 1.97% of the median.

## The rates

| level | 2B aggregate | 2B per-request | 0.8B aggregate | 0.8B per-request |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 230.79 | 246.50 | 310.19 | 330.09 |
| 2 | 394.51 | 217.66 | 518.01 | 282.42 |
| 4 | 629.76 | 182.70 | 806.74 | 228.67 |
| 7 | 781.21 | 126.58 | 1056.21 | 168.57 |
| 8 | 805.70 | 118.05 | 1099.56 | 163.74 |
| 10 | 857.70 | 104.58 | 1179.53 | 140.05 |
| 11 | 897.76 | 98.42 | 1202.69 | 129.65 |

The served single-sequence arm is the control rather than any llama-bench
figure, and it lands beside one: the 2B reads 230.79 aggregate against the
registry's 231.37, taken under a harness with no host sampler at all.

The trade is two numbers rather than one. At eleven slots the appliance delivers
3.89 times the tokens and one client waits 2.5 times as long: the per-request
rate falls to 0.399 of the single-sequence rate on the 2B and 0.393 on the 0.8B.
Those two shares agree to four parts in a thousand across checkpoints differing
in size, quantization, and mat-mul family, which makes the latency cost a
property of the batching rather than of the model. Whether the trade is worth
taking is a policy question about whether requests arrive together, and it is
not answered by any quantity measured here.

`2b-dispatch-01/` carries a second single-sequence arm at 230.62 against
`2b-run-01/`'s 230.79, taken through a separate server launch to reach the
capture phase. The two are one measurement repeated to 0.07% rather than two
observations to average.

## Dispatch crosses where the closure says it does

`update_slots` builds one batch across every slot holding a token to decode, so
N decoding slots make one ubatch of N columns and `ne11` equals the slot count.
The Nsight symbol names that count directly, and the four captured levels read:

| level | Q4_K | Q6_K |
| ---: | --- | --- |
| 7 | `mul_mat_vec_q<Q4_K,7>`, 6624 launches | `mul_mat_vec_q<Q6_K,7>`, 1150 |
| 8 | `mul_mat_q<Q4_K>`, 4968 | `mul_mat_vec_q<Q6_K,8>`, 1150 |
| 10 | `mul_mat_q<Q4_K>`, 4968 | `mul_mat_vec_q<Q6_K,10>`, 1149 |
| 11 | `mul_mat_q<Q4_K>`, 4968 | `mul_mat_q<Q6_K>`, 1125 |

Q4_K leaves MMVQ above seven at the upstream constant and Q6_K above ten through
`GGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE`, which the promoted closure sets to 10.
Levels 8 and 10 are the mixed pass, Q4_K on MMQ beside Q6_K on MMVQ. The 1150,
1149, and 1125 counts are one weight -- `attn_qkv`, the Q6_K tensor of this
checkpoint -- changing family between 10 and 11 while everything else holds.

## The crossover is visible in the rate, and the control separates it

Marginal aggregate throughput per added slot:

| step | 2B | 0.8B |
| --- | ---: | ---: |
| 1 to 2 | 163.7 | 207.8 |
| 2 to 4 | 117.6 | 144.4 |
| 4 to 7 | 50.5 | 83.2 |
| 7 to 8 | 24.5 | 43.3 |
| 8 to 10 | 26.0 | 40.0 |
| **10 to 11** | **40.1** | **23.2** |

The two columns are not calibrated against each other. The checkpoints differ in
weight count, layer count, quantization, and which family each mat-mul dispatches
to at every level rather than only at the crossing step, so these are two
saturation trajectories rather than one trajectory with and without a crossing.

The 0.8B falls monotonically across the whole sweep. It is Q8_0 at a threshold
of 16, so it crosses nowhere here, and its curve is what saturation alone looks
like on this device. The 2B does not fall monotonically: its marginal gain rises
at 8 to 10 and then nearly doubles at 10 to 11, which is the step where Q6_K
changes family. Against per-level medians whose observed spans are 1.6 and 2.2
tok/s, a 14 tok/s per-slot divergence from the control's direction is roughly
twenty times the spread.

This is the same-shape control the evidence discipline asks for. A kink both
checkpoints showed at one level would belong to the roofline or the host; a kink
the crossing checkpoint shows and the non-crossing one does not is dispatch.

**The threshold was selected in a different regime.**
`../mmvq-crossover-ad104/` measured Q6_K at ne11 seven through twelve with
llama-bench `-p N`, which issues one mat-mul of N columns in isolation, and read
MMVQ ahead through ten. The regime that actually produces `ne11 > 1` on the
appliance is N decoding sequences, where the same column count arrives with N
separate KV caches and a flash-attention pass over N sequences beside it. The
rate here is consistent with MMQ being the better family for Q6_K earlier than
ten in that regime. It rests on one model's derivative at one crossing point
against an uncalibrated second model, which is a candidate rather than a verdict.
A simpler reading is not excluded either: 1149 MMVQ launches become 1125 MMQ
launches, so the step removes launches as well as changing family. The arm that
settles it is one build at a lower Q6_K threshold measured against the production
closure on this harness, which compares one model with itself.

## What this does to the three refuted levers

An iteration at N slots costs more than an iteration at one and produces N
tokens. Measured:

| level | 2B iteration | growth | 0.8B iteration | growth |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 4332.9 us | 1.000 | 3223.8 us | 1.000 |
| 4 | 6351.6 us | 1.466 | 4958.2 us | 1.538 |
| 8 | 9929.3 us | 2.292 | 7275.6 us | 2.257 |
| 11 | 12252.7 us | 2.828 | 9146.2 us | 2.837 |

The two growth columns agree within 2% at every level across checkpoints
differing in size, quantization, and dispatched family, so the iteration grows
with the slot count in a way that belongs to the batching rather than the model.

A lever that removes a fixed cost paid once per iteration therefore has its
share of the work divided by that growth. At eleven slots:

| lever | batch-1 ceiling | eleven-slot ceiling |
| --- | ---: | ---: |
| projection fan-out merge, 2B | 3.08% | 1.09% |
| projection fan-out merge, 0.8B | 4.63% | 1.63% |
| bounded graph loop, 2B | 3.26% | 1.15% |
| bounded graph loop, 0.8B | 4.57% | 1.61% |

`../projection-fan-out/` said its table recomputes in this regime and
`../graph-loop-bound/` said the same of the 140-microsecond round trip. Both
recompute downward, and the direction is the finding: concurrency is itself the
amortization every one of those levers was trying to buy, and it buys 289%
where they were bounded at single digits.

The recomputation assumes the per-iteration host cost does not grow with N, and
that assumption is unmeasured here. Its direction is robust to being wrong in
the ordinary way: a host cost that grew linearly in N would hold each share
constant rather than raising it, so a lever reopens only if the host round trip
grows faster than the iteration itself. The measured aggregate curve is
inconsistent with that, since a host cost exploding in N would flatten the
aggregate rate hard rather than the gentle flattening observed. Measuring the
served round trip per iteration directly is the arm that would replace this
argument with a number.

## Falsifiers, against the preregistered list

1. **Slots do not co-batch.** Refuted before the sweep by the pre-check and
   again by every captured level: the symbol names column counts 7, 8, 10, and
   11 matching the slot count exactly.
2. **Aggregate throughput does not scale.** Refuted. 3.89 and 3.88 times at
   eleven slots against a per-level spread under 2%.
3. **No dispatch effect is visible at request level.** Unresolved. The Q6_K
   crossing at 11 is where the 2B reverses the control's direction, which is
   suggestive and rests on two uncalibrated trajectories rather than on a paired
   comparison. Q4_K at 8 is not separable from saturation at all: the 2B's
   marginal gain falls from 50.5 to 24.5 there and the 0.8B's falls from 83.2 to
   43.3 over the same step, the same direction at a similar ratio. The dispatch
   *transition* is settled cold by the symbol table; its effect on the rate is
   what a paired closure A/B has to decide.
4. **The round trip per iteration is flat in N.** Not measured. The iteration
   duration is measured and the round trip inside it is not, so this arm reports
   the growth of the whole iteration and leaves its host term to a later
   capture.
5. **Concurrency costs per-request latency more than it buys aggregate.**
   Both terms are measured and neither dominates by construction: aggregate rises
   3.89 times while the per-request rate falls to 0.399 of its single-sequence
   value. Which one the appliance should buy depends on whether requests arrive
   concurrently, so this falsifier resolves into a policy question rather than
   into a measurement.

## What this arm is not

Per-slot depth is fixed at 4096 and depth is an axis rather than a constant:
weight traffic is amortized across the ubatch and constant in N while KV traffic
is per-sequence and linear in it, so a deeper slot moves the balance toward KV
and a second depth is a separate arm. The requests are identical in prompt and
reply length, which holds batch composition for the window and is not what a
served mix looks like. No arm here combines concurrency with speculation, which
already accepts several tokens per host round trip and would amortize the same
iteration a second way.

`device-environment.tsv` in each run directory records the driver, CUDA runtime,
toolkit, and kernel these numbers are bound to. The desktop client set held
throughout, which is this host's standing covariate rather than a controlled
condition.
