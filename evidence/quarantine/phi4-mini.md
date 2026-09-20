# phi4-mini

The appliance serves under LLAMA_NO_CPU_FALLBACK=1 with
--device CUDA0 --n-gpu-layers all --override-tensor '.*=CUDA0'. Under the
build promoted as qwen-cuda-15bc632adf7f this checkpoint aborted during
warmup at ggml-impl.h's GGML_ABORT("fatal error") inside ggml_hash_find,
reached from ggml_backend_sched_split_graph, and refused the placement
without the override because GET_ROWS on token_embd landed on the host.

llama_context::graph_max_nodes gave phi3 the default lane, 8 nodes per
tensor, which is 1568 nodes at 196 tensors. patches/llama-sched-graph-budget.patch
raises the multiplier to 32 for phi3 and lfm2moe alone, and the row loads
and warms up under the unchanged placement on the build that carries it.
The device failure is resolved, so the row leaves quarantine and returns to
tier candidate.

It then reads the source better than any row measured outside the Qwen
family: five of the six DiscoBSD contract questions pass, inventing no
identifier on any of them, against four for the incumbent. It calls no
tool. The GGUF's packaged chat template renders no tool_calls branch, the
server runs it under --jinja, and a forced record_symbols request comes back
as prose in message content, so the row drops every target across three
files. Microsoft documents a function-calling format for this checkpoint
that the packaged template omits; reaching it needs a per-row template
override the registry does not carry.

Recorded 2026-09-19, resolved 2026-09-20. The abort is in
evidence/ada/agent-model-roster/WAVE2.md and the recovery in
evidence/ada/agent-model-roster/WAVE2-REBUILD.md.
