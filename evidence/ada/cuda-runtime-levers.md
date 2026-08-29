# What the CUDA runtime levers are worth on the 2B

Five arms of `remote/run-cuda-baseline-sweep.sh` against Qwen3.8-2B-Distill
Q4_K_M at the served tuple: full offload with `-ot .*=CUDA0`, flash attention
on, `q8_0`/`q4_0` KV, pp512 and tg128, three repetitions, forward and reverse.
Four vary `QWEN_CUDA_PROFILE` through `remote/cuda-runtime-env.sh` on one build;
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

The MMQ kernel policy is inert on this checkpoint: 231.85 against 230.15, 0.7%,
inside the same band. `GGML_CUDA_FORCE_MMQ=ON` forces the quantized mat-mul
kernels where the default lets cuBLAS take some shapes, and on Ada at Q4_K_M
those two paths reach the same rate. The second build tree is retained at
`build-qwen-cuda-sm89-mmq` because the arm is per-checkpoint: a different
quantization or a different shape can separate them, and this measures one.

## What this decides

The serving default is the `default` profile: graphs on, fusion on, PDL unset,
cuBLAS free to take what it wins. Two of the four levers are refuted as
performance knobs on this checkpoint and two are confirmed as defaults already
in force.

## What stays open

One checkpoint and one shape. `no-graphs` and `no-fusion` were measured on the
2B alone, and the doctrine's order runs the 0.8B and the 4B next before either
becomes a host-wide statement rather than a class one. `unified` is unmeasured
because it belongs to an allocation that would otherwise not load, and every
checkpoint here fits.

`GGML_CUDA_REGISTER_HOST`, `GGML_CUDA_NO_PINNED`, `GGML_CUDA_GRAPH_OPT`, and
`GGML_OP_OFFLOAD_MIN_BATCH` are reachable through the `custom` profile and
unmeasured.
