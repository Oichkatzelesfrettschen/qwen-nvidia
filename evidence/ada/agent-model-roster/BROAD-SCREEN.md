# Broad screen: thirty-three admitted rows on graft's summarize request

Every admitted row whose ceiling clears graft's 16384-token floor, measured
on 2026-09-19 at the screen budget: a 2048-token reply cap, a 512-token
thought budget, a 60-second request timeout, and a 16384-token context
allocation rather than each row's ceiling, since the largest probe file is
8760 prompt tokens and the KV a launch reserves is paid whether the
requests reach it or not. Thirty-three rows, five model families, nineteen
of them stopping on all three files.

## Rows that stop on every file

| model | total s | s/file | out tokens | thought ch | body ch | tool call |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| lfm25-350m-qad | 1.7 | 0.6 | 1179 | 0 | 4490 | yes |
| lfm25-12b-thinking | 4.4 | 1.5 | 1736 | 0 | 7691 | no |
| minicpm-v-46 | 4.4 | 1.5 | 1353 | 3894 | 2474 | no |
| hammer21-3b | 6.9 | 2.3 | 376 | 0 | 1791 | no |
| qwen38-4b-i1-q2k | 7.6 | 2.5 | 862 | 2061 | 1834 | yes |
| qwen25-coder-7b | 7.7 | 2.6 | 506 | 0 | 2483 | no |
| qwenseer-2b | 8.2 | 2.7 | 1757 | 5021 | 2646 | yes |
| swe-dev-7b | 9.7 | 3.2 | 523 | 0 | 2669 | no |
| qwen3-4b-instruct-2507 | 10.9 | 3.6 | 797 | 0 | 3897 | yes |
| qwen38-4b-distill (incumbent) | 12.4 | 4.1 | 1321 | 1797 | 3833 | yes |
| qwen35-2b-unredacted | 13.0 | 4.3 | 2886 | 5744 | 6787 | yes |
| qwen38-4b-i1-q6k | 13.3 | 4.4 | 1175 | 1687 | 3496 | yes |
| qwen38-4b-i1-q5km | 13.6 | 4.5 | 1350 | 2139 | 3388 | yes |
| qwen38-9b-distill | 19.3 | 6.4 | 1272 | 2901 | 2903 | yes |
| granite40-micro | 19.4 | 6.5 | 1037 | 0 | 4971 | yes |
| klear-agentforge-8b | 30.6 | 10.2 | 1729 | 0 | 8341 | no |
| qwable-9b-fable5 | 38.2 | 12.7 | 2117 | 6421 | 2373 | yes |
| swe-agent-lm-7b | 45.5 | 15.2 | 2877 | 0 | 13529 | no |
| ornith15-9b | 45.5 | 15.2 | 2607 | 5435 | 4813 | yes |

## Rows that run to the cap

Fourteen rows run to the cap on at least one file, which is a statement
about those files and not about the row in general: `lfm25-vl-450m`,
`qwen35-08b-unsloth-unc`, `lfm25-vl-16b`, `minicpm5-1b`,
`qwen35-2b-hauhau`, `qwen35-2b`, `qwen35-08b-f16`, `qwen38-2b-distill`,
`qwen35-2b-heretic`, `qwen35-08b`, `minicpm5-1b-fable5-v2`,
`qwen38-2b-uncensored`, `qwen35-4b-base` and `oxcoder-9b`. `qwen35-08b`
and `minicpm5-1b-fable5-v2` cap on all three, and are the only two rows
the screen never saw stop. That is the same shape the
first roster recorded at a 32768 cap: the answer runs until the budget
ends rather than until the summary does, and a smaller cap bounds the cost
without fixing the behavior.

## What the screen finds

`lfm25-350m-qad` is the result worth acting on. A 350M-parameter Liquid
model, quantization-aware, finishes three files in 1.7 seconds against the
incumbent's 12.4: 7.3 times faster per file, with more body text than the
incumbent, no thought block at all, and a completed forced tool call.
Against graft's concept pass over 2533 DiscoBSD files that is the
difference between roughly 2.9 hours and roughly 25 minutes at the same
request shape.

Four other rows also beat the incumbent while completing the tool call:
`qwen38-4b-i1-q2k` at 2.5 s per file, `qwenseer-2b` at 2.7 and
`qwen3-4b-instruct-2507` at 3.6. Two rows sit between the Liquid row and those four but answer the forced
tool call in prose, so they cannot drive a pass that records through
`record_graph` or `record_symbols`: `lfm25-12b-thinking` and
`minicpm-v-46` at 1.5 s per file each, which is slower than the Liquid
row's 0.58 and faster than everything below it.

A thought block is the clearest cost in the table. Every row above four
seconds per file that passes the tool probe spends 1687 to 6421 characters
thinking, and the four fastest tool-capable rows spend zero or little. The
incumbent's 1797 characters per three files is what a non-thinking
checkpoint does not pay.

## What the screen does not find

Nothing here measures whether a summary is true. A 350M model that answers
fast, stops cleanly and completes a tool call may still describe a test
model's property as the function's, which is the failure
docs/research/graft-concept-review.md in the DiscoBSD tree records for the
incumbent's own output. The six contracts of that review are the next
gate, run against a fixed source package on the fastest tool-capable rows,
followed by small `record_graph` and `record_symbols` instances. A row is
promoted on that, not on this table.
