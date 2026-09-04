# The threshold transfers, and the identity gate does not survive concurrency

Two results, and the second was not the question this arm was built to ask.

The Q6_K MMVQ ceiling of ten holds in the served concurrent regime. Moving it to
seven, which sends Q6_K to MMQ at eight columns alongside Q4_K, moves aggregate
throughput by less than a percent in either direction at every level. The
candidate `../concurrent-sequences/` raised is refuted on its own preregistered
floor.

Exact greedy token identity, the gate this tree applies to every dispatch
candidate, cannot be evaluated at concurrency at all. Seven identical requests
answered simultaneously by one server on one closure returned six distinct
replies.

## The rate verdict

Control is the promoted closure `88681bf4d161` at `Q6_K_MAX = 10`; subject is
`4db51fb538cf`, identical in every configuration field but that one, which reads
7. Both carry `Q8_0_MAX = 16`. Four alternating pairs per level, per-slot depth
4096, clock lock requested at 2835 MHz.

| level | aggregate ratio, subject over control | clears 5.1% floor |
| ---: | ---: | --- |
| 7 | 1.0000 | no |
| 8 | 0.9970 | no |
| 9 | 0.9932 | no |
| 10 | 1.0070 | no |
| 11 | 1.0040 | no |

Levels 7 and 11 are the null controls the arm carries itself: the two closures
dispatch identically there, and they read 1.0000 and 1.0040. The harness is
therefore measuring the threshold rather than itself, and falsifier 1 is
answered.

Levels 8, 9, and 10 are the whole blast radius of the change, and the band moves
0.9932 to 1.0070 against a floor of 1.051. **This is falsifier 2.** The threshold
`../mmvq-crossover-ad104/` selected with llama-bench `-p N` transfers to N
decoding sequences, and the cross-model marginal-gain reading that raised the
question was the artifact of comparing two uncalibrated saturation trajectories,
which is what `../concurrent-sequences/` said it might be. The subject closure is
rejected and reaches no promotion path.

## Greedy decoding is not reproducible at concurrency

The identity clause returned `diverged` at every level including both null
controls, which is impossible if it were measuring the closures. It was not.

At level 7 on the control closure alone, one burst of seven requests carrying one
prompt at temperature 0 with `ignore_eos`:

- seven replies, **six of them distinct**
- slot 0 parts from slot 1 at generated token 4
- across four repeats, 28 requests produced **ten distinct replies**
- no request index is stable across repeats, so the effect is not a fixed
  property of slot position

The batch-1 control settles the cause. `2b-identity-control/` runs the same two
closures through the same harness at `--parallel 1` and reads **identical** over
four pairs. One changed dimension separates the two readings, and it is the slot
count.

The mechanism follows from what this campaign already established. `ne11` is the
count of slots holding a token to decode, so it varies with arrival timing as
requests join and leave the batch; `ggml_cuda_should_use_mmvq` selects the
mat-mul family from `ne11`, and MMVQ and MMQ reduce in different orders, as does
one MMVQ column count against another. A sequence therefore sees a different
sequence of reduction orders depending on what else was in flight beside it, and
a near-tie in the logits resolves differently. The first four tokens agree across
every slot, which is the stretch where all seven requests are still in lockstep.

**This makes the exact-identity gate a batch-1 gate.** It decided the MMVQ
nineteen-column candidate in `../mmvq-q8-b17-b20/` and the MMQ tiling threshold
in `../mmq-stream-k-grid/phase-c-identity/`, and both were batch-1 comparisons
where it means what it says. No concurrency candidate can be gated that way,
because the control arm of such a gate fails against itself. A concurrency
candidate needs a distributional quality comparison rather than a token
comparison, and this tree holds no such instrument.

It is also a serving fact independent of any candidate. The appliance serves
`--parallel 1`, so nothing shipped is affected. A future default above one would
mean two identical requests can receive different replies, and the graded quality
suite -- whose own discipline already records that a result is conditioned on the
request sequence that produced it -- would be reading a distribution rather than
a reply.

## What this run is not

The clock lock reported `observed=2535` against the requested 2835 on the paired
run, with persistence mode disabled, while the batch-1 control read 2835. The
alternation protects the ratio, since both arms of every pair met the same clock,
and the control closure's level-7 aggregate of 779.74 sits 0.19% from the 781.21
`../concurrent-sequences/2b-run-01/` measured at 2835. The absolute rates in this
directory are the paired arm's own and the ratio is what it reports.

The identity finding rests on one checkpoint at one per-slot depth with identical
prompts. Requests differing in prompt length would change batch composition
further rather than less, so the direction is not in question; the rate at which
replies diverge is unmeasured.
