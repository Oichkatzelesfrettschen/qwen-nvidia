# HIP against Vulkan from one binary, one phase at a time

`build-qwen-dual` carries both backends against llama.cpp `f280b26`, so
`llama-bench --device` selects between them and the rows below differ by the
backend alone. Prompt processing and token generation run as separate
invocations with the unused side set to zero, because a combined run reports one
elapsed time for two mechanisms.

Checkpoint: Qwen3.8-4B Distill Q4_K_M, 2.58 GiB,
`dec96e8cf2e11b613bb46513dec485377f9ca5a351e71712ee0e244f287c6790`.
Full offload, `-ngl 99`, two threads, one repetition, 600 s per phase.

## Rows

Measurement runs under the policy the appliance serves under, nice 19 with the
idle I/O class, verified on the running process rather than assumed from the
shell. The rows are the retained ones:

| Arm | ggml threads | prefill tok/s | decode tok/s | prefill seconds | decode seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| V, RADV Vulkan | 2 | 23.48 | 3.09 | 50 | 26 |
| H0, `gfx900` under override, automatic kernels | 2 | 12.20 | 1.97 | 89 | 38 |
| H0t1, the same arm at one ggml thread | 1 | | 1.98 | | 37 |

Decode repeated three times, which the section below uses:

| Arm | decode tok/s |
| --- | ---: |
| V, RADV Vulkan | 3.07 +/- 0.02 |
| H0, HIP | 2.02 +/- 0.15 |

HIP reaches 52.0% of the Vulkan prefill rate and 65.8% of its decode rate. The
falsification criterion recorded in `evidence/rocm-feasibility-audit.md` asks
for a HIP row above 22.00 prefill or 3.02 decode on this checkpoint. Both rows
fall below both figures, so the criterion is tested and unmet, and RADV Vulkan
holds the serving backend on measurement rather than on default.

## The thread-contention prediction is falsified

`BusyWaitSignal` polls a completion value in userspace rather than sleeping on
it, so a HIP arm holds one of this machine's two cores before ggml asks for any,
and `-t 2` then asks for both. The prediction recorded before the run was that
removing that oversubscription would recover decode.

It recovers nothing. One ggml thread measures 1.98 decode tok/s against two
threads at 1.97, a difference inside the run-to-run spread of a single
repetition. The deficit survives the arm designed to remove it, so ggml thread
count is not the mechanism and the deviation is the result: whatever the host
spin costs, it is not costing decode through ggml worker starvation.

## The two policies measure different-sized deficits

The same two arms ran earlier at normal priority, and those rows are retained
here as a comparison between scheduling policies rather than backends:

| Arm | prefill, nice 0 | prefill, nice 19 | decode, nice 0 | decode, nice 19 |
| --- | ---: | ---: | ---: | ---: |
| V, RADV Vulkan | 21.49 | 23.48 | 3.10 | 3.09 |
| H0, HIP | 14.06 | 12.20 | 2.22 | 1.97 |

Vulkan decode moves 0.3% across the policies and its prefill measures 9.3%
higher at nice 19. HIP measures 13.2% lower on prefill and 11.3% lower on
decode.

Those figures each come from a single repetition. Re-running both decode phases
at three repetitions under the serving policy refuses the scheduling reading:

| Arm | decode, three repetitions | spread |
| --- | ---: | ---: |
| V, RADV Vulkan | 3.07 +/- 0.02 | 0.7% |
| H0, HIP | 2.02 +/- 0.15 | 7.4% |

HIP's 2.02 +/- 0.15 covers the 2.22 measured at normal priority within about
1.3 standard deviations, so the policy difference has no support and the
candidate mechanism -- a userspace poll loop descheduled where a fence sleep is
not -- is withdrawn. What was read as a scheduling effect on the mean is one
repetition of a wide distribution.

The distribution itself is the retained observation. HIP decode varies eleven
times as much as Vulkan decode across repetitions of an identical workload,
7.4% against 0.7%, on a machine whose desktop and QEMU guest load both arms
equally. A backend that sleeps on a fence hands its wait to the scheduler and
resumes when the work completes; a backend that polls a value in userspace
competes for the CPU it polls on, and that competition varies with whatever else
the machine is doing. The variance separates the backends where the mean shift
did not survive.

Vulkan's 3.07 +/- 0.02 also settles the earlier prefill question in the other
direction. Decode reproduces to better than one percent, so this machine does
not simply vary by ten percent at one repetition, and the 9.3% Vulkan prefill
swing between the policies is unexplained rather than dismissed. Prefill was not
re-run at three repetitions and stays a single-repetition figure.

The verdict rests on none of it. HIP decodes at 2.02 +/- 0.15 against 3.07
+/- 0.02 under the policy the appliance serves under, a separation far outside
either spread, and the falsification criterion is unmet by a margin no
scheduling attribution changes.

The Vulkan row here differs from the figures the README quotes, 21.49 against
22.00 prefill and 3.10 against 3.02 decode. Two things changed at once and this
run separates neither: the protocol split the phases, and the binary is the
dual-backend build rather than the Vulkan-only one, which is why its backend
column reads `ROCm,Vulkan`. Attributing the 2.5% to phase splitting alone would
overstate what the run shows.

The V row is the correct control for H0 regardless, because H0 came from the
same binary in the same protocol. The README figures stay as the serving
numbers, because serving alternates the phases.

## Every HIP arm requires HSA_ENABLE_SDMA=0

With the copy engine enabled, `llama_model_loader::load_all_data` parks in
`hipEventSynchronize` and never returns; the run above completes in 80 seconds
where the same binary hung for 51 minutes.
`evidence/rocm-h0-operational-failure.md` carries the backtrace, the flat
counters, and the termination.

This narrows what TheRock 10.1 repairs. The runtime returns the correct result
from a small-buffer smoke test where Ubuntu 5.7.1 hangs, and a 2.58 GiB tensor
upload reaches the same wait state on both. The copy engine still requires the
variable on this silicon.

## What the split shows about the mechanism

The deficit is larger on prefill than on decode, 48.0% against 36.2%. Prefill is
the compute-bound half and the half that enters rocBLAS, so a `gfx900` Tensile
solution set tuned for a 64-compute-unit Vega 10 running on two compute units is
consistent with the larger gap.

It does not account for the decode gap. Decode is bandwidth-bound and moves
weights at a rate the backend does not change, so a 36.2% decode deficit points
at per-token overhead outside the matrix multiplications: dispatch frequency and
short-kernel synchronization, both untested, and the host wait state, which the
`-t 1` arm has now excluded as a ggml-worker effect while the priority
comparison keeps it alive as an HSA-thread effect.

## Predictions recorded before the arms run

`GGML_CUDA_FORCE_MMQ` is a compile-time option that routes batched quantized
matrix multiplication through ggml's own kernels instead of dequantize plus
rocBLAS. Decode at batch one goes through `mul_mat_vec_q` in `mmvq.cu` whatever
that option says, because the flag governs a choice the batched path makes.

H1 therefore predicts prefill above 12.20 and decode within noise of 1.97. A
decode figure that moves materially falsifies the reading of what the option
controls, and that deviation is the finding rather than a footnote.

H1 remains unbuilt. `GGML_CUDA_FORCE_MMQ` is compiled in, and seeding its tree
by copying the reference tree carried a nested ExternalProject cache naming the
original directory; clearing that prefix regenerated `ggml-vulkan-shaders.hpp`
and forced the Vulkan backend to recompile, where GCC 13 took an internal
compiler error in `mul_mm.comp.cpp` under the memory pressure of a resident
QEMU guest and a saturated zram device. Reconfiguring the reference tree in
place rebuilds the HIP objects alone and is the remaining route, at the cost of
the arms replacing each other rather than coexisting.

## How a partial result is read

The recorded criterion asks for prefill above 22.00 tok/s or decode above 3.02.
A HIP arm that satisfies the prefill half while decode stays near 2.22 refutes
the arithmetic claim that Vulkan holds the reachable prefill performance, and
leaves the serving default where it is: an appliance answering a chat prompt
spends its time in decode, and a backend that loses there loses the deployment
whatever prefill does. The report names which half moved rather than reporting
the disjunction as satisfied.
