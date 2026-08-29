# ROCm Feasibility on the Raven2 APU

An audit of what a ROCm/HIP path would cost and return against the deployed
RADV Vulkan backend. Every machine fact below is read from the running system.

## Machine identity

| Fact | Value | Source |
| --- | --- | --- |
| Distribution | Linux Mint 22.2 "Zara", `UBUNTU_CODENAME=noble` | `/etc/os-release` |
| Kernel | 7.0.0-28-generic | `uname -r` |
| GPU | `1002:15d8` rev `cd`, driver `amdgpu` | `lspci -nnk` |
| ATOM BIOS | `113-RAVEN2-117` | `dmesg` |
| Mesa chip name | `RAVEN2` | `RADV_DEBUG=info` |
| Mesa `gfx_level` | 11, which is GFX9 | `RADV_DEBUG=info` |
| Chip revision | 9 | `RADV_DEBUG=info` |
| Family id | 142, `AMDGPU_FAMILY_RV` | `RADV_DEBUG=info` |
| Compute units | `num_cu = 2`, `cu_mask[SE0][SA0] = 0x3` | `RADV_DEBUG=info` |
| Shader engines, render backends | 1 and 1 | `RADV_DEBUG=info` |
| L2 cache | 128 KB | `RADV_DEBUG=info` |
| GC IP version | 9.1.0 | `ip_discovery` sysfs |
| Memory bus | 128 bits, `RAM width 128bits DDR4` | `RADV_DEBUG=info`, `dmesg` |
| Memory frequency | 3 GHz effective | `RADV_DEBUG=info` |
| VRAM carveout | 2,048 MiB | `mem_info_vram_total` |
| GTT | 15,723 MiB | `mem_info_gtt_total` |
| `/dev/kfd` | present | `ls -l` |
| Group membership | `video`, `render` | `groups` |

## The ASIC is gfx902

`rocminfo` reports `gfx902`, and `hipDeviceProp_t::gcnArchName` reports
`gfx902:xnack+` under ROCm 5.7.1 and `gfx902:xnack-` under ROCm 10.1. That is
the target the compiler and the runtime must agree on, so `gfx902` is the
answer.

An earlier revision of this file derived `gfx909` from Mesa reporting
`name = RAVEN2` with `chip_rev = 9`, reasoning that the revision digit selects
the family member. Mesa does distinguish Raven2 from Raven for its own
purposes, and the digit does appear in the LLVM target name, but the KFD
driver advertises one `gfx_target_version` for the whole Raven family and that
version is 90002. The target a code object must match is the one KFD
advertises, not the one a chip revision suggests. Building
`--offload-arch=gfx909` against this runtime produces objects it declines to
load.

Mesa also reports `num_cu = 2` with `cu_mask[SE0][SA0] = 0x3`, one shader
engine, one render backend, and 128 KB of L2. That count is the ground truth
against which a ROCm enumeration is checked: the reported freezes on this exact
3050U followed an enumeration of 11 compute units, and Mesa reading the same
hardware as 2 is what makes such a report recognizable as a defect.

The xnack feature moves with the runtime version and is checked rather than
assumed: 5.7.1 negotiates `xnack+` and 10.1 negotiates `xnack-` on the same
silicon, and a code object built for the wrong one is the target-feature
mismatch the AMDGPU backend documentation names as a cause of incorrect
execution.

`gfx900` and `gfx902` are both GCN5, so `HSA_OVERRIDE_GFX_VERSION=9.0.0` is
the impersonation for libraries that ship only `gfx900` kernels. Both halves
are measured: a smoke test built `--offload-arch=gfx902` runs natively, and one
built `--offload-arch=gfx900` runs under the override, which then reports
`gfx900:xnack+`.

## Memory is already dual-channel

The kernel and Mesa independently report a 128-bit DDR4 bus, which is two
64-bit channels. A second DIMM therefore adds nothing.

DMI type 17 reports two 16 GB modules configured at 2400 MT/s, which fixes
nominal bandwidth at 38.4 GB/s across a 128-bit bus. Mesa reports a 3 GHz
effective memory frequency in the same field; the two disagree, the DMI figure
is the one that states a physical module rate, and what Mesa's field counts here
is unresolved. The conclusion holds across both figures.

Measured sequential host read bandwidth reaches 7.97 GB/s on one CPU thread and
15.44 GB/s on two, or 40% of nominal, which is where two Zen+ cores at 2.3 GHz
saturate. Decode moves weights at roughly 7.8 GB/s, so the two compute units
reach the single-thread figure.

## The Ubuntu route reaches the hardware and stops short of llama.cpp

The inbox `amdgpu` driver is active, `/dev/kfd` and `/dev/dri/renderD128`
exist, and the user holds `video` and `render`. Ubuntu Noble's `universe`
component carries `rocminfo` and `hipcc` at 5.7.1, `librocblas0` and
`libhipblas0` at 5.5.1, and no third-party repository is involved. Listing
`librocblas0` without installing shows `TensileLibrary_gfx900.co` present and
no `gfx902`, which is the condition `HSA_OVERRIDE_GFX_VERSION=9.0.0` addresses.

Installed, that stack reaches the hardware. `rocminfo` enumerates
`gfx902:xnack+` with 2 compute units and 14,995 MiB of allocatable memory, so
the 11-compute-unit misenumeration reported for this exact 3050U is absent
here.

It also reproduces the hang that follows that report. A HIP kernel built
`--offload-arch=gfx902` launches and completes -- `AMD_LOG_LEVEL=3` records
`hipDeviceSynchronize: Returned hipSuccess` -- and the following `hipMemcpy`
enters `Host active wait for Signal ... for -1 ns` and never leaves it. The
main thread spins at 90% of a core while its worker parks in
`kfd_wait_on_events`, and the GPU sits at 1% busy. The compute path works and
the SDMA copy engine never signals completion. `HSA_ENABLE_SDMA=0` returns the
correct answer at once, which localizes the defect to that engine rather than
to the target, the code object, or the queue.

The route ends at llama.cpp regardless. `ggml/src/ggml-hip/CMakeLists.txt:55`
requires HIP 6.1 or newer and Ubuntu ships 5.7.31921, so the backend refuses to
configure. Newer distribution packages do not exist for this release, which
makes the current-ROCm route mandatory rather than optional.

## TheRock supplies the runtime and repairs the small copy

`rocm[libraries,devel,device-gfx900]` from the AMD nightly index installs ROCm
10.1.0a20260825 with HIP 7.16.26332 into a virtual environment, which clears
the 6.1 requirement. Its device pack ships `gfx900` rocBLAS kernels and its
target list omits `gfx902`, so the impersonation the Ubuntu route needed is
still the one that applies.

The newer runtime reads the same silicon differently and clears the smoke
test:

| Runtime | HIP | `gfx902` smoke test, SDMA enabled |
| --- | --- | --- |
| Ubuntu Noble | 5.7.31921 | hangs in `hipMemcpy` |
| TheRock nightly | 7.16.26332 | returns the correct result |

10.1 negotiates `gfx902:xnack-` where 5.7.1 negotiates `gfx902:xnack+`, and it
advertises `gfx9-generic:xnack-` besides. The xnack change is simultaneous with
the smoke-test repair across a runtime revision that moves many components, so
it is correlated with it rather than established as its cause.

The repair is narrower than the smoke test suggests. A 2.58 GiB tensor upload
under 10.1 reaches the same wait state through `hipEventSynchronize`, and
`HSA_ENABLE_SDMA=0` clears it exactly as it clears the 5.7.1 case;
`evidence/rocm-h0-operational-failure.md` records both. What 10.1 repairs is the
small copy, and the copy engine still requires the variable on this silicon.

The scope of that result is the hang reproduced here. Whether the freezes
reported elsewhere against this 3050U share the mechanism is untested, and the
invalid 11-compute-unit enumeration in those reports is a second difference from
this machine.

Both target paths run under 10.1: a binary built `--offload-arch=gfx902`
executes natively, and one built `--offload-arch=gfx900` executes under
`HSA_OVERRIDE_GFX_VERSION=9.0.0`, which then reports `gfx900:xnack+`.

## Mixing the two stacks breaks the build

TheRock's `hipcc` resolves `/usr/include/hip` ahead of its own headers when the
Ubuntu packages are installed, and Ubuntu's headers compiled by TheRock's clang
fail on `__AMDGCN_WAVEFRONT_SIZE` and the `__ocml_*` intrinsics. Purging the
ten Ubuntu ROCm packages removes `/usr/include/hip` and leaves TheRock as the
only ROCm on the machine, which is the supported arrangement.

Two further toolchain facts hold for any build here. TheRock's `hipconfig -l`
returns a doubled path in this nightly, so `$ROCM_PATH/lib/llvm/bin/clang++`
names the HIP compiler directly. And its clang, LLVM 24, selects GCC 14's
libstdc++ where Ubuntu 24.04 installs only GCC 13's, so `libstdc++-14-dev`
supplies what it looks for and spares every target a `--gcc-install-dir` flag.

## The arithmetic heuristic sizes what ROCm can return

Nominal FP32 throughput for this GPU:

```text
2 CU x 64 lanes x 2 FLOP/FMA x 1.1 GHz = 281.6 GFLOP/s
```

Prefill is the compute-bound half of inference. `llama-bench` measures 21.2
prompt tok/s on the Qwen3.5-4B base checkpoint, so 512 tokens take 24.2 s. Prefill arithmetic is
about `2 x 4.21e9 x 512 = 4.31 TFLOP`, giving:

```text
4.31e12 / 24.2 = 178 GFLOP/s = 63% of nominal FP32 peak
```

That 63% is a heuristic, not a bound. `2 x parameters x tokens` counts a dense
transformer's multiply-accumulates and omits dequantization, attention,
normalization, elementwise kernels, packing, and synchronization, none of which
map onto nominal FP32 FMA peak. The figure says the Vulkan backend is within the
same order as the arithmetic ceiling; it does not cap what a different backend
can return.

Decode is the bandwidth-bound half, so a backend change that leaves memory
traffic identical returns nothing there. A backend can still change coalescing,
cache behavior, dequantization cost, and the number of passes over
intermediates, and the 9B row shows the simple model's error: pure bandwidth
predicts 1.31 decode tok/s where 1.76 measures, 34% high.

The empirical falsifier below is the operative test. The arithmetic excludes an
interactive 27B deployment and does not bound backend implementation
differences.

Combining both halves: the reachable upside is a fraction of prefill and
nothing on decode, against an unsupported stack, an ISA impersonation, rocBLAS
5.5.1 under a current llama.cpp, and a reported history of this exact 3050U
being enumerated as an 11-compute-unit device followed by application freezes.

## Verdict

RADV Vulkan remains the serving backend until a measurement moves it.

The first HIP run against that criterion produced no row: it hung in model load
for 51 minutes and was terminated. The criterion is unreached rather than
failed, and `evidence/rocm-h0-operational-failure.md` carries the backtrace and
the `HSA_ENABLE_SDMA=0` result that lets the same binary finish in 19 seconds.

Falsification criterion, recorded before the run: a HIP `llama-bench` row that
exceeds its own checkpoint's Vulkan row refutes that verdict. Each retained
result names the checkpoint it ran against, because the two in this tree carry
different thresholds:

| Checkpoint | prefill falsifier | decode falsifier |
| --- | ---: | ---: |
| Qwen3.8-4B Distill Q4_K_M | above 22.00 tok/s | above 3.02 tok/s |
| Qwen3.5-4B base Q4_K_M | above 20.88 tok/s | above 2.84 tok/s |

At or below those figures the Vulkan backend already holds the reachable
performance.

The criterion is now tested and unmet. Under `HSA_ENABLE_SDMA=0` the same
binary benchmarks both backends against Qwen3.8-4B Distill Q4_K_M at nice 19
with idle I/O, phases split, and HIP loses both serving metrics:

| Backend | prefill tok/s | decode tok/s |
| --- | ---: | ---: |
| RADV Vulkan | 23.48 | 3.07 +/- 0.02 |
| HIP, gfx900 override | 12.20 | 2.02 +/- 0.15 |

HIP decode variance is 7.4% against Vulkan's 0.7%, eleven times wider over the
same three repetitions. A one-thread HIP arm returns 1.98 against two threads'
1.97, which falsifies host-worker starvation as the explanation.
`evidence/rocm-vulkan-backend-matrix.md` carries the arms.

`gpu_busy_percent` reads high throughout the hung run, so it establishes that
work is resident on the device rather than that the run makes forward
progress. The counters that distinguish the two are the process read counters
and the GTT allocation, and `evidence/rocm-h0-operational-failure.md` records
them flat across the wait.

The comparison runs from one binary. `build-qwen-dual` configures
`-DGGML_VULKAN=ON -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx900` against the same
source commit, so `llama-bench --device` selects the backend and a difference
between two rows is a difference between two backends rather than between two
builds. The HIP rows run under `HSA_OVERRIDE_GFX_VERSION=9.0.0`, which is what
lets the `gfx900` rocBLAS kernels and the `gfx900` ggml objects load together
on `gfx902` silicon.

## What the audit corrects in the proposed plan

The plan's Route 1 package selection, its inbox-driver requirement, its
per-process override discipline, its rejection of PPAs, its warning against
mixing ROCm stacks in one process, and its `HSA_ENABLE_SDMA=0` diagnostic all
hold against the machine. The SDMA step in particular found the exact defect.

Four inputs differ. The distribution is Mint 22.2 "Zara" rather than 22.3
"Zena", which changes nothing because both carry the `noble` base. The memory
bus is 128-bit with both slots holding 16 GB at 2400 MT/s, which removes a
dual-channel upgrade from consideration and fixes nominal bandwidth at
38.4 GB/s. Ubuntu's ROCm cannot build llama.cpp at all, which promotes
TheRock from secondary route to the only route. And TheRock clears the
small-buffer copy that the older runtime hangs on, which narrows rather than
retires the plan's SDMA workaround: a 2.58 GiB model upload still enters
`rocr::core::BusyWaitSignal` under 10.1, so `HSA_ENABLE_SDMA=0` remains
mandatory on this silicon at every runtime revision tested.

The plan's own reservation about TheRock stands: `gfx900` is build-passing
rather than sanity-tested, and `gfx902` is absent from its public device
targets, so the newer stack impersonates exactly as the older one does. It
earns its place here by supplying a HIP the build accepts and a runtime that
completes a small copy.

OpenCL availability and OpenCL support are separate questions. TheRock installs
an AMD ICD, and RustiCL supplies another from Mesa, so a runtime can enumerate
this GPU. The pinned llama.cpp OpenCL backend nevertheless admits Adreno and
Intel devices and rejects every other vendor before the model loads, so neither
ICD yields a benchmark row without a backend patch. What an ICD settles is
device enumeration and compute-unit count.
