# Nanbeige4.2-3B: the loop costs what the parameter count saves

`Nanbeige/Nanbeige4.2-3B` is a looped transformer: `config.json` declares
`num_hidden_layers: 22` with `num_loops: 2` and `tie_word_embeddings: false`.
`src/models/nanbeige.cpp` in the pinned tree reads `{arch}.num_loops`, sets
`hparams.n_layer_all = n_layer_phys * n_loops`, and comments that it shares the
physical weights across loops while each slot keeps its own KV index. Decode
therefore runs 44 layers per token over 22 layers' worth of weights.

Parameter count falls and per-token weight traffic does not. A loop saves
weights, and this appliance has 29 GiB of DDR4 against a 2.6 GB checkpoint, so
capacity is the axis it has slack on. Bandwidth is the axis it is starved on,
and a 1.87 GB working set cannot stay in 4 MB of L3 between iterations, so the
second loop re-reads every layer from DRAM.

## The census, from a range request

`remote/gguf-tensor-census.py` parses the header and index, so the first 48 MiB
of the file answers the admission question without the weights.
`Abiray/Nanbeige4.2-3B-GGUF` at revision
`774a61f8217ad18e7e102107fb7abcfecfae6a99`, `Nanbeige4.2-3B-Q4_K_M.gguf`,
2,574,807,986 bytes,
`18a659d0c1744e5bd2f4b8da55e0dcabf42ec7f005b74ec8eb66593b3380f958`:

```text
architecture             nanbeige
block_count              22
num_loops                2
skip_loop_final_norm     False
embeddings_tied          false
token_embd               287,096,832   Q4_K, lookup only
output.weight            418,682,880   Q6_K, streamed once
looped_layer_bytes     1,865,048,064   streamed once per loop
```

The conversion is community-produced and this tree cannot reproduce it:
`convert_hf_to_gguf.py` at the pinned commit carries no Nanbeige class, while
`gguf-py` carries the `NUM_LOOPS` and `SKIP_LOOP_FINAL_NORM` writer keys and
`src/` carries the runtime. That gap is a hazard rather than a blocker, and it
is the first thing the census checked. `nanbeige.cpp` reads the loop count with
`ml.get_key(LLM_KV_NUM_LOOPS, n_loops_u, false)`, a non-required lookup that
defaults to 1, so a converter predating loop support would produce a file that
loads cleanly and runs 22 layers instead of 44 -- answering wrongly rather than
failing, which is the same failure this repository documents for a mismatched
projector. This file carries `num_loops = 2`, so that hazard is refuted here and
stays a standing check for any other looped conversion.

## Prediction, recorded before the run

Per-token traffic is the looped layers twice plus the logit projection once:

```text
2 x 1,865,048,064 + 418,682,880 = 4,148,803,584 bytes = 4.149 GB
```

Against the 8.28 to 8.88 GB/s band the two 32-layer Qwen3.5-architecture
checkpoints measured on this machine, that predicts **2.00 to 2.14 decode
tok/s**, and 44 effective layers argue for the lower end because per-layer cost
grows with depth.

| Checkpoint | streamed/token | decode tok/s |
| --- | ---: | ---: |
| Qwen3.8-2B distill | 1.263 GB | 9.46 measured |
| Qwen3.8-4B distill | 2.698 GB | 3.07 measured |
| **Nanbeige4.2-3B Q4_K_M** | **4.149 GB** | **2.00 to 2.14 predicted** |
| Qwen3.8-9B distill | 5.046 GB | 1.76 measured |

A 4.2B checkpoint therefore lands between the 4B and the 9B rather than near the
2B, and below the 4B it is nominally smaller than. Q6_K at 3.42 GB would
predict roughly 1.6 tok/s.

**Falsification criterion:** a measured decode above 2.5 tok/s refutes the model
that the second loop re-streams from DRAM, and would mean either that the
backend retains the layer weights across iterations or that the loop is elided.
A measurement inside 2.00 to 2.14 confirms it. Below 2.00 indicates depth cost
beyond the 32-layer band, which is a quantitative correction rather than a
refutation.

## The loop doubles the KV cache, and the architecture is dense

Weight traffic is half the account. `nanbeige.cpp` comments that each loop slot
keeps its own KV index, so the cache is sized for 44 layers, and Nanbeige is
dense full attention: every one of those 44 holds a key-value cache. The
Qwen3.5-architecture checkpoints are 3:1 hybrids where only the full-attention
layers do, six of the 2B's 24 and eight of the 32 in the 4B and 9B, with the
rest holding recurrent state instead.

`qwen-capacity-policy.sh` sets `--cache-type-k q8_0` and `--cache-type-v q4_0`,
which is 34 and 18 bytes per 32 elements. That gives
`layers x kv_heads x head_dim x (34+18)/32` bytes per token, and the formula
reproduces the served logs exactly:

| Checkpoint | KV layers | bytes/token | KV at 24576 | measured |
| --- | ---: | ---: | ---: | --- |
| Qwen3.8-2B distill | 6 of 24 | 4,992 | 117.0 MiB | 117.00 MiB |
| Qwen3.8-4B distill | 8 of 32 | 13,312 | 312.0 MiB | 312.00 MiB |
| Qwen3.8-9B distill | 8 of 32 | 13,312 | 312.0 MiB | 312.00 MiB |
| Nanbeige4.2-3B | 44 of 44 | 73,216 | 1716.0 MiB | derived |

Two measured rows fix the formula, so the Nanbeige row is derived rather than
estimated: 1716 MiB against the 4B's 312, 5.5 times the footprint at the same
context.

The consequence for throughput is larger than the footprint. Attention reads the
whole cache every token, so the context tax scales with the same factor:

| Context | 4B and 9B | Nanbeige4.2-3B |
| ---: | ---: | ---: |
| 4,096 | 54.5 MB/token | 299.9 MB/token |
| 16,384 | 218.1 MB/token | 1199.6 MB/token |
| 24,576 | 327.2 MB/token | 1799.4 MB/token |

`llama-bench tg64` measures decode against a near-empty cache, so the 2.00 to
2.14 tok/s prediction is the optimistic end and applies to the first tokens of a
conversation. At 4K of context Nanbeige adds 0.30 GB per token to a 4.15 GB
weight stream, a 7% cost, while the 4B adds 0.05 GB to 2.70 GB, a 2% cost. The
gap widens with depth in a way it does not for the incumbents, which is the
opposite of what an agent workload wants: repository and terminal work is
long-context by nature.

`model-memory-preflight.sh` reports headroom and admits every launch, so the
resident total of roughly 2.4 GB of weights plus 1.7 GB of cache is read from
its report rather than predicted here.

## Why the published evidence does not transfer

The Artificial Analysis mobile study that places Nanbeige4.2-3B at the top of
its 16K bracket ran on phone-class silicon with unified memory an order of
magnitude faster than 38.4 GB/s nominal and with a system-level cache large
enough to change the loop's cost. A loop is close to free where bandwidth is
abundant and arithmetic is the constraint. This machine is the opposite case,
so the ranking inverts rather than transfers.

The same study's second finding transfers directly and points the same way:
Nanbeige's score fell from 63 to 18 under a one-minute output budget because
its reasoning traces did not finish. This appliance already measured that
failure on the Qwen3.5-4B base, which produced an empty answer at the 2048-token
cap, and it decodes several times slower than the phones tested.

## Measured: the mechanism holds and the rate does not

`llama-bench` on the appliance, full Vulkan offload, two threads, `nice 19` with
idle I/O, phases split, three repetitions:

```text
| nanbeige ?B Q4_K - Medium | 2.39 GiB | 4.17 B | Vulkan | 99 | tg64  |  2.38 +/- 0.00 |
| nanbeige ?B Q4_K - Medium | 2.39 GiB | 4.17 B | Vulkan | 99 | pp512 | 14.06 +/- 0.00 |
```

The reported 4.17 B matches the parameter count derived from `config.json`,
4,169,662,464, so the loader and the census agree on what the file holds.

Decode measures 2.38 against a predicted 2.00 to 2.14. The falsification
criterion was 2.5, so the re-streaming model stands and the band was too
pessimistic by 11 to 19%. The band, not the mechanism, was the error: it assumed
this checkpoint would achieve the 8.28 to 8.88 GB/s the two 32-layer
Qwen3.5-architecture checkpoints reach, and 4.149 GB at 2.38 tok/s is 9.87 GB/s.

That the loop re-streams is settled by the same measurement read the other way.
Were the second pass served from cache, per-token traffic would be 2.284 GB and
the achieved rate 5.44 GB/s, which is below every checkpoint measured on this
hardware and below the 8.28 GB/s floor of the pair nearest in size. The
alternative reading requires the machine to have become 40% worse at streaming
for this file alone.

| Checkpoint | streamed/token | decode tok/s | GB/s | architecture |
| --- | ---: | ---: | ---: | --- |
| Qwen3.8-2B distill | 1.263 GB | 9.46 | 11.95 | hybrid 3:1, 24 layers |
| **Nanbeige4.2-3B** | **4.149 GB** | **2.38** | **9.87** | dense, 22 layers x 2 loops |
| Qwen3.8-9B distill | 5.046 GB | 1.76 | 8.88 | hybrid 3:1, 32 layers |
| Qwen3.8-4B distill | 2.698 GB | 3.07 | 8.28 | hybrid 3:1, 32 layers |

Nanbeige achieves a higher rate than either 32-layer hybrid while running 44
effective layers, which a simple depth-cost account does not predict. One
mechanism fits and is untested: the loop re-runs the same 22 layers with the
same pipelines, descriptor sets, and dispatch shapes, so the second pass repeats
work the driver has already set up, and dispatch overhead falls where memory
traffic does not. A per-operator capture separates that from the alternative,
that dense attention and feed-forward simply stream better than the hybrid's
recurrent-state operators.

Prefill measures 14.06 tok/s. The loop doubles compute as well, giving 6.808 B
effective parameters and 6.97 TFLOP for 512 tokens, so 36.4 seconds is 191.4
GFLOP/s, 68% of the 281.6 GFLOP/s heuristic against the 2B's 79% and the 4B's
72%. Prefill is therefore ordinary for this machine and the loop is paid in
full on both halves.

## Verdict

The checkpoint is admitted and it is not the resident model for this appliance.
It is slower than the Qwen3.8-4B distill on both halves, 2.38 against 3.07 and
14.06 against 23.48, while being nominally smaller, and it is four times slower
than the 2B. Its KV cache is 5.5 times the 4B's at the same context and its
context tax grows with the same factor, so the gap widens exactly where an agent
workload lives.

The loop is a good trade on hardware with bandwidth to spare and memory to save.
This machine has 29 GiB of DDR4 and 38.4 GB/s nominal, which is the other case.

## What still has to be measured

Quality is untested. `remote/compare-model-candidate.sh` and
`remote/reasoning-span-probe.sh` are the suite that separates checkpoints here,
and the loop argument says nothing about whether the model answers correctly. A
checkpoint that answers better at 2.38 tok/s remains a legitimate choice for
work that is not interactive: the measurement sets the price, not the verdict.
The published agent-benchmark evidence that prompted the test is the reason to
run that suite rather than to skip it.

## Depth prediction, recorded before the ladder ran

Nanbeige holds 22 physical layers run twice, and every one of the 44 effective
slots keeps its own KV index, against 8 full-attention layers in the 32-layer
Qwen hybrid. Derived from two served logs, its cache costs 5.5 times the 4B
distill's per token of context. Decode is bandwidth-bound in the depth term:
each token attends over the whole cache, so the added per-token traffic is
proportional to cache size and Nanbeige should lose decode about 5.5 times as
fast per token of depth as the 4B.

Expressed as the fraction of shallow decode retained at a given depth, with the
4B measured alongside as the control that makes the ratio a comparison rather
than an assertion, the prediction is that

    (1 - retained_nanbeige) / (1 - retained_qwen4b)

lands near 5.5 at both 4096 and 16384. The falsifier is a ratio below 3 or above
9 at either depth: below 3 refutes the claim that slot count sets the depth cost
and points at cache layout or attention kernel instead, and above 9 refutes
proportionality and says the deeper cache costs superlinearly.

The row measures `llama-bench` at `-ngl 99 -t 2 -r 3 -p 0 -n 64` over depths 0,
4096, and 16384, which is f16 KV with flash attention off. The served path
quantizes both caches with `--cache-type-k q8_0 --cache-type-v q4_0` and enables
flash attention, so this ladder supports the relative claim between two models
given identical treatment and supports no statement about served depth. A
CPU-buffer fallback at 16384 would read as degradation, so the loader's
allocation lines are checked before the ratio is computed.

## The 4096 rung confirms the prediction; the 16384 rung wedged the GPU

`llama-bench -ngl 99 -t 2 -r 3 -p 0 -n 64`, f16 KV, flash attention off, both
models in the same invocation pair.

| depth | Nanbeige tok/s | retained | Qwen3.8-4B tok/s | retained |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 2.38 | 1.0000 | 3.31 | 1.0000 |
| 4096 | 1.86 | 0.7815 | 3.12 | 0.9426 |
| 16384 | device wedged | - | 2.69 | 0.8127 |

At 4096 the loss ratio is 0.2185 against 0.0574, which is 3.81. The prediction
was 5.5 with a falsifier below 3 or above 9, so it stands and the centre was 31%
too pessimistic. Slot count sets the direction and the magnitude within a factor
of one and a half; it is not the whole depth cost.

The 16384 rung is a result rather than a gap. `llama-bench` aborted with
`vk::Queue::submit: ErrorDeviceLost` after RADV reported the context lost, and
the kernel names the cause:

```
amdgpu 0000:04:00.0: ring comp_1.2.0 timeout, signaled seq=1051998, emitted seq=1052000
amdgpu 0000:04:00.0:  Process llama-bench pid <pid> thread llama-bench pid <pid>
amdgpu 0000:04:00.0: Starting comp_1.2.0 ring reset
amdgpu 0000:04:00.0: Ring comp_1.2.0 reset succeeded
amdgpu 0000:04:00.0: [drm] device wedged, but recovered through reset
```

At 16384 with f16 KV and flash attention off, the Nanbeige decode graph caused
a compute-ring submission to fail to retire before the amdgpu timeout. The
driver reset the ring successfully and the subsequent Qwen control passed. The
exact kernel-level cause remains unisolated: the kernel record establishes that
a submission on `comp_1.2.0` did not retire, and it separates none of a
legitimately overlong kernel, a dependency or synchronization deadlock, an
amdgpu or RADV defect, a shader compiler defect, and a malformed or
pathologically inefficient dispatch. Naming the attention pass over 44 KV slots
of f16 cache as the submission is the obvious candidate and it is untested; a
`GGML_VK_PERF_LOGGER` capture or a bisected depth ladder between 4096 and 16384
would tell which dispatch grows and whether the growth is continuous.

That fixes the registry ceiling by measurement. `remote/models.tsv` carried
16384 for this checkpoint on scaled arithmetic, and 16384 is the depth that
wedged the device under f16 KV. The served path quantizes both caches, which
cuts that traffic by about 2.4 times and may well complete, but a ceiling
admitted on an untested margin above a measured hang is the wrong default for a
research row. The ceiling drops to the 8192 interactive default until a served
allocation at a greater depth is measured.

The comparison the ladder supports is between two models under identical
treatment. It says nothing about served depth, where `--cache-type-k q8_0
--cache-type-v q4_0` and flash attention change both the traffic and the kernel.
The 4B's own shallow rate marks the size of the unexplained gap rather than its
cause: 3.31 tok/s here against 3.07 through the served path, a 7.2% difference
across four simultaneous changes -- llama-bench against a served request, f16
against q8_0/q4_0, flash attention off against on, and a different prompt and
timing instrumentation. At zero depth the cache holds almost nothing, so
assigning that difference to cache quantization is the least likely of the four.
`evidence/kv-cache-policy-factorial.md` separates them.
