# What the CUDA runtime levers are worth on the 2B

Five arms of `scripts/run-cuda-baseline-sweep.sh` against Qwen3.8-2B-Distill
Q4_K_M at the served tuple: full offload with `-ot .*=CUDA0`, flash attention
on, `q8_0`/`q4_0` KV, pp512 and tg128, three repetitions, forward and reverse.
Four vary `QWEN_CUDA_PROFILE` through `scripts/cuda-runtime-env.sh` on one build;
the fifth is a second build tree carrying `GGML_CUDA_FORCE_MMQ=ON`, which is a
compile-time option rather than a variable.

| arm | prefill tok/s | decode tok/s | pp span | tg span |
| --- | ---: | ---: | ---: | ---: |
| default | 14907.17 | 230.15 | 2.0% | 0.3% |
| no-graphs | 15819.96 | 212.67 | 2.4% | 0.1% |
| no-fusion | 14286.64 | 217.52 | 1.1% | 0.0% |
| pdl | 14811.65 | 230.62 | 2.3% | 0.2% |
| force-mmq build | 14945.97 | 231.85 | 0.2% | 0.3% |

The forward-to-reverse spans of 0.0 to 2.4% are what make these readable: a 5
to 8% difference is several times the sweep's own instability, where the same
comparison on the APU sat inside a 30.6% band.

CUDA graphs buy decode and cost prefill. Disabling them takes decode from
230.15 to 212.67, 7.6% down, and raises prefill 6.1%. The direction is the
mechanism: graph replay removes per-node launch overhead from a decode step
that issues many small kernels, and it adds capture and instantiation work to a
prefill step whose kernels are large enough that the launch overhead is
negligible. Decode is what the appliance is judged on, so graphs stay on and
`no-graphs` is a control rather than a candidate.

Fusion buys 5.8% of decode and 4.2% of prefill together, with no arm where
disabling it helps.

Programmatic dependent launch is inert here: 230.62 against 230.15, 0.2% apart
where the arm's own span is 0.2 and 0.3%. `GGML_CUDA_PDL` stays available and
unset.

The `GGML_CUDA_FORCE_MMQ` arm moves 0.7%, 231.85 against 230.15, inside the same
band -- and the source says why, which is a stronger statement than the number.
`GGML_CUDA_FORCE_MMQ` is read at one place, `ggml/src/ggml-cuda/mmq.cu:320`,
inside `ggml_cuda_should_use_mmq`. Eight lines above it,
`if (turing_mma_available(cc)) return true;` already returns for every NVIDIA
part at Turing or later, and this device is compute capability 8.9. The
preprocessor branch is therefore unreachable here at every batch size, and the
mat-mul dispatcher consults `ggml_cuda_should_use_mmvq` before
`ggml_cuda_should_use_mmq` in any case, with no `FORCE_MMQ` escape on that path.

The arm measures two builds that dispatch identically, so 0.7% is this tree's
build-to-build noise floor rather than a comparison of kernel policies. Nothing
here says MMQ and cuBLAS tie on Ada; the flag that would have separated them
does not reach the decision. The second build tree stays at
`build-qwen-cuda-sm89-mmq` as that noise-floor reference.
`GGML_CUDA_FORCE_CUBLAS` is the flag that does reach it --
`mmq.cu:260` returns false ahead of everything -- and
`evidence/ada/b789-calibration-design.md` preregisters it as the differential
control that separates MMQ from MMVQ by behaviour rather than by assertion.

## What this decides

The serving default is the `default` profile: graphs on, fusion on, PDL unset,
cuBLAS free to take what it wins. Two of the four levers are confirmed as defaults already in
force, programmatic dependent launch is refuted as a performance knob on this
checkpoint, and the MMQ kernel-policy flag is refuted as a lever at all on this
device because the source never reads it here.

## What stays open

One checkpoint and one shape. `no-graphs` and `no-fusion` were measured on the
2B alone, and the doctrine's order runs the 0.8B and the 4B next before either
becomes a host-wide statement rather than a class one. `unified` is unmeasured
because it belongs to an allocation that would otherwise not load, and every
checkpoint here fits.

`GGML_CUDA_REGISTER_HOST`, `GGML_CUDA_NO_PINNED`, `GGML_CUDA_GRAPH_OPT`, and
`GGML_OP_OFFLOAD_MIN_BATCH` are reachable through the `custom` profile and
unmeasured.
