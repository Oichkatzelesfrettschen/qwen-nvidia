# Stage-one review of the drain protocol, and what each finding cost

`codex exec -m gpt-6-astra -c model_reasoning_effort=low` reviewed
`53e63dc..894a89e`, twelve commits, in a disposable clone at
`894a89e3411419a6f81fe5959458bb1e881caba3`; the report names that commit itself.
The reviewer ran the suites and reproduced each defect in that clone, and the
authoring checkout was untouched throughout. Eight findings, six of them P1, and
every one is accepted: each names a verdict or a release that a concurrent event
invalidates, which is the class this branch exists to close.

## Disposition

| Finding | Repair | The arm that decides it | Reverting the repair |
| --- | --- | --- | --- |
| the handler is installed after the spawn, so a signal in that interval ends the admitter with its job alive | the handler precedes the spawn and is correct with `job_pid` unset | `test_a_signal_inside_the_spawn_window_still_holds_the_share` | refused |
| a retirement writes `running` after releasing its references, so a second retirement's quiescence is overwritten | the state word is written while both references are still held | none; the retirement reference closes the interleaving first | see below |
| recovery reads the in-flight reference alone, so it reopens admission during an emergency destruction that holds none | a retirement holds a second reference for its whole lifetime, and `resume` reads it | `test_recovery_is_refused_while_an_emergency_destruction_runs` | refused |
| the destroy child is unsupervised, so a signal releases the exclusive reference under a live teardown | the destroy child is supervised the way the admitted job is | `test_terminating_a_retirement_holds_its_references_until_the_child_leaves` | refused |
| admission verifies the pathname and then locks a descriptor it never checks | the identity is read from the acquired descriptor, after the lock, in both the Python and the shell participant | `test_a_replacement_between_the_check_and_the_open_is_refused` | refused |
| a detected identity mismatch still runs the destroy command and reports afterwards | a mismatch refuses destruction before invocation | `test_an_identity_mismatch_refuses_destruction_rather_than_reporting_it` | refused |
| a destroy printing both teardown markers is read as held | a contradiction is read before either single marker and establishes nothing | `test_a_contradictory_teardown_report_establishes_nothing` | refused |
| the merged mutation summary is absent from the evidence manifest | the manifest is refreshed after staging rather than before | `refresh-evidence-manifest.sh --check`, in the gate | refused |

Six of the seven code repairs are refused by exactly the arm that names them
when that repair alone is reverted. The two entries that read differently read
so for stated reasons rather than by omission.

## The second finding is closed by the reference, not by the ordering

The interleaving the second finding describes needs two retirements running at
once, and the retirement reference the third finding's repair introduces refuses
the second retirement outright at exit 75. Reverting the ordering alone
therefore changes nothing observable, and no arm discriminates it. Three arms
settle which change carries the closure:

```text
as merged                            accepted
ordering reverted, reference kept    accepted
ordering reverted, reference removed refused
```

The ordering change is retained as a second barrier rather than as the one that
holds: a retirement that writes the state word while it still owns both
references cannot be overtaken whatever else changes around it. It is recorded
here as unexercised rather than counted among the arms.

## What the review could not execute

The reviewer's sandbox refused socket creation, so all three arms in
`scripts/test-drain-client-attachment.py` failed at setup and its
completed-request and unanswered-request readings are INSPECTED in that report
rather than executed. Those three arms pass in the authoring checkout, where the
stand-in binds a loopback socket, so the gap is the review's rather than the
suite's; stage two needs socket access for that half of the coverage to be read
by a second party.

## The manifest finding is a procedure defect

`refresh-evidence-manifest.sh` enumerates tracked files, so a refresh that runs
before `git add` skips a new evidence file and the manifest ships stale. That is
what happened to `merged-mutation-summary.tsv`, and the quality gate would have
refused the merged tree for it. The order is staging first, refresh second,
commit third.
