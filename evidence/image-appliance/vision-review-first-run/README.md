# The first appliance run of `remote/image-review.py`, before the grammar

Four reviews ran on the appliance on 2026-08-29 over the CLI two-phase
protocol `evidence/image-appliance/vision-review-design.md` names: two
artifacts already on disk from an earlier generation run, `17e452e6...` (a
fox) and `7c6b7565...` (an apple), each reviewed once by `lfm25-vl-16b` and
once by `qwen35-2b` against the same two-constraint declaration, through the
router's served model id `qwen-apu`. Every request sent no `response_format`
and no `json_schema`; the reply's shape rested on the system instruction
alone. `chain.log` bounds the run at 2026-08-29T11:19:15Z through
11:21:10Z. This directory retains the sanitized chain log, the image-service
log, the eight per-review stdout/stderr files, and the one verdict record the
run produced.

## The falsifier

The claim this run tests is that a schema-free request cannot produce a
verdict the strict parser accepts -- the premise that would make a grammar
strictly redundant with the parser rather than a remedy for a real gap. The
falsifier is a vision row returning a verdict the parser accepts with no
grammar in the request. It was met once, on `qwen35-2b` reviewing the apple:
row 4 of the table below parsed clean with no schema in play at all. The claim
is therefore refuted as stated -- a schema-free reply can pass -- and the
finding narrows to what the other three rows show: a schema-free request
reached a parser-acceptable reply on 1 of 4 rows here, so the path is
unreliable rather than categorically broken, and the grammar's value is
closing the gap on the three that failed structurally rather than creating a
possibility that did not already exist. Four rows is too few to state a rate;
it is enough to state that both outcomes occurred inside one sweep.

## The four rows

| Row | Artifact | Wall seconds | Outcome | Refusal code |
| --- | --- | ---: | --- | --- |
| `lfm25-vl-16b` | fox (`17e452e6...`) | 19.03 | refused | `constraint_count` |
| `lfm25-vl-16b` | apple (`7c6b7565...`) | 18.56 | refused | `constraint_count` |
| `qwen35-2b` | fox (`17e452e6...`) | 31.63 | refused | `hard_constraints_not_list` |
| `qwen35-2b` | apple (`7c6b7565...`) | 30.18 | accepted | -- (both constraints passed, no regeneration) |

`lfm25-vl-16b` answered a `hard_constraints` array of length 1 against 2
declared, both times, in about half the wall time `qwen35-2b` took.
`qwen35-2b` answered `hard_constraints` as something other than a JSON array on
the fox and a schema-conforming object on the apple. `reasoning_emitted` reads
`no` on every row: the thinking-off request was not inert against either
row's chat template here, which rules out falsifier 2 of
`vision-review-design.md` for this run.

## The failures are structural, not fenced or prose

Every one of the four replies parsed as one JSON object with `content` alone
-- no code fence, no sentence before or after the object, no `tool_calls`.
`vision-review-design.md`'s falsifier 1 predicted a fenced or narrated reply
as the first failure mode a schema-free request would hit; this run did not
hit it. What it hit instead is a reply whose object-level shape (an array of
the wrong length, a field of the wrong JSON type) diverges from the
declaration while the object itself parses cleanly. `not_json` never appears
in this run's four outcomes. A system instruction states the schema in prose,
so a model that reads it can still miscount an array or emit the wrong type
for one field without ever leaving valid JSON -- the failure mode a grammar
is built to close and a strict parser alone cannot prevent, because the parser
runs only after the reply already exists.

The remedy to test next is the one `vision-review-design.md` names first and
leaves conditional on a source check that had not run when it was written:
`response_format` carrying a JSON schema. That check has now run.
`tools/server/server-common.cpp:1156-1174` in the workstation clone
`~/src/llama.cpp` at commit `c2c62855c` (which contains `f280b269`, the pinned
commit) reads a top-level `json_schema` key directly and, for
`response_format: {"type": "json_schema", "json_schema": {"schema": ...}}`,
reads the schema from `response_format.json_schema.schema` alone -- the
sibling `name` key the OpenAI shape carries is never read at that commit.
`common/chat.cpp:3673` parses whichever schema arrived into `params.json_schema`
and line 3802 converts it with `json_schema_to_grammar`, so the schema becomes
the grammar bounding every sampled token, and line 1158-1160 refuses a request
naming both `json_schema` and `grammar` together. `remote/image-review.py` now
sends `response_format` with an array schema whose `minItems` and `maxItems`
both equal the declared constraint count and whose per-entry `name` is an enum
of the declared names -- the two fields that would have closed both observed
failure modes here, `constraint_count` and `hard_constraints_not_list`, before
the reply left the server.

The converter reads every keyword the schema uses, none of them silently.
`common/json-schema-to-grammar.cpp` builds an array repetition rule from
`minItems` and `maxItems` at lines 1030-1031, a literal-alternation rule from
`enum` at line 938 (checked ahead of `type`, so the `name` field's `enum`
governs its rule regardless of its declared `"type": "string"`), a character
repetition rule from `maxLength` on a `"type": "string"` schema at lines
1046-1049, and an object rule that reads `required` and `additionalProperties`
at lines 943-965. Every keyword in `build_verdict_schema` maps to one of these
branches; none falls through to the `_errors.push_back("Unrecognized
schema: ...")` branch at line 1080, which is what a request naming an
unsupported keyword would hit as a 4xx before generation starts.

## The next run

The same four reviews, `response_format` on every request, alternating rows
(`lfm25-vl-16b` fox, `qwen35-2b` fox, `lfm25-vl-16b` apple, `qwen35-2b` apple)
inside one sitting rather than grouped by row, because this machine spans
30.6% on a repeated checkpoint between sweeps and a same-sweep comparison is
what a wall-time difference between the two rows can support. Retain the audit
line, the verdict JSON, and the raw reply -- now `raw_reply` on the record and
a sibling `.raw` file next to `--verdict-json` -- for every row including a
refusal, since a grammar-bounded reply that still fails the parser is itself a
finding about which rule closed and which did not.

The page arm follows after that: `vision-review-design.md` records that
`webui/index.html`'s Review button stays hidden on the appliance as the tree
stands, because `qwen-web-launch.sh` admits exactly one preset section and the
served roster therefore names no vision row. That arm waits on the launcher
change to admit a language section and a vision section together, and on the
2048 MiB VRAM budget accepting the pair resident at once.
