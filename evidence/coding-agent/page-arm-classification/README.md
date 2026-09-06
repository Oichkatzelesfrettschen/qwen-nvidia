# What a refused coding-chain page arm says

Two refusals on the GitHub runner carried an empty detail. The arm reported
that it refused and named nothing a reader could act on, so the failure stayed
unclassified and the only way to learn more was to wait for another one. This
record is the instrumentation that replaces that wait, and it deliberately
changes no deadline: what exhausted the deadline is the open question, and
moving it would answer a different one.

## Where the detail went

`scripts/web-mcp/drive-fallback-page.py` catches its own exceptions, writes the
report to stdout carrying an `error` object, and returns 1. Its stderr holds a
traceback only for a death before that write, so the report is the authority
and stderr is the fallback. Reading the stderr tail alone therefore produced a
refusal whose detail was the empty string exactly when the driver worked as
designed.

The driver also knew how far it got and threw the knowledge away. Twelve
`wait_for` calls each carry a name and a budget -- `the page to load`, `the
page to select a model`, `the coding plan approval dialog`, `the turn to end`
-- and a `TimeoutError` named the seconds and the wait in a message string
rather than in a field. A page that never loaded and a page that loaded and
never proposed reached the same verdict.

## What the run now leaves behind

`wait_for` records each phase with its budget and its outcome over `started`,
`completed`, `timed_out`, and `raised`, and the report carries the timeline
beside `last_completed_phase`, `pending_phase`, and
`pending_phase_deadline_s`. The two failures above separate on
`last_completed_phase` alone: absent for a page that never loaded, and naming
the last wait that returned for a page that loaded and stalled later.

The pending phase follows the last wait rather than the last unfinished one,
because the driver recovers from some timeouts and continues: the image path
catches the artifact fetch and goes on to complete both review waits, and
naming that recovered timeout as pending would name a phase the run passed.
The timeline keeps every outcome, so the recovery stays readable in `phases`.

`scripts/classify-page-arm.sh` owns the reading. It takes the report, the
stderr file, the exit status, and the elapsed milliseconds, and prints a
termination reason, the exit status, the signal where one ended the process,
the elapsed time, the configured deadline of the pending phase, the last
completed phase, the pending phase, both file sizes, the error, and the stderr
tail. Every field carries a value, since a refusal with a blank right-hand side
is the defect this record exists to remove.

The classification lives outside the admission so it runs without a browser, a
router, a network, or the device. `scripts/test-coding-page-arm-classification.sh`
drives it through every terminal shape:

| Case | Termination reason | What separates it |
| --- | --- | --- |
| page never loads | `timeout` | `pending_phase=the page to load`, no completed phase |
| expected phase never arrives | `timeout` | a completed phase names how far it got |
| nonzero exit, empty stderr | `protocol_error` | the report is read at `stderr_bytes=0` |
| signal | `signal` | the status names it whether or not a report exists |
| report absent | `report_missing` | a death before the write |
| report truncated | `report_unreadable` | a death during the write |
| report parses, carries no error | `crash` | a death after the write |
| exit 0 | `completed` | a run that finished inside its deadline |
| phase name carrying a newline | `timeout` | the value is flattened, so eleven fields stay eleven lines |

Three arms hold the classifier's own boundaries: an argument count, a
non-numeric status, and an elapsed count carrying a newline each exit 2, and every case requires the classifier's stderr
to stay empty, since a shape it is built to name should not also reach the log
as an error. `scripts/test-drive-fallback-page-phases.py` drives `wait_for`
against a fake socket over eight arms: the four outcomes, the reset, a
recovered timeout that stops being pending once a later wait returns, a wait
whose socket answers falsely through every poll but the last its budget
allows -- `wait_for` sleeps half a second between polls, so a two-second
budget permits four -- and which therefore records `completed` on the boundary
with its elapsed time under the deadline, and a phase name carrying a
newline, since the driver builds one phase from its
`--model` argument rather than from a literal.

What no arm measures is a real deadline being exhausted. The boundary arm
proves that finishing against a budget classifies as a completion; which phase
exhausts a budget on the runner is what an instrumented occurrence has to say.

## What a real recurrence has to retain

The admission appends the repository commit and whether the tree was dirty, the
Chromium version, the kernel release, and the Python version to `page-arm.txt`,
so a refusal is triaged later against the stack that produced it rather than
against the stack the reader happens to have. A `git status` that cannot run
records `repository_dirty=unavailable` rather than `no`, since a probe that
produced no text and a tree that carries no change are different facts.

A successful rerun writes its own output directory and replaces neither the
failed record nor the stages it never reached. A rerun that passes establishes
no cause by itself: it establishes that the failure is intermittent, which is
the thing already known.

## What stays open

The intermittent itself. These fixtures make the next occurrence readable and
prove the reading against every shape it can take; they observe no occurrence.
The deadline stays where it is until an instrumented run says which phase
exhausted it and why.
