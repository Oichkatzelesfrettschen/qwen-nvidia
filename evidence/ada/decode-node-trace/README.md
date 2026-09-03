# Preregistration: where a decode token's time goes outside its kernels

`../ncu-decode-baseline/` measured the mat-vec kernels that move the weights at
the sustainable DRAM roofline -- 444.68 GB/s on the 2B's Q4_K launch against
the 442.61 GB/s an isolated bandwidth-bound kernel achieved on this device -- so
the per-token time those kernels do not account for lives in launch,
submission, and synchronization. That record named this arm as the one that
finds it and left it unrun. Nsight Compute cannot: it profiles one kernel at a
time and serializes what it replays, which is the opposite of a timeline.

## The budget being partitioned

Streamed bytes per token come from `gguf-tensor-census.py`, decode rate from
`scripts/models.tsv`, and the divisor is this device's own measured 442.61 GB/s
rather than the 504 GB/s theoretical:

| model | streamed bytes | tok/s | token ms | roofline ms | slack ms | slack |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| qwen35-08b | 800881920 | 310.50 | 3.221 | 1.809 | 1.411 | 43.8% |
| qwen38-2b-distill | 1263435008 | 231.37 | 4.322 | 2.855 | 1.468 | 34.0% |
| qwen38-4b-distill | 2697836544 | 113.54 | 8.807 | 6.095 | 2.712 | 30.8% |
| qwen38-9b-distill | 5046011904 | 67.91 | 14.725 | 11.401 | 3.325 | 22.6% |

The slack is roofline slack rather than measured overhead, and two of its
inputs are approximations: GGUF byte count omits activation, KV, and
temporary-buffer traffic and includes file material that never streams as
weights, and a memory transaction moves a cache line rather than the useful
payload. The column is a budget to explain, not a quantity to attribute.

What it does establish is a shape. The 0.8B and the 2B carry 1.411 and 1.468 ms
of slack for models differing by 58% in streamed bytes, which is what a fixed
per-token cost looks like; the 4B and 9B carry 2.712 and 3.325 ms, which is
not. This arm measures the terms rather than fitting that shape.

## Five terms, two decompositions

`read-nsys-decode-partition.py` computes, per token, over the interval between
consecutive `cudaGraphLaunch` calls:

```text
device_busy      union of kernel, memcpy, and memset intervals on the device
device_idle      span minus device_busy
api_host         union of CUDA runtime API intervals on the host
sync_host        the subset of api_host whose API name synchronizes
host_uncovered   span minus api_host, host work inside no CUDA call
```

`device_busy` and `device_idle` sum to the span, and `api_host` and
`host_uncovered` sum to it as well, so these are two views of one interval
rather than five addends. `sync_host` sits inside `api_host` and separates the
host waiting on the device from the host issuing to it. An interval union is
taken rather than a duration sum, because two overlapping kernels occupy one
stretch of wall time.

`host_uncovered` is where the sampler chain runs. `common_sampler_sample`
builds a `llama_token_data` per vocabulary entry and walks the configured
samplers, every one of which scans or partially sorts 248320 candidates
(`common/sampling.cpp:607-646`, `src/llama-sampler.cpp`), and none of that is
inside a CUDA call. The term therefore sizes #44 directly.

## The instrument is measured, not assumed

`nsys profile --help` states that node granularity "may cause significant
runtime overhead" while graph granularity "can reduce overhead to the minimal".
A device-idle figure read from a node capture alone cannot separate the gaps
the decode has from the gaps the instrument added, so each arm takes three
observations of one shape:

1. `untraced` -- llama-bench with no profiler, `-r 2`, the token time being
   explained.
2. `graph` -- the same capture at graph granularity. One device row per replay,
   so `device_busy` is the replay's whole device span including its internal
   gaps and `device_idle` is the time outside the graph alone.
3. `node` -- the same capture at node granularity. One device row per graph
   node, so `device_busy` is the sum of the nodes and `device_idle` gains the
   time inside the graph that no node occupies.

The difference between the two `device_idle` figures is the inter-node time,
which is what #43 targets. The difference between the two spans is what the
instrument cost, and it bounds how much of that inter-node time is real. A
validation capture on the 0.8B at 32 tokens already read a node-granularity
span of 3.865 ms against the 3.221 ms the registry serves, so the inflation is
around 20% and is not negligible against a 19.6% idle reading; that capture is
the reason this arm carries a control rather than a reason to trust it.

## What this decides, stated before it runs

- `host_uncovered` large: the host sampler chain is on the critical path and
  #44 is the target. Backend sampling already exists in this tree
  (`llm_graph_context::build_sampling`, `src/llama-graph.cpp:3711-3813`) behind
  `--backend-sampling`, so the remedy is a measurement rather than an
  implementation.
- `device_idle` at node granularity large and surviving the instrument bound:
  the graph's nodes do not fill the device timeline and #43 shape-bucketed
  prewarming and graph-node consolidation are the target.
- `sync_host` large with `device_busy` near the span: the host is correctly
  blocked on a device that is busy, the token is near its floor, and neither
  #43 nor #44 reaches it.
- `device_busy` near the span with `device_idle` small: the slack in the table
  above is an artifact of the byte count rather than a real gap, and the
  budget itself is what needs re-deriving.

## Falsifiers

The partition is arithmetic over a capture, so it cannot fail to produce
numbers; what it can do is produce numbers that do not describe the served
token. Three checks stand for that:

- The `graph` span must land near the untraced token time. A graph-granularity
  span far from it means the minimal instrument is not minimal here and no
  reading from either capture describes serving.
- The anchor count must equal the decoded token count less the leading tokens
  that ran before the graph was captured. The two-call warmup in
  `ggml_backend_cuda_graph_compute` means the first tokens of a run execute
  eagerly, and a partition that silently included them would mix two regimes.
- The kernel ring must carry the same signature count before and after, and the
  desktop client set must not change between arms.

## Order

The 2B distill leads as the primary performance target, the 0.8B follows as the
secondary fast target. Both run the promoted closure `88681bf4d161` with no
candidate patch, since the question is where a served token goes.

Nothing is measured yet.
