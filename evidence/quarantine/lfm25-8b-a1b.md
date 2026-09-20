# lfm25-8b-a1b

The appliance serves under LLAMA_NO_CPU_FALLBACK=1 with
--device CUDA0 --n-gpu-layers all --override-tensor '.*=CUDA0'. Under the
build promoted as qwen-cuda-15bc632adf7f this checkpoint aborted during
warmup at ggml-impl.h's GGML_ABORT("fatal error") inside ggml_hash_find,
reached from ggml_backend_sched_split_graph: the blanket override
materializes one buffer per tensor, the splits that produces push the graph
past llama_context::graph_max_nodes, and the scheduler's hash set overruns
with no size reported. Without the override the embedding lookup, GET_ROWS
on the token_embd node, landed on the host and the strict policy refused it,
so neither half of the placement admitted the architecture.

graph_max_nodes gave a named list of architectures 32 nodes per tensor and
everything else 8. This row fell in the default lane at 256 tensors and 2048
nodes, beside phi3 at 196 and 1568; granite at 362 and smollm3 at 326 loaded,
and qwen35 sits in the large lane at 441 tensors and 14112 nodes.

patches/llama-sched-graph-budget.patch raises the multiplier to 32 for
lfm2moe and phi3 alone, and the row loads and warms up under the unchanged
placement on the build that carries it. The device failure is resolved, so
the row leaves quarantine and returns to tier candidate.

What it does not do is call a tool. Given a forced record_symbols request
with a 2048-token cap it writes the entries as prose in message content and
the served template parses no call out of them, so it drops every target
across three files. That is a template property, not a device failure, and
it holds the row at standalone-only rather than in quarantine.

Recorded 2026-09-19, resolved 2026-09-20. The abort is in
evidence/ada/agent-model-roster/WAVE2.md and the recovery in
evidence/ada/agent-model-roster/WAVE2-REBUILD.md.
