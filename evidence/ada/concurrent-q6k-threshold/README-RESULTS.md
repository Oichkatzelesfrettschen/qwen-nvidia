# The candidate is inside the floor, and concurrent greedy replies are a function of slot position

**Status: provisional.** The paired arm ran under cold admission, so above
four slots its bursts entered decode through a mixed-width prefix, the clock
lock was read once, and no during-run operating-state series exists. The rate
verdict stands as a bounded null; the mechanistic claim it was written to
carry does not.

```text
candidate=Q6_K_MAX 7 against 10, closure 4db51fb538cf against 88681bf4d161
promotion_status=not_supported
observed_gain=inside_measurement_floor
mechanistic_refutation=not_established
```

## The rate verdict

Control is the promoted closure at `Q6_K_MAX = 10`; subject is `4db51fb538cf`,
identical in every configuration field but that one, which reads 7. Both carry
`Q8_0_MAX = 16`. Four alternating pairs per level, per-slot allocation 4096,
prompt 468 tokens, reply 128.

| level | delivered ratio, subject over control | clears 5.1% floor |
| ---: | ---: | --- |
| 7 | 1.0000 | no |
| 8 | 0.9970 | no |
| 9 | 0.9932 | no |
| 10 | 1.0070 | no |
| 11 | 1.0040 | no |

Levels 7 and 11 are the null controls the arm carries itself, since the two
closures dispatch identically there, and they read 1.0000 and 1.0040. Levels 8,
9, and 10 are the whole blast radius of the change and move 0.9932 to 1.0070
against a floor of 1.051. The candidate has no demonstrated benefit and reaches
no promotion path.

What the arm does not establish is that the llama-bench crossover fails to
transfer, or that it transfers: the bursts mixed widths, the lock was unproven,
and a difference under a percent is inside what this run can resolve. The
candidate is retired because production serves `--parallel 1` and the setting
has no serving role, and it is revisited only if concurrent serving becomes a
target after the boundary below is located.

The clock lock did not hold on this arm. `nvidia-smi` accepted
`(gpuClkMin 2835, gpuClkMax 2835)` and the harness's single reading two seconds
later, on an idle device with persistence mode off, was 2535; no during-run
series exists. The alternation protects the ratio, since both arms of every pair
met whatever clock the device held, and the control's level-7 delivered rate of
779.74 sits 0.19% from the 781.21 `../concurrent-sequences/2b-run-01/` measured.

## Reply identity is a function of slot position

The identity clause returned `diverged` at every level including both null
controls, which is impossible if it were measuring the closures. It was not.
`2b-identity-control/` runs both closures at `--parallel 1` and reads
**identical** over four pairs, so the closure pair is numerically sound and the
slot count is the changed dimension.

`2b-divergence-onset/` sweeps two, three, and four slots on the control closure
alone, and its `-lv 10` logs state the composition of every pass.
`../../../scripts/read-server-decode-iterations.py` reads them, and the
`reply` rows are a twelve-hex digest of each slot's 127 sampled ids per burst:

| slots | prefill passes | full-width history | slot replies, every burst | matches width 1 |
| ---: | ---: | --- | --- | --- |
| 1 | 1 | yes | `ef3619eee1d3` | itself |
| 2 | 1 | yes | `9b3ee873f6dd` `9b3ee873f6dd` | none |
| 3 | 1 | yes | `7a6441910d35` `03f484e6d7bf` `4f6277a6fa35` | none |
| 4 | 1 | yes | `9b3ee873f6dd` `940927d55a58` `4deddc010209` `03f484e6d7bf` | none |

Three facts sit in that table.

**The effect is deterministic per position, so it is not a race.** Every slot
answers the same way in every burst of its width, and the width-4 row is
identical across `2b-divergence-onset/level-4` and
`../concurrent-sequences/2b-run-01/level-4`, two server launches on different
days. Three identical simultaneous requests return three different replies, and
they return the same three every time.

**Schedule history is not the cause at three and four.** Every prompt of every
burst entered one prefill pass, and every decode pass held every slot, which
the `history_full_width` column reads as `yes`. The three sequences ran the
same widths through the same passes and still parted at the third token.

**The prefill composition is what the reply follows.** One burst of the width-4
run prefilled in two passes, three prompts and then one. Its first three slots
reproduced the width-3 replies `7a64`, `03f4`, `4f62` exactly, over 127 decode
passes at width four rather than three, and the fourth slot answered a reply
seen nowhere else. A change of decode width from three to four flipped no token
in three replies, while a change of prefill composition flipped one by the
third token in every case observed. That points at the geometry each prompt's
tokens occupied in the shared prefill ubatches, which is where a sequence's KV
cache is written, rather than at the column each slot occupied in the decode
mat-mul.

The boundary is a property of the model and the width rather than of three:
the 0.8B agrees across all four slots at width four in every burst and parts at
token 15 at width two. A numerical difference flips a greedy token only where
the top-two margin is small, so a null token read at one width states nothing
about numerical identity, and the logit margin is the instrument for a width
where the tokens agree.

Above four slots the second mechanism appears on top: `n_batch` admits four
468-token prompts per pass, so the first four enter decode while the rest
prefill, each burst's assignment of prompts to passes follows arrival order,
and per-slot replies vary between bursts of one level. That regime is
schedule-history and the harness now refuses it under primed admission.

## What the identity gate now means

Free-running exact-token identity is a valid numerical gate only after the
control demonstrates self-reproducibility in the same execution regime. One
sequence is self-reproducible, and it is the regime that decided
`../mmvq-q8-b17-b20/` and `../mmq-stream-k-grid/phase-c-identity/`. Two
sequences are self-reproducible in this harness. Three or more under cold
admission are not, so the gate is inapplicable there rather than failed. Under
primed admission every slot's prefill runs alone in its own pass, which removes
the prefill-composition term, and `../concurrent-sequences/README-PRIMED.md`
carries that arm: every slot of a width-3 or width-4 burst returns one reply,
so the two remaining readings resolve to prefill geometry.

It is also a reason `qwen-capacity-policy.sh:1140` holds `--parallel 1`
beside placement and memory: above one, the reply a request receives depends on
which slot it landed in and on which prompts shared its prefill pass, and the
graded quality suite would read a position rather than a reply.

## What this run is not

The identity finding rests on one checkpoint at one allocation with identical
468-token prompts and one 0.8B comparison. The rate verdict is a delivered
ratio inside a paired design, which cancels drift between arms and states
nothing about the absolute rate at either. Neither the ubatch split rule the
prefill applied nor the row offsets each prompt received are logged, so the
prefill-composition reading is an inference from the split burst rather than
an observation of the geometry itself.
