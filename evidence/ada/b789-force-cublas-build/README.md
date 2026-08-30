# The forced-cuBLAS differential tree

`GGML_CUDA_FORCE_CUBLAS` is the one build-time flag on this device that reaches
the mat-mul dispatcher. `ggml/src/ggml-cuda/mmq.cu:260` reads it at the head of
`ggml_cuda_should_use_mmq` and returns false ahead of everything, where
`GGML_CUDA_FORCE_MMQ` at `mmq.cu:320` sits eight lines below a
`turing_mma_available(cc)` return that already fires at compute capability 8.9
and never executes here. `evidence/ada/cuda-runtime-levers.md` records that
refutation and the 0.7% it leaves as this tree's build-to-build noise floor.

The flag is not a switch that sends every quantized multiplication to cuBLAS.
`ggml_cuda_mul_mat` consults `ggml_cuda_should_use_mmvq` before
`ggml_cuda_should_use_mmq`, so a width inside the Ada MMVQ threshold reaches
MMVQ in both builds and only a width above it changes: default takes MMQ and
the forced build falls through to cuBLAS. That makes the flag a behavioural
corroboration of the crossover rather than a second measurement of it, and
`evidence/ada/b789-calibration-design.md` preregisters the six arms it runs.

`scripts/build-llama-cuda.sh` takes `QWEN_FORCE_CUBLAS=ON` and names the tree
`build-qwen-cuda-sm89-force-cublas`. The two flags are exclusive arms and the
script refuses a tree naming both, because the dispatcher reads one policy.

## What separates the two trees

`closure.txt` carries the digest of every artifact either tree produced along
with the source revision, the patch-series digest, and both compiler versions.
Comparing the two `CMakeCache.txt` files leaves one build option apart:

```text
GGML_CUDA_FORCE_CUBLAS:BOOL=OFF  ->  ON
```

Three cache entries differ for reasons that belong to the host rather than to
the arm, because the primary tree was configured earlier: CMake's own
`CMAKE_CACHE_PATCH_VERSION` moved 2 to 3, `CMAKE_C_COMPILER` and
`CMAKE_CXX_COMPILER` are recorded `UNINITIALIZED` in the older cache and
`STRING` in the newer with the same `/usr/bin/gcc-15` and `/usr/bin/g++-15`
values, and the found OpenSSL moved 3.6.3 to 3.6.4. None of the three reaches
`libggml-cuda.so`, which links neither OpenSSL nor curl, and the differential
is measured with `llama-bench` rather than with `llama-server`. It is recorded
here so a later reader meets the deviation rather than discovering it.

Everything the design holds fixed is equal across the two caches:

```text
CMAKE_BUILD_TYPE=Release
CMAKE_CUDA_ARCHITECTURES=89
GGML_CUDA_FA=ON
GGML_CUDA_FA_ALL_QUANTS=ON
GGML_CUDA_GRAPHS=ON
GGML_CUDA_NCCL=ON
GGML_CUDA_COMPRESSION_MODE=size
GGML_CUDA_FORCE_MMQ=OFF
GGML_NATIVE=ON
GGML_LTO=OFF
GGML_VULKAN=ON
```

`GGML_CUDA_NCCL`, `GGML_CUDA_COMPRESSION_MODE`, and `GGML_LTO` each have a
reason to move on this host and each stays where the primary tree put it, since
a differential carrying two changes attributes its result to neither.

## What this tree does not measure

Anything on the clean-boot timing campaign. The forced-cuBLAS arms run after
the default matrix completes, its closing control passes, the latch reads
clear, and the ring is unchanged, so a cuBLAS rate never enters the comparison
the matrix is read from.
