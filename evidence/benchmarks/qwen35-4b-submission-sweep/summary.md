# Submission Settings Against a Chat Request

## Scope

Each arm loaded the model once, served one chat-shaped request from a client on
another machine, and was torn down, so its graphics-latency samples belong to
exactly one configuration. The request is a 45-token question with a 128-token
answer and `cache_prompt: false`, which is the shape a person typing into the
page produces rather than the long-prefill shape the depth ladder measures.
`custom` profile; `observe` latency mode; context 24,576.

## Results

| Arm | Serialize | Nodes | Graphics queue | TTFT s | Decode tok/s | Prefill tok/s | probe p90 us | Frames inside 60 Hz | Breaches |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| serialized-32 | yes | 32 | no | 4.013 | 1.348 | 12.033 | 846 | 99.97% | 1 |
| serialized-128 | yes | 128 | no | 4.044 | 1.392 | 12.054 | 933 | 100.00% | 0 |
| serialized-512 | yes | 512 | no | 4.010 | 1.396 | 12.054 | 905 | 100.00% | 0 |
| async-16 | no | 16 | no | 4.267 | 2.718 | 14.612 | 1,086 | 100.00% | 0 |
| async-128 | no | 128 | no | 3.795 | 2.587 | 14.191 | 1,379 | 99.88% | 2 |
| serialized-128-gfx | yes | 128 | yes | 3.928 | 2.376 | 12.383 | 20,998 | 66.00% | 346 |

## Findings

Submission size is not the bottleneck. Raising nodes per submission from 32 to
512 moves decode from 1.348 to 1.396 tok/s, a 3.5% change against a 16-fold
change in the setting. The hypothesis that per-submission fence latency
dominated decode is falsified.

Serialization is the whole cost. Dropping it raises decode from 1.348 to 2.718
tok/s, a 102% gain, and prefill from 12.033 to 14.612 tok/s. Waiting for each
submission to retire, rather than the size of those submissions, is what halves
decode.

Async submission does not cost desktop service under a chat request. The
async-16 arm recorded zero deadline breaches and placed 100.00% of probe
submissions inside one 60 Hz frame, matching the serialized arms. This
contradicts the depth-ladder comparison, where async raised p90 from 864 to
7,456 us: that arm prefilled 4,096 tokens, and a long prefill submits large
sustained graphs, while chat decode submits short graphs that leave the queue
free between tokens. The profile's latency cost is therefore a property of the
workload, not of the profile.

Placing inference on the graphics family is rejected on both terms. It gives up
desktop service outright, with p90 at 20,998 us, 346 breaches, and only 66.00%
of frames served on time, and it is slower than async on the compute family at
2.376 against 2.718 decode tok/s. The queue-family selection ggml already
performs, which avoids the graphics family, is confirmed correct.

Time to first token holds near 4 s across every arm because it is set by
prefilling a 45-token prompt at 12 to 14.6 tok/s, not by the submission policy.
Lowering it requires raising prefill throughput or reusing a cached prefix, not
retuning submissions.

## Decision

`low-async` becomes the default for interactive serving: it doubles decode and
raises prefill 21% while leaving desktop service indistinguishable from the
serialized arms under chat. `low-serialized` is retained for sustained
long-context prefill, where the ladder measured async raising p90 8.6-fold.
