# Raven2 Vulkan Priority-First Policy

## Effective priority floor

`VK_KHR_global_priority` defines LOW as the minimum application-visible global
queue priority and describes it as suitable for non-interactive work. The
patched llama.cpp requests LOW on every compute and transfer queue and fails
closed when the device does not advertise or permit it.

Mesa 26.2.1 maps that request through:

```
VK_QUEUE_GLOBAL_PRIORITY_LOW
 -> RADEON_CTX_PRIORITY_LOW
 -> AMDGPU_CTX_PRIORITY_LOW
 -> DRM_AMDGPU_CTX
 -> DRM_SCHED_PRIORITY_LOW
```

Linux 7.0 also accepts `AMDGPU_CTX_PRIORITY_VERY_LOW`, but
`amdgpu_ctx_to_drm_sched_prio()` maps LOW and VERY_LOW to the same
`DRM_SCHED_PRIORITY_LOW` run queue. Both values also select the normal GFX pipe
and ring hardware priority. A custom RADV remap from -512 to -1023 therefore
cannot create a lower effective scheduling class on the running kernel.

Mesa's `ac_drm_cs_ctx_create2()` reads `AMD_PRIORITY` after RADV translates the
Vulkan request. An inherited value can silently override LOW. The launcher
clears `AMD_PRIORITY`, and the llama.cpp patch accepts only the exact
`GGML_VK_LOW_PRIORITY=1` opt-in.

The pinned Vulkan backend also accepts `GGML_VK_ENABLE_MEMORY_PRIORITY`, which
adds allocation priority 1.0 through `VK_EXT_memory_priority`. That policy and
RADV settings such as `RADV_PERFTEST=nogttspill` favor model allocation
residency over competing allocations. The launcher clears every inherited
`GGML_VK_*` tuning variable, the Mesa/RADV priority and performance variables,
Vulkan layer injection variables, `DRI_PRIME`, and graphics-queue selection
before it applies one closed qwen-apu profile.

Primary sources:

- https://registry.khronos.org/vulkan/specs/latest/man/html/VK_KHR_global_priority.html
- https://registry.khronos.org/vulkan/specs/latest/man/html/VkQueueGlobalPriority.html
- https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.1/src/amd/vulkan/radv_queue.h
- https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.1/src/amd/vulkan/winsys/amdgpu/radv_amdgpu_winsys.h
- https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-26.2.1/src/amd/common/ac_linux_drm.c
- https://github.com/torvalds/linux/blob/v7.0/include/uapi/drm/amdgpu_drm.h
- https://github.com/torvalds/linux/blob/v7.0/drivers/gpu/drm/amd/amdgpu/amdgpu_ctx.c
- https://github.com/torvalds/linux/blob/v7.0/drivers/gpu/drm/scheduler/sched_main.c
- https://github.com/torvalds/linux/blob/v7.0/drivers/gpu/drm/amd/amdgpu/amdgpu_job.c

## Submission boundary

The DRM scheduler chooses the highest-priority ready entity before it calls
`amdgpu_job_run()`. That function submits the selected job's complete IB
through `amdgpu_ib_schedule()`. The inspected path establishes priority at job
selection boundaries; it does not establish arbitrary preemption within one
submitted IB.

llama.cpp already splits weak-AMD graphs by estimated FLOPs and node count.
`llama-vulkan-runtime-submit-limit.patch` makes the node limit a validated
runtime value. The paced and serialized profiles fix it at 32. The serialized
profile waits for each fence before it submits more low-priority work, which
limits the process to one in-flight model job. The first 32-node async run
produced a 20.017 ms MEDIUM fence, so the admitted async retest uses 16-node
boundaries while retaining multiple in-flight low-priority jobs.

## Closed profiles

| Profile | LOW | In-flight policy | Model sleep | Busy stop | Admission |
| --- | --- | --- | --- | --- | --- |
| `paced-60` | required | serialized | 60% duty | 75% aggregate | Retained control |
| `low-serialized` | required | one fenced job | none | 100% observation ceiling | Candidate daily profile |
| `low-async` | required | asynchronous, 16 nodes | none | 20 ms MEDIUM service | Experimental throughput arm |

`low-serialized` replaces an aggregate utilization cap with a service-latency
gate. `vulkan-graphics-service-probe.c` owns a MEDIUM-priority graphics-family
queue and submits a small barrier command every 16 ms. The server stops when
one fence takes more than 20 ms or when the probe disappears. This observes
whether normal-priority graphics work receives GPU service while the LOW model
queue remains busy. It creates no surface, opens no display connection, and
does not operate the remote GUI.

The probe is a scheduler and contention oracle, not a frame-time measurement.
It does not observe scanout, compositor CPU work, memory-bandwidth effects on a
specific desktop frame, or human input latency. A user report of degraded
desktop performance remains an immediate stop condition even when the probe
passes.

The model server remains nice 19 on CPU 0. The latency, resource, and kernel
guards run at normal CPU priority on CPU 1 so model-side CPU contention cannot
delay the observer and masquerade as GPU queue latency. Their work is limited
to one small queue submission every 16 ms, one sysfs sample per second, and
kernel-log polling.

## Falsifiers

The priority-first profile fails admission if any condition occurs:

- LOW is unavailable, denied, or absent from the real server log;
- `AMD_PRIORITY` reaches the child process;
- the profile's 32- or 16-node limit is absent from the real server log;
- more than one model submission remains in flight under `low-serialized`;
- a MEDIUM graphics-family fence exceeds 20 ms;
- the graphics-service probe exits while the server remains alive;
- a ring timeout, GPU reset, VM fault, device loss, or OOM appears;
- strict Vulkan placement detects a CPU tensor or graph node; or
- the laptop user reports degraded desktop response.

The 4B control runs first under `paced-60`, then `low-serialized`. The 9B
Distill and admitted 27B quantizations use `low-serialized` only after that
comparison proves the watchdog and shutdown path under the real Web server.

The equal-request 4B comparison admits `low-serialized` at 11.437 prompt tok/s
and 1.316 decode tok/s. The 32-node async arm is rejected at a 20.017 ms
MEDIUM fence. The bounded 16-node async arm passes at 14.103 prompt tok/s,
2.713 decode tok/s, and 11.185 ms maximum MEDIUM service. It remains
experimental until an external desktop-input oracle and a longer thermal soak
pass. Evidence and percentile calculations are in
`evidence/benchmarks/qwen35-4b-vulkan-priority-comparison.md`.
