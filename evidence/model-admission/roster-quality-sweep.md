# The 55-row graded suite across every servable checkpoint

`remote/run-quality-roster.sh` grades every production and candidate row of
`remote/models.tsv` against `remote/quality-suite.tsv` through the one router
listener the appliance already serves. Rate is measured for seven checkpoints in
`evidence/model-admission/universal-candidate-ladder.md` and quality is graded
for four, so three of the six servable rows carry a `candidate` tier that claims
device safety and leaves quality unqualified. This sweep is what closes that gap.

## Terms

```text
endpoint:      http://127.0.0.1:8080, router mode, --models-max 1
thinking:      off, through chat_template_kwargs.enable_thinking
token budget:  1024
long context:  24000 filler characters, 4216 tokens by the served tokenizer
sampling:      temperature 0, top_k 1, seed 1
geometry:      batch 128, ubatch 32, q8_0/q4_0, Flash Attention on, from the
               preset file rather than the router argv
```

Each arm names its checkpoint in the request body and asserts the id the
response came back with. The router answers 400 for a name it does not hold --
`model 'qwen-apu' not found` for the id the suite runner formerly hardcoded --
so a mis-routed arm fails rather than grading the default preset under another
name.

## What the ordering costs

The arms run model-major. The router holds one child at a time, so row-major
would evict and reload on every request and pay a cold first token 55 times per
checkpoint against six loads for the whole sweep. What that buys in wall time it
gives up in rate comparability: the first and last arms are hours apart, and
this tree reads a rate within a sweep. **The per-row decode figures this sweep
records are incidental to the grade.** Rate comparisons belong to the
seven-checkpoint bandwidth ladder, which met all seven checkpoints inside one
queue in forward and reverse order.

## What a passing long-context column does not establish

Every servable row admits at least 8192 tokens and the padded prompt occupies
4216, so the long-context rows sit well inside every allocation. The 4B distill
reads `validated_filled_depth` 16384 and the other five read `-`. A passing
long-context column measures retrieval past a 4216-token prefix and leaves the
allocation-beyond-validation gap exactly where the registry states it.

## The arithmetic gate

The 10 arithmetic rows ran first across all six checkpoints, as a gate rather
than a warm-up: they check model selection, per-template acceptance of the
thinking keyword, and termination at a small budget for the cost of minutes.

| checkpoint | arithmetic | empty | truncated | wall s |
| --- | ---: | ---: | ---: | ---: |
| LFM2.5-VL-1.6B | 9/10 | 0 | 0 | 10.9 |
| Qwen3.8-4B Distill | 8/10 | 0 | 0 | 35.8 |
| Qwen3.8-2B Distill | 7/10 | 0 | 0 | 14.0 |
| Qwen3.5-4B base | 7/10 | 0 | 0 | 38.0 |
| Qwen3.5-2B | 6/10 | 0 | 0 | 15.2 |
| Qwen3.5-0.8B | 5/10 | 0 | 0 | 7.1 |

The gate passed on the terms it was built to check. Every arm completed every
row with a non-empty, untruncated reply, every served id matched its arm, and
both non-Qwen and Qwen templates accepted `enable_thinking: false` -- LFM2.5-VL
returns an empty reasoning span under it rather than refusing the keyword.

`arith-02`, `floor(1073 / 63)`, fails on all six. A row every checkpoint misses
is the shape of a grader defect, and this one is not: the answer is 17, the six
replies are 16, 16, 16, 10, 1, and 17, and four of them are the same near miss.
`arith-06`, `7 - 3 x 6`, fails on four as an operator-precedence error, and
`arith-10` fails on four as the mean 4.5 rounded to 5.

Thinking state governs this category. `evidence/qwen38-2b-distill-quality.md`
records the 4B base spending 2048 predicted tokens on a reasoning span and
returning an empty answer; with thinking off at 512 tokens the same checkpoint
answers all ten arithmetic rows and gets seven right.

## Registered before the full results are read

The gate is already in hand, so these predictions are registered against a
partially informed prior rather than a blind one, and that is stated rather than
concealed.

| # | prediction | falsifier |
| --- | --- | --- |
| 1 | Total pass rate orders by parameter count inside the Qwen family | the 0.8B outscores either 2B row, or a 2B row outscores a 4B row by more than 3 of 55 |
| 2 | LFM2.5-VL's arithmetic lead does not extend to the whole suite | LFM2.5-VL leads the total by more than 3 rows |
| 3 | Completion stays uniform at a 1024-token budget with thinking off | any arm reports a completion rate below 0.95 |
| 4 | The suite separates Qwen3.5-2B from the 2B distill, which decode measurement left unresolved at 2.6% | the two land within 2 rows of each other |

## Results

Six arms, 330 graded rows, no transport error, and every served id equal to the
id its arm requested. Records are retained under `evidence/quality-roster/`.

| checkpoint | passed | corrected | completion | correct on completed | wall s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3.5-4B base Q4_K_M | 47/55 | 47 | 1.000 | 0.855 | 1756.4 |
| Qwen3.8-4B Distill Q4_K_M | 47/55 | 47 | 1.000 | 0.855 | 1659.5 |
| LFM2.5-VL-1.6B Q4_K_M | 43/55 | 43 | 1.000 | 0.782 | 442.3 |
| Qwen3.5-2B Q4_K_M | 41/55 | 41 | 1.000 | 0.745 | 667.4 |
| Qwen3.8-2B Distill Q4_K_M | 41/55 | **40** | 0.964 | 0.755 | 880.4 |
| Qwen3.5-0.8B Q8_0 | 33/55 | 33 | 1.000 | 0.600 | 277.0 |

| checkpoint | screen | arith | word | code | format | ctx | term |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Qwen3.8-4B Distill | 5/5 | 8/10 | 6/10 | 9/10 | 9/10 | 5/5 | 5/5 |
| Qwen3.5-4B base | 5/5 | 7/10 | 7/10 | 9/10 | 9/10 | 5/5 | 5/5 |
| LFM2.5-VL-1.6B | 4/5 | 9/10 | 8/10 | 7/10 | 6/10 | 4/5 | 5/5 |
| Qwen3.8-2B Distill | 3/5 | 8/10 | 5/10 | 7/10 | 9/10 | 4/5 | 5/5 |
| Qwen3.5-2B | 3/5 | 7/10 | 4/10 | 9/10 | 8/10 | 5/5 | 5/5 |
| Qwen3.5-0.8B | 4/5 | 5/10 | 1/10 | 7/10 | 6/10 | 5/5 | 5/5 |

## The registered predictions

| # | outcome |
| --- | --- |
| 1 | holds -- 33 for the 0.8B, 41 for both 2B rows, 47 for both 4B rows |
| 2 | holds -- LFM2.5-VL's 9/10 arithmetic lead ends at 43 against 47, four rows behind |
| 3 | holds -- the lowest completion rate is 0.964 against a 0.95 falsifier |
| 4 | **falsified** -- the two land 0 rows apart on the recorded grades and 1 row apart on the corrected ones, inside a 2-row falsifier either way |

## Two categories resolve nothing and one grader passes its own failure

`termination` is 5/5 on all six and `long_context` is 4/5 or 5/5 on all six, so
neither separates any pair in this roster. The long-context prompt occupies 4216
tokens against an 8192-token floor, which is the depth it was built to test and
is far from any admitted ceiling.

`term-02` asks for the largest prime in at most two sentences and grades
`nonempty`, so it credited any reply that existed, including one that never
stopped. The 2B distill ran it to the full 1024-token budget and the grader
passed it, which is the termination failure the category exists to detect.

`grade()` now refuses `nonempty` on a truncated reply. That grader asserts the
model reached an answer and stopped, and a reply cut at the token budget was
stopped rather than stopping. The refusal is confined to that grader: every
other one asserts a property of content, and content that is present is present
wherever the reply ended, which `ctx-03` shows in the same arm by being
truncated and failing on its own numeric terms.

`remote/regrade-quality-roster.py` re-applies the corrected grader to the reply
each retained record already holds, so the correction is computed rather than
asserted and the records stay as the harness wrote them.
`evidence/quality-roster/regrade-summary.tsv` is that output. Registered before
running it: only the 2B distill moves, 41 to 40, because it is the only arm with
a truncated row that the recorded grade passed. The re-grade moves exactly that
row on exactly that arm, leaves the other five at their recorded totals, and
reports no unregradable row.

The correction breaks the exact tie with Qwen3.5-2B against the distill and
leaves prediction 4 falsified either way: its falsifier is a 2-row margin and
the corrected gap is 1 row.

A weak grader on a termination category could flatter every arm, so the retained
`generated_tokens` decide whether it did. Across the 30 termination rows the
longest reply outside the 2B distill is 114 tokens against a 1024-token cap:

```text
LFM2.5-VL-1.6B        65  19  18  42    6
Qwen3.5-0.8B          57  42  37  18  106
Qwen3.5-2B            72  41 110  37   57
Qwen3.5-4B base       81  47 114  68   33
Qwen3.8-4B Distill    55  47  41  35    6
Qwen3.8-2B Distill     8 1024 16  37    4
```

Twenty-nine of thirty rows terminate an order of magnitude short of the budget,
so the 5/5 column is a real result that separates no pair rather than a grader
crediting failures. The one exception is the row the correction already removes.

## The two 4B rows are indistinguishable on quality

They tie at 47/55, at 0.855 correct-on-completed, and within one row in every
category. `evidence/qwen38-2b-distill-quality.md` promoted the distill over the
base at 5/5 against 4/5, and the base's single failure there was an empty answer
after 2048 predicted tokens of reasoning -- the termination failure that thinking
off removes. **With thinking off across 55 rows the quality half of that
promotion does not reproduce.** The throughput half stands untouched: the distill
reasons in 43.3% of the base's tokens and decodes 3.34 against 3.11 tok/s.

## A graded result depends on which rows preceded it in the same session

The gate scored the 2B distill 7/10 on arithmetic and the full sweep scored it
8/10, so the ten rows were re-run to find the reproducibility floor. The gate ran
at a 512-token budget and the sweep at 1024, and the repeats below run at 1024
and land on the gate's figure, so the budget is not the variable and the two
tables compare.

| run | preceding rows | 2B distill | Qwen3.5-2B |
| --- | --- | ---: | ---: |
| repeat 1 | none | 7/10 | 6/10 |
| repeat 2 | none | 7/10 | 6/10 |
| repeat 3 | none | 7/10 | 6/10 |
| `screen,arithmetic` | the 5 screen rows | **8/10** | **7/10** |
| full sweep | the 5 screen rows | **8/10** | **7/10** |

Three repeats reproduce exactly, so greedy decoding on this backend is
deterministic within a fixed request sequence. Prepending the five `screen` rows
moves both checkpoints up one row, deterministically and in the same direction,
and `arith-05` is the row that moves: `Convert 98.6 degrees Fahrenheit to
Celsius` answers 37 with no predecessors and 23 with the screen rows ahead of it.

**The reported prefill count does not move.** The arithmetic rows report
identical `prompt_n` in all three conditions -- 27, 37, 27, 44, 36, 28 for the
first six -- so the server charges each request the same prompt length whether it
runs cold or warm. Whether slot-level prefix state is reused behind that
unchanged count is a separate question this observation leaves open, and the
running listener carries `--cache-ram 0` and `--ctx-checkpoints 0`, which govern
checkpointing rather than that reuse.

**Predecessor content decides it, not predecessor count.** One unrelated
300-token request between a fresh model load and `arith-05` leaves the answer at
37. Five unrelated short requests -- the same count as the screen block --
also leave it at 37. Five screen rows move it to 23. Count is therefore excluded
by direct measurement and what the screen rows carry is what matters.

The mechanism beneath that content dependence is not isolated and is recorded as
an effect rather than a cause,
on the same terms as the two wedge signatures this tree declines to merge. What
is established is the measurement consequence: **a suite result is conditioned on
the request sequence that produced it, so a difference of one or two rows between
two checkpoints reports position in a sequence rather than capability.** Every
quality figure previously recorded in this tree came from a single fixed prompt
sequence and carries the same conditioning. Comparisons in the table above are
read inside this one sweep, where all six arms met the same 55 rows in the same
order.

## What this admits

The three candidate rows now hold a graded result under the tuple they are
admitted at, which is what `candidate` left unqualified. None of the three
promotes on it. Qwen3.5-0.8B is last by 8 rows and answers 1 of 10 word problems.
LFM2.5-VL leads arithmetic and word problems and trails both 4B rows by four,
with its losses concentrated in `format` at 6/10. Qwen3.5-2B ties the serving
default. Promotion also needs an image through the projector for the two vision
rows, which has not run.

