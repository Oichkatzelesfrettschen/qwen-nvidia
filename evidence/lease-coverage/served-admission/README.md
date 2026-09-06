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
idle, and it was restored from that same argv afterwards to the same 6424 MiB it
held before. `run-01/window-preconditions.tsv`, `window-open.log`, and
`window-close.log` carry both ends.

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

## The failure, and where its mechanism stops being established

The decode pass's interruption works exactly as the patch designs it. Under a
terminating signal the blocking acquire returns in 101 ms and the server writes
`wait ended without the lease ... reason=Interrupted system call`, then
`cleaning up before exit...`. It writes nothing further, remains alive past the
30 s bound, reports `Received second interrupt, terminating immediately` when
the escalation's second `SIGTERM` arrives, and ends on `SIGKILL`.

The same binary shutting down with the lease free finishes in 44 ms and writes
the whole sequence: `cleaning up before exit`, `acquired ... waited_ms=0
bound=deadline`, `teardown: held=yes`, `released`. That is arm D's server, and
it is the control that isolates the condition: the one state that differs at
shutdown is whether another process holds the lease.

What consumes the interval after `cleaning up before exit` is unresolved. The
log carries no lease line inside it, and `SIGKILL` discards whatever the logger
had not flushed, so an absent line is not evidence that the code failed to reach
it. Three arms would close it, in increasing cost: repeat the arm with the
holder releasing at the instant of the signal, which attributes the stall to the
contended lease if the shutdown then completes; repeat it by hand against the
promoted closure `88681bf4d161`, which reads no lease name, so a slow shutdown
there attributes the stall to the server rather than to the patch; and read the
stack of the stuck process at ten seconds, which names the blocking call
directly. None has run.

## What this costs the program

Promotion is refused. The teardown this arm exercises is the combined session's
own shape -- a session teardown arriving while an image generation holds the
lease -- so the combined-session campaign stays blocked behind this reading
rather than behind promotion alone. The contended-teardown exception
`evidence/lease-coverage/README.md` records is a claim about what `destroy()`
frees; this is a separate reading about whether the process reaches `destroy()`
at all under contention, and the two are recorded apart.

The candidate closure's other properties stand as
`candidate-build-source-identity.tsv` states them, provenance gap included. No
production pointer moved, the promoted closure served nothing during the window,
and the `qwen35-08b` arms, the strict CUDA0 admission, the router admission, and
the serialized image review read `not_run` because the chain stopped on this
failure rather than continuing into an unsettled device state. The state latch
read clear and the owner lock read free at both ends.
