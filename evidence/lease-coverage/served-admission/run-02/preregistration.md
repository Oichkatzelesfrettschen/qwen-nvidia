# What this run is asked, before it runs

`run-01/` refused candidate closure `15bc632adf7f` on `shutdown_while_decode_waits`,
and `../../shutdown-stall/` named the bound that arm read as llama.cpp's own:
the promoted closure, which compiles in no lease at all, holds the same interval
and leaves it at its client's departure. The arm now ends its client before it
reads the bound. This run reads the served stage again under that criterion, on
the two model sizes the registry declares and in the order the campaign fixes.

## The arms and what each terminal line has to be

| Subject | Arms | Required terminal line |
| --- | --- | --- |
| `qwen35-2b` | seven, its own pinned projector attached | `served=accepted projector=required` |
| `qwen35-08b` | six, no projector attached | `served=partial ... served_reason=text_arms_only_projector_none` |

`scripts/models.tsv` declares `qwen35-2b` projector-required and `qwen35-08b`
projector-none, so the 0.8B's six text arms are the whole admission its tuple
allows and `partial` is that row's correct outcome rather than a failure. The
2B's projector is `mmproj-Qwen3.5-2B-f16.gguf` from its own directory, and no
projector is attached to the 0.8B: a foreign projector of matching dimensions
loads cleanly and writes image tokens the language model reads nothing from, so
attaching one to make a cell green would answer wrongly rather than fail.
`QWEN_LEASE_PROJECTOR_POLICY=none` on the 0.8B is what separates
`text_arms_only_projector_none` from `projector_arm_not_run`. Reading the
second as the first is the dangerous direction: it would dress an incomplete
multimodal admission, a projector-required row handed none, as a row that
intentionally serves text only.

Each subject writes its own evidence directory, so no run reads a log another
run left.

## What arm G predicts

Two readings, stated ahead of the run because the shutdown record is what they
test:

```text
attached_exit=no      the server survives the five seconds its client is attached
ended 0s or 1s        it leaves inside a second or two of the departure
```

`attached_exit=yes` on the device contradicts
`evidence/lease-coverage/shutdown-stall/`, where five arms and one thread sample
put the shutdown inside a join released by the client's departure. That outcome
would send the finding back for re-examination rather than the arm.

## What a clean run licenses

It lifts `served=refused` and nothing else. The provenance gap in
`../candidate-build-source-identity.tsv` stands, the drain-before-destroy policy
is untested, and the strict CUDA0 admission, the router admission, and the
serialized image review stay `not_run`: this window was authorized for the
served stage.

## What ran

Both terminal lines are the ones the table above required.

| Subject | Terminal line | Readings |
| --- | --- | --- |
| `qwen35-2b` | `load_lease_coverage=accepted reach=accepted served=accepted projector=required` | ten, none refused |
| `qwen35-08b` | `load_lease_coverage=partial reach=accepted served=partial projector=none served_reason=text_arms_only_projector_none` | nine, none refused, the projector arm `not_run` by declaration |

`qwen35-2b/` and `qwen35-08b/` each carry their own server logs, completion
bodies, outcome rows, timeline, teardown states, and exit status, and neither
directory holds a byte the other run wrote. `stage-status.tsv` carries the
per-stage result and `window-open.log` and `window-close.log` carry the
telemetry handoff at both ends.

What those two logs establish about the handoff is narrower than the operation
performed. `window-preconditions.tsv` records the 9B's pid, executable, start
time, argv, working directory, health, and device bytes while it served;
`window-open.log` records `telemetry_stop=absent`, which is the process's
disappearance rather than a transcript of the interrupt sent into its owning
tmux session; and `window-close.log` records the restarted server's executable
and argv, which match the recorded ones, at 6424 MiB with `/health` reading
`ok`. The state latch is clear and the owner lock free at both ends.

The compute-client lists are four snapshots rather than a continuous sample,
and none of them precedes the stop: `window-open.log` lists the three desktop
clients after the telemetry server is gone, each harness's own ownership
acquisition lists them again in `qwen35-2b.log` and `qwen35-08b.log`, and
`window-close.log` lists them beside the restarted 9B. Between those points the
campaign's own servers ran and nothing else was sampled.

## Arm G read both predictions

```text
qwen35-2b    ended 1s after the client left by=eintr attached_exit=no
qwen35-08b   ended 0s after the client left by=eintr attached_exit=no
```

`qwen35-2b/server.1.log` dates the whole sequence on the same arm and binary
run-01 ended with `SIGKILL`. The decode pass's acquire waits 100 ms and returns
`reason=Interrupted system call`, `cleaning up before exit...` follows at
0.22.395.713, and `cancel task, id_task = 17` lands at 0.27.294.285 --
4.899 s later, which is the five seconds the arm holds the client attached.
`vulkan workload lease teardown: held=no` follows that cancel by 426
microseconds.

That line marks the destructor's entry into its lease handling rather than the
end of the shutdown: the device synchronize and the frees follow it, and the
client's departure carries no microsecond timestamp of its own, so what the log
times is the interval between two of its own boundaries. The process's own
disappearance is the harness's reading, `ended 1s after the client left`, at
whole-second resolution. Both say the same thing at different precisions: the
shutdown run-01 recorded as outliving a 30 s bound proceeds here as soon as its
client is gone, which is what `../../shutdown-stall/` predicted and what the
criterion change was for.

`arm_g.exit_with_client_attached` reads `no` in both timelines, so neither
server left inside the five seconds its client was attached. That is the
reading whose opposite would have sent the shutdown finding back for
re-examination.

## What the 0.8B's `partial` states

`scripts/models.tsv` declares `qwen35-08b` projector-none, so its six text arms
plus the armed-lease reading are the whole admission its tuple allows and
`text_arms_only_projector_none` is the reason that says so. No projector was
attached to it, and this run measured nothing about what would have happened if
one had been: the reason a foreign projector is refused is the pairing rule
`scripts/select-projector.sh` implements, where a projector of matching
dimensions loads cleanly while writing image tokens into an embedding space its
own model did not export, so the mismatch answers rather than fails. This run's
contribution is that the arm was declared unrun rather than filled.

## What this lifts and what it leaves

`served=refused` is lifted: loading exclusion and evaluation exclusion are
measured on both model sizes, and the shutdown arm passes under a criterion
that holds llama.cpp's client-bounded shutdown constant. Promotion of
`15bc632adf7f` still needs the provenance gap in
`../candidate-build-source-identity.tsv` closed and the drain-before-destroy
policy tested, and the strict CUDA0 admission, the router admission, and the
serialized image review stay `not_run`, since this window was authorized for
the served stage.

The harness's own stdout carries the ownership block, whose `name=` field is
nvidia-smi's `process_name` column; for the desktop browsers that column carries
their whole command line, and their cgroup follows it. The caller retains the
block through a filter that elides both tails, so a crash-reporter GUID and a
session identifier stay out of the record while the pid, executable, memory,
start time, and verdict that make up the ownership identity remain. The harness elides its own mktemp directory from every
byte it retains, which run-01 needed by hand.
