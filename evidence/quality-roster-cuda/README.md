# The 84-row graded sweep over every servable row, promoted binary

One sweep through configuration 572951d25562, thinking off, 1024 reply
tokens, images withheld on every arm so all twenty-three rows meet the
identical request sequence; the two vision rows' real-image arms remain a
separate paired condition. summary.tsv carries the per-arm grades and each
JSON record retains every reply. A prior run without the withheld control
failed nineteen vis rows per text arm at HTTP 500, which is the modality
boundary asserting itself rather than a harness fault; the withheld condition
is the comparable sweep.

## Readings

The 4B class is monotone in quantization: base 63, Q6_K 62, Q5_K_M 60, the
served Q4_K_M distill 59, Q2_K 55 of 84. The uncensored 2B variants outgrade
the 2B distill -- heretic 51, hauhau 51, unredacted 48 against the distill's
44 -- so the distill's admission stays a throughput claim while the quality
lead in that class belongs to the fine-tunes. minicpm-v-46 matches the 4B
distill at 59 in two thirds of its wall time. lfm25-vl-16b reads 55,
qwenseer-2b 51, the 0.8B Q8_0 46 against its derived F16's 43, and the
sub-half-billion rows grade at 30 to 34.

## The thinking arm

lfm25-12b-thinking truncated 44% of rows at the 1024 budget, the unguarded
reasoning-span failure the static admission predicts for such templates, so
its sweep grade is a budget fault. thinking-4096/ carries the escalated
condition: truncation falls to 1.2% and the arm grades 54 of 84 at 218
seconds of wall time against the 4B distill's 24.5, its own labeled
condition rather than a row in the sweep.
