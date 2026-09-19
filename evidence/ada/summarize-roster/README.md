# Summarize roster: which admitted model fits graft's deep pass

`scripts/admit-summarize-roster.sh` drove every admitted text-capable
registry row through `scripts/qwen-launch.sh` on 2026-09-19, on the
promoted closure `15bc632adf7f` with `QWEN_CHAT_TOOLS=on`,
`QWEN_CHAT_REASONING_BUDGET=8192`, and the row's context ceiling capped
at 32768. Each row answered graft's summarize request shape for three
files of the DiscoBSD tree, `flash_swap.c` at 1120 prompt tokens,
`cat.c` at 1644 and `usb.c` at 13063, at a 32768-token reply cap, after
the forced tool-call probe `scripts/graft-consumer-env.sh` sends.
`roster.tsv` carries one row per request and `sample-*.txt` the first
1200 characters of each answer. `nanbeige42-3b` and `qwen35-08b-bf16`
were skipped: their ceilings sit below graft's 16384-token floor.

## What the numbers say

A model fits when every file reads `finish=stop`, the content is
non-empty, and the tool-call probe passes. Ten rows read `finish=length`
on at least one file, and every one of them is the same shape: the
thought block ended at the budget and the content ran to the cap, 50 to
125 thousand characters of repetition for a 300-line utility. That is
the 0.8B family (`qwen35-08b`, `-unsloth-unc`), the 1B MiniCPM rows,
the LFM 450M vision row, the 2B `unredacted` row, and the 4B `i1-q2k`
quantization. `lfm25-12b-thinking` stopped on every file and answered
`usb.c` with 3 tokens. Nine rows stop on every file with the probe
passing; the seven that finish inside 30 seconds for the three files:

| Row | wall s | max completion | flash_swap.c summary |
| --- | --- | --- | --- |
| lfm25-350m-qad | 2 | 1168 | muddled: "copying the source memory, then overwriting the destination" |
| qwen38-4b-distill | 18 | 1035 | correct: sector erase at the boundary, 0xFF padding, ascending order |
| qwen38-4b-i1-q5km | 18 | 780 | invented: "avoids the need for a full sector erase" |
| qwen38-4b-i1-q6k | 20 | 782 | adequate |
| qwenseer-2b | 26 | 2823 | correct on alignment, verbose |
| qwen38-9b-distill | 30 | 785 | invented: "resilient to power loss" |
| minicpm-v-46 | 5 | 700 | adequate, but the tool-call probe fails |

`qwen38-4b-distill` is the one row that is both fast and right on the
file whose invariant the tree documents, so it is the deep-pass model.
The tree-wide rate measured on it is 7 to 9 files a minute for the
concept pass, which puts the 2533-file concept pass at about 6 hours
and the per-file symbol pass after it at about the same, roughly 12
hours end to end on this card at the 8192 thought budget.

## What the run corrected

The 0.8B was not failing on the thought budget alone. Under graft's
2048-token cap the thought consumed the reply and the content came back
empty; with the thought bounded at 8192 and the cap lifted, the answer
itself does not terminate. Both readings are in `roster.tsv` under
`qwen35-08b`. The fix for a thinking model on this host is the pair
`QWEN_CHAT_REASONING_BUDGET` plus a client reply cap above the budget,
and the model has to be one that stops.
