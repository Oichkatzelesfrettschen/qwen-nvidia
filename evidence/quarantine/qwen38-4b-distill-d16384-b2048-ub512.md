# Quarantined profile: Qwen3.8-4B Distill at 16384 with batch 2048 and ubatch 512

```text
id             qwen38-4b-distill-d16384-b2048-ub512
scope          profile
subject        qwen38-4b-distill
model file     Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf
failure class  ring-timeout-only
tuple          depth 16384, batch 2048, ubatch 512, K q8_0, V q4_0, Flash Attention on
first evidence evidence/kv-cache-policy-factorial.md
latest evidence evidence/depth-versus-submission-geometry.md
```

The checkpoint is not quarantined. This one tuple is.

## Kernel signature

```text
ring comp_1.1.1 timeout, signaled seq=19922, emitted seq=19924
Starting comp_1.1.1 ring reset  ->  reset succeeded
[drm] device wedged, but recovered through reset
```

`llama-bench` threw `vk::Queue::submit: ErrorDeviceLost` and aborted with
SIGABRT. The arm logged zero fault lines, so the class is `ring-timeout-only`.

An earlier wedge at the same depth and cache triple, recorded in
`evidence/kv-cache-policy-factorial.md` and retained as
`evidence/model-admission/amdgpu-coredump-d16384-served-cache.txt`, reset
`comp_1.3.0` and produced a coredump naming a gfxhub page fault at address
`0x0` with a zero protection-fault status. The two signatures differ in what the
driver reported, so they are recorded as two observations rather than merged
into one mechanism. Whether they share a cause is undecided and the
instrumentation that would decide it is registered below.

## Validated safe tuples

Same depth, same cache triple, same Flash Attention state, same device, minutes
apart:

| depth | batch | ubatch | status | decode tok/s | wall | post-arm control |
| ---: | ---: | ---: | --- | ---: | ---: | --- |
| 16384 | 2048 | 512 | wedge | n/a | 508 s | pass 3.23 |
| 16384 | 128 | 32 | pass | 2.32 | 1361 s | pass 3.34 |
| 16384 | 32 | 8 | pass | 1.99 | 3993 s | pass 2.49 |
| 8192 | 2048 | 512 | pass | 2.27 | 515 s | pass 2.87 |
| 8192 | 128 | 32 | pass | 2.55 | 700 s | pass 3.28 |

`128/32` is the served geometry and is what `remote/models.tsv` carries in the
`batch` and `ubatch` fields for this row. Every control passed including the one
following the wedge, so the device recovers fully and the failure is one
rejected execution graph rather than persistent corruption.

## What the allocation column refutes

The wedging arm peaked at 1965 MiB of the 2048 MiB VRAM carve-out, below both
passing 8192 arms at 2029 and 2022 MiB, so exhausting the carve-out is not the
mechanism. GTT peaked at 2820 MiB for the wedging geometry against 2321 and 2383
for the two surviving 16384 arms, which correlates with submission size and is
not monotone in it, so scratch demand stays a correlate rather than a
demonstrated cause.

## Re-entry gate

The tuple leaves quarantine on either of two outcomes and on no other basis.

A backend or driver correction is identified, and the tuple then passes a
reproduction run in reversed arm order with zero resets, zero faults, zero
device losses, and a passing post-arm control at the served geometry. Reversed
order is required because the wedging arm ran third of five and run state has
not been excluded.

Or the project rejects the geometry permanently and records `128/32` as the
maximum admitted serving submission geometry for this checkpoint, at which point
the row moves from quarantine to a documented policy limit.

Smaller geometries already working is not a re-entry condition. The tuple is
quarantined for what it did, not for what its neighbours do.

## Instrumentation registered, not run

The three measured points fix the endpoints and leave `batch`, `ubatch`, and
their interaction unseparated. Two orthogonal series decide it, each starting
from a known-safe arm and stopping at the first reset, because a reset is a
terminal measurement rather than another point:

```text
hold batch 2048:  ubatch 512, 256, 128, 64, 32
hold ubatch 32:   batch 128, 256, 512, 1024, 2048
cross-checks:     128/128, 512/512
```

`2048/32` is the decisive single arm. It passes if the 512-token physical
microbatch or its generated dispatch dominates; it wedges if the 2048 logical
batch, its graph construction, its persistent scratch, or its queued operation
count remains causal. A page fault there rather than a bare timeout establishes
at least two failure modes and forbids merging their explanations. `128/128`
separates the opposite direction: passing puts the weight on logical batch size,
wedging puts it on a physical microbatch at or above 128.

Moving past correlation needs the backend to name the operation that fails to
retire. Vulkan debug labels carrying graph-node number, operation, tensor names,
pipeline name, and dispatch dimensions; the last node submitted before
`vkQueueSubmit` and the last completed fence recorded; `vkGetDeviceFaultInfoEXT`
called on `VK_ERROR_DEVICE_LOST` where the extension is present; and buffer
spans, workgroup dimensions, batch, ubatch, depth, and cache layout retained
beside each. The failure classes stay distinguished permanently rather than
collapsed: `ring-timeout-only`, `gfxhub-page-fault`, `vm-protection-fault`,
`device-lost-without-kernel-record`, `post-reset-control-failure`.
