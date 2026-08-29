# Qwen3.5-4B Prefill Depth Ladder to 24K

## Scope

One `low-serialized` model load served all four rungs, so per-rung timings
differ by prompt depth alone rather than by allocation or warm-up state. The
server ran Qwen3.5-4B Q4_K_M at `--ctx-size 24576` with strict `Vulkan0` tensor
placement, one slot, one CPU thread, Q8 K and Q4 V cache, Flash Attention, and
`cache_prompt: false` on every request. The listener bound `0.0.0.0:8080` behind
the generated API key. The client posted exact-token prompts built from
`benchmarks/corpora/multidomain-long-context.txt` on CPU 0 at nice 19, and each
prompt carried a retrieval key planted near its start.

The graphics-family probe ran in `observe` mode. The run predates deployment of
the temperature change, so the abort at 90,000 millicelsius was still armed.

## Results

| Prompt depth | Prefill tok/s | Decode tok/s | Retrieval |
|---:|---:|---:|---|
| 4,096 | 12.438 | 1.195 | correct |
| 8,192 | 10.767 | 1.199 | correct |
| 16,384 | 11.347 | 1.120 | correct |
| 24,000 | 9.979 | 1.052 | correct |

Every rung returned `violet compass at archive shelf 42`, the value paired with
`ORBITAL-CEDAR-7319` near the beginning of the corpus, so the model read across
the full prompt at each depth rather than answering from its tail. Server-side
timings match the client: the 16,384 rung logged `prompt eval time = 1443850.59
ms / 16384 tokens` and `eval time = 113369.14 ms / 128 tokens`, reproducing
11.35 and 1.12 tok/s.

Prefill does not fall monotonically with depth. The 16,384 rung ran faster than
the 8,192 rung, which places run-to-run variance above the depth effect across
the 8K to 16K interval. One sample per rung cannot separate the two, so these
are four measured points rather than a fitted curve. Decode declines gently,
from 1.195 tok/s at 4K to 1.052 tok/s at 24K, consistent with attention over a
longer cache.

## Desktop service under load

The independent MEDIUM graphics-family queue submitted every 16 ms for the whole
run while inference held the GPU at 89% mean busy and the top DPM level.

| Percentile | Fence service |
|---|---:|
| p50 | 143 us |
| p90 | 864 us |
| p99 | 3,922 us |
| p99.9 | 21,302 us |
| p99.99 | 22,882 us |
| max | 39,063 us |

Mean service was 422 us across 320,648 samples, and 99.47% of submissions
completed inside one 60 Hz frame. LOW global priority therefore yields the GPU
to desktop-class work as intended.

The same distribution measures why the terminating guard was replaced. p99.9
exceeds the 20,000 us deadline, placing that deadline near the 99.56th
percentile: the 1,407 recorded breaches are one per 228 samples, or one every
3.6 seconds of sustained load. A guard that stops the server on the first late
frame ends any run of this length within seconds and returns no throughput at
all, which is what `observe` mode exists to avoid.

## Retained state

No kernel watcher matched a ring timeout, GPU reset, VM fault, device loss, OOM,
or oom-kill record. Peak junction temperature reached 89,500 millicelsius
against the 90,000 millicelsius abort still armed for this run; 500
millicelsius separated a completed ladder from a discarded one, and that margin
is what moved temperature to a reported observation.

`graphics-latency-breaches.log` retains the probe banner, the terminating
record, and all 1,407 breach lines. The full 322,057-line sample stream stays on
the laptop at 24,408,137 bytes, sha256
`4ab033952083bb0f694dd2fd019fff3adad54a018ec6059303551316c1e4cf9a`; the
percentiles above are computed from that file. `api.key` and `server.pid` are
excluded.
