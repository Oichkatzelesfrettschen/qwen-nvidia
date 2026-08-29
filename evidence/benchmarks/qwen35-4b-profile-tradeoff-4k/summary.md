# Serialized against Async Submission at 4K

## Scope

Both arms served the same 4,096 token prompt and 128 token decode from the same
Qwen3.5-4B Q4_K_M load at `--ctx-size 24576`, on loopback so no browser shared
the slot. The serialized figures are the 4,096 rung of
`qwen35-4b-depth-ladder-24k`. The only difference is the profile:
`low-serialized` exports `GGML_VK_SERIALIZE_SUBMISSIONS=1` with 32 nodes per
submission, so each submission waits for its predecessor to retire, while
`low-async` drops serialization and submits 16 nodes at a time.

## Throughput

| Profile | Prefill tok/s | Decode tok/s |
|---|---:|---:|
| `low-serialized` | 12.438 | 1.195 |
| `low-async` | 13.546 | 1.906 |

Dropping serialization raises decode 59.5% and prefill 8.9%. Decode gains most
because a decode step is a short graph whose submission latency, rather than
its arithmetic, sets the step time; waiting for each submission to retire adds
that latency to every token.

The earlier priority comparison measured 2.713 decode tok/s for the same async
profile against a 46-token prompt. That figure is not comparable to the 1.906
here: decode slows as the attention cache grows, and this arm decodes with 4,096
tokens resident.

## Desktop service

The MEDIUM graphics-family probe submitted every 16 ms in both arms.

| Measure | `low-serialized` | `low-async` |
|---|---:|---:|
| mean | 422 us | 2,212 us |
| p50 | 143 us | 173 us |
| p90 | 864 us | 7,456 us |
| p99 | 3,922 us | 21,130 us |
| p99.9 | 21,302 us | 22,857 us |
| max | 39,063 us | 39,187 us |
| within one 60 Hz frame | 99.47% | 95.48% |
| breach rate | 0.44% | 3.65% |

The medians are close, so an idle desktop feels the same under either profile.
The tail separates them: p90 rises 8.6 times and the share of submissions that
miss a 60 Hz frame rises from one in 190 to one in 22. A serialized submission
yields the queue at a known boundary after every 32 nodes, and an async one
leaves several submissions in flight for the desktop's work to queue behind.

## Decision

`low-serialized` remains the default because the deployment's stated priority
is desktop responsiveness ahead of inference throughput, and one dropped frame
in 22 is visible during interaction while one in 190 is not. `low-async` is
selected per session with `qwen-launch.sh low-async` and suits a laptop nobody
is sitting at, where 59.5% more decode is the only term that matters.

Peak junction temperature reached 85,125 millicelsius in the async arm against
89,500 in the serialized ladder; the async run is shorter, so the two are not a
thermal comparison. No kernel watcher matched a ring timeout, GPU reset, VM
fault, device loss, OOM, or oom-kill record in either arm.
