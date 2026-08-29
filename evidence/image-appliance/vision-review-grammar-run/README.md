# The grammar-bound appliance run of `remote/image-review.py`

Four reviews ran on the appliance on 2026-08-29 over the CLI two-phase
protocol `evidence/image-appliance/vision-review-design.md` names: the same
two artifacts as `evidence/image-appliance/vision-review-first-run/`,
`17e452e6...` (a fox) and `7c6b7565...` (an apple), each reviewed once by
`lfm25-vl-16b` and once by `qwen35-2b` against the same two-constraint
declaration, through the router's served model id `qwen-apu`. Every request
now carries `response_format` with a `json_schema`, so the reply's shape rests
on a grammar `common/chat.cpp:3673,3802` compiles from that schema rather than
on the system instruction alone; every audit line's `schema_mode=response_format`
field records that the condition held for that row. `chain.log` bounds the run
at 2026-08-29T11:39:34Z through 11:41:33Z, twenty minutes after the first
run's own 2026-08-29T11:19:15Z through 11:21:10Z. This directory retains the
sanitized chain log, the image-service log, the eight per-review
stdout/stderr files, the four `.raw` replies, and the four verdict records.

## The falsifier

The claim this run tests is that the grammar removes the structural refusals
the first run hit -- `constraint_count` and `hard_constraints_not_list` --
without changing the models' judgments about the two constraints, so the
grammar acts as a shape constraint alone and not as a second opinion on
content. The falsifier is either a refusal surviving under the grammar (the
shape constraint failing to close) or a verdict disagreeing with the
unconstrained run's judgment on the same artifact where both parsed (the
grammar changing what the model concludes rather than how it is forced to say
it). Neither was met: all four rows parsed clean and accepted, and the one
row that also parsed under the first run -- `qwen35-2b` on the apple -- passed
both constraints there too. The judgment-invariance half of the falsifier has
n=1: three of the first run's four rows refused structurally and produced no
verdict to compare, so `qwen35-2b`/apple is the only row that could have shown
the grammar moving a judgment, and it did not. The shape half has n=4: every
row that refused under the schema-free request parsed and passed under the
grammar. The claim survives this run on both halves, with the weaker sample
recorded as weak.

## The four rows

| Row | Artifact | Wall seconds | Constraints passed | Regenerate | Observation excerpt |
| --- | --- | ---: | --- | --- | --- |
| `lfm25-vl-16b` | fox (`17e452e6...`) | 20.45 | 2/2 | no | "A fox is standing in the snow." / "The background is plain and uncluttered." |
| `lfm25-vl-16b` | apple (`7c6b7565...`) | 20.48 | 2/2 | no | "A red apple is placed on a white surface." / "The background is plain and uncluttered." |
| `qwen35-2b` | fox (`17e452e6...`) | 33.19 | 2/2 | no | "A single red fox stands prominently in the center of a snowy field..." / "The background consists of snow-covered branches and twigs, which are uncluttered..." |
| `qwen35-2b` | apple (`7c6b7565...`) | 30.21 | 2/2 | no | "A single red apple with a stem is centered on a white surface." / "The background is a plain, uncluttered white surface." |

Every `hard_constraints` array holds exactly two entries, each entry's `name`
matches a declared constraint, `passed` is a JSON boolean on every entry, and
`composition_change_required` and `regenerate` are both `false` on every row.
`reasoning_emitted` reads `no` on every row, matching the first run. `chain.log`
carries `teardown row=... status=1` on both rows here, the same nonzero status
the first run's chain log carries on all four of its own teardown lines, so
that status is a reproducing property of the chain rather than a symptom of
this run: only the `review row=...` status moved, from `1` on every refusal in
the first run to `0` on every acceptance here.

## The `qwen35-2b` fox `background_plain` observation is a judgment call, not a parser fact

`qwen35-2b`'s fox review marks `background_plain` passed while its own
observation names "snow-covered branches and twigs" as the background rather
than an empty or neutral field. The grammar enforces that the entry is a
two-key object of the right types; it does not enforce that "plain" excludes
a textured backdrop the model chose to describe in detail. The verdict is
schema-conformant and the judgment inside it is recorded here rather than
corrected, because correcting it would substitute this run's reading of
"plain" for the model's.

## The comparison with the first run

`evidence/image-appliance/vision-review-first-run/` sent no `response_format`
and hit three structural refusals: `lfm25-vl-16b` returned a `hard_constraints`
array of length 1 against 2 declared on both artifacts (`constraint_count`),
and `qwen35-2b` returned `hard_constraints` as something other than a JSON
array on the fox (`hard_constraints_not_list`). Its fourth row, `qwen35-2b` on
the apple, parsed clean with no grammar in play and passed both constraints.
Under the grammar, all three prior refusals are gone: `lfm25-vl-16b` now
returns a two-entry array on both artifacts, and `qwen35-2b` now returns a
JSON array on the fox. The one row present in both runs, `qwen35-2b` on the
apple, reports the same outcome in each -- both constraints passed, no
regeneration -- so the grammar did not move that row's answer, only closed the
three that the unconstrained request left open.

| Row | Artifact | First run outcome | Grammar run outcome |
| --- | --- | --- | --- |
| `lfm25-vl-16b` | fox | refused, `constraint_count` | accepted, 2/2 passed |
| `lfm25-vl-16b` | apple | refused, `constraint_count` | accepted, 2/2 passed |
| `qwen35-2b` | fox | refused, `hard_constraints_not_list` | accepted, 2/2 passed |
| `qwen35-2b` | apple | accepted, 2/2 passed | accepted, 2/2 passed |

## The timing cost of the grammar

| Row | Artifact | First run wall_s | Grammar run wall_s | Delta |
| --- | --- | ---: | ---: | ---: |
| `lfm25-vl-16b` | fox | 19.03 | 20.45 | +7.5% |
| `lfm25-vl-16b` | apple | 18.56 | 20.48 | +10.3% |
| `qwen35-2b` | fox | 31.63 | 33.19 | +4.9% |
| `qwen35-2b` | apple | 30.18 | 30.21 | +0.1% |

The two runs sit twenty minutes apart on the same morning rather than in
separate sweeps, so the nearest comparator this tree carries is
`evidence/measurement-state-and-memory-clock.md`'s finding of about 4%
uncontrolled spread on a depth-0 bench rate from identical flags ten minutes
apart. That figure measures a different quantity -- a bench rate rather than a
served review's wall time over an image prefill and a 400-token budget -- so
it bounds this comparison loosely rather than exactly. All four deltas here
are positive (+7.5%, +10.3%, +4.9%, +0.1%), mean +5.0%, which sits at the edge
of that ~4% band rather than clearly inside or outside it: the consistent
sign across four pairs is worth recording, and the magnitude is not separated
from machine spread by this comparison. Resolving it needs the two schema
conditions run alternating inside one sitting, which this record proposes as
the next timing arm rather than one the design document already specified.

## The next step

The page arm follows the launcher change `evidence/image-appliance/vision-review-design.md`
names: `qwen-web-launch.sh` admits exactly one preset section and exports
`QWEN_ROUTER_MAX=1`, so `GET /v1/models` returns one id on the appliance,
`resolveVisionModel` finds no vision row, and `webui/index.html`'s Review
button stays hidden. That arm waits on the launcher admitting a language
section and a vision section together -- a change to the section-count rule
and to `QWEN_ROUTER_MAX` -- and on the 2048 MiB VRAM budget accepting the pair
resident at once. Until then `remote/web-mcp/test-fallback-page-image.py`
remains the only place the page half of the review runs end to end, against a
stub roster that serves both rows.
