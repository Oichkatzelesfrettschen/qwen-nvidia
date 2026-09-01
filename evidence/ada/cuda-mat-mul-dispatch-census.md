# The quantized mat-mul dispatch on AD104, read from the source

This census reads `ggml/src/ggml-cuda/` at llama.cpp `f280b2698` and answers two
questions the device cannot answer without a build: which conditions reach the
dense cuBLAS dequant-and-GEMM path, and what pins the MMVQ kernel at sixteen
columns. Both are static reads. No arm ran on the device for this record, and
every rate claim it touches belongs to the campaigns it cites.

## cuBLAS is reached by condition rather than by weight type

`ggml_cuda_should_use_mmq` (`mmq.cu:259`) admits twenty-two weight types:
Q1_0, Q2_0, Q4_0, Q4_1, Q5_0, Q5_1, Q8_0, Q2_K through Q6_K, IQ1_S, IQ2_XXS,
IQ2_XS, IQ2_S, IQ3_XXS, IQ3_S, IQ4_XS, IQ4_NL, MXFP4, and NVFP4. Every
quantization this tree serves -- Q4_K_M, Q6_K, and Q8_0 -- is inside that set,
so no served checkpoint reaches cuBLAS because its type lacks a kernel. IQ1_M is
the one absent weight type a GGUF could plausibly carry, since IQ1_S is admitted
beside it; a checkpoint at that quantization would run the dense path for every
mat-mul.

Q8_1 and Q8_K are not weight types and belong to no such list.
`quantize_mmq_q8_1_cuda` (`mmq.cu:236`) produces Q8_1 as the activation
quantization the MMQ path derives from `src1` inside the launch, and Q8_K plays
the same role for the K-quant vector kernels. Reading either as a fallback
subject counts an intermediate as a model artifact.

Two conditions in `ggml_cuda_mul_mat` reach the dense path instead.
`ggml-cuda.cu:1829` takes it where `src1->type != GGML_TYPE_F32 ||
dst->type != GGML_TYPE_F32`, or where a compute-usage buffer holds a view whose
byte count differs from its allocation, so the activation and destination types
decide it ahead of the weight type. `ggml-cuda.cu:1869` takes it where all four
specialized predicates decline at once -- `ggml_cuda_should_use_mmvf`,
`ggml_cuda_should_use_mmf`, `ggml_cuda_should_use_mmvq`, and
`ggml_cuda_should_use_mmq`. Inside `ggml_cuda_mul_mat_cublas_impl` the shape
then selects the entry: `cublasSgemm` at `:1546` for an F32 compute type with
`ne12 == 1 && ne13 == 1`, `cublasGemmEx` at `:1553` for the same unbatched shape
at another compute type, `cublasGemmStridedBatchedEx` at `:1568` where
`r2 == 1 && r3 == 1` and both operands are 2D-contiguous, and
`cublasGemmBatchedEx` at `:1606` for the remaining broadcast shapes.

`GGML_CUDA_FORCE_CUBLAS` at `mmq.cu:260` returns false from
`ggml_cuda_should_use_mmq` before the type switch runs, which is the build-time
lever `QWEN_FORCE_CUBLAS=ON` reaches and
`evidence/ada/b789-cublas-differential/` measured.

## The runtime compute type is already scrubbed

`ggml-cuda.cu:1634` reads `GGML_CUDA_CUBLAS_COMPUTE_TYPE` and overrides the
compute type to F32, F16, or BF16 after the hardware-capability default and the
`GGML_PREC_F32` request have both applied, so an ambient value changes the
numerical policy of every cuBLAS call in the process. `cuda-runtime-env.sh`
already names it, along with `GGML_CUDA_DISABLE_GRAPHS`, `GGML_CUDA_PDL`,
`GGML_CUDA_ENABLE_UNIFIED_MEMORY`, `GGML_CUDA_DEVICES`, `GGML_CUDA_ALLREDUCE`,
`GGML_CUDA_NO_PINNED`, `GGML_CUDA_DISABLE_FUSION`, `GGML_CUDA_GRAPH_OPT`,
`GGML_CUDA_REGISTER_HOST`, and `GGML_OP_OFFLOAD_MIN_BATCH`. `GGML_CUDA_P2P`
(`ggml-cuda.cu:393` and `:608`) is the one backend variable the wrapper leaves
alone, and it selects peer access between devices, which one card cannot
express.

## Sixteen columns is a source ceiling rather than a resource one

`mmvq.cuh:14` defines `MMVQ_KERNEL_MAX_NCOLS` as 16 and three mechanisms hold
the kernel there. `mmvq.cu:934` asserts `ncols_dst <= MMVQ_KERNEL_MAX_NCOLS` at
launch; `mul_mat_vec_q_switch_ncols_dst` instantiates cases 1 through 16 and
ends at `mmvq.cu:1167`; and the two `static_assert`s at `mmvq.cuh:15-20` bind
`GGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE` and
`GGML_CUDA_ADA_MMVQ_Q8_0_MAX_BATCH_SIZE` to the range
`[1, MMVQ_KERNEL_MAX_NCOLS]`. A CMake threshold above sixteen therefore fails
the build rather than producing a wider kernel, which is the guard those
assertions exist to provide.

Both macros default to 8 in `mmvq.cuh:9` and `:12`. The promoted closure's Q6_K
threshold of 10 and Q8_0 threshold of 16 come from the build setting them, so
the patch and the closure state two different numbers and only the closure's
reach the served binary.

Raising the ceiling takes four coordinated edits and no kernel-body change:
`MMVQ_KERNEL_MAX_NCOLS` itself, new cases in `mul_mat_vec_q_switch_ncols_dst`
(`mmvq.cu:924`), new cases in `calc_nwarps` (`mmvq.cu:401`), and new cases in
`calc_rows_per_block` (`mmvq.cu:536`). The template at `mmvq.cu:564` sizes
`float tmp[ncols_dst][rows_per_cuda_block]`, `float x_biases[ncols_dst]`, and
the shared `tmp_shared` array from the parameter, so each scales at
instantiation.

No resource bound explains the ceiling at the widths measured here. At sixteen
columns `tmp_shared` occupies 4096 bytes against roughly 96 KiB of shared memory
per SM on compute capability 8.9, and `tmp` costs 128 bytes per thread. Whether
register pressure binds before an arbitrary width is unmeasured and a compiled
occupancy read would settle it; `/tmp` retains three `.ncu-rep` occupancy
captures from the Q8_0 arms, which carry no environment block and are the
nearest existing evidence.

## What this changes about the open work

Measuring Q8_0 MMVQ beyond sixteen requires a fifth patch in `patches/` ahead of
any sweep, rather than a threshold argument to the existing one. The promoted
Q8_0 threshold already sits on the instantiation ceiling, so the crossover above
sixteen is unmeasured because no build has expressed it.

A dense-path planner has no served subject to plan for: every quantization in
`scripts/models.tsv` carries an MMQ kernel, and the dense path is reached by
activation type and tensor shape. A planner keyed on weight type would act on a
condition this roster never presents. `cuda-dispatch-census/` is the runtime
reading this static one predicted the need for: the quantized text rows reach
cuBLAS zero times, the dense F16 and BF16 rows run their whole prefill there,
and the vision encoder reaches it wherever the projector file carries F16
weights.

## Falsifiers

A served checkpoint whose mat-muls reach `ggml_cuda_mul_mat_cublas_impl` under
the promoted closure refutes the reading that condition rather than type selects
the dense path here, and `scripts/run-ad104-path-audit.sh` reads the executed
symbols that would show it. A build at `MMVQ_KERNEL_MAX_NCOLS` above sixteen
that compiles and runs without the four edits refutes the instantiation account.
An occupancy read showing register pressure already binding at sixteen refutes
the reading that the ceiling is a maintenance decision.
