# OpenCL on this APU: the runtime admits the device, the backend rejects it

Two questions look alike and separate cleanly here. An OpenCL runtime can
enumerate this GPU and report it correctly. The pinned llama.cpp OpenCL backend
refuses to run on it regardless.

## The runtime enumerates the device correctly

TheRock ships an AMD ICD at `etc/OpenCL/vendors/amdocl64.icd` naming
`libamdocl64.so`. Pointing `OCL_ICD_VENDORS` at that directory tests it without
registering anything in `/etc/OpenCL/vendors`, which on this machine is empty.

```text
Platform Name           AMD Accelerated Parallel Processing
Platform Version        OpenCL 2.1 AMD-APP (3581.0)
Device Name             gfx902:xnack-
Device Version          OpenCL 2.0
Device Type             GPU
Device Board Name (AMD) AMD Radeon Graphics
Max compute units       2
Global memory size      15723495424 (14.64 GiB)
```

Two facts in that output are worth keeping. The device reports `gfx902`
directly, with no `HSA_OVERRIDE_GFX_VERSION` in the environment, so the ISA
identity holds across a third runtime after Mesa and `rocminfo`. And it reports
two compute units, which is the count Mesa reads from `cu_mask[SE0][SA0] = 0x3`;
the 11-compute-unit misenumeration reported elsewhere against this 3050U is
absent from every runtime tested here.

## The backend admits Adreno and Intel

`ggml/src/ggml-opencl/ggml-opencl.cpp` defines three GPU families, `ADRENO`,
`INTEL`, and `UNKNOWN`, and assigns `UNKNOWN` to every device whose name matches
neither vendor. The rejection is a process exit rather than a return:

```c
const int sg_size = backend_ctx->gpu_family == GPU_FAMILY::ADRENO ? 64
                  : backend_ctx->gpu_family == GPU_FAMILY::INTEL  ? 32 : -1;
if (sg_size < 0) {
    GGML_LOG_ERROR("Unsupported GPU Family: only Adreno and Intel are supported.\n");
    exit(1);
}
```

That block sits in the `gated_delta_net` kernel setup, which Qwen3.5 and
Qwen3.8 both require, so the checkpoints this appliance serves reach it on every
load. The subgroup size the branch selects is the reason: the backend carries no
value for a 64-lane AMD wavefront in this path even though the number matches
Adreno's.

## What that costs to change, and why it stays unbuilt

Building the backend at all needs `ocl-icd-opencl-dev`, which is absent here;
`opencl-headers` 3.0 is installed. That package is one `apt-get` away and is not
the obstacle.

Deleting the admission check is also not the work. A backend that produced
comparable numbers would need the family-specific workgroup geometry, the
subgroup and wave64 assumptions, FP16 and packed dot product support, the Q4_K
matrix kernels, the Gated DeltaNet and SSM operations, cache and allocation
reporting, and CPU-fallback detection all reviewed against this hardware. That
is backend development rather than a comparison arm.

## Verdict

OpenCL contributes a device-identity confirmation and no throughput row. The
`gfx902` and two-compute-unit readings above are the retained result.

RustiCL would answer the same two questions from Mesa instead of from TheRock
and reach the same backend rejection, so it changes the ICD under test rather
than the outcome. The Mesa build carrying RustiCL is a separate question:
`ernstp/mesarc` supplies the installed 26.2.1 for noble and omits RustiCL from
it, `kisak-mesa` supplies 26.1.7 with RustiCL present, and `oibaf` publishes
nothing for noble at all.
