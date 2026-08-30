# Preregistration: the AD104 B7/B8/B9 calibration

This record is written before the run and before the reboot that precedes it,
which is what makes the result readable as a test rather than as a summary. It
states what the calibration measures, what would refute each expectation, and
what the run needs that this tree does not yet hold.

## B7, B8, and B9 read out of the source

No file in this repository defined them, and the earlier draft of this record
named that as the blocker. It is read rather than supplied, and the derivation
is here so a reader can reject it.

`ggml_cuda_mul_mat` consults `ggml_cuda_should_use_mmf`, then
`ggml_cuda_should_use_mmvq`, then `ggml_cuda_should_use_mmq`, then falls to
cuBLAS. `mmf.cu:135` returns false for every quantized type, so it cannot
intercept a K-quant. `mmvq.cu:295-306` then carries a switch guarded on
`cc == GGML_CUDA_CC_ADA_LOVELACE`, which `common.cuh:55` sets to 890 and which
is this device exactly:

```text
Q2_K            ne11 <= 4
Q3_K            ne11 <= 6
Q4_K, Q5_K      ne11 <= 7
everything else ne11 <= MMVQ_MAX_BATCH_SIZE, which mmvq.cuh:3 sets to 8
```

Above its threshold a type reaches `ggml_cuda_should_use_mmq`, which returns
true at `mmq.cu:312` for every NVIDIA part at Turing or later.

`B` is therefore `ne11`: the column count of the second operand of a quantized
mat-mul, which for a prefill of N tokens inside one ubatch equals N. It is not
the logical batch, not the ubatch size, and not a compile-time constant, and
`scripts/ad104-b789-matrix.tsv` spells that out in a `b_definition` column on
every row rather than leaving it to the arm name. Seven, eight, and nine bracket
the two thresholds this device carries: Q4_K and Q5_K leave MMVQ between B7 and
B8, Q6_K between B8 and B9.

The switch is commented `// tuned on RTX 4090`. That part is AD102 with 128
streaming multiprocessors and a 384-bit bus; this is AD104 with 60 and 192 bits,
sharing only the compute capability the branch is keyed on. Whether a threshold
tuned on one die is right for the other is the question the campaign asks.

The matrix is committed as **proposed**. It follows from the constants above and
from nothing else, and a definition supplied from outside this tree replaces it
without argument.

## Every artifact is mixed, and the census says by how much

A `Q4_K_M` label names a recipe rather than a layout, so no arm here puts one
model on one path. `scripts/gguf-tensor-census.py` reads what each artifact
actually holds:

| artifact | bytes by ggml type |
| --- | --- |
| Qwen3.8-4B-Q4_K_M | Q4_K 61.11%, Q6_K 38.36%, F32 0.14% |
| Qwen3.8-4B-i1-Q5_K_M | Q5_K 65.76%, Q6_K 33.77%, F32 0.12% |
| Qwen3.8-4B-i1-Q6_K | Q6_K 99.58%, F32 0.11% |
| Qwen3.8-4B-i1-Q2_K | Q2_K 38.35%, Q6_K 26.62%, Q3_K 19.15%, Q4_K 15.13%, F32 0.20% |

The embedding is Q6_K in all four and the embeddings are tied, so the output
projection is a Q6_K mat-mul in every arm.

That makes the mixing the design rather than a nuisance. At B8 a Q4_K_M forward
pass runs its Q4_K tensors on MMQ and its Q6_K tensors on MMVQ at the same time,
so the B7-to-B8 step isolates the 61.11% that is Q4_K and the B8-to-B9 step
isolates the 38.36% that is Q6_K. The two steps separate the two families inside
one artifact.

The `expected_kernel_family` column is therefore stated per tensor type, and a
row's `quant_family` names the type the prediction is about rather than the
file's label. `qwen38-4b-i1-q6k` at 99.58% one type is the only near-pure arm
and is the discriminator: it should show **no** step between B7 and B8 and the
matrix's largest step at B9. A step at B8 there refutes the reading.

A single-family artifact for Q4_K or Q5_K would settle the rest directly. This
tree holds none, and that is a limit rather than something the analysis can
subtract.

## The kernel path is derived, and one differential control can observe it

`path_evidence` reads `derived` on every row. The selection is a pure function of
`(type, cc, ne11)` with no runtime state, and neither `GGML_CUDA_DEBUG` site in
`ggml-cuda.cu` logs a mat-mul dispatch -- both log fusion -- so no marker names
the kernel without patching the backend.

`GGML_CUDA_FORCE_MMQ` cannot serve as the differential control, and finding out
why corrected a standing claim in this tree. The flag is read once, at
`mmq.cu:320`, eight lines below the `turing_mma_available(cc)` return that
already fires at compute capability 8.9, and `ggml_cuda_should_use_mmvq` is
consulted before `ggml_cuda_should_use_mmq` with no escape on that path. The
flag is unreachable on this device at every batch size.
`evidence/ada/cuda-runtime-levers.md` now records its 0.7% arm as a
build-to-build noise floor rather than as two kernel policies tying.

`GGML_CUDA_FORCE_CUBLAS` does reach the decision: `mmq.cu:260` returns false
ahead of everything, so MMQ is removed while MMVQ still fires first at its own
threshold. That yields a preregistered behavioural discriminator, from a third
build tree carrying `-DGGML_CUDA_FORCE_CUBLAS=ON`:

```text
forced-cuBLAS B7 == default B7    both MMVQ; the flag cannot reach an MMVQ shape
forced-cuBLAS B8 != default B8    cuBLAS against MMQ, so B8 was not on MMVQ
forced-cuBLAS B9 != default B9    the same, for Q6_K
```

An equal pair at B8 refutes the claim that B8 left MMVQ. The arms are named here
and unrun; the matrix keeps `derived` until they run, and the runner refuses an
arm on an observed mismatch rather than on an unobserved path.

## What the clean boot is for

The device has carried, across one session: repeated overlapping high-allocation
loads, 69 distinct seconds of the terminating NVRM `nv_gpu_ops.c:5077` chain, 34
seconds of `_kgmmuClientShadowFaultBufferPagesAllocate` retries, several SIGKILL
terminations, and relaunches inside the reclaim window.
`evidence/quarantine/qwen38-9b-distill-router-load.md` records the pool the
refusals name and states that the resource is unresolved. A calibration measured
on that state cannot separate a kernel-policy effect from accumulated driver
state, which is exactly the confound the clean boot removes.

The reboot therefore precedes the run, and `scripts/gpu-state-latch.sh` gates
every launch after it.

## Preconditions the runner enforces

- The GPU state latch reads clear.
- No `llama-server` and no CUDA compute client holds the device.
- The promoted binary's SHA-256 and the llama.cpp revision are recorded before
  the first arm. At the time of writing those are
  `c51daa95fe2fc4086264e4694f0d7a10d1e8207184d3d6cdf2a01ed8538b6e4a` for
  `llama-bench` and revision `f280b2698`; the runner records what it finds
  rather than asserting these.
- Every checkpoint the matrix names exists on disk. The three K-quant ladder
  artifacts were fetched and verified against their pinned revision, byte count,
  and SHA-256 before the reboot, since a download is not a use of the clean
  state:

  ```text
  Qwen3.8-4B-i1-Q2_K.gguf     1959168512  434c68a076c5e62da6f0ae01d5eff5211a04f3ff76092756d5d8ccfaf6534736
  Qwen3.8-4B-i1-Q5_K_M.gguf   3161426432  e050bca9c74d996992d65b3421b3add4cbd387ccf49cc68455336d0ffde2cfdd
  Qwen3.8-4B-i1-Q6_K.gguf     3563028992  e39712a3f9eb7d46274ff7503f0297d6a38d3bc2a6f4081d6e8a2a00d907e417
  ```

  No CUDA context and no llama process was started to fetch or hash them.
- The calibration lock at `/tmp/qwen-ad104-gpu-0.lock` is free. It excludes a
  second calibration rather than the device generally, since a lock excludes
  only what also takes it and nothing else in this tree does; the process and
  compute-client checks are what exclude the appliance. The descriptor is held
  for the whole campaign including the closing control and the post-run read.
- `run-ad104-b789-calibration.sh --validate` accepts the matrix. It reads the
  same fields the run reads -- the arm ids unique, `ne11` numeric, the kernel and
  math vocabularies closed, `path_evidence` one of `observed` or `derived`, every
  bench digest matching, every artifact present -- and runs nothing.
- The desktop compositor is a covariate this host carries rather than a
  condition it excludes, so its occupancy is recorded before the first arm and
  after the last.

## Run discipline

Each arm runs through `scripts/run-cuda-baseline-sweep.sh`, which already owns
the properties a kernel-policy comparison needs: the served tuple rather than
llama-bench's defaults, `-ot .*=CUDA0` placement under `LLAMA_NO_CPU_FALLBACK=1`
so a host placement is a refusal rather than a silent halving, three repetitions
per arm, and each checkpoint measured at position i and again at position n-i so
the paired mean is reported and the forward-to-reverse span is the sweep's own
instability. `scripts/sample-nvidia-clocks.sh` records SM clock, memory clock,
temperature, power draw, both utilisation counters, occupancy, and the throttle
reason once a second beside every arm.

The span is what makes a difference readable. `evidence/ada/cuda-runtime-levers.md`
measures forward-to-reverse spans of 0.0 to 2.4% on this host, so an arm
separated by less than its own span reports position in the sweep rather than a
kernel policy. A calibration that reports a 1% effect against a 2% span reports
unresolved direction, and this record says so ahead of the run.

Decode is a second control inside every arm. `ne11` is 1 for a decode step
whatever the arm's prefill length, so the `tg` row takes MMVQ on every arm and
should not move across B7, B8, and B9. A `tg` rate that moves with B is drift
the `pp` column carries too.

Clock and power policy is left where the host sets it: 285 W, persistence mode
disabled, application clocks deprecated on this driver. The device moves its own
state under its power and thermal budget rather than on a driver ladder, which
is why the sampler records the state beside the rate instead of pinning it.

## Output equivalence belongs to a different arm, and this campaign drops the claim

An earlier draft of this record promised that every arm answers fixed prompts at
temperature 0 and that replies are compared character-for-character. The runner
cannot do that and should not pretend to: each arm is `llama-bench` at a fixed
`ne11`, which runs prefill and samples no tokens. Producing a reply would need a
separate `llama-cli` or `llama-server` run at a different batch geometry than the
arm it is meant to validate, so it would exercise a different dispatch than the
one measured. `evidence/ada/speculation-runtime-classes.md` earned its
reply-comparison column because those arms generated; these do not.

The correctness question is real and stays open. MMVQ and MMQ compute the same
dot product through different instruction paths -- packed `__dp4a` against the
Turing `mma` integer path -- so a numerical difference is possible. What settles
it is a logits comparison at one fixed `ne11` across the two paths, forced apart
by the build rather than by the batch size, and no arm here runs it. The
calibration reports rates and claims nothing about output identity.

## Stop conditions

The run halts and retains what it has when any of these appears:

- the GPU state latch is set by the hazard watcher during an arm;
- a new `NV_ERR_NO_MEMORY`, mapping, invalid-state, Xid, or reset signature
  enters the kernel ring between arms;
- `nvidia-smi -q` stops answering;
- an arm's `llama-bench` emits other than exactly one `pp` row and one `tg` row,
  which the tree already treats as `n/a` and a failed ladder rather than half a
  pair.

An arm that halts the run leaves the remaining arms unrun and named as unrun.
The run is not retried on the same boot after a driver-level signature, since
that is the state the clean boot exists to exclude.

## Post-arm controls

- The opening arm is repeated as the closing arm. Agreement between them
  licenses reading the interior arms as kernel-policy effects rather than as
  position in a warming device; disagreement makes the drift the finding.
- The device health check runs after the last arm: latch clear, ring quiet,
  counters returned to the compositor-only baseline.
- The router is restored afterward and its `/health` and roster are recorded, so
  the calibration ends with the appliance in the state it started from.

## What this record does not claim

That the derived paths were observed. Every `expected_kernel_family` follows
from source constants, and the forced-cuBLAS arms that would observe them are
unrun.

That MMVQ and MMQ produce identical outputs. The logits comparison that would
settle it is named above and unrun.

Which direction each step goes. The matrix predicts *where* a step falls, not
whether crossing to MMQ is faster or slower on AD104. The RTX 4090 thresholds
assert that MMVQ is worth keeping up to seven columns for Q4_K on AD102; a step
in either direction here is a result, and a step saying the threshold is
misplaced for this die is the outcome the campaign exists to be able to report.
