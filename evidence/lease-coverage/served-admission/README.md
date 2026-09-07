# The served lease arms on the candidate closure

`scripts/test-load-lease-coverage.sh` drove closure `15bc632adf7f` against a
held compute lease on the RTX 4070 Ti across two runs.

`run-02/` is the stage's standing result: `qwen35-2b` reads
`served=accepted projector=required` on ten readings with its own pinned
projector attached, and `qwen35-08b` reads
`served=partial ... served_reason=text_arms_only_projector_none` on the nine its
projector-none tuple allows. Loading exclusion and evaluation exclusion are
measured on both model sizes, and `run-02/preregistration.md` states what each
terminal line had to be before the run and what arm G predicted.

`run-01/` is the earlier run under the criterion since requalified. Nine of its
ten readings pass and the tenth fails, so it reads `served=refused`;
`../shutdown-stall/` measured the promoted closure -- which compiles in no lease
at all -- holding the same interval between the same two log boundaries and
leaving it at its client's departure, so that arm read a bound a lease-free
binary reaches rather than lease exclusion. Its terminal result stands as the
run produced it, and `run-02/qwen35-2b/server.1.log` carries the same arm on the
same binary reaching `teardown: held=no` 426 microseconds after the cancel its
client's departure triggers. That interval spans those two log boundaries alone:
it marks the destructor's entry into its lease handling while the device
synchronize and the frees follow, the departure itself carries no microsecond
timestamp, and the `0s` and `1s` the arms report are the harness's own
whole-second readings of process absence.
`run-01/qwen35-2b/` carries the record: one sanitized server log per launch,
every completion body the arms graded, one outcome row per decision, the
termination timeline, the teardown state read out of each log, and the
harness's own exit status.

The window ran on the workstation with the desktop resident, which is a
covariate of every duration below rather than a condition excluded from it. The
9B telemetry server on port 18086 was stopped through its owning tmux session
after its recorded argv was compared against the live process and its slots read
idle, and it was restarted from that same argv afterwards.
`run-01/window-preconditions.tsv`, `window-open.log`, and `window-close.log`
carry what each end retained; `run-01/stage-status.tsv` carries the per-stage
result.

## What run-01's arms read

| Arm | Reading |
| --- | --- |
| `lease_armed` | the closure opened the lease, so every arm below is read against a binary carrying the patch |
| `load_after_wait` | the load waited 8810 ms behind the holder, then loaded on CUDA0 and answered |
| `load_after_wait_releases` | the idle server returned the lease at `idle_ms=0` |
| `decode_waits` | no decode inside the hold, with the decode pass's own wait line counted |
| `decode_resumes_on_release` | the waiting request completed 300 ms after the release, with no second request |
| `shutdown_while_decode_waits` | fail under the criterion this run applied: the server outlived a 30 s bound with its client still attached and ended on `SIGKILL`. `../shutdown-stall/` names that bound as llama.cpp's own and the criterion is requalified |
| `refused_on_deadline` | the load named its deadline and reached no loader line |
| `recovery_after_refusal` | a fresh attempt loaded and answered |
| `shutdown_while_load_waits` | ended in 1 s by default disposition, the holder's lock intact |
| `projector_load` | the projector-bearing load waited, loaded, and answered |

Loading exclusion and evaluation exclusion are measured here rather than
claimed: a load behind a holder waits and then serves, and a decode pass behind
a holder submits nothing until the release, with the pass's own wait line as the
positive evidence that the lease is what it waited on.

## Run-01's failure, and what that record does and does not establish

Under a terminating signal the decode pass's blocking acquire returned without
the lease and named `reason=Interrupted system call`, and the server then wrote
`cleaning up before exit...`. It wrote nothing further, remained alive past the
30 s bound, reported `Received second interrupt, terminating immediately` when
the escalation's second `SIGTERM` arrived, and ended on `SIGKILL`. The interval
between the acquire's `waiting` line and its interrupted return is 101 ms; that
is the acquisition wait's own duration, and the record carries no
signal-delivery timestamp, so it bounds rather than measures the response to the
signal.

The same binary shutting down with the lease free wrote its whole sequence --
`cleaning up before exit`, `acquired ... waited_ms=0 bound=deadline`,
`teardown: held=yes`, `released` -- across a logged interval of 44 ms from the
cleanup line to the release line. That is arm D's server, and the timeline
records its termination at whole-second resolution rather than proving process
exit at that instant.

The two shutdowns differ in more than the lease. Arm D's server had completed
and released its request before cleanup began; the failing server was cleaning
up with a request interrupted mid-acquisition, so request state, interruption
path, and execution history differ alongside whether another process held the
lease. The record establishes two shutdown outcomes and does not establish which
difference causes them.

What consumes the interval after `cleaning up before exit` is resolved, and
`../shutdown-stall/` carries the resolution. The process sits in
`ctx_http.thread.join()` while cpp-httplib's listener joins its workers and one
worker waits inside `server_response::recv_with_timeout` for a result of the
task the interrupted pass launched and never answered; a completion's wait ends
at `is_connection_closed`, so the shutdown ends at the client's own departure.
The promoted closure `88681bf4d161`, which compiles in no lease at all, holds
the same join for 30.9 s with a generation in flight and leaves it 1.34 s after
its client departs. Releasing the holder moves nothing. The candidate's
teardown is reached rather than skipped: once the client leaves, the same
sequence writes `teardown: held=no` and the destructor completes.

This arm's client ran a 90 s timeout against a 30 s bound, so the `SIGKILL`
arrived with 60 s of that timeout left. The criterion is therefore what was
wrong rather than the closure: it read llama.cpp's shutdown with a client
attached and called it lease exclusion. The unconditional expectation it
encoded -- that a signal ends the process inside a bound whatever requests are
attached -- was never a validated property of the pinned server. The arm now
ends its client before it reads the bound, which holds that server property
constant, and records the interval with the client attached as an observation.

What run-02 accepts is bounded by the client rather than by the signal:

> After the attached client departs, the candidate completes the tested
> interrupted-decode shutdown within the declared bound.

The lease patch keeps its contribution under that reading. Its interrupted
acquire returns before `update_slots` posts `NEXT_RESPONSE`, which is how a task
reaches the join unanswered; the production control establishes that the
resulting shutdown behavior exists without the patch, and establishes neither
that every interruption path is equivalent nor that an unanswered task is
harmless. The control contributed matching timing and a matching log signature,
and the one thread sample came from the candidate, so no stack was taken from
the production arm.

## What the two runs cost the program

`run-02` lifts `served=refused` and no gate moves with it. The policy
`evidence/lease-coverage/README.md` records has an orderly session teardown
drain the active holder before destroying an idle child, so an ordinary
combined-session teardown is uncontended by construction and run-01's failing
arm never reproduced its shape; what that arm reaches is the
emergency-termination exception the policy reserves. Promotion still requires
the remainder of the replacement route -- the lease-off companion built and the
lease change isolated against it -- and the drain-before-destroy policy tested,
and the strict CUDA0 admission, the router admission, and the serialized image
review read `not_run` in both runs.

The candidate closure's other properties stand as
`candidate-build-source-identity.tsv` states them. `../source-provenance/`
resolved the source question after these runs:
`historical_source_reconstruction=unavailable` beside
`replacement_source_provenance=verified` and
`historical_binary_regression=required`, so the historical source is closed as
unrecoverable rather than outstanding while the companion's own build stays
open. No production pointer moved and the promoted closure served nothing
during the window.

Run-01's 2B harness ran its remaining arms after the failure, since the arms
are independent and each takes and releases its own fixture; what stopped there
is the downstream chain, so its `qwen35-08b` arms read `not_run` rather than
continuing into an unsettled device state. `run-02` ran that subject and
`run-02/stage-status.tsv` carries both.

Run-01's `window-open.log` records the state latch clear and the compute clients
reduced to the three desktop processes after the telemetry stop; the owner lock's
availability at that point is evidenced by the harness acquiring it, recorded on
the `gpu_ownership_lock=held` line of `qwen35-2b.log`, rather than by a separate
reading. `window-close.log` records the latch clear and the owner lock free, and
carries two device readings of the restarted telemetry server: 5558 MiB taken
while it was still loading, and 6424 MiB taken after `/health` returned `ok`.
The pre-stop figure is not in a retained artifact of this run.
