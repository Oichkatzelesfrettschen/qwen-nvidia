# The launch is worth a microsecond, and the fan-out holds too few of them

Two node-granularity captures ran on the promoted closure with no candidate
patch, under the owner lock with the appliance stopped, against the same two
desktop clients throughout: `t0-2b/` is the subject and `t0-08b/` the
corroboration the preregistration named.

The hypothesis holds. t0 is near one microsecond, the fan-out merge removes 123
to 163 launches per token, and every runtime class lands under the 5.1%
promotion floor.

## The instrument turned out cleaner than the preregistration assumed

`../decode-node-trace/run-02/` reported node granularity inflating the 2B token
span by 17%, and the preregistration read a per-kernel duration from it as an
upper bound on t0 for that reason. Comparing the two granularities term by term
places that inflation somewhere else:

| term | 2B graph | 2B node | ratio | 0.8B graph | 0.8B node | ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| median span | 4261.2 us | 4813.3 us | 1.13 | 3171.3 us | 6952.6 us | 2.19 |
| median device busy | 3998.6 us | 4088.6 us | **1.02** | 2942.1 us | 6171.0 us | **2.10** |

On the 2B the kernel durations carry 2.25% of the span inflation and the CUDA
API cost between nodes carries the rest, so a duration read from that capture is
within a few percent of the graph-granularity figure the served token
reproduces. On the 0.8B the same capture stretches the durations themselves by
2.10 times, which is why the preregistration made it corroboration rather than
subject. Its body is unreadable; its lower quantiles are not, and they are what
the corroboration rests on.

## Two estimators, one number

| estimator | launches | 2B p05 | 2B p10 | 2B p20 | 0.8B p05 | 0.8B p10 | 0.8B p20 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `quantize_q8_1` | 10595 | 896 ns | 896 ns | 960 ns | 960 ns | 960 ns | 992 ns |
| `mul_mat_vec_q<T, 1, 0>` | 6240 / 7085 | 1216 ns | 1248 ns | 1312 ns | 1216 ns | 1248 ns | 2720 ns |

The two classes agree on the lower quantiles to within 64 ns even though the
0.8B capture inflates its own body twofold, which is the corroboration: t0 does
not differ between a 1024-wide and a 2048-wide activation.

The launch counts corroborate the reading a second way. Both captures issue
10595 `quantize_q8_1` launches, and both issue 7085 unfused and 3510 fused
`mul_mat_vec_q` launches -- the 0.8B in one Q8_0 class each, the 2B split 6240
Q4_K against 845 Q6_K unfused and 2730 against 780 fused. The two checkpoints
carry the same 25 blocks at the same `full_attention_interval`, so they issue the
same launches and differ only in how the quantization recipe partitions them.
That 7085 + 3510 equals 10595 exactly is the invariant `mmvq.cu:1332` states:
one quantize launch per `ggml_cuda_mul_mat_vec_q` call, fused or not.

The mat-mul estimator reads the `ssm_alpha` and `ssm_beta` launches, 2048 by 16
and 18432 bytes, which is 0.04 us of traffic at the 442.61 GB/s this device
sustains. Their share of the unfused class is 36 of the 104 launches a 2B token
issues, and the 2B distribution has its knee exactly there: 1216 to 1504 ns from
p05 to p25, then 2496 ns at p30. That band is the launch's whole duration and so
is t0 to within the traffic rounding.

Correcting the 2.25% instrument inflation:

    t0 for one quantize_q8_1 launch    0.970 us
    t0 for one mul_mat_vec_q launch    1.221 us

The mat-mul figure comes from the smallest launch in the class, and it is
applied to every removed launch including wide ones. A wider launch schedules
more blocks, so a merged launch reabsorbs part of what the removed one was
paying, and the fixed cost that actually vanishes is under 1.221 us. Every
saving below is therefore an overestimate and the true share sits under the
figure stated, which moves the conclusion further from the floor rather than
toward it.

## What the merge reaches

`scripts/derive-projection-fan-out-bound.py` reads the group widths and the type
splits off the GGUF headers and applies the two measured costs:

| model | mat-mul launches removed | quantize launches removed | saving | share of token | clears 5.1% |
| --- | ---: | ---: | ---: | ---: | --- |
| qwen35-08b | 68 | 68 | 149.0 us | **4.63%** | no |
| qwen38-2b-distill | 55 | 68 | 133.1 us | 3.08% | no |
| qwen38-4b-distill | 73 | 90 | 176.4 us | 2.00% | no |
| qwen38-9b-distill | 73 | 90 | 176.4 us | 1.20% | no |

The 0.8B is the class the lever reaches furthest into and it still falls 0.47
points short. It is the closest because it is the one checkpoint quantized to a
single type: Q8_0 throughout merges all four members of the linear-attention
fan-out and all three of the full-attention fan-out, where Q6_K `attn_qkv`
against Q4_K everywhere else splits the larger group on the other three.

Two architecture facts bound this before any kernel is written, and both outlive
the arm. Every checkpoint this tree serves declares
`qwen35.full_attention_interval` of 4, so the `wq`/`wk`/`wv` fan-out the task
was written against exists in 7 of 25 layers on the 0.8B and 2B and 9 of 33 on
the 4B and 9B. The wider fan-out is the four-way linear-attention group, and
what bounds it is the weight type rather than the width.

## The refutation, and what would reopen it

**#41 is refuted on measurement.** Sharing one activation across a projection
fan-out and merging the mat-muls that read it removes real launches at a real
cost, and the product is 1.20% to 4.63% of a decode token against a 5.1% floor.
No kernel was written and no default moved.

The preregistered numerics gate never ran, because a lever that cannot reach the
floor is decided before its identity is tested.

Reopening needs a regime rather than a better kernel. The whole table is
computed at `ne11` of 1, where these mat-muls take the MMVQ path. A
concurrent-sequence or speculative-accept workload moves them to MMQ with a
different geometry and a different launch count, which recomputes every row --
the same shape `../decode-node-trace/` demoted graph prewarming to. A checkpoint
without the hybrid interleave would quadruple the full-attention fan-out count,
and this tree serves none.

## What these numbers are not

t0 is a fixed cost read from launches far under one wave, so it measures
launch serialization rather than small-launch bandwidth efficiency. The 39.5%
of peak `../ncu-decode-baseline/` measured on the unfused `<Q4_K, 1, 0>` class
is a separate finding about wave occupancy, and merging launches does not
address it: a merged launch moves the same bytes in the same tiles.

The untraced warm rates these captures recorded are 245.24 tok/s on the 2B and
335.92 on the 0.8B, against registry figures of 231.37 and 310.50 and against
243.46 and 326.20 in `../decode-node-trace/run-02/`. The shares above divide by
the registry token, which is what the promotion floor is quoted against.
Dividing the 0.8B by its own faster untraced token raises its share to 5.01%,
which is 0.09 points under the floor rather than 0.47, and that is the closest
any denominator brings this lever to promotion. It still falls short, and the
1.221 us overestimate above means the true figure sits under both readings, but
a 0.09-point margin is inside this host's own run-to-run span and the 0.8B is
better read as measured at the floor than as measured clear of it. The verdict
rests on the registry denominator and on the direction of the estimator bias
rather than on that margin.

The raw Nsight databases are removed and their digests retained in
`t0-2b/node-removed-export.sha256` and `t0-08b/node-removed-export.sha256`.
