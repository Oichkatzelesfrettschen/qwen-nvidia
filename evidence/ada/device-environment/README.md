# What a retained number depends on, and what per-model tuning would have to key

Two claims sit behind "cache a tuned threshold against the model hash, GPU UUID,
driver, CUDA version, and kernel revision". One is refuted by where the
thresholds live; the other names a gap this tree had and now closes.

## The dispatch thresholds are not per-model and not runtime

`ggml_cuda_should_use_mmvq` (`mmvq.cu:295-306`) selects MMVQ against MMQ on the
quantization type and the column count of the mat-mul second operand, and the
two thresholds this tree can move -- `QWEN_CUDA_MMVQ_Q6K_MAX` and
`QWEN_CUDA_MMVQ_Q8_0_MAX` -- reach the kernel as cmake cache entries that
`patches/llama-cuda-mmvq-crossover-ad104.patch` bridges into compile
definitions (`GGML_CUDA_ADA_MMVQ_Q8_0_MAX_BATCH_SIZE`). They enter the
configuration digest, so two thresholds are two closures with two build
directories and two names.

Nothing about them is per-model. A threshold is per quantization type, and two
checkpoints sharing a recipe dispatch identically at the same width;
`../cuda-dispatch-census/` grouped fourteen candidate rows into four runtime
classes on architecture and value format for that reason. Keying a threshold to
a model hash would produce one closure per checkpoint, which is the opposite of
the single promoted closure every admission in `../promotion-88681bf4d161/`
rests on, and it would tune a constant against a variable it does not depend on.

The runtime knobs that do exist are the ones `../cuda-runtime-levers.md` already
measured per class: graphs, fusion, programmatic dependent launch, unified
memory, the cuBLAS compute type, and the operation-offload batch floor.
`ggml/src/ggml-cuda/` reads no environment variable that moves a mat-mul
dispatch threshold, so there is no runtime surface to autotune even if the
threshold varied per model.

Per-model tuning that this tree does perform lives in `scripts/models.tsv`,
where `batch`, `ubatch`, the cache triple, Flash Attention, and the context
fields are per-row and measured per row, and in
`scripts/validated-tuples.tsv`, which keys a measured arm by model, runtime
mode, submission geometry, cache triple, and backend. **What is refuted is per-model threshold
compilation, rather than per-model caching.** A threshold is a compile input and
keying it to a checkpoint multiplies closures; a measured serving tuple is a
result and keying it to a checkpoint is what `scripts/validated-tuples.tsv`
already does, by model, runtime mode, submission geometry, cache triple, and
backend. The registry is the cache the task asks for, holding the results that
vary per model rather than the constants that do not.

## The environment a number was taken under went unrecorded

The caching-key half names something real. Every measurement harness admits its
observations through the ownership authority and the state latch and records the
closure digest that produced them, and none of them recorded the driver that
executed them. `evidence/ada/` holds per-launch costs, dispatch crossovers,
paired served rates, and a decode partition whose authority is the AD104 driver
branch, the CUDA runtime, and the kernel module in force when each ran, and a
reader comparing a retained figure to a later one had only the dates to go on.

`scripts/device-environment-identity.sh` emits one block, and six harnesses now
write it beside their ownership and latch records:
`run-mmvq-width-request-tails.sh`, `run-mmvq-paired-crossover.sh`,
`run-ncu-kernel-baseline.sh`, `run-decode-node-trace.sh`,
`run-cuda-baseline-sweep.sh`, and `probe-backend-sampling-reach.sh`.

| field | this host |
| --- | --- |
| gpu_name | NVIDIA GeForce RTX 4070 Ti |
| driver_version | 610.57.04 |
| kernel_module_version | 610.57.04 |
| vbios_version | 95.04.31.00.A4 |
| cuda_driver_version | 13.3 |
| cuda_toolkit_version | 13.3 |
| kernel_release | 7.2.2-1-cachyos |

The CUDA runtime the driver reports and the toolkit that compiled the closure
are two fields because they are two claims: compute_89 PTX JITs under the first
while the SASS in the fatbin came from the second, and a stack can move one
without the other.

The GPU UUID stays out. It identifies the board rather than the software stack a
threshold depends on, which puts it in the class this tree scrubs beside MAC
addresses and private hostnames, and the four fields that carry the invalidation
signal carry it without the board's serial. `gpu_uuid_sha256` retains the first
sixteen hex of its digest, so two records are comparable for the same device
without either naming it.

Every field reads `unavailable` rather than empty where its source is absent, so
a block written on a host with no driver is distinguishable from a harness that
never wrote the column.

## The block is a key, not a policy

Recording the stack is what makes an invalidation rule possible; asserting one
now would expire every record written before the block existed, which is every
record in `evidence/ada/`. Those keep their authority on the dates they carry.
A policy deciding when a driver change retires a measured threshold is a
separate decision that needs a measurement of what a driver change actually
moves, and this tree has never observed one: the AD104 host has served one
driver branch throughout.

`../graph-loop-bound/` is the first record to carry the block.
