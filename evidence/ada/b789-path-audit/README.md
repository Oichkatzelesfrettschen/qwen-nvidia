# The MMVQ-to-MMQ crossover, observed rather than derived

`scripts/ad104-b789-matrix.tsv` derived its kernel families from three source
constants: `ggml_cuda_mul_mat` consults `ggml_cuda_should_use_mmvq` before
`ggml_cuda_should_use_mmq`, `mmvq.cu:295-306` guards Q4_K and Q5_K at `ne11<=7`
and everything else at `MMVQ_MAX_BATCH_SIZE` of 8, and `mmq.cu:312` returns
true for every NVIDIA part at Turing or later. Seven arms of that matrix now
carry `path_evidence=observed`, and the observation is a kernel symbol rather
than a rate.

The symbol carries the claim. `mmvq.cu:544` declares
`template <ggml_type type, int ncols_dst, bool has_fusion, bool small_k, bool
halve_iters> __global__ void mul_mat_vec_q`, so an MMVQ launch demangles to
`mul_mat_vec_q<(ggml_type)12, (int)7, ...>` and names the quantization type and
the column count of the mat-mul second operand in the symbol itself. `B is
ne11` is therefore read off the device rather than out of the source: every
prefill MMVQ launch below carries `ncols_dst` equal to its arm's B.

`scripts/run-ad104-path-audit.sh` runs one profiled prefill per arm under
Nsight Systems with `--sample=none --cpuctxsw=none`, which records launched
names without replaying a kernel, and discards every duration. It holds the
same `/tmp/qwen-ad104-gpu-0.lock` the calibration holds, refuses to start
beside a llama-server, and halts on a new kernel-ring signature.

## What the device executed

Each row is a distinct kernel symbol. The `ncols=1` rows are the `-n 1` decode
step that shares the capture with the prefill, so the arm's own launches are
the ones whose `ncols` equals its B or whose family is MMQ.

| arm | B | type | family | ncols | launches |
| --- | ---: | --- | --- | ---: | ---: |
| b7-q4k | 7 | Q4_K | MMVQ | 7 | 216 |
| b7-q4k | 7 | Q6_K | MMVQ | 7 | 32 |
| b7-q5k | 7 | Q5_K | MMVQ | 7 | 216 |
| b7-q5k | 7 | Q6_K | MMVQ | 7 | 32 |
| b7-q6k | 7 | Q6_K | MMVQ | 7 | 248 |
| b8-q4k | 8 | Q4_K | MMQ | - | 168 + 48 |
| b8-q4k | 8 | Q6_K | MMVQ | 8 | 32 |
| b8-q5k | 8 | Q5_K | MMQ | - | 168 + 48 |
| b8-q5k | 8 | Q6_K | MMVQ | 8 | 32 |
| b8-q6k | 8 | Q6_K | MMVQ | 8 | 248 |
| b9-q6k | 9 | Q6_K | MMQ | - | 200 + 48 |

Every prediction the matrix stated holds. Q4_K and Q5_K leave MMVQ between B7
and B8 while Q6_K stays, which is the mixed forward pass the matrix predicted
and the two families appear in one capture. Q6_K leaves MMVQ between B8 and
B9, and `b8-q6k` is the null step the reading rests on: 248 MMVQ launches at
`ncols_dst` of 8 and no MMQ launch at all.

`b9-q4k` and `b9-q5k` remain `derived`. The ring guard halted the run that
would have covered them, and the protocol forbids a retry on the boot a
signature appeared on.

The MMQ launch count splits across two symbols differing in `mmq_x`, the tile
width its second template parameter carries, which is why an MMQ row reads its
type from the symbol and its B from the arm.

## The report is not the authority

`nsys stats --report cuda_gpu_kern_sum` returns a header and no rows against
these captures under Nsight Systems 2026.1.3.425, while
`CUPTI_ACTIVITY_KIND_KERNEL` in the same capture holds 2162 launches joined to
`StringIds` by `demangledName`. `scripts/read-nsys-mat-mul-kernels.py`
therefore exports the SQLite and queries the activity table, and the discrepancy
is recorded here because a reader who runs the documented report will see an
empty result and conclude the capture is empty.

## The NVRM system-memory refusal reproduces outside the router switch

`evidence/quarantine/qwen38-9b-distill-router-load.md` names an overlapping
router-child load as the observed trigger of the
`_memdescAllocInternal`/`system_mem.c:353`/`nv_gpu_ops.c:5077` chain and leaves
the refused resource unresolved. Two arms of this audit emitted that identical
three-line chain from a single-process `llama-bench` holding one model, with no
router, no second child, and no switch:

```text
23:34:04  during 01-b7-q4k of the first invocation, four lines
23:38:32  during 01-b7-q6k of the third invocation, three lines
```

The conditions separate this from every candidate the quarantine record lists.
`MemAvailable` read 21649564 kB and `Mlocked` 1032 kB immediately afterward, so
host memory and the locked-pages limit were both far from short. `nvidia-smi`
reported 1429 MiB of the 12282 MiB framebuffer in use, held by the compositor
alone, so the framebuffer was about 88% free. Both arms **completed**:
`b7-q4k` returned pp7 at 227.00 and tg1 at 52.24 tok/s and `b7-q6k` returned
pp7 at 348.97 and tg1 at 57.35, and each produced the kernel observation the
table above carries.

Three statements follow and one does not. The chain is not specific to a router
switch, it is not a report of framebuffer exhaustion, and it is not always
fatal. What allocation the RM refused stays unresolved, and the six arms of the
second invocation emitted nothing under the same shape, so a first-touch or
warm-state explanation is available and unmeasured. The profiler is a covariate
of both bursts and cannot be separated from them by this run, since every arm
here ran under Nsight Systems.

What this changes for the quarantine record is the reading of its trigger
section rather than its verdict: the 9B router switch reproduced the chain
fatally and no measured router geometry is safe, and the same chain is now
observed non-fatally without a switch. `scripts/quarantine.tsv` keeps the 9B at
model scope against the router path.

## Falsifiers

An unprofiled `llama-bench` arm emitting the chain refutes the profiler as a
necessary covariate. A profiled arm emitting it while `MemAvailable` is short
or the framebuffer is near full would return the exhaustion readings this run
excludes. An arm whose prefill MMVQ symbol carries an `ncols_dst` other than
its B refutes `B is ne11`. A B8 Q6_K capture carrying any MMQ launch refutes
the `MMVQ_MAX_BATCH_SIZE` reading, and a B9 Q6_K capture carrying no MMQ
launch refutes the crossover.
