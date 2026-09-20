# Wave two: four checkpoints fetched, two blocked by a build limit the
# rebuild removed, and the cheap predictor that saw the rest coming

Four candidates entered on 2026-09-19 after the header audit:
LFM2.5-8B-A1B at Q4_K_M, the mixture-of-experts Liquid with about one
billion active parameters; LFM2.5-1.2B-Instruct, the rung above the 350M
that had failed both gates; SmolLM3-3B; and Phi-4-mini-instruct. Osprey
was considered and dropped: its published checkpoints are a 7B
vision-language model with no GGUF conversion, so it is not a candidate
for this workload at all.

`admit-candidate-static.py` read each GGUF header over a range request
before any bytes were fetched:

| artifact | architecture | context | thinking | tool_calls branch |
| --- | --- | ---: | --- | --- |
| LFM2.5-8B-A1B-Q4_K_M | lfm2moe | 128000 | no | yes |
| LFM2.5-1.2B-Instruct-Q4_K_M | lfm2 | 128000 | no | no |
| SmolLM3-Q4_K_M | smollm3 | 65536 | yes | no |
| Phi-4-mini-instruct-Q4_K_M | phi3 | 131072 | no | no |

All four were fetched and verified in three and a half minutes, which is
what the scheduling purge bought: these download scripts used to run at
nice 19 pinned to one core in the idle I/O class.

## What happened

| row | launch | screen s/file | tool probe | record_symbols | six contracts |
| --- | --- | ---: | --- | ---: | ---: |
| lfm25-8b-a1b | refused | - | - | - | - |
| phi4-mini | refused | - | - | - | - |
| lfm25-12b-instruct | ok | 0.52 | no | 0/3 called | 1/6 |
| smollm3-3b | ok | 3.09 | no | 0/3 called | 3/6 |

### Two are refused by the CUDA-only contract, not by a defect

`lfm25-8b-a1b` and `phi4-mini` never reach a request. Both serve normally
when launched by hand; under the appliance's `LLAMA_NO_CPU_FALLBACK=1`
both fail identically at load:

```text
CPU fallback rejected for graph node embd (GET_ROWS)
tensor token_embd.weight selected CPU buffer CPU while LLAMA_NO_CPU_FALLBACK is enabled
```

Forcing every tensor onto the device the way the appliance does,
`--device CUDA0 --n-gpu-layers all --override-tensor '.*=CUDA0'`, does not
recover them. It aborts instead, with SIGABRT and no diagnostic:

```text
ggml/src/ggml-impl.h:318: fatal error
#6 ggml_backend_sched_split_graph
#8 llama_context::process_ubatch
```

That line is `GGML_ABORT("fatal error")` at the end of `ggml_hash_find`,
reached when the scheduler's hash set has been walked without a hit. The
blanket override materializes one buffer per tensor, the splits that
produces push the graph past the budget
`llama_context::graph_max_nodes` allocated, and the set overruns.

The budget is the whole story. `graph_max_nodes` gives a named list of
architectures `32 * n_tensors` and everything else `8 * n_tensors`, and
the models sort exactly along it:

| model | architecture | tensors | lane | budget | under full override |
| --- | --- | ---: | --- | ---: | --- |
| qwen38-4b-distill | qwen35 | 441 | large | 14112 | loads |
| granite40-micro | granite | 362 | default | 2896 | loads |
| smollm3-3b | smollm3 | 326 | default | 2608 | loads |
| lfm25-8b-a1b | lfm2moe | 256 | default | 2048 | aborts |
| phi4-mini | phi3 | 196 | default | 1568 | aborts |

The incumbent works because `qwen35` is one of the architectures upstream
already granted the larger budget. Nothing about the two that abort is
wrong with the artifact: both serve normally when launched by hand without
the override, and the graph they build under it is larger than the default
lane was sized for.

`patches/llama-sched-graph-budget.patch` raises the multiplier to 32 for
`phi3` and `lfm2moe`. The rebuild it needed has happened, both rows load
under the unchanged placement, and the quarantine is lifted:
`evidence/ada/agent-model-roster/WAVE2-REBUILD.md` carries the recovery.

The first version of that patch raised the default lane for every
architecture, which is the change this diagnosis points at and is wrong.
`max_nodes` sizes the scheduler hash set cleared on every graph build, once
per decoded token, so the blanket form cost `qwen3-4b-instruct-2507` 22
percent of its wall time. The rebuild record carries the three-way
measurement that rejected it.

The mixture-of-experts row was the architectural bet: eight billion
parameters with about one billion active, and the only one of the four
whose template renders a `tool_calls` branch. It serves now, and it still
never completes a tool call, which the rebuild record measures at a
2048-token cap.

### Two run and produce nothing graft can record

`lfm25-12b-instruct` is fast, 0.52 seconds per file, faster than the 350M
and faster than everything else measured. Its answers are 131 to 133
completion tokens, roughly 680 characters, and it answers one of six
contract questions. `smollm3-3b` at 3.09 seconds per file answers three of
six, the best of this wave.

Neither completes a forced tool call, and neither ever calls
`record_symbols`: nine files between them, zero calls, every target
dropped. They cannot drive graft's symbol pass whatever their prose looks
like.

## The predictor

A GGUF whose chat template renders no `tool_calls` branch has now failed
to complete a tool call in every case measured: `hammer21-3b`,
`lfm25-350m-qad`, `lfm25-12b-instruct`, `smollm3-3b` and, once the rebuild
let it serve, `phi4-mini`. The header read that establishes it costs a
range request and no download.

The converse does not hold. `swe-dev-7b`, `oxcoder-9b` and `lfm25-8b-a1b`
all render the branch and all failed the probe, so the template is
necessary and not sufficient. As a filter it is still worth running first: it rejected three
of this wave's four before any bytes moved, and would have rejected the
350M before the whole line of work that followed it.

The rule this leaves is narrow and cheap. Read the header; a row without
the branch does not proceed. A row with it still has to complete
`record_symbols` on real targets before any prose about it means
anything.
