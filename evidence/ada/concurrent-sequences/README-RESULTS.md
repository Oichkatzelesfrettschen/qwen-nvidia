# Concurrency amortizes the iteration, and the retained logs state by how much

**Status: provisional.** The rates in `rates.tsv` are delivered throughput, the
per-slot depth is an allocation the prompt filled to about 596 tokens, and the
bursts above four slots did not enter decode together. Each of those was found
in review after the run and each is corrected below from what the run retained
rather than by a rerun; `../../../scripts/run-concurrent-sequence-sweep.sh` now
measures all three directly, and the publication-grade sweep is the one it has
not yet run.

Both sweeps ran on the promoted closure `88681bf4d161` with the SM clock lock
requested at 2835 MHz and read once at lock time, four measured bursts per level
after an uncounted warm-up, per-slot allocation 4096, and every request carrying
one 468-token prompt, `n_predict` 128, and `ignore_eos`.

## What the delivered rate is

`rates.tsv` divides every generated token of a burst by the wall time from the
first request leaving the client to the last reply arriving. That window holds
the prefill of every prompt, the process start of N `curl` clients, and the
HTTP round trips, while the numerator counts generated tokens alone, so the
figure is what a client population received per second and is not a decode
rate. The `per_request` column divides one reply by the server's own
`predicted_ms`, which is a generation rate and not the time a client waited,
since `prompt_ms` is outside it.

| level | 2B delivered | 2B generation | 0.8B delivered | 0.8B generation |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 230.79 | 246.50 | 310.19 | 330.09 |
| 2 | 394.51 | 217.66 | 518.01 | 282.42 |
| 4 | 629.76 | 182.70 | 806.74 | 228.67 |
| 7 | 781.21 | 126.58 | 1056.21 | 168.57 |
| 8 | 805.70 | 118.05 | 1099.56 | 163.74 |
| 10 | 857.70 | 104.58 | 1179.53 | 140.05 |
| 11 | 897.76 | 98.42 | 1202.69 | 129.65 |

Delivered throughput rises 3.89 times on the 2B and 3.88 on the 0.8B at eleven
slots, and the generation rate one request sees falls to 0.399 and 0.393 of its
single-sequence value. Those are two measured quantities and their ratio is not
a third one.

## The decode rate, read from the server's own log

Every server here ran at `-lv 10`, which logs one `decode:` line per
`llama_decode` call and one `slot decode token` line per slot per pass, so the
log states the composition of every pass: how many slots decoded in it and how
many prompts it carried. `../../../scripts/read-server-decode-iterations.py`
reads that back, and `full-width-decode.tsv` is its reading of the fourteen
retained logs. A full-width pass is one in which every slot of the burst
decoded; its count and span give the iteration cost at exactly N columns, free
of prefill, of client start-up, and of any pass a member sat out.

| level | 2B iteration | 2B decode tok/s | 0.8B iteration | 0.8B decode tok/s | synchronized bursts |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4.088 ms | 244.51 | 3.052 ms | 327.33 | 4 of 4 |
| 2 | 4.629 ms | 431.85 | 3.568 ms | 560.41 | 4 of 4 |
| 4 | 5.514 ms | 725.18 | 4.402 ms | 907.72 | 4 of 4 |
| 7 | 7.384 ms | 948.02 | 5.593 ms | 1251.20 | 0 of 4 |
| 8 | 8.139 ms | 981.53 | 6.030 ms | 1325.71 | 0 of 4 |
| 10 | 9.308 ms | 1074.22 | 6.897 ms | 1448.28 | 0 of 4 |
| 11 | 9.730 ms | 1130.08 | 7.405 ms | 1483.07 | 0 of 4 |

The single-sequence iteration of 4.088 ms is 244.5 tok/s against the registry's
231.37 from llama-bench, and the difference is the host sampler and HTTP that
the delivered figure carries and the full-width span leaves out. At eleven
slots the iteration costs 2.380 times the single-sequence iteration on the 2B
and 2.426 on the 0.8B, against the 2.83 the delivered window reported, and the
full-width decode rate reads 4.62 and 4.53 times the single-sequence rate.

The growth columns agree within 2% at eight and eleven slots and differ by 6.9%
at four (1.349 against 1.442), so the earlier statement that they agree at
every level was wrong and is withdrawn; the growth is close across the two
checkpoints rather than shared.

A burst is synchronized where every prompt entered one prefill pass and every
decode pass held the whole burst. That holds at one, two, and four slots and at
none of the levels above: `n_batch` is 2048 and five prompts of 468 tokens
exceed it, so four prompts entered the first pass and decoded at width four
while the remainder prefilled, which is the mixed-width history the review read
out of the Nsight symbols. The iteration cost above is unaffected, because 125
to 126 of each burst's 127 decode passes are full-width, but the first tokens of
those bursts were produced at widths the level did not name.

## What this does to the three refuted levers

A lever that removes a fixed cost paid once per iteration has its share of the
work divided by the iteration growth. On the full-width figures at eleven slots:

| lever | batch-1 ceiling | eleven-slot ceiling |
| --- | ---: | ---: |
| projection fan-out merge, 2B | 3.08% | 1.29% |
| projection fan-out merge, 0.8B | 4.63% | 1.91% |
| bounded graph loop, 2B | 3.26% | 1.37% |
| bounded graph loop, 0.8B | 4.57% | 1.88% |

`../projection-fan-out/` said its table recomputes in this regime and
`../graph-loop-bound/` said the same of the 140-microsecond round trip. Both
recompute downward. The recomputation assumes the per-iteration host cost holds
constant in N, which is unmeasured; a host cost growing linearly in N would hold
each share constant rather than raise it, so a lever reopens only if the round
trip grows faster than the iteration, and the gentle flattening of the decode
curve is inconsistent with that.

## Dispatch crosses where the closure says it does

The Nsight symbol names the column count, and the four captured levels read:

| level | Q4_K | Q6_K |
| ---: | --- | --- |
| 7 | `mul_mat_vec_q<Q4_K,7>`, 6624 launches | `mul_mat_vec_q<Q6_K,7>`, 1150 |
| 8 | `mul_mat_q<Q4_K>`, 4968 | `mul_mat_vec_q<Q6_K,8>`, 1150 |
| 10 | `mul_mat_q<Q4_K>`, 4968 | `mul_mat_vec_q<Q6_K,10>`, 1149 |
| 11 | `mul_mat_q<Q4_K>`, 4968 | `mul_mat_q<Q6_K>`, 1125 |

Each capture also holds MMVQ launches at widths one through four beside the
named width, which are the passes the first prompts decoded in while the rest
prefilled. The marginal-gain reading this file once drew from the delivered
rates, and the Q6_K candidate it raised, are withdrawn: `../concurrent-q6k-threshold/`
measured the candidate and found it inside the floor, and the reading rested on
a window that mixed prefill into the rate.

## Falsifiers, against the preregistered list

1. **Slots do not co-batch.** Refuted at one, two, and four slots by the log,
   where every decode pass holds every slot. Above four the slots co-batch
   after a mixed prefix, which the harness now refuses under primed admission.
2. **Aggregate throughput does not scale.** Refuted on the full-width decode
   rate: 4.62 and 4.53 times at eleven slots.
3. **No dispatch effect is visible at request level.** Not measurable here.
   The paired arm in `../concurrent-q6k-threshold/` is the instrument.
4. **The round trip per iteration is flat in N.** Not measured.
5. **Concurrency costs per-request latency more than it buys aggregate.** Both
   measured, neither dominates by construction; which the appliance should buy
   depends on whether requests arrive together.

## What this arm is not

The 4096 per-slot allocation was never filled: the prompt is 468 tokens and the
reply 128, so attention read about 596 positions per sequence and KV traffic
was the short-context share of the iteration. A deeper filled slot moves the
balance toward KV and is a separate arm, which the harness now cuts in tokens.
The clock lock was read once at lock time and no operating-state series spans
the bursts; the harness now samples one row per second for the whole campaign.
No arm combines concurrency with speculation. The desktop client set held
throughout, which is this host's standing covariate.
