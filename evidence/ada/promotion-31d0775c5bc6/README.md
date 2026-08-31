# Promotion of configuration 31d0775c5bc6

The promoted tuple is the lean serving closure: architecture 89-real
(cuda_payload=verified cubin=187 ptx=0), CUDA backend alone, NCCL off,
graphs on, all served flash-attention quant pairs, VMM on, compression
size, native host, LTO off, and the AD104 MMVQ thresholds at ten for Q6_K
and twelve for Q8_0 through patches/llama-cuda-mmvq-crossover-ad104.patch.
The 89-real arm measured rate-identical to the PTX-bearing sibling and
removes about 26.7 MB of PTX payload a serving consumer on a fixed SM89
device never reads.

This is the first promotion through the CUDA-authoritative gate.
`promote-llama-build.sh` ran the strict one-token check and the multimodal
smoke on CUDA0 under LLAMA_NO_CPU_FALLBACK=1, detected the absent Vulkan
backend library, and reported `strict_cuda=passed multimodal_cuda=passed
fallback_vulkan=not-built`, then swung build-appliance-current to this
tree with build-qwen-cuda-572951d25562 retained as the rollback target.
That retained sibling remains the PTX-bearing dual-backend diagnostic
closure for CUDA/Vulkan comparison, PTX inspection, and driver-JIT arms.

`admit-cuda-router-serving.sh` then ran the assembled chain on the
promoted binary: nine checks, none rejected, a 23-row roster, both the 2B
distill and the 0.8B answering from CUDA0 with both resident at 5295 MiB
of device memory, and a clean teardown (serving-summary.tsv).
