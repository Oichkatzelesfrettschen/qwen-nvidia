# The PTX-bearing default and the 89-real compact closure

`scripts/build-llama-cuda.sh` names every lever and folds the tuple into a
configuration digest that names the build tree. Four build roles remain
distinct:

The frozen comparison control is the unsuffixed-89, CUDA-plus-Vulkan,
NCCL-linked tree behind every retained baseline and calibration figure. It
stays as built and is reproduced by `QWEN_CUDA_ARCHITECTURES=89
QWEN_BUILD_VULKAN=ON QWEN_CUDA_NCCL=ON`.

The CUDA-only PTX-bearing candidate is configuration 0d69b05df789: 89,
Vulkan off, NCCL off, graphs on, flash attention with all served quant pairs,
VMM on, compression size, native host, LTO off, and the upstream MMVQ
thresholds at eight. Its `libggml-cuda.so` is 84016656 bytes with SHA-256
`b9741e2bd7f4ac6e7254aeacd1ff093cdec7cbc784cbaed75a1ceca97100f49e`.
Independent `cuobjdump` inspection reads 187 sm_89 cubins and 187 compute_89
PTX files. Extraction produced all 187 PTX files, and `ptxas -arch=sm_89`
reassembled a representative file into a 31560-byte cubin. `llama-cli
--list-devices` enumerates the RTX 4070 Ti as CUDA0. This configuration is the
default because the artifact contract requires inspectable PTX as well as
native SM89 code.

The compact CUDA-only candidate is configuration 844181cfaedc: 89-real,
Vulkan off, NCCL off, graphs on, flash attention with all served quant pairs,
VMM on, compression size, native host, LTO off, MMVQ thresholds at the
upstream eight. Its `libggml-cuda.so` is 57355792 bytes with SHA-256
`51bd6ab0b6ee09bab20faa94e057e611c2fb37d1258cc2773fddace166593cbe`.
`cuobjdump` reads 187 sm_89 cubins from the library and
answers "No PTX file found", where the frozen control lists one PTX per
cubin. The `89-real` spelling deliberately omits PTX and reduces the library
from 84016656 to 57355792 bytes with the cubin inventory unchanged. The 2B serve spot-check
reads 15142 prefill and 229.8 decode against the registered 14748 and 231.4,
inside the drift floor, so the SASS path is rate-identical as the spelling
change predicts.

The CUDA-plus-Vulkan diagnostic closure is one `QWEN_BUILD_VULKAN=ON` away
and owns backend A/B, fallback, and driver-recovery work; the launch
authority promotes a closure by its exact configuration digest, so a
diagnostic tree cannot stand in for the production candidate silently.

Promotion of either CUDA-only closure into scripts/ serving waits on the one-variable
ladder: compression size against speed against none, LTO with the CUDA-LTO
inspection, lazy against eager module loading, and the strict placement,
teardown, and mixed-roster admission the promotion contract requires.
