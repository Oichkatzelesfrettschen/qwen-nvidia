# Fast screen: which configuration summarizes DiscoBSD files fastest

run-20260919T173031-699316 ran the nine candidate rows and the qwen38-4b-distill control
through graft's summarize request on 2026-09-19, after the deep build
released the device. The budget is the screen's, not graft's: a
2048-token reply cap, a 512-token thought budget, and a 60-second request
timeout, sized for the three-to-eight-sentence summary the prompt asks
for rather than for the earlier stress screen. Every one of the nine
passed the strict CUDA0 placement load first, each bracketed by a kernel
ring read that stayed clean. Thirty-one of the thirty-three expected
answers stopped; the two that did not are OxCoder's, which ran to the cap.

| model | stop | capped | total s | s/file | out tokens | thought ch | body ch | tool call |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| hammer21-3b | 3 | 0 | 7.5 | 2.5 | 376 | 0 | 1791 | no |
| swe-dev-7b | 3 | 0 | 10.6 | 3.5 | 523 | 0 | 2669 | no |
| qwen3-4b-instruct-2507 | 3 | 0 | 11.5 | 3.8 | 797 | 0 | 3897 | yes |
| qwen38-4b-distill (control) | 3 | 0 | 12.8 | 4.3 | 1321 | 1797 | 3833 | yes |
| granite40-micro | 3 | 0 | 21.2 | 7.1 | 1037 | 0 | 4971 | yes |
| klear-agentforge-8b | 3 | 0 | 33.5 | 11.2 | 1729 | 0 | 8341 | no |
| qwable-9b-fable5 | 3 | 0 | 45.6 | 15.2 | 2117 | 6421 | 2373 | yes |
| ornith15-9b | 3 | 0 | 47.2 | 15.7 | 2607 | 5435 | 4813 | yes |
| swe-agent-lm-7b | 3 | 0 | 50.4 | 16.8 | 2877 | 0 | 13529 | no |
| oxcoder-9b | 1 | 2 | 83.6 | 27.9 | 4803 | 5774 | 14166 | no |

The deployment arm served the control alone under its registry
speculation profile, draft-mtp with one drafted token: 2427, 3160 and
5819 ms against 2726, 3610 and 6456 ms without it, for the same 312, 401
and 608 output tokens on each file. Identical output, 10.8 percent less
wall time, which is what the MTP head buys on this request shape rather
than the 1.42x decode ratio the speculation campaign measured on short
prompts.

## What the screen decides

The row `qwen3-4b-instruct-2507` is the challenger worth the next round.
It is faster than the incumbent on every file, emits more body text,
spends no tokens on a thought block, and completes the forced tool call.
The incumbent's 1797 characters of thought per three files is the cost
the non-thinking checkpoint does not pay.

The three agent-trajectory 9B rows are not competitive here. OxCoder is
the slowest row by a factor of 6.5 against the incumbent, ran to the cap
on two of three files, and its forced tool call did not complete despite
a template that renders a tool_calls branch. Ornith and Qwable stop on
every file but cost 3.5 times the incumbent's time, most of it inside the
thought block.

Five rows fail the tool probe: `hammer21-3b` (predicted, since its
template renders no tool_calls branch), `swe-dev-7b`,
`klear-agentforge-8b`, `swe-agent-lm-7b` and `oxcoder-9b`. A row that
cannot complete record_probe cannot drive graft's record_graph or
record_symbols, so speed alone does not qualify `hammer21-3b` or
`swe-dev-7b` for the deep pass.

## What the screen does not decide

Speed and a stopped answer say nothing about whether the summary is
source-grounded. docs/research/graft-concept-review.md in the DiscoBSD
tree supplies the correctness workload the screen lacks: six contracts
whose discriminator is whether the answer separates a checked condition
from a caller obligation. The next round puts the top two or three
configurations against those six questions with a fixed source package,
then exercises small record_graph and record_symbols instances on the
finalists. No configuration is promoted on this table alone.
