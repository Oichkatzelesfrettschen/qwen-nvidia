# Qwen2.5-Coder-7B-Instruct graded arm

The 7B coder joined the registry after the twenty-three-row sweep, so this
arm ran alone rather than inside it. A graded result is conditioned on the
request sequence that produced it -- prepending rows moves answers
deterministically -- so this total compares to the sweep only as a separate
condition, and the code category below is the reading the role decision
rests on.

55 of 84 with every row completed and none truncated,
correct-on-completed 0.655, median decode 79.8 tok/s across the arm.

| category | passed |
| --- | ---: |
| arithmetic | 9/10 |
| code | 9/10 |
| format | 10/10 |
| long_context | 5/5 |
| screen | 5/5 |
| termination | 5/5 |
| word_problem | 6/10 |
| tool | 1/10 |
| photo | 4/9 |
| vision | 1/10 |

The row is text-only, so the photo and vision categories ran as the
image-withheld control the sweep applies to every text row and their
counts state nothing about a vision capability the checkpoint lacks.

The code category ties `qwenseer-2b` at 9 of 10 while decoding at 80
against its 232 tok/s, so the fast-coding role stays where the sweep put
it. The 7B's position is the deeper coding tier beside the 4B Q5_K_M and
Q6_K rungs, which hold 10 of 10 in that sweep. `raw_tool_selection` is
unmeasured here and `guarded_tool_execution` reads `refused` like every
other row: 1 of 10 on the tool category states selection alone, and no
runtime in this tree compares emitted arguments against the user's own
authorization.
