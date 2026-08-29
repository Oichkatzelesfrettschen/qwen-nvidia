# The HIP path hangs in model load on this Raven2

The first HIP `llama-bench` run against the dual-backend binary emitted no row
in 46 minutes, against a Vulkan reference that completes the identical shape in
two to three minutes. A backtrace taken before termination shows why, and the
reason is not the one the elapsed time suggests.

## The run

```text
build-qwen-dual/bin/llama-bench
    -m ~/models/Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf
    --device ROCm0 -ngl 99 -p 512 -n 64 -t 2 -r 2

HSA_OVERRIDE_GFX_VERSION=9.0.0
ROCM_PATH=~/.venvs/rocm-gfx900/lib/python3.12/site-packages/_rocm_sdk_devel
```

Start 21:29:58, terminated 22:21, elapsed 51 minutes, zero rows, zero stdout
past the harness banner.

## The process never reached the benchmark

`gdb -p` against the live process places the main thread inside tensor upload:

```text
#0  rocr::core::BusyWaitSignal::WaitRelaxed              libhsa-runtime64.so.1
#1  rocr::core::BusyWaitSignal::WaitAcquire              libhsa-runtime64.so.1
#2  rocr::HSA::hsa_signal_wait_scacquire                 libhsa-runtime64.so.1
#6  hipEventSynchronize                                  libamdhip64.so.7
#7  ggml_backend_cuda_device_event_synchronize           libggml-hip.so.0
#8  llama_model_loader::load_all_data                    libllama.so.0
#9  llama_model_base::load_tensors                       libllama.so.0
#13 llama_bench                                          libllama-bench-impl.so
```

Frame 8 is the weight upload path. Prompt processing, token generation,
rocBLAS, and Tensile kernel selection are all downstream of a call that never
returned, so the run measures none of them. The elapsed time is a hang, not a
slow benchmark.

## The hang is total

Sampled while the process was alive and again 20 seconds later:

| Counter | First | Second | Source |
| --- | --- | --- | --- |
| GTT in use | 3,312,472,064 | 3,312,472,064 | `mem_info_gtt_used` |
| Resident set | 894,340 kB | 894,340 kB | `/proc/PID/status` |
| Read syscalls | 3,255 | 3,255 | `/proc/PID/io` |
| Characters read | 15,632,772 | 15,632,772 | `/proc/PID/io` |

GTT held 3.09 GiB against a 2.58 GiB checkpoint, so most of the upload had
completed and then stopped. Seven GTT samples across 70 seconds moved by one
4 KiB page. A process reading nothing and allocating nothing while its main
thread sits in `BusyWaitSignal` is making no progress at all.

The remaining thread states complete the picture: one worker parked in
`hsaKmtWaitOnMultipleEvents_ExtCtx` on an ioctl, one in the HSA async event
loop, two RADV disk-cache threads on futexes. Nothing is waiting on the host.

## The cost of the wait state

| Observation | Value | Source |
| --- | --- | --- |
| CPU consumed | 2739.7 s over 2760 s wall | `/proc/PID/schedstat` |
| Voluntary context switches | 22 | `/proc/PID/status` |
| Involuntary context switches | 324,903 | `/proc/PID/status` |
| Main thread state | `R`, WCHAN empty | `ps -L` |
| GPU busy | 99%, five samples at one second | `gpu_busy_percent` |
| GPU busy after SIGTERM | 0% | `gpu_busy_percent` |
| Shader clock | 1100 MHz, top DPM state | `pp_dpm_sclk` |
| Swap | 0 | `smaps_rollup` |
| GPU reset, VM fault, thermal throttle | absent | `dmesg` |

`BusyWaitSignal` polls a signal value in userspace rather than sleeping on it,
which is why a deadlocked process holds 99.3% of one of this machine's two
cores. The 99% GPU busy reading belongs to the same stall: sampled again after
termination it reads 0%, and `gpu_busy_percent` counts work resident on the
device rather than work completing, so a queue holding a packet that never
retires reads the same as a queue doing useful arithmetic. The two samples
bracket the kill rather than catching a transition.

## KFD userptr restore runs only during the ROCm run

`amdgpu_amdkfd_restore_userptr_worker` reports overruns past 10 ms four times,
each with a higher count, and every appearance falls inside the run:

```text
run start                       Tue Aug 25 21:29:58
restore_userptr hogged 4 times  Tue Aug 25 21:31:36
restore_userptr hogged 5 times  Tue Aug 25 21:37:08
restore_userptr hogged 7 times  Tue Aug 25 22:06:38
restore_userptr hogged 11 times Tue Aug 25 22:11:34
```

The preceding amdgpu entries are the boot-time ring assignments of Aug 24 and a
single `dm_irq_work_func` overrun at Aug 25 16:01. The worker is the KFD
eviction and restore path for userptr buffer objects, which RADV never enters
because it allocates through the graphics stack rather than through `/dev/kfd`.
The escalating counts continue after upload has stopped advancing, which places
the worker alongside the stall rather than establishing it as the cause.

## This narrows the earlier TheRock conclusion

`evidence/rocm-feasibility-audit.md` records that Ubuntu ROCm 5.7.1 hangs in
`hipMemcpy` at `Host active wait for Signal ... for -1 ns` while TheRock 10.1
returns the correct result. Both halves of that remain true as stated, and the
scope of the second half is now smaller than the audit implies: the TheRock
result came from a smoke test copying a small buffer, and a 2.58 GiB tensor
upload through `hipEventSynchronize` reaches the same wait state on the same
runtime. The newer runtime repairs the smoke test rather than the copy engine.

The two failures share a signature -- a compute or transfer operation that
completes on the device while its completion signal never reaches the host --
and differ in the runtime version and the API entry point. Whether they share a
defect is untested.

## What is settled

RADV Vulkan remains the serving backend, and the falsification criterion is
unreached rather than failed: no HIP row exists to compare against 22.00
prefill tok/s and 3.02 decode tok/s on Qwen3.8-4B Distill Q4_K_M.

The kernel-quality hypotheses -- `gfx900` Tensile solutions mistuned for two
compute units, generic HIP code generation, dispatch frequency -- are untested
rather than supported. Nothing downstream of model load executed.

The next experiment is the signal path, not the kernels. `HSA_ENABLE_SDMA=0`
returned the correct answer at once under 5.7.1, which localized that defect to
the copy engine; the same variable against this upload separates a copy-engine
completion defect from a signal-delivery defect, and it runs before any
kernel-policy arm is worth building.
