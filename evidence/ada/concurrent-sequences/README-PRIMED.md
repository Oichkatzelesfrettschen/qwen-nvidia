# Primed admission: the reply follows the prefill composition

`2b-primed-01/` and `2b-primed-offset-01/` are two runs of
`../../../scripts/run-concurrent-sequence-sweep.sh` on the promoted closure
`88681bf4d161` and the 2B distill, one server per level at widths 1, 3, and 4,
four measured bursts each, the same 448-token prompt cut from `CLAUDE.md`
whose first 468 tokens tokenize identically at every commit since the cold
runs, and 128 greedy tokens per request. Admission is `primed`: the client
sends the prompt to each slot alone with a one-token reply, waits half a
second, and releases the burst from one barrier with `cache_prompt`. The
second run occupies slots 1..N under a server at `--parallel N+1`
(`QWEN_CONCURRENCY_SLOT_OFFSET=1`), the permutation control.

## What a primed slot evaluates on this model

Qwen3.5 holds a recurrent state in its linear-attention layers that the
server cannot roll back, so cache reuse on a hybrid model goes through a
context checkpoint. `server-context.cpp` creates one only where
`--ctx-checkpoints` is positive, and it breaks the prompt batch four tokens
before the prompt end so that the checkpoint sits at length minus four
(upstream PR 20288). The sweep therefore serves `--ctx-checkpoints 8` under
primed admission and 0 under cold, and a primed burst re-evaluates the last
four prompt tokens per slot in one pass: `observations.tsv` reads `prompt_n`
4 for every slot at every width. The retained level-1 log shows the sequence:
`created context checkpoint ... n_tokens = 444` during priming, then
`restored context checkpoint ... n_past = 444` on the burst.

## The result, read from the server logs

`bursts.tsv` is `read-server-decode-iterations.py` over each level's `-lv 10`
log. Every measured burst at every width reads `prefill_passes 1`,
`history_full_width yes`, and `distinct_replies 1`. The twelve-hex reply
digests:

| width | slots | `2b-primed-01` | `2b-primed-offset-01` (slots 1..N) | cold, retained |
| ---: | --- | --- | --- | --- |
| 1 | one | `3bcc4345d01d` in 4 of 4 | `3bcc4345d01d` in 4 of 4 | `ef3619eee1d3` |
| 3 | all | `6b4387f02240` in 4 of 4 | `6b4387f02240` in 4 of 4 | `7a6441910d35` `03f484e6d7bf` `4f6277a6fa35` |
| 4 | all | `6b4387f02240` in 4 of 4 | `6b4387f02240` in 4 of 4 | `9b3ee873f6dd` `940927d55a58` `4deddc010209` `03f484e6d7bf` |

The cold column is `../concurrent-q6k-threshold/2b-divergence-onset/` and
`2b-run-01/`, where each slot's 448 tokens shared one prefill pass with the
others.

Four facts follow.

**Per-slot divergence is a prefill effect.** Under primed admission every
slot of a width-3 or width-4 burst returns one reply, in every burst, in both
runs. The decode passes are the same full-width passes the cold bursts ran,
so the term that parted the cold slots at token three is the geometry each
prompt's tokens occupied in the shared prefill, not the column each slot
occupied in decode.

**Decode width flips nothing.** Widths 3 and 4 return the same reply
`6b4387f02240` over 127 decode passes at three and at four columns. That is a
second, independent instance of what the cold 3+1 split burst showed.

**The reply follows history, not slot index.** Moving the burst from slots
0..N-1 to 1..N under a wider server changes no digest at any width.

**The joint four-token pass is itself a composition.** Width 1 under primed
reads `3bcc4345d01d`, differing from the cold single-sequence
`ef3619eee1d3`, and widths 3 and 4 read a third value. Two things change
between those arms and both are prefill-side: the recurrent state is restored
from a checkpoint at 444 rather than carried through one 448-token pass, and
the last four tokens are evaluated in a pass of 4, 12, or 16 tokens. On the
promoted closure a 4-column mat-mul runs MMVQ and 12 or 16 columns run MMQ
for both Q4_K and Q6_K, which would place widths 3 and 4 on one kernel family
and width 1 on another; that assignment is inferred from the closure's
thresholds rather than read from a capture, and an Nsight arm over the
priming pass is what would confirm it. Either way the statement holds as
measured: batched prefill changes the numerical state that is subsequently
decoded, even when every later decode pass has the same composition.

## What this decides

Free-running exact-token identity is a valid numerical gate only after the
control demonstrates self-reproducibility in the same execution regime, and
primed admission is a regime in which three and four sequences are
self-reproducible on this closure: the harness's identity clause is
applicable there. Graph prewarming (#43) has to key on the topology the
prefill and decode state produce rather than on N alone, since the same N
yields different states under the two admissions.

## What this is not

One checkpoint, one prompt, one allocation, widths up to four. The 0.8B,
which parted at width two under cold admission, has not run primed. The
kernel-family reading of the width-1 versus width-3 difference is an
inference. `../concurrent-sequences/README-RESULTS.md` and
`../concurrent-q6k-threshold/README-RESULTS.md` keep the cold records and
their delivered-rate caveats.
