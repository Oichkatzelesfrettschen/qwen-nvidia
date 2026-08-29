# One directory per build arm, and a proof of what it produced

A shared build tree lets an experiment overwrite its own reference. An H1
reconfigure replaces the H0 kernels in place while the recorded launcher hash
still verifies, because the launcher is 17 KB of argument parsing and the
kernels are elsewhere. A tree copied between machines keeps a nested
`CMakeCache.txt` naming another prefix, which the Vulkan shader generator
refuses. A stale binary satisfies `[ -x ]`, which a waiting script reads as a
finished build.

`remote/build-llama-preset.sh` gives each arm its own directory, cache, compile
database, and manifest, so an arm changes only by being rebuilt:

| Preset | Arm |
| --- | --- |
| `raven2-vulkan-production` | serving build |
| `raven2-vulkan-profile` | `RelWithDebInfo` with frame pointers, for captures |
| `raven2-vulkan-tests` | tests and fatal warnings |
| `raven2-cpu-control` | CPU backend alone, the placement control |
| `raven2-hip-h0` | HIP for `gfx900`, run under the override |
| `raven2-hip-h1-mmq` | H0 plus `GGML_CUDA_FORCE_MMQ=ON` |
| `raven2-hip-h2-native` | HIP compiled for `gfx902` directly |

Acceptance is a timestamp rather than an existence test. Every declared output
is removed before compilation and must exist afterwards with an mtime at or past
the start stamp, which a surviving stale file fails. The manifest then records
the preset, the commit, the worktree state, the compiler flags, the full CMake
line, and the load closure of each output through
`remote/hash-load-closure.sh`.

Router mode gets no separate arm, and the reason is a regression the split
would have introduced. `common/CMakeLists.txt` defines `LLAMA_SUBPROCESS` only
when the option is on, and `common/subproc.cpp` compiles `create()` to an
unconditional failure otherwise. That one function is what router mode spawns a
child server through and what the MCP tool servers behind `--tools` run, so a
production build with the option off serves one model and refuses both
features. Upstream defaults it on for every system except iOS, Android, and
Emscripten, so every serving preset here keeps it on and router mode is a
runtime flag rather than a build.

The HIP arms leave Vulkan off. Shader generation is the longest step in the dual
tree and it has no bearing on a HIP row, and the dual tree is where GCC 13 hit
an internal compiler error in `mul_mm.comp.cpp` under memory pressure, so H1
reaches a binary through the narrower path.

## What ran

`raven2-cpu-control` built on the workstation against the pinned commit
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0` with a dirty worktree carrying the
repository patch series, at `nice 19` with idle I/O, 329 targets:

```text
executable  llama-bench   11,516,824  51c9b2eb6f9242ddc0ce4945c36876b33cc90734550f72f50c70cacd8b1726ea
executable  llama-server  15,287,400  3c047e020f923386802cfe675e40e7e945f0549b2683f506c402789924c3819e
```

`BUILD_SHARED_LIBS=OFF` puts the whole load closure inside each executable, so
the manifest carries two rows and no shared object, which the closure walker
reports rather than assumes.

Rebuilding the same preset moved the `llama-bench` mtime from 1787728634 to
1787728657 while the SHA-256 stayed
`51c9b2eb6f9242ddc0ce4945c36876b33cc90734550f72f50c70cacd8b1726ea`. The output
is therefore removed and recreated rather than left in place, and the build is
byte-reproducible across runs from unchanged inputs.

`ggml` reports the instruction selection back:
`-msse4.2;-mf16c;-mfma;-mbmi2;-mavx;-mavx2`, which is what
`GGML_NATIVE=OFF` plus the named feature options request.

## What did not run

`raven2-vulkan-production` stops at configure on this workstation:
`ggml/src/ggml-vulkan/CMakeLists.txt` calls `find_package(SPIRV-Headers)` and
the workstation lacks that package. The Vulkan arms build on the laptop, which
carries it, or inside the `ubuntu:24.04` container that
`remote/build-llama-on-workstation.sh` already uses and which installs
`spirv-headers`. The flags themselves are checked against the pinned
`CMakeLists.txt`: `LLAMA_BUILD_APP`, `LLAMA_BUILD_UI`, `LLAMA_USE_PREBUILT_UI`,
`LLAMA_OPENSSL`, `LLAMA_SUBPROCESS`, `LLAMA_FATAL_WARNINGS`, `GGML_BMI2`,
`GGML_SSE42`, `GGML_LTO`, `GGML_CCACHE`, and `GGML_CUDA_FORCE_MMQ` all exist as
options at this commit, and the HIP arms pass `GPU_TARGETS`, which
`ggml/src/ggml-hip/CMakeLists.txt` forwards to `CMAKE_HIP_ARCHITECTURES` and
accepts `AMDGPU_TARGETS` as an alias for.

The presets are authored rather than promoted. `-march=znver1` is GCC's Family
17h target and covers Zen+, and it is the correct choice for a binary built in a
container on a 5600X3D and run on a Raven2, where `-march=native` would target
the wrong machine. Whether it moves a measured number is untested: the appliance
default and the configuration `README.md` names stay where the last measurement
put them until the B0 reference and the B1 `znver1` arm are both benchmarked on
the laptop.
