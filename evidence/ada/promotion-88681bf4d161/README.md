# Promotion of configuration 88681bf4d161

The promoted tuple is the lean serving closure carrying the sixteen-column
Q8_0 extension: architecture 89-real (cuda_payload=verified cubin=187
ptx=0), CUDA backend alone, NCCL off, graphs on, all served
flash-attention quant pairs, VMM on, compression size, native host, LTO
off, and the AD104 MMVQ thresholds at ten for Q6_K and sixteen for Q8_0
through patches/llama-cuda-mmvq-crossover-ad104.patch at kernel ceiling
sixteen. ../mmvq-crossover-ad104/ carries the sweep that placed the Q8_0
floor: MMVQ ahead of stock MMQ dispatch by 8.3 to 19.6 percent at
thirteen through sixteen columns, every point past the 5.1% floor.

The CUDA-authoritative gate accepted the preset with strict_cuda=passed,
multimodal_cuda=passed, and fallback_vulkan=not-built, retaining
build-qwen-cuda-31d0775c5bc6 (Q8_0 at twelve) as the rollback target;
build-qwen-cuda-572951d25562 remains the PTX-bearing dual-backend
diagnostic closure. admit-cuda-router-serving.sh then passed nine of nine
checks on the promoted binary, both the 2B distill and the 0.8B answering
from CUDA0 with 5297 MiB resident and a clean teardown
(serving-summary.tsv).
