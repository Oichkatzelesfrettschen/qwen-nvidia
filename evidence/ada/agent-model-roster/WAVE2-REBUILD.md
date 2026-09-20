# The rebuild that admitted two wave-two rows, and the cost that made the
# first patch wrong

`lfm25-8b-a1b` and `phi4-mini` aborted during warmup under the appliance's
placement, `--device CUDA0 --n-gpu-layers all --override-tensor '.*=CUDA0'`
with `LLAMA_NO_CPU_FALLBACK=1`, at `ggml-impl.h`'s
`GGML_ABORT("fatal error")` inside `ggml_hash_find`. The cause is
`llama_context::graph_max_nodes`, which gives a named list of architectures
32 nodes per tensor and everything else 8. The blanket override materializes
one buffer per tensor; the splits that produces push the graph past the
budget, and the scheduler's hash set overruns with no size reported.

`patches/llama-sched-graph-budget.patch` now raises the multiplier to 32 for
`LLM_ARCH_PHI3` and `LLM_ARCH_LFM2MOE` alone. It joined the production
series, and both rows load and warm up under the unchanged placement on
`qwen-cuda-1f88e8fca5ef`.

## The first version of the patch cost 22 percent

The patch first raised the default lane for every architecture. That is the
change the diagnosis pointed at, and it is wrong, because `max_nodes` sizes
the scheduler hash set that `ggml_backend_sched_split_graph` clears on every
graph build -- once per decoded token. Quadrupling it quadruples that work.

Three readings per arm of the three-file summarize screen at
`max_tokens 2048`, one machine state, teardown between every launch:

| build | graph budget | qwen3-4b-instruct-2507 total | qwen38-4b-distill total |
| --- | --- | ---: | ---: |
| qwen-cuda-15bc632adf7f | upstream | 11161, 11161, 11797 | 13124, 12897 |
| qwen-cuda-efa48befa03b | 32 for every architecture | 13802, 13206, 13601 | 13278 |
| qwen-cuda-1f88e8fca5ef | 32 for phi3 and lfm2moe | 11455, 11430, 11156 | 13143, 12493 |

The split is the finding and it falsifies nothing else: `qwen3` sits in the
default lane, so the blanket change moved it and cost 2.4 s on three files;
`qwen35` was already in the 32 lane, so the same binary left the incumbent
where it was. The narrow patch returns `qwen3-4b-instruct-2507` to its
retained 11.492 s baseline and keeps both recovered rows.

## What the two recovered rows do once they serve

| row | screen s/file | tool probe | record_symbols | six contracts |
| --- | --- | ---: | ---: | ---: |
| lfm25-8b-a1b | 3.78 | no | 0/3 called | 0/6 |
| phi4-mini | 3.96 | no | 0/3 called | 5/6 |

`phi4-mini` reads this source better than anything measured outside the Qwen
family. It passes five of the six DiscoBSD contracts, inventing no
identifier on any of them, against four for the incumbent and six for
`qwen3-4b-instruct-2507`. It fails `swapram-exclusion`, where it names
neither `swapram` nor `exec_text_restore`.

Neither row calls a tool. `phi4-mini`'s packaged chat template renders no
`tool_calls` branch, which `admit-candidate-static.py` read from the GGUF
header before the download, and the server runs it under `--jinja`, so there
is no syntax to parse a call out of. Microsoft documents a function-calling
format for this checkpoint that the packaged template omits, and reaching it
needs a per-row template override the registry does not carry.

`lfm25-8b-a1b` is the more interesting failure, because its template does
render the branch. Given a forced `record_symbols` request with a 2048-token
cap it writes exactly the right entries -- correct ids, one-sentence
summaries, `crux_start`/`crux_end` -- as a JSON fragment in message content,
and the served template parses no call out of them. The 128-token cap in the
broad screen's `record_probe` is not the explanation: at 2048 it still does
not call.

So the cheap predictor holds in one direction only, which is how it was
stated. A GGUF whose template renders no `tool_calls` branch has never
completed a tool call: `hammer21-3b`, `lfm25-350m-qad`, `lfm25-12b-instruct`,
`smollm3-3b`, `phi4-mini`. A GGUF that renders one may still fail:
`swe-dev-7b`, `oxcoder-9b`, and now `lfm25-8b-a1b`.

## A registry defect the rebuild uncovered

The wave-two quarantine rows carried `cpu-fallback-refused` and
`no-tool-calls-branch` as failure classes. `model-registry.sh` holds a fixed
vocabulary and neither term is in it, so every read of the quarantine
registry came back invalid and `qwen-webui-session.sh` reported
`state=failed reason=server_policy_not_active` for every launch, including
the rows the bad rows said nothing about. The appliance served nothing
between that commit and this one.

The two device failures now carry `graph-assert-abort`, which is the term for
a rejected graph and was already in the vocabulary. The two template failures
leave `scripts/quarantine.tsv` entirely: a template failure carries no device
observation, and `hammer21-3b` is the precedent -- it is held out of the
picker by its tier and its `standalone-only` switch policy. Their records
stay under `evidence/quarantine/` as the evidence behind that tier.

Every quarantine check in `test-model-registry.sh` read a fixture, so the
vocabulary gate had never been pointed at the file the appliance loads.
`committed_quarantine_carries_only_vocabulary_classes` reads the committed
file and then the same file with one class rewritten. It accepts the repaired
registry and rejects the exact row that shipped.

## Build identities

`qwen-cuda-15bc632adf7f` is the retained rollback. Its source state is
preserved at `evidence/ada/llama-build-rollback/qwen-cuda-15bc632adf7f.source.diff`,
whose sha256 `76f4b8e888cde28f354482e4fea3d91e609ce634fb9d6654608b68f496a96768`
is the `source_diff_sha256` its own `build-configuration.tsv` records, so the
bundle is that build's input bit for bit.

`qwen-cuda-efa48befa03b` carries the blanket budget and is retained as the
measurement that rejected it. `qwen-cuda-1f88e8fca5ef` is promoted: CUDA
enabled, Vulkan disabled, no `libggml-vulkan.so` in the closure, strict CUDA0
placement and the projector admission both passed.

Recorded 2026-09-20.
