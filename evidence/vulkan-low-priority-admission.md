# Raven2 Vulkan Low-Priority Queue Admission

## Result

The installed RADV stack admits a headless low-global-priority compute queue on
Raven2. The verified device and queue are:

```text
device=AMD Radeon Graphics (RADV RAVEN2) vendor=0x1002 device=0x15d8 queue_family=1 global_priority=LOW result=VK_SUCCESS
```

The probe used the RADV ICD directly, created no display surface, submitted no
GPU workload, and ran under one-core affinity, nice level 19, and idle I/O
priority. Source: `remote/vulkan-low-priority-probe.c`.

## Runtime capabilities

The installed `vulkaninfo` reports:

- `VK_KHR_global_priority`, revision 1;
- `VK_EXT_global_priority`, revision 2;
- `VK_EXT_global_priority_query`, revision 1;
- `globalPriorityQuery = true`; and
- LOW and MEDIUM priorities for both the graphics/compute family 0 and the
  compute-only family 1.

llama.cpp selects family 1 because `GGML_VK_ALLOW_GRAPHICS_QUEUE` is unset and
the family supports compute without graphics. Family 1 exposes four queues.

## llama.cpp path

At commit `f280b26983ad0fdb705a0d9ebf0503e76f2899b0`,
`ggml/src/ggml-vulkan/ggml-vulkan.cpp`:

1. enumerates physical devices and device extensions;
2. selects compute and transfer queue families;
3. creates one or two `vk::DeviceQueueCreateInfo` records with ordinary float
   priorities set to 1.0;
4. creates the logical device;
5. retrieves queues with `getQueue2()`; and
6. submits all compute and transfer work through those queue handles.

No global-priority structure is present in the selected revision, so the
driver uses MEDIUM by default.

## RADV and kernel mechanism

Upstream RADV reads `VkDeviceQueueGlobalPriorityCreateInfo` from each queue
create record. With no structure, `radv_get_queue_global_priority()` selects
MEDIUM. With LOW, RADV creates or selects a low-priority winsys context and
passes the mapped AMDGPU priority to `ac_drm_cs_ctx_create2()`. An unpermitted
priority returns `VK_ERROR_NOT_PERMITTED`.

Relevant upstream sources inspected on 2026-08-24:

- https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/amd/vulkan/radv_device.c
- https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/amd/vulkan/radv_queue.c
- https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/amd/vulkan/winsys/amdgpu/radv_amdgpu_cs.c

The successful local `vkCreateDevice()` call proves that the installed Mesa,
libdrm, and amdgpu stack accepts the LOW context. The upstream source explains
the mechanism but does not substitute for the runtime proof.

## Local-fork design

`GGML_VK_LOW_PRIORITY=1` will be an opt-in flag in the pinned local fork. When
unset, device creation remains unchanged. When set, the backend must:

- require `VK_KHR_global_priority`;
- query each selected queue family and require LOW support;
- add `VkDeviceQueueGlobalPriorityCreateInfoKHR` to every compute and transfer
  queue-create record;
- enable the KHR device extension;
- report that LOW was selected; and
- stop initialization if the extension, family priority, or permission check
  fails.

The launcher will always set the flag for laptop inference. Silent fallback to
MEDIUM would violate the desktop-priority policy.

The implementation is applied to the remote checkout and retained as
`patches/llama-vulkan-low-priority.patch`. `git diff --check` passes, and the
retained patch passes `git apply --reverse --check` against the modified
checkout. Compilation and positive/negative binary tests remain gated on the
Vulkan shader build dependencies.

`remote/test-vulkan-low-priority.sh` passes warning-clean ShellCheck, POSIX shell
syntax validation, and the standalone C build with all warnings as errors. Its
headless probe creates the LOW queue directly. Its model-backed server test
keeps the unset default unchanged and observes `global queue priority = LOW`
only when `GGML_VK_LOW_PRIORITY=1` is supplied. The server loads the pinned
TinyLlama fixture and creates no display surface or remote listener.

## Boundary

LOW gives the kernel and RADV a lower scheduling class. It does not prove a
specific frame-time bound or guarantee that memory-bandwidth contention cannot
affect the desktop. Admission still requires compositor/frame responsiveness,
memory reserve, temperature, and device-loss telemetry under the real model
workload.

Mesa reads `AMD_PRIORITY` when it creates the amdgpu context, after RADV maps
the Vulkan request. The qwen-apu wrapper clears that variable so an inherited
override cannot replace LOW. The llama.cpp patch accepts only the exact value
`GGML_VK_LOW_PRIORITY=1`; zero, an empty value, and arbitrary strings fail
before device creation. Linux 7.0 maps `AMDGPU_CTX_PRIORITY_LOW` and
`AMDGPU_CTX_PRIORITY_VERY_LOW` to the same DRM scheduler and hardware priority,
so LOW is the lowest distinct class on the running stack.

Upstream issue 23950 records the same desktop-responsiveness need for NVIDIA's
different occupancy-priority extension. It does not implement or validate the
AMD global-priority mechanism used here:
https://github.com/ggml-org/llama.cpp/issues/23950.
