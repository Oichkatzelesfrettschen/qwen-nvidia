# A router switch into the 9B distill ends the server on an NVRM allocation refusal

`qwen38-9b-distill` is admitted as a standalone checkpoint and refused as a
router child. Two switches into it ended the whole server, and the kernel ring
names the refusal. One burst, verbatim:

```text
NVRM: GPU0 nvCheckOkFailedNoLog: Check failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from _memdescAllocInternal(pMemDesc) @ mem_desc.c:1338
NVRM: GPU0 nvCheckOkFailedNoLog: Check failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from rmStatus @ system_mem.c:353
NVRM: nvAssertOkFailedNoLog: Assertion failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from pRmApi->Alloc(pRmApi, device->session->handle, isSystemMemory ? device->handle : device->subhandle, &physHandle, isSystemMemory ? NV01_MEMORY_SYSTEM : NV01_MEMORY_LOCAL_USER, &memAllocParams, sizeof(memAllocParams)) @ nv_gpu_ops.c:5077
```

## What the chain establishes

`system_mem.c` sits inside the chain, so the `isSystemMemory` branch of the
`nv_gpu_ops.c:5077` allocation was taken and the class requested was
`NV01_MEMORY_SYSTEM` rather than `NV01_MEMORY_LOCAL_USER`. `nv_gpu_ops.c` is
the driver's UVM interface. The pool that refused is RM-managed system memory
reached through UVM, and the framebuffer counter is not what the driver
reported short.

The refusal is therefore a system-memory allocation refusal rather than
framebuffer exhaustion, and the failure class in `scripts/quarantine.tsv` reads
`nvrm-system-memory-allocation-refusal` rather than `device-lost`. No Xid, no
bus-fallen-off record, no `NV_ERR_GPU_IS_LOST`, and no reset appears in the ring
anywhere in the window; the device answers `nvidia-smi` immediately afterward
and carries no leftover process allocation.

## Observed trigger

```text
resident router child
  -> the router starts the incoming child before it releases the outgoing one
  -> NVRM refuses an NV01_MEMORY_SYSTEM allocation
  -> the server ends
  -> a relaunch inside the same minute meets an unsettled device and fails wider
```

The trigger is the overlapping load of a high-residency child. It reproduces on
the switch into the 9B and on no other transition the sweep ran, and lowering
the 4B to 32768 while excluding the 9B from the router path clears the whole
15-row roster. `--models-max 1` does not avoid it: a sweep at that setting
answered fourteen checkpoints in sequence with a peak of 6010 MiB and then died
on the switch into the 9B, which is the two-child peak the count does not bound.

## What stays unresolved

Which resource ran out. Candidates, none measured here:

- pinned or otherwise unswappable host pages the RM holds for a UVM mapping;
- GPU page-table or virtual-address backing;
- BAR1 mapping pressure or mapping reuse state;
- a transient CUDA allocation inside the incoming child's load that no sampler
  caught;
- device-memory pressure that pushed the driver onto the system-memory path in
  the first place, which the chain neither confirms nor excludes.

`RLIMIT_MEMLOCK` is observed and not approached: the serving user's limit is
8192 kB and `/proc/meminfo` reports `Mlocked: 1032 kB` at rest, and a UVM
system-memory allocation is a kernel page allocation rather than a charge
against the calling process's limit. It is recorded here so a later reader does
not re-open it without a measurement.

The ring separates a fatal refusal from a recoverable one and the counts are
read rather than summarised. Over the session's 24 hours, 69 distinct seconds
carry the terminating `nv_gpu_ops.c:5077` chain and 34 carry
`_kgmmuClientShadowFaultBufferPagesAllocate: Allocation failed with big page
size, retrying with default page size`, of which 31 seconds carry both. The
fault-buffer line retries at the default page size and continues, so it is not
the fatal line: the last one at 20:44:46 local landed inside a launch that then
served for 57 seconds. Which allocation inside a second carrying both was fatal
against which was recoverable is unread.

The kernel ring carries no Xid, no `RmInitAdapter` failure, no fallen-off-bus
record, and no `NV_ERR_GPU_IS_LOST` across the same window.

Host memory was not short: `MemAvailable` sat near 20 GB at rest and at
sampling after the refusals.

## The same chain fires without a switch

`evidence/ada/b789-path-audit/` records the identical three-line chain from a
single-process `llama-bench` holding one model, three times, with no router and
no second child. `MemAvailable` read 21649564 kB and the framebuffer 1429 MiB
of 12282 at the time, and every one of those arms completed and returned its
rates.

The chain is a code path rather than a cause. `system_mem.c:353` names the RM's
system-memory allocator, and two callers reaching it while refusing different
resources print the same three lines, so those instances and these are
consistent with two unrelated phenomena. One asymmetry separates them: Nsight
Systems is present in all three of the new instances and absent in both router
instances, and every arm of that audit ran under it, so the profiler is a
candidate allocating party there and no candidate at all here.

This record's verdict therefore stands on the router evidence alone. What the
new instances add is a bound on the reading rather than a narrowing of it: the
same chain can fire with host memory and framebuffer both far from short and
without ending the workload, so its appearance in the ring is not by itself
evidence that a resource this record lists ran out. The switch-time
instrumentation campaign in the re-entry gate is still what would name the pool,
and the clean boot's first unprofiled arm is what separates the profiler from
the device.

## Arithmetic that makes the switch unsafe without naming the pool

The 9B carries 5.37 GiB of weights and reaches about 6.3 GiB with its
16384-token cache; the 4B distill at 65536 measures 4100 MiB. The overlap asks
for roughly 10.4 GiB of model and cache while the compositor holds 1.4, against
a 12282 MiB carve-out. That leaves a small unmeasured margin for CUDA graphs,
context construction, BAR1 mappings, page tables, and pinned staging, which is
enough to call the switch unsafe and not enough to identify the refused pool.

## Scope

Model scope against the router path, matching `ministral3-3b`. The checkpoint
loads and serves standalone: `evidence/ada/baseline-sweep-02/` measures it at
4410.81 prefill and 67.91 decode tok/s, and `evidence/ada/context-depth-64k/`
loads it at 32768 and 49152 alone. An exact-tuple profile row would readmit an
unmeasured 9B router geometry the moment a context field moves, and no 9B router
geometry has been measured safe.

## Re-entry gate

Any one of these admits it back:

- an evict-before-load router mode that releases the outgoing child and proves
  its allocations returned before the incoming child allocates, which removes
  the overlap the trigger names;
- a switch-time instrumentation campaign that samples framebuffer, BAR1,
  per-process CUDA memory, and the host's locked and page-table counters fast
  enough to name the pool, followed by a measured pair that fits it;
- a smaller quantization of the 9B whose overlap fits with headroom.

The first two are unrun.

## Re-entry

The first gate condition is met and the row is lifted.
`evidence/ada/evict-first-9b-readmission/` carries two runs of
`scripts/admit-evict-first-transition.sh` on the pinned tree at
`--models-max 1`: the roster poll reads the 2B unloaded about 2.2 seconds
before the 9B enters loading, the 100 ms framebuffer trace shows the
trough between plateaus at 1227-1228 MiB against a 1199 MiB desktop rest,
and the peak reaches 7579 MiB of the 12282 carve-out. The overlap this
record names as the trigger did not occur, and the transition windows
carry no NVRM line. `scripts/models.tsv` pins the row at
`switch_policy=evict-first`, which `qwen-capacity-policy.sh` enforces by
refusing any router launch wider than one resident.
