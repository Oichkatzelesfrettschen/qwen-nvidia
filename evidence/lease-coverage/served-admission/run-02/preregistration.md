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
`text_arms_only_projector_none` from `projector_arm_not_run`, and reading the
second as the first would report a text-path result as an incomplete
multimodal one.

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
telemetry handoff at both ends: the 9B was stopped through its owning tmux
session against its recorded argv and restarted from it on the same closure at
6424 MiB, with the state latch clear and the owner lock free at both ends. The
compositor and two browsers were the only compute clients across the window.

## Arm G read both predictions

```text
qwen35-2b    ended 1s after the client left by=eintr attached_exit=no
qwen35-08b   ended 0s after the client left by=eintr attached_exit=no
```

`qwen35-2b/server.1.log` dates the whole sequence on the same process run-01
ended with `SIGKILL`. The decode pass's acquire waits 100 ms and returns
`reason=Interrupted system call`, `cleaning up before exit...` follows at
0.22.395, and then `cancel task, id_task = 17` at 0.27.294 -- 4.899 s later,
which is the five seconds the arm holds the client attached. The destructor
runs 0.9 ms after that cancel and writes
`vulkan workload lease teardown: held=no`. The shutdown that run-01 recorded as
outliving a 30 s bound completes here in under a millisecond once its client is
gone, on the same binary and the same arm, which is what
`../../shutdown-stall/` predicted and what the criterion change was for.

`arm_g.exit_with_client_attached` reads `no` in both timelines, so neither
server left inside the five seconds its client was attached. That is the
reading whose opposite would have sent the shutdown finding back for
re-examination.

## What the 0.8B's `partial` states

`scripts/models.tsv` declares `qwen35-08b` projector-none, so its six text arms
plus the armed-lease reading are the whole admission its tuple allows and
`text_arms_only_projector_none` is the reason that says so. No projector was
attached to it. The 2B's own `mmproj-Qwen3.5-2B-f16.gguf` would have loaded
cleanly at matching dimensions and written image tokens the 0.8B reads nothing
from, which answers wrongly rather than failing, so a green projector cell
there would have been the conflation the reason exists to prevent.

## What this lifts and what it leaves

`served=refused` is lifted: loading exclusion and evaluation exclusion are
measured on both model sizes, and the shutdown arm passes under a criterion
that holds llama.cpp's client-bounded shutdown constant. Promotion of
`15bc632adf7f` still needs the provenance gap in
`../candidate-build-source-identity.tsv` closed and the drain-before-destroy
policy tested, and the strict CUDA0 admission, the router admission, and the
serialized image review stay `not_run`, since this window was authorized for
the served stage.

The harness's own stdout carries the ownership block, which names each compute
client's full argv and cgroup; the caller retains it through a filter that
elides both, so a desktop browser's crash-reporter GUID and session identifiers
stay out of the record. The harness elides its own mktemp directory from every
byte it retains, which run-01 needed by hand.
