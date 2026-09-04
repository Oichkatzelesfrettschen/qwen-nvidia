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
0.9932 to 1.0070 against a floor of 1.051. **This is falsifier 2.**

The clock lock did not hold on this arm and the verdict is a null, which is the
pairing where that matters most. `nvidia-smi` accepted
`(gpuClkMin 2835, gpuClkMax 2835)` and the harness's single reading two seconds
later, on an idle device with persistence mode disabled, was 2535; no during-run
series was recorded, so whether the clock stayed there is unknown. What protects
the ratio is the alternation, since both arms of every pair met whatever clock
the device held, and the control closure's level-7 aggregate of 779.74 sits 0.19%
from the 781.21 `../concurrent-sequences/2b-run-01/` measured. A reader revisiting
this threshold should weigh the null against that rather than against a lock the
run proved. The threshold
`../mmvq-crossover-ad104/` selected with llama-bench `-p N` transfers to N
decoding sequences, and the cross-model marginal-gain reading that raised the
question was the artifact of comparing two uncalibrated saturation trajectories,
which is what `../concurrent-sequences/` said it might be. The subject closure is
rejected and reaches no promotion path.

## Greedy decoding stops being reproducible above two sequences

The identity clause returned `diverged` at every level including both null
controls, which is impossible if it were measuring the closures. It was not.

`2b-divergence-onset/` sweeps the small levels on the control closure alone,
with every request carrying one prompt at temperature 0 and `ignore_eos`, and
finds a sharp boundary:

| slots | distinct replies per burst | repeats agreeing | first divergence |
| ---: | ---: | --- | ---: |
| 1 | 1 of 1 | 4 of 4 | none |
| 2 | 1 of 2 | 4 of 4 | none |
| 3 | 3 of 3 | 0 of 4 | token 2 |
| 4 | 4 of 4 | 0 of 4 | token 2 |
| 7 | 5 to 6 of 7 | 0 of 4 | token 2 to 4 |

Two sequences answer identically to each other and reproducibly across all four
repeats: eight responses, one distinct reply. Three sequences give three
different replies to three identical simultaneous requests, in every repeat.

The slot count changes the answer before it destroys reproducibility. The N=2
reply is stable but differs from the N=1 reply, so a sequence's own arithmetic
already depends on how many sequences share its pass, which follows from
`mul_mat_vec_q` being templated on the column count at `mmvq.cu:544`. What
happens at three is that the dependence stops being the same for every sequence
in one pass: at N=3 no reply matches the N=1 reply and the three part from it at
tokens 43, 2, and 10 respectively.

The paired closures corroborate the boundary from the other side.
`2b-identity-control/` runs both closures at `--parallel 1` and reads
**identical** over four pairs, so the closure pair is numerically sound and the
slot count is the changed dimension.

**The in-kernel cause is unlocated.** The server at `-lv 10` logs per-slot prompt
lengths and startup graph reservations rather than the composition of each
runtime ubatch, so which sequences shared which pass is not readable from what
this run retained. A per-iteration ubatch trace is what would locate it, and
this arm did not take one.

**The consequence does not wait on the cause.** Exact greedy token identity
decided `../mmvq-q8-b17-b20/` and `../mmq-stream-k-grid/phase-c-identity/`, both
batch-1 comparisons where the gate means what it says. Above two sequences the
gate fails against itself: its control arm, one closure compared with itself,
does not pass. No concurrency candidate can be gated that way, and a
distributional quality comparison is the instrument that would replace it. This
tree holds none.

It is also a reason the serving default holds rather than a footnote about blast
radius. `qwen-capacity-policy.sh:1140` sets `--parallel 1`, recorded against
placement and memory; above one, two identical requests can receive different
replies, and the graded quality suite would sample a distribution rather than
read a reply. Raising the setting for the 3.89x aggregate throughput
`../concurrent-sequences/` measured costs that, and the cost is now measured
rather than suspected.

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
