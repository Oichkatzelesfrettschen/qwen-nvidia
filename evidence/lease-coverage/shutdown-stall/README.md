# What ends a llama-server shutdown that a request is still inside

`evidence/lease-coverage/served-admission/` refused candidate closure
`15bc632adf7f` on one reading: a terminating signal delivered while a decode
pass waited on a lease another process held left the server alive past a 30 s
bound and it ended on `SIGKILL`. That record states two shutdown outcomes and
names no cause. This probe names one.

## What the source says before the device runs

Three facts read out of the pinned tree at `f280b2698` set the hypotheses.

`server.cpp:488-492` makes the signal handler call `ctx_server.terminate()`,
which unblocks `start_loop()`; `:531` then runs `clean_up()`, whose non-router
form at `:450-458` stops the stream session manager, calls `ctx_http.stop()`,
terminates the task queue, shuts the MCP manager down, and calls
`llama_backend_free()`. `:534` joins the HTTP thread afterwards, and
`~server_context_impl` -- where the lease patch writes its
`teardown: held=` line -- runs after that join. The failing log carries the
`cleaning up before exit...` line and no teardown line, so the process had not
reached the destructor.

`server-context.cpp:4555` serves a non-streamed completion through
`server_response_reader::wait_for_all(req.should_stop)`, and
`server-http.cpp:642` binds `should_stop` to httplib's `is_connection_closed`.
`server-queue.cpp:550-575` polls `recv_with_timeout` at
`HTTP_POLLING_SECONDS`, which `server-context.cpp:49` sets to 1, and returns
only when a result arrives or the client has gone. A request whose task never
completes therefore holds its HTTP worker until its own client disconnects,
and cpp-httplib's listener joins its workers before `ctx_http.thread` returns.

The lease patch's decode-path acquire returns false on `EINTR` and
`update_slots` leaves before posting `NEXT_RESPONSE`, so the task the pass
launched is never answered. That is how the failing arm reaches a request in
flight with no result coming.

## The two hypotheses

```text
H1  the HTTP join waits on a worker inside wait_for_all, so the shutdown ends
    when that request's client disconnects and the lease is incidental
H2  the shutdown stalls inside CUDA teardown under lease contention, so it
    ends when the holder releases and the client is incidental
```

`clean_up()` calls `llama_backend_free()` ahead of the join, so both sit on the
path and the record cannot pick between them by reading the log.

## The arms, and what each outcome means

Every arm launches its own server, so no arm reads a process another arm
perturbed. `client_timeout_s` is an instrument rather than a setting: an arm
asking whether the server outlives a bound gives the client a timeout past the
whole observation, and an arm asking what a departing client does uses the
timeout itself as the departure.

| Arm | Setup | H1 predicts | H2 predicts |
| --- | --- | --- | --- |
| `no_intervention` | candidate, holder holds, client times out at 20 s, signal, observe 90 s untouched | exits about 1 s after the client's own timeout | stays alive |
| `client_disconnect` | candidate, holder holds, client at 600 s, signal, hold 30 s, then end the client | exits within about 1 s of the disconnect | no effect |
| `holder_release` | candidate, holder holds, client at 600 s, signal, hold 30 s, then release the holder | no effect | exits |
| `promoted_in_flight` | promoted `88681bf4d161`, no lease named, a 2048-token generation decoding, signal, hold 30 s, then end the client | outlives the bound and exits on the disconnect | n/a: no lease exists to contend |
| `candidate_in_flight` | candidate, lease armed and free, the same generation decoding, signal, hold 30 s, then end the client | the same as `promoted_in_flight` | n/a |
| `stack` | candidate, the `client_disconnect` setup, one all-thread stack at 10 s and no timing read | a worker in `recv_with_timeout` and the main thread in a join | a thread inside CUDA teardown |

`promoted_in_flight` is what decides whose property the stall is. The promoted
closure reads no lease name, so it cannot reproduce a lease wait; what it can
reproduce is a request in flight when the signal arrives. A promoted closure
that also outlives the bound puts the stall on llama.cpp's shutdown, which
production already carries, and makes the refused arm's pass criterion wrong
rather than the closure wrong. A promoted closure that exits promptly puts the
stall on the patch.

The stack arm runs as its own repetition because `eu-stack` stops the target,
which contaminates any latency measured afterwards in the same process.

## Falsifiers

An exit latency after disconnect far from the 1 s polling interval weakens H1
whatever its direction. `no_intervention` exiting at a time unrelated to the
client's timeout weakens H1 the same way. Both interventions ending the
shutdown, or neither, refutes the 2x2 and leaves a third mechanism to name.

## What a confirmed H1 does not settle

It requalifies one arm and moves no gate. `server_response::terminate()` has no
caller anywhere in `tools/server/`, which is a separate latent fact about the
blocking `recv(int)` path rather than about this client-bounded poll, and
fusing the two would report an unbounded hang where the measurement shows a
client-bounded one. The patch's non-`EINTR` `flock` failure path returns false
the same way with the server still running, which is reachable and unobserved.
Promotion of the lease closure still requires the provenance gap of
`candidate-build-source-identity.tsv` closed and the drain-before-destroy
policy tested, and neither is in this probe.
