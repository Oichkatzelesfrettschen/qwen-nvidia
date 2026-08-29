# Vulkan submission trace: naming the dispatch that fails to retire

`evidence/quarantine/qwen38-4b-distill-d16384-b2048-ub512.md` records a ring
timeout at depth 16384 with batch 2048 and ubatch 512, and a separate gfxhub
page fault at address `0x0` at the same depth and cache triple. The two
signatures differ in what the driver reported, and nothing in the retained
evidence attributes either to an operation: `vk::Queue::submit` threw
`ErrorDeviceLost`, and a lost queue reports only that the queue is gone. The
host side is where the identity of the failing dispatch still exists.
`patches/llama-vulkan-submit-trace.patch` retains it.

## What the pinned commit already provides

llama.cpp at `f280b26983ad0fdb705a0d9ebf0503e76f2899b0` detects
`VK_EXT_device_fault`, loads `vkGetDeviceFaultInfoEXT`, and prints its
description, address records with type, address, and precision, and its vendor
records from `ggml_vk_print_device_fault_info`. `ggml_vk_print_device_lost_info`
calls that printer and adds the node range of the previous submission from
`diag_cgraph`, `diag_prev_start`, and `diag_prev_end`, and the `DeviceLostError`
catches in `VK_CHECK`, in both queue-handle submit wrappers, and in
`ggml_backend_vk_graph_compute` reach it. Three of the four capabilities the
quarantine record registers therefore exist upstream, and the fifth patch adds
the fourth: a per-dispatch record naming the operation, the pipeline, the
dispatch geometry, and every buffer the dispatch bound.

## The record

`ggml/src/ggml-vulkan/ggml-vulkan-submit-trace.h` follows the pacing and
submit-limit headers: a parse function that accepts the exact value `1` and
throws otherwise, and the plain data the translation unit uses.
`GGML_VK_SUBMIT_TRACE=1` sets `device->submit_trace.enabled` at device
creation, and a ring of 256 fixed-size records lives on `vk_device_struct`
because every device-lost catch site holds a `vk_device` or a `vk_device_ref`
and nothing else.

Each record carries the submission serial, the graph node index, the ggml
operation name, the `src[0]`, `src[1]`, and destination tensor names, the
pipeline name, the dispatch grid, the pipeline's workgroup denominators, and up
to twelve descriptor buffer handle, offset, and size triples, which is
`MAX_PARAMETER_COUNT` and therefore every buffer a dispatch can bind. The
handle travels beside the span because a `vk::DescriptorBufferInfo` offset is
relative to its own `VkBuffer`, so a span alone names no allocation. Two sites
fill it. `ggml_vk_build_graph` publishes the node index, operation, and tensor
names for the node it is recording; `ggml_vk_dispatch_pipeline` appends one
record per `vkCmdDispatch` with the pipeline, the computed workgroup counts, and
the descriptor spans. Names are copied into fixed `char[64]` arrays inside the
guarded block, because the dump runs after the device is lost and a pointer into
a graph or a pipeline is a claim about lifetime that the dump cannot check.

Fence state is derived rather than queried. The serial advances when a batch
reaches the queue, and the two paths that submit mark it: `submit_after` in
`ggml_backend_vk_graph_compute` for every flushed batch, and
`ggml_vk_synchronize` for the tail the graph leaves behind. Each marks the
completed serial after `waitForFences` returns success. A record reads
`retired`, `submitted`, or `recorded` by comparing its own serial against those
two marks. A fence query per record would cost a round trip at record time and
would answer a question about a submission that has not happened yet.

Retirement marking lives on the serialized path, because that is where a fence
is waited on at all: under `GGML_VK_SERIALIZE_SUBMISSIONS` absent,
`last_completed_serial` stays zero and every record reads `submitted` or
`recorded`. Upstream gates its own node-range print the same way. A traced arm
therefore sets `GGML_VK_SERIALIZE_SUBMISSIONS=1`, which is what the two named
serialized profiles already export.

The dump prints every record no fence has retired, bounded by the 256 the ring
holds, rather than a fixed tail. A node is not a dispatch -- `mul_mat` with
split_k issues two and flash attention up to three -- so a fixed count under
`GGML_VK_MAX_NODES_PER_SUBMIT=32` can truncate before the batch boundary and
hide where the failing submission started.

Cost when disabled is one load and one branch at each of the two sites. The
guard precedes every string copy, so a disabled trace constructs nothing.

## The launch chain passes it through `custom`

`remote/radv-low-priority-env.sh` unsets an enumerated list of `GGML_VK_*`
variables so that a named profile means one thing, and
`GGML_VK_SUBMIT_TRACE` joins that list. The `custom` profile records the
requested value before the scrub and restores it afterwards, which is the same
mechanism `GGML_VK_MAX_NODES_PER_SUBMIT` and `GGML_VK_SERIALIZE_SUBMISSIONS`
already use, so a traced arm and an untraced arm differ in one variable:

```sh
QWEN_VULKAN_PROFILE=custom GGML_VK_SUBMIT_TRACE=1 \
    GGML_VK_SERIALIZE_SUBMISSIONS=1 GGML_VK_MAX_NODES_PER_SUBMIT=32 \
    ~/qwen-laptop-setup/remote/qwen-launch.sh
```

`remote/test-radv-low-priority-env.sh` asserts what each of the three named
profiles exports after the scrub and ends on a `vulkaninfo` assertion naming
RADV RAVEN2, so the full test passes on the laptop alone.

## The five failure classes and what recognises each

The trace supplies one discriminator among several. Each class below names what
supplies the rest, so that a class is never assigned on the trace alone.

`ring-timeout-only`. The kernel log carries a ring timeout and a reset with zero
fault lines, `vkGetDeviceFaultInfoEXT` returns zero address and zero vendor
records, and the trace shows one serial submitted with no retirement mark. The
unretired set then names the dispatches that batch contained, which is the set
the timeout is charged to.

`gfxhub-page-fault`. The kernel names a faulting virtual address. The trace
narrows what that address can belong to: the unretired records name every
buffer handle the failing submission bound and the span of each, so the fault is
charged to a dispatch once one of those buffers is resolved to a base address.
That resolution lives in the memory binding rather than in the record, so the
attribution the trace delivers by itself is buffer-relative and the kernel VA
correlation needs the allocation base beside it. The address `0x0` the retained
coredump names resolves against no buffer at all, which is itself a finding
about the class rather than about a node.

`vm-protection-fault`. A nonzero protection-fault status in the kernel record
separates this from the page fault above. The kernel supplies the
discriminator; the trace supplies the same address attribution.

`device-lost-without-kernel-record`. `vk::DeviceLostError` is thrown and the
kernel log carries no reset and no fault line at all. The trace is then the only
retained account of what the device was holding, and its unretired set plus the
submitted and retired serials are the whole record.

`post-reset-control-failure`. The post-arm control at the served `128/32`
geometry fails after a wedging arm. Registered and unobserved: every control in
the quarantine record passed, including the one immediately after the wedge, so
the device recovered fully in every measured case.

The classes stay distinguished. A page fault at `2048/32` where a bare timeout
appears at `2048/512` establishes at least two mechanisms and forbids merging
their explanations, which is the outcome the orthogonal series is run to reach.

## Build state

`cmake -B build-trace -DGGML_VULKAN=ON` on the workstation fails during
configuration: the `ggml-vulkan` target requires SPIRV-Headers, and the
workstation has `glslc` and `vulkan_core.h` without it. Compiling the
`ggml-vulkan` target is therefore `not run` with that dependency named, and no
package was installed. `g++ -std=c++17 -fsyntax-only` over
`ggml-vulkan-submit-trace.h` passes, which is a partial result about the header
alone and says nothing about the nine hunks in `ggml-vulkan.cpp`.
`remote/verify-llama-patch-series.sh` replays all five patches against a
pristine checkout of the pinned commit and matches every recorded digest, so the
patch applies and its result is fixed; whether it compiles is open until the
laptop builds it.

## Deployment gate

The patch reaches the laptop only after the running depth campaign finishes. A
change in this tree is inert on the appliance until it is rsynced to
`~/qwen-laptop-setup/remote/` and llama.cpp is rebuilt there by
`remote/build-llama-vulkan.sh`, so nothing lands mid-campaign by accident and
the gate is a decision rather than a race.

The orthogonal batch and ubatch reset series registered in the quarantine record
waits on this instrumentation. Its arms are terminal measurements: each starts
from a known-safe geometry and stops at the first reset, so an arm that wedges
without a trace spends a reset and returns a correlation. `2048/32` is the
decisive single arm and is the first one that must run traced.
