# Stage-two review of the drain protocol, and what the repairs cost

`codex exec -m gpt-daybreak-blue` reviewed `53e63dc..dd0e05a`, thirteen commits,
in a disposable clone at `dd0e05a0cfb4de64566c7dd4f73cf3516717d6d3`; the report
names that commit itself. The stage-one disposition record travelled with the
prompt as a statement of what was claimed rather than as findings to inherit, and
the brief required an independent reading of the corrected implementation.

Three findings, two P1 and one P2, each reproduced in that clone. All three are
defects the stage-one repairs introduced or left half-closed, which is where a
fix round puts them.

## Disposition

| Finding | Repair | The arm that decides it |
| --- | --- | --- |
| the retirement reads identity from the pathname while the admission path reads the descriptor, so a replacement put back before the reading restores a match over a live share on the armed inode | the retirement reads `qwen_barrier_descriptor_identity 9`, the description its drain was granted on | `test_a_pathname_restored_before_the_reading_is_still_refused` |
| emergency destruction runs as an unsupervised foreground command, so a signal releases the retirement reference with that child alive | the emergency child is supervised the way the orderly one is | `test_terminating_an_emergency_escalation_holds_its_references` |
| recovery samples the retirement reference and releases it before taking the in-flight one, so a retirement acquires it in between and recovery writes `running` over that quiescence | recovery holds the retirement reference across its whole operation | `test_recovery_holds_its_retirement_reference_across_the_write` |

Reverting each repair alone refuses exactly the arm that names it;
`stage-two-mutation-summary.tsv` retains that run.

The first two are the stage-one repairs applied to one path and not its twin:
descriptor identity reached admission and not retirement, and child supervision
reached orderly destruction and not the escalation. The third is a defect the
retirement reference itself introduced, since a reference that exists can be
sampled instead of held.

## Two arms widen a window rather than race it

The interleavings the first and third findings describe are microseconds wide,
and an arm that signalled or raced into them decided nothing. Both are widened
instead. The retirement's identity reading is timestamped through a fork of
`awk`, so a stub slow on its third call restores the armed pathname while the
reading is pending. Recovery takes both its references through `flock`, so a stub
slow on its second call holds recovery open while a retirement runs against it.
In each case the arm asserts an invariant rather than a timing: a restored
pathname buys no orderly verdict, and a retirement and a recovery never both
report success.

## What stage two executed

All four suites ran in that clone, including
`scripts/test-drain-client-attachment.py` with loopback socket access, which
stage one's sandbox refused. That closes the coverage gap stage one's record
named: both halves of the branch have now been read and executed by an
independent party.

## The gate was not hermetic against the barrier

The first full gate on the reviewed head refused at
`scripts/sidecar-mcp/test-sidecar-mcp.py`, five failures, all reporting `the
physics service refused the run: the admission barrier is closed: quiescing`.
The barrier's directory falls back to the serving state directory, and the three
sidecar suites isolated the compute lease while reading the live barrier, so any
session or probe that left `~/qwen-webui-state/admission.barrier` closed refused
the suites of a mechanism they never touched. A drain probe run without
`QWEN_GPU_ADMISSION_BARRIER` put it there.

The suites now isolate the barrier the way they already isolate the lease. The
reading that establishes it: with the live barrier deliberately set to
`quiescing`, `test-physics-service.py` and `test-sidecar-mcp.py` both pass, where
that same condition refused them before. Recovery ran through the controller's
own `resume` rather than by writing the state file, and the serving llama-server
answered `/health` 200 throughout -- it consults no barrier, since the lease
patch is a candidate and the promoted closure compiles none.

This is a defect the branch owns, because the branch is what made those services
consult a barrier at all.
