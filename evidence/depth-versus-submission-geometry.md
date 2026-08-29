# Whether the 16384 wedge indicts depth or submission geometry

`evidence/kv-cache-policy-factorial.md` records a compute-ring wedge: at 16384
tokens with the served cache triple, a submission failed to retire before the
amdgpu timeout, the driver reset the ring, and the subsequent control passed.
The exact kernel-level cause remains unisolated. Both wedges this tree has
recorded were found under `llama-bench` at its own batch defaults, `-b 2048
-ub 512`, while the guarded server runs `--batch-size 128 --ubatch-size 32`.
Depth and submission size are therefore confounded, and the 4B's 24576
interactive ceiling rests on which one is responsible.

## Configured allocation is not validated depth

```text
configured context capacity:        24,576
filled and decoded depth validated: not established
```

A server that loads a 24576-token allocation has proven it can reserve the
memory. It has not proven that a near-full cache executes. The registry field
the ceiling lives in is a scalar, and the capability being measured is a tuple:

```text
(model, cache policy, flash-attention policy, batch, ubatch, validated filled depth)
```

## The arms

`remote/probe-depth-wedge.sh` crosses two depths with three submission
geometries at the served cache triple, `q8_0`/`q4_0` with Flash Attention on.

| geometry | batch | ubatch | role |
| --- | ---: | ---: | --- |
| harness default | 2048 | 512 | establishes that the wedge reproduces |
| served | 128 | 32 | decides whether the shipped configuration is exposed |
| below served | 32 | 8 | decides which way to move if it is |

Each arm ends with a shallow control at the served geometry. A ring reset that
recovers leaves the control passing and the wedge is one rejected graph; a
control that fails establishes persistent device corruption, and the probe halts
rather than measuring a broken device.

Each arm retains its batch and microbatch, its evaluated depth, the cache types
and Flash Attention state it ran under, its peak device memory, arm wall time,
steady-state decode, the kernel lines the arm emitted verbatim with ring-reset
and fault counts grepped from that delta rather than from the whole buffer, the
control status and rate, and the modal memory clock and peak die temperature.

Device memory comes from amdgpu's own accounting sampled at 1 Hz through the
arm, `mem_info_vram_used` against the 2 GiB carve-out and `mem_info_gtt_used`
against the system memory the driver maps, and the peak of each is reported
because the KV cache grows through the prefill. Reading the driver rather than
the log is what makes the field survive the case it exists for: `llama-bench`
prints no buffer sizes at default verbosity, and an arm that wedges prints
nothing at all. The device holds far more in GTT than in the carve-out -- 2626
MiB against 2024 MiB under load, against 467 and 367 at idle -- so a ceiling
argued from the 2 GiB figure alone describes the smaller of the two pools.

Prefill wall time and first-decode latency are not separable under `llama-bench`,
which reports steady-state rates and a single arm duration. Separating them
requires the served path, and this probe records arm wall time and steady-state
decode in their place.

## Registered interpretation

Fixed before the run:

| 8192 served | 16384 served | 16384 below served | conclusion |
| --- | --- | --- | --- |
| pass | pass | pass | the wedge is a large-batch harness artefact; the served policy stands and 24576 full occupancy is tested separately |
| pass | wedge | pass | ubatch 32 crosses a Raven2 submission threshold at 16K; reduce the served microbatch and depth stays viable |
| pass | wedge | wedge | the q8_0/q4_0 Flash-Attention graph is unsafe at 16K under both practical geometries; the admitted filled-depth ceiling comes below 16K pending a backend fix |
| pass | pass | wedge | run state or ordering, because a smaller microbatch should not uniquely fail with nothing else changed; repeat in reversed order before concluding |
| wedge | - | - | the deep-context policy is unsafe below its published operating point; stop and re-establish the highest stable depth from below |

No ceiling moves before the two 16384 arms land.

## Amendment: the 8192 reduced-geometry arm is conditional

`d8192-b32-ub8` is conditional. It runs only if `d8192-b128-ub32` fails or
leaves the post-arm control unhealthy. Successful 8K operation at both
`2048/512` and `128/32` already validates the depth and brackets the deployed
geometry; the smaller 8K arm cannot discriminate among the 16384 failure
mechanisms.

The three 16384 arms answer the matrix on their own:

| 2048/512 | 128/32 | 32/8 | interpretation |
| --- | --- | --- | --- |
| wedge | pass | pass | the harness-default submission geometry caused the failure and the served geometry is viable |
| wedge | wedge | pass | 16K is viable only with smaller submissions; the served batch and microbatch come down |
| wedge | wedge | wedge | the depth or the deep attention graph is unsafe at 16K |
| pass | pass | pass | the original failure depended on run state or another uncontrolled variable; reproduce before changing policy |
| wedge | pass | wedge | internally inconsistent, because a smaller geometry uniquely failing is not the expected relation; reverse the order and repeat |

## The 8192 allocation result stands on its own

```text
VRAM: 2029 / 2048 MiB
GTT:  2700 MiB
```

The fixed carve-out is saturated at 8192 tokens and the allocation continues
through GTT, so the 16384 arms test driver allocation, graph construction, and
submission behaviour across both pools rather than whether a KV cache fits in
2 GiB. Depth costs 21% by itself at this rung: 2.27 tok/s at 8192 against the
post-arm control's 2.87 at depth 0, same geometry, ninety seconds apart.

## Results

| arm | status | resets | faults | decode | vram peak | gtt peak | wall | control |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| d8192 b2048 ub512 | pass | 0 | 0 | 2.27 | 2029 | 2700 | 515 s | pass 2.87 |
| d8192 b128 ub32 | pass | 0 | 0 | 2.55 | 2022 | 2173 | 700 s | pass 3.28 |
| **d16384 b2048 ub512** | **wedge** | **1** | **0** | n/a | 1965 | 2820 | 508 s | pass 3.23 |
| d16384 b128 ub32 | pass | 0 | 0 | 2.32 | 1986 | 2321 | 1361 s | pass 3.34 |
| d16384 b32 ub8 | pass | 0 | 0 | 1.99 | 1965 | 2383 | 3993 s | pass 2.49 |

**The registered matrix resolves to its first row: the harness-default submission
geometry caused the failure and the served geometry is viable at 16384.** The
wedging arm and the two surviving arms differ in submission size alone -- same
depth, same `q8_0`/`q4_0` cache, same Flash Attention state, same device, minutes
apart -- so submission geometry rather than depth decides whether the ring
retires its work.

The failure is a bare ring timeout:

```text
ring comp_1.1.1 timeout, signaled seq=19922, emitted seq=19924
Starting comp_1.1.1 ring reset  ->  reset succeeded
[drm] device wedged, but recovered through reset
```

`llama-bench` threw `vk::Queue::submit: ErrorDeviceLost` and aborted. Every
control passed, including the one after the wedge, so the device recovers fully
and the failure is one rejected graph rather than persistent corruption.

## Two readings the allocation column refutes

**Exhausting the VRAM carve-out is not the mechanism.** The wedging arm peaked at
1965 MiB, below both 8192 arms at 2029 and 2022 which passed. The carve-out is
saturated from 8192 onward in every arm and the depth that fails holds less of
it than the depths that succeed.

**A page fault is not involved.** `evidence/model-admission/amdgpu-coredump-d16384-served-cache.txt`
records a gfxhub page fault at address `0x0` for the earlier wedge under the
served cache triple. This wedge logs no fault of any kind, so the two events
share a ring reset without being shown to share a cause.

## Scratch size correlates with the wedge without being shown to cause it

The wedging geometry allocates about 500 MiB more GTT than either surviving one
at the same depth, and the same pair differs by 527 MiB at 8192 where both pass.
The two surviving geometries refuse to order by submission size, though: `128/32`
holds 2321 MiB and the smaller `32/8` holds 2383. Scratch demand therefore
separates the wedging arm from the surviving ones without being monotone in
submission size, which leaves it a correlate rather than a mechanism.

`128/32` is also the fastest of the three at depth, decoding 2.32 tok/s against
`32/8`'s 1.99 and prefilling 16384 tokens in 1361 s against 3993. The served
geometry is the operating point on both axes measured here.

## What is validated, and what is still not

```text
(Qwen3.8-4B-Distill Q4_K_M, q8_0/q4_0, flash attention on, batch 128, ubatch 32)
    validated filled depth: 16384
    configured context default: 24576
```

**The 24576 interactive default remains unvalidated at occupancy.** This probe
raises the proven filled depth from nothing to 16384 and says nothing about
24576, where only an allocation has ever been measured. The gap is the same
class of claim the probe was built to separate, and closing it needs a 24576
arm at the served geometry.

The Nanbeige ceiling deserves re-examination on the same grounds. That row
admits 8192 because 16384 wedged the ring under an f16 cache, and that wedge was
found under the harness geometry rather than the served one, which is now the
distinction that decides the 4B.

Depth costs decode on its own, apart from geometry: 2.87 tok/s at depth 0, 2.55
at 8192, and 2.32 at 16384 on the served geometry, a 19% fall across the span.
