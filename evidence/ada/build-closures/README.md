# The three build closures and the 89-real admission

`scripts/build-llama-cuda.sh` names every lever and folds the tuple into a
configuration digest that names the build tree. Three closures exist:

The frozen comparison control is the unsuffixed-89, CUDA-plus-Vulkan,
NCCL-linked tree behind every retained baseline and calibration figure. It
stays as built and is reproduced by `QWEN_CUDA_ARCHITECTURES=89
QWEN_BUILD_VULKAN=ON QWEN_CUDA_NCCL=ON`.

The CUDA-only production candidate is configuration 844181cfaedc: 89-real,
Vulkan off, NCCL off, graphs on, flash attention with all served quant pairs,
VMM on, compression size, native host, LTO off, MMVQ thresholds at the
upstream eight. cuobjdump reads 187 sm_89 cubins from its libggml-cuda.so and
answers "No PTX file found", where the frozen control lists one PTX per
cubin, so the unsuffixed spelling was carrying compute_89 PTX no JIT on this
one-device fleet consumes; the library drops from 84.0 to 57.4 MB on that
removal alone with the kernel inventory unchanged. The 2B serve spot-check
reads 15142 prefill and 229.8 decode against the registered 14748 and 231.4,
inside the drift floor, so the SASS path is rate-identical as the spelling
change predicts.

The CUDA-plus-Vulkan diagnostic closure is one `QWEN_BUILD_VULKAN=ON` away
and owns backend A/B, fallback, and driver-recovery work; the launch
authority promotes a closure by its exact configuration digest, so a
diagnostic tree cannot stand in for the production candidate silently.

Promotion of 844181cfaedc into scripts/ serving waits on the one-variable
ladder: compression size against speed against none, LTO with the CUDA-LTO
inspection, lazy against eager module loading, and the strict placement,
teardown, and mixed-roster admission the promotion contract requires.
