# llama.cpp Backend and Build Policy

## Decision

The selected llama.cpp revision cannot build a functional `llama-server` with
`GGML_CPU=OFF`. `src/llama-context.cpp` always initializes a CPU backend after
the selected accelerator backends, and model loading, buffer selection,
adapters, sampling, and scheduler control contain explicit CPU-backend
dependencies. Removing that backend would make context initialization fail; it
would not create a purer Vulkan model path.

The production build therefore keeps the required CPU control backend and
enables Vulkan as the only accelerator backend. CPU tensor fallback is a
separate runtime policy: every model weight, KV tensor, recurrent tensor, and
graph operation must remain on `Vulkan0`, while tokenization, HTTP handling,
sampling control, and driver submission can use the single low-priority CPU
thread.

## Build configuration

`remote/build-llama-vulkan.sh` pins commit
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0` and configures:

- `GGML_VULKAN=ON`;
- `GGML_CPU=ON`, because llama context creation requires it;
- CUDA, HIP, SYCL, OpenCL, RPC, BLAS, and llamafile acceleration off;
- OpenMP and native CPU specialization off;
- both npm-built and prebuilt embedded Web UI assets, examples, unified app,
  and HTTPS support off;
- compiler warnings as errors;
- static libraries; and
- one Ninja job under one-core affinity, nice level 19, and idle I/O priority.

The retained Vulkan patch makes pacing opt-in and preserves upstream behavior
when its environment variable is absent. The production wrapper selects 60%,
and the build runs the warning-clean pacing math test after both executables
link.

The server still exposes its localhost HTTP API. Disabling the embedded Web UI
removes a GUI payload but does not remove the headless server. The same binary
retains `--path`, so the guarded interactive profile serves the tracked static
panel without rebuilding or adding another laptop process.

## Runtime enforcement boundary

`--device Vulkan0 --split-mode none --n-gpu-layers all --kv-offload` expresses
the desired placement, but llama.cpp appends CPU buffer types as compatibility
fallbacks during model loading. These flags alone do not prove that every
tensor remained on Vulkan.

The runtime guard must inspect the model buffer breakdown and graph placement,
reject any model or KV allocation on a CPU buffer, keep
`GGML_VK_ALLOW_SYSMEM_FALLBACK` unset, and stop if an operation reports CPU
fallback. This enforcement belongs in the guarded launcher and strict-load
patch rather than in the build option.

## Validation result

The pinned build completes under one-core affinity, nice 19, idle I/O, and one
Ninja job. The generated build graph contains 451 compile commands with
`-Werror`. `LLAMA_BUILD_UI` and `LLAMA_USE_PREBUILT_UI` are both off, the
build-tree UI asset directory is absent, and the server binary contains no HTML
doctype marker. The exact build, dependency, package, binary-hash, and device
evidence is retained in `evidence/llama-vulkan-build-provenance.log`.

Both `llama-cli --list-devices` and `llama-server --list-devices` expose only
`Vulkan0: AMD Radeon Graphics (RADV RAVEN2)`. The model-backed runtime tests
prove default and LOW queue behavior, CPU tensor rejection, CPU graph
rejection, and a strict two-token Vulkan completion. Source:
`evidence/llama-vulkan-runtime-validation.log`.
