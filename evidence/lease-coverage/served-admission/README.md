# The served lease arms on the candidate closure

`scripts/test-load-lease-coverage.sh` drove closure `15bc632adf7f` against a
held compute lease on the RTX 4070 Ti. Nine of ten readings pass and one fails,
so the stage reads `served=refused` and the closure is not promoted.
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

## What the arms read

| Arm | Reading |
| --- | --- |
| `lease_armed` | the closure opened the lease, so every arm below is read against a binary carrying the patch |
| `load_after_wait` | the load waited 8810 ms behind the holder, then loaded on CUDA0 and answered |
| `load_after_wait_releases` | the idle server returned the lease at `idle_ms=0` |
| `decode_waits` | no decode inside the hold, with the decode pass's own wait line counted |
| `decode_resumes_on_release` | the waiting request completed 300 ms after the release, with no second request |
| `shutdown_while_decode_waits` | fail: the server outlived a 30 s bound and ended on `SIGKILL` |
| `refused_on_deadline` | the load named its deadline and reached no loader line |
| `recovery_after_refusal` | a fresh attempt loaded and answered |
| `shutdown_while_load_waits` | ended in 1 s by default disposition, the holder's lock intact |
| `projector_load` | the projector-bearing load waited, loaded, and answered |

Loading exclusion and evaluation exclusion are measured here rather than
claimed: a load behind a holder waits and then serves, and a decode pass behind
a holder submits nothing until the release, with the pass's own wait line as the
positive evidence that the lease is what it waited on.

## The failure, and what the record does and does not establish

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

What consumes the interval after `cleaning up before exit` is likewise
unresolved. The log carries no lease line inside it, and `SIGKILL` discards
whatever the logger had not flushed, so an absent line is not evidence that the
code failed to reach it.

Three arms narrow it, and each is weaker than a proof:

- Repeat the arm with the holder releasing after the signal, requiring the log
  to show the interrupted return before the release. A shutdown that then
  completes implicates the contended lease; without that ordering check the
  acquire may simply have succeeded, and the arm measures nothing.
- Repeat it by hand against the promoted closure `88681bf4d161`. It reads no
  lease name and cannot reproduce a lease wait, so a slow shutdown there shows
  that this server can stall under a signal without the patch. It does not
  identify the candidate's stall.
- Read every thread's stack at ten seconds. That names where the process sat in
  one sample, which locates the wait without establishing that it is permanent
  or that it is the cause.

## What this costs the program

Promotion is refused. The teardown this arm exercises is the combined session's
own shape -- a session teardown arriving while an image generation holds the
lease -- so the combined-session campaign stays blocked behind this reading
rather than behind promotion alone. The contended-teardown exception
`evidence/lease-coverage/README.md` records is a claim about what `destroy()`
frees; this is a separate reading about whether the process completes a shutdown
under contention, and the two are recorded apart.

The candidate closure's other properties stand as
`candidate-build-source-identity.tsv` states them, provenance gap included. No
production pointer moved and the promoted closure served nothing during the
window.

The 2B harness ran its remaining arms after the failure, since the arms are
independent and each takes and releases its own fixture; what stopped is the
downstream chain, so the `qwen35-08b` arms, the strict CUDA0 admission, the
router admission, and the serialized image review read `not_run` rather than
continuing into an unsettled device state.

`window-open.log` records the state latch clear and the compute clients reduced
to the three desktop processes after the telemetry stop; the owner lock's
availability at that point is evidenced by the harness acquiring it, recorded on
the `gpu_ownership_lock=held` line of `qwen35-2b.log`, rather than by a separate
reading. `window-close.log` records the latch clear and the owner lock free, and
carries two device readings of the restarted telemetry server: 5558 MiB taken
while it was still loading, and 6424 MiB taken after `/health` returned `ok`.
The pre-stop figure is not in a retained artifact of this run.
