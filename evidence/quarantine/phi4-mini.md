# phi4-mini

The appliance serves under LLAMA_NO_CPU_FALLBACK=1 with
--device CUDA0 --n-gpu-layers all --override-tensor '.*=CUDA0'. Under
that placement this checkpoint aborts during warmup at
ggml-impl.h's GGML_ABORT("fatal error") inside ggml_hash_find, reached
from ggml_backend_sched_split_graph: the blanket override materializes one
buffer per tensor, the splits that produces push the graph past
llama_context::graph_max_nodes, and the scheduler's hash set overruns with
no size reported. Without the override the embedding lookup, GET_ROWS on
the token_embd node, is placed on the host and the strict policy refuses
it, so neither half of the placement admits this architecture as the
build stands.

graph_max_nodes gives a named list of architectures 32 nodes per tensor
and everything else 8. This row falls in the default lane, and the
budget crossing is measurable: phi3 at 196 tensors and lfm2moe at 256
abort, granite at 362 and smollm3 at 326 do not, while qwen35 sits in the
large lane at 441 tensors and 14112 nodes.

patches/llama-sched-graph-budget.patch raises the default lane to 32 and
is registered as a candidate in verify-llama-patch-series.sh, where it
applies cleanly. It takes effect only through a rebuild and a fresh CUDA
admission, which is the same transaction the compute-lease rename waits
on. Until then this row stays quarantined on a build limit rather than on
anything the artifact does wrong.

Recorded 2026-09-19. The measurements are in
evidence/ada/agent-model-roster/WAVE2.md.
