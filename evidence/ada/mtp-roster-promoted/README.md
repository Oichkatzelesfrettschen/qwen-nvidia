# The speculation roster on the promoted binary

`admit-router-speculation-roster.sh` ran every servable row once through the
promoted configuration 572951d25562: fifteen children, each answering its
one-question probe with finish=stop, each child's speculation read from its
own argv. The four mtp1 rows -- qwen35-08b, qwen38-2b-distill,
qwen38-4b-distill, and qwenseer-2b -- ran draft-mtp with zero
`model has unused tensor` lines, so each prediction block loaded rather than
being skipped, and every off row ran none. The mutation negative refused a
registry row edited mid-session, the GPU state latch read clear after the
teardown, and the admission closed at nine checks with none rejected
(summary.tsv, checks.tsv, occupancy.tsv).
