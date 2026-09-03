# The decode token is 91 to 94% device-busy, so the slack is not outside the kernels

The graph-granularity capture reproduces the served token time: 3.062 ms
against an untraced 3.066 ms on the 0.8B, a 0.1% difference, and 4.261 against
4.107 ms on the 2B, 3.7%. That agreement is what licenses reading the partition
as the served token rather than as the instrument, and it is the first of the
three preregistered falsifiers passing.

Medians over 60 partitioned tokens per arm, promoted closure `88681bf4d161`,
the same three desktop clients throughout, kernel ring at 44 signatures before
and after:

| term | 2B Q4_K_M | 0.8B Q8_0 |
| --- | ---: | ---: |
| span | 4.261 ms | 3.062 ms |
| device_busy | 93.8% | 90.6% |
| device_idle | 5.6% | 8.4% |
| idle between device rows | 2.1% | 3.3% |
| idle outside device work | 3.3% | 4.6% |
| api_host | 99.2% | 98.5% |
| sync_host | 95.5% | 92.0% |
| host_uncovered | 0.8% | 1.2% |

The host is inside a CUDA call for 98.5 to 99.2% of the token and blocked in a
synchronization for 92.0 to 95.5% of it. The device is executing for 90.6 to
93.8%. Both sides agree on the same picture: the host waits on a device that is
working.

## This refutes the budget that ordered the arm

The preregistration computed 34.0% and 43.8% of the 2B and 0.8B tokens as
roofline slack against GGUF streamed bytes at this device's measured 442.61
GB/s, and named launch, submission, and synchronization as where that slack
would be found. Non-kernel time is 5.6% and 8.4%. The slack is not there.

The GGUF-byte roofline is what fails. `streamed_bytes_per_token` counts weight
bytes, and the device spends its time on more than streaming weights: attention,
KV traffic, normalization, RoPE, and the small mat-vec launches
`../ncu-decode-baseline/` already measured at 39.5% and 69.7% of peak DRAM at
1.78 and 2.13 waves per multiprocessor. A model that divides weight bytes by
peak bandwidth predicts the time the weight-carrying kernels take and calls
everything else overhead, when everything else is other kernels.

The preregistration named this outcome and what it would mean: "device_busy near
the span with device_idle small: the slack in the table above is an artifact of
the byte count rather than a real gap, and the budget itself is what needs
re-deriving." That is the branch this arm took.

## What it decides for #43

Shape-bucketed graph prewarming has an upper bound of the idle outside the
submitted device work, 3.3% and 4.6%, and reaches even that only where a shape
changes. In steady-state batch-1 decode no shape changes at all: the capture
holds 60 `cudaGraphLaunch` calls against 2 `cudaStreamBeginCapture`, 2
`cudaGraphInstantiate`, and 2 `cudaGraphExecUpdate`, so one graph is captured
per llama-bench phase and replayed for every token after it.

The mechanism agrees. `ggml_cuda_graph_update_required` takes a fast path on
`cgraph->uid == graph->uid` (`ggml/src/ggml-cuda/ggml-cuda.cu:2593-2597`) that
skips the node-property scan entirely whenever llama.cpp reused its own
`ggml_cgraph`, and `llm_graph_params::allow_reuse` (`src/llama-graph.h:809-836`)
keeps that uid stable while token count, sequence counts, and output count hold
-- which is exactly steady-state single-sequence decode. The cache is keyed on
`cgraph->nodes[0]` (`ggml-cuda.cu:2581-2583`), one entry per CPU/GPU split
rather than per shape, so a shape change forces a recapture through the
two-call warmup gate at `ggml-cuda.cu:4266-4280` rather than finding a second
cached graph. That is the cost #43 would remove, and this arm measures the
regime where it is not paid.

**#43 is demoted.** It targets shape transitions, its ceiling in steady decode
is under 5%, and the arm that would justify it is a served workload with mixed
prefill and decode and several sequences rather than a batch-1 decode loop.

## What it does not decide, and why

`host_uncovered` is 0.8% and 1.2%, and that number does **not** bound #44.
`test_gen` in `tools/llama-bench/llama-bench.cpp:2143-2162` is the decode loop
this harness drives, and it runs `llama_decode`, `llama_synchronize`, and
`std::rand()`. It calls no sampler. The O(vocab) host chain that
`common_sampler_sample` walks in the server -- a `llama_token_data` per
vocabulary entry over 248320 entries, then penalties, top-k, top-p, min-p, and
temperature, each scanning or partially sorting that array
(`common/sampling.cpp:607-646`) -- is absent from every arm here.

What llama-bench does carry is the other half of #44's mechanism: `needs_raw_logits`
is true with no backend sampler armed, so `llama_context::decode` issues the
993280-byte device-to-host logits copy per token (`src/llama-context.cpp:1873`,
248320 floats), and that copy is inside the `device_busy` and `api_host` terms
above.

**#44 is undecided by this arm and needs the served path.** The measurement is
cheap because the mechanism already exists: this tree implements device-side
sampling as graph nodes -- `ggml_argmax`, `ggml_top_k`, and a
`ggml_soft_max`/`ggml_cumsum` inverse-CDF draw spliced in by
`llm_graph_context::build_sampling` (`src/llama-graph.cpp:3711-3813`) -- behind
`--backend-sampling`, which `QWEN_BACKEND_SAMPLING=1` already carries through
`qwen-capacity-policy.sh:1112`. The draft side already defaults it on
(`common/common.h:331`), so every MTP speculation arm this tree has run used it.

## The synthesis across three arms

`../mmq-fixup-pipeline/` found the stream-K fixup at 0.33 waves per
multiprocessor with its stall counter anti-correlating with duration.
`../ncu-decode-baseline/` found the mat-vec launches that fall short of the
roofline are the ones at 1.78 and 2.13 waves. This arm finds that only 5.6 to
8.4% of a token is outside the kernels at all.

One constraint recurs: launches too small to fill the device, inside a token
whose time is almost entirely device execution. The remaining levers are the
ones that make each launch do more -- fusion, activation reuse across the
projection fan-outs (#41), and batching the small launches -- rather than the
ones that reduce time between launches.

## Two harness defects this arm found and fixed

A first run read the graph-granularity arm as a 99% idle device. At graph
granularity the replay is recorded in `CUPTI_ACTIVITY_KIND_GRAPH_TRACE`, one row
per launch, and nothing for it lands in `CUPTI_ACTIVITY_KIND_KERNEL`, which the
reader was querying alone. `read-nsys-decode-partition.py` now reads both, so
one reader is correct at either granularity.

The same run read untraced rates 20% below the registry on both models, because
it took the median of llama-bench's reported `avg_ts` across repetitions. The
first timed run is cold even after llama-bench's own warm-up; the harness now
reads the warm `samples_ts` entry, and the corrected rates of 243.46 and 326.20
tok/s sit above the registry's 231.37 and 310.50 rather than below.

## What the node-granularity arm is worth

Its timing is not usable. The 0.8B node capture inflated the span to 7.433 ms
against a 3.066 ms untraced token, a factor of 2.4, which is `nsys profile
--help`'s "may cause significant runtime overhead" arriving in full on a small
model with many short nodes. The 2B inflated 17.2%. No idle figure from a node
capture is attributed here, and the preregistration's plan to read the
inter-node gap as the difference between the two granularities is abandoned for
that reason rather than reported.

The node capture's structure remains real: it is what shows the decode running
as a replayed graph and it is what the anchor count is read from. Its numbers
stay in `*-node-partition.tsv` labeled by the arm that produced them.
