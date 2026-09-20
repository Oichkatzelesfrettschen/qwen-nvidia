# Promotion of configuration de074f9738b8

The serving closure carrying `patches/llama-sched-graph-budget.patch`, which
raises the nodes-per-tensor multiplier to 32 for `LLM_ARCH_PHI3` and
`LLM_ARCH_LFM2MOE` so both load under the appliance's
`--device CUDA0 --n-gpu-layers all --override-tensor '.*=CUDA0'` with
`LLAMA_NO_CPU_FALLBACK=1`.

Built at `QWEN_CUDA_ARCHITECTURES=89-real`, the local-serving arm:
`cuda_payload=verified arch=89-real cubin=187 ptx=0`. Two closures built
before this one, `efa48befa03b` and `1f88e8fca5ef`, took the builder's bare
default of `89` and carry 187 PTX images beside their cubins. Neither is the
documented serving arm and neither is promoted; they are retained as the
measurement that rejected the blanket graph budget and as the first narrow
build.

`promotion.log` carries the gate: `strict_cuda=passed multimodal_cuda=passed
backend_set=cuda`, so one token decoded entirely on CUDA0 and the projector
admission read an image before the symlink moved.

`build-configuration.tsv` is the digest's own input record and
`artifact-manifest.tsv` the closure hashes promotion re-verified.
`build-payload.txt` is the architecture verdict.

Both rows the budget had blocked, `lfm25-8b-a1b` and `phi4-mini`, load and
warm up on this closure under the unchanged placement.

Recorded 2026-09-20.
