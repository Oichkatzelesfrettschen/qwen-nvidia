# CUDA PTX code selection and compiler falsification

The RTX 4070 Ti host ran one CUDA kernel through CUDA 13.3.1 `nvcc` and
NVHPC 26.5 `nvc++`. The kernel writes `89` into device memory and the host
requires the same value after synchronization and copy-back. `cuobjdump`
counts the embedded ELF and PTX payloads, and `ptxas -arch=sm_89` reassembles
each extracted PTX file.

| Compiler arm | Code selection | Cubins | PTX | Kernel | Extracted PTX |
| --- | --- | ---: | ---: | --- | --- |
| `nvcc` | `arch=compute_89,code=[compute_89,sm_89]` | 2 | 1 | accepted | 340 bytes, `ptxas` accepted |
| `nvcc` | `arch=compute_89,code=[sm_89]` | 2 | 0 | accepted | absent by request |
| `nvc++` | `-cuda -gpu=cc89` | 1 | 0 | accepted | absent under RDC default |
| `nvc++` | `-cuda -gpu=cc89,nordc` | 1 | 1 | accepted | 11417 bytes, `ptxas` accepted |

The NVCC PTX SHA-256 is
`50670a6025daa1da69c73a5d6b01260035d2cd4af078cd894d586fa13f1c5269`.
The NVHPC PTX SHA-256 is
`5f1c10dcd7dd3c3f2d938a06afecf35dd9d0129721bfb797edb6599c210a1b0b`.
Both files declare PTX 9.3, target SM89, and the
`_Z24write_compute_capabilityPi` entry. The successful `ptxas` runs establish
that both extracted files are consumable PTX rather than names alone.

`CUDA_FORCE_PTX_JIT=1` and `CUDA_FORCE_JIT=1` each executed all four
binaries on driver 610.57.04, including the two fatbins where `cuobjdump`
counts zero PTX payloads. Those environment variables fail to discriminate
the selected image on this driver and carry no authority in the conclusion.
Payload extraction and reassembly supply the PTX oracle.

The Arch `nvhpc-compilers` split package first refused compilation because its
default toolkit selector requires CUDA 13.2 while the host provides CUDA
13.3.1. The documented `NVHPC_CUDA_HOME=/opt/cuda` override reached the
installed toolkit. `nvc++` then emitted a `cuda_compile` warning that CUDA C++
compilation is unsupported and named `nvcc` as the recommended compiler.

The live `paru` package surface contains `nvhpc-compilers`,
`nvhpc-comm-libs`, and the `nvhpc` metapackage in CachyOS and Arch
repositories. The installed `nvhpc-compilers 26.5-1.1` package occupies
1763.89 MiB and supplies `nvc`, `nvc++`, and `nvfortran`. Its profile fragment
appends the versioned compiler directory to `PATH`; the package does not set
`CC` or `CXX`, and pacman declares no package conflicts. The `nvhpc`
metapackage additionally depends on CUDA, Nsight Compute, Nsight Systems, the
communication libraries, and the compiler split. Installing NVHPC beside CUDA
does not replace NVCC, but selecting NVHPC for an unsupported consumer role
creates the compiler-interface failures below.

The llama.cpp consumer checks reject both NVHPC substitutions:

- CMake 4.4.3 classifies `nvc++` as an unknown CUDA compiler and stops during
  `enable_language(CUDA)`.
- CMake accepts `nvc` and `nvc++` as the C and C++ compilers beside NVCC, but
  the first ggml CUDA translation unit stops because `nvc++` rejects
  `-Wmissing-declarations`, `-Wmissing-noreturn`, `-Wno-array-bounds`, and
  `-Wextra-semi` forwarded by NVCC.

The regular CUDA compiler therefore generates valid compute_89 PTX. The
missing PTX in configuration `844181cfaedc` comes from
`CMAKE_CUDA_ARCHITECTURES=89-real`, which asks CMake for
`code=[sm_89]`. The build default uses `89`, which asks for
`code=[compute_89,sm_89]`; `89-real` remains the explicit SASS-only arm.

The full llama.cpp consumer build confirms the same mechanism. Configuration
`0d69b05df789` completed with CUDA 13.3.1 NVCC and
`CMAKE_CUDA_ARCHITECTURES=89`. Its 84016656-byte `libggml-cuda.so` has
SHA-256
`b9741e2bd7f4ac6e7254aeacd1ff093cdec7cbc784cbaed75a1ceca97100f49e`.
Independent `cuobjdump` enumeration and extraction found 187 cubins and 187
PTX files; all 187 files extracted, and `ptxas -arch=sm_89` reassembled a
representative PTX file into a 31560-byte cubin. The completed `llama-cli`
enumerated the RTX 4070 Ti as CUDA0. The matched `89-real` artifact contains
187 cubins and zero PTX files. Those paired consumer artifacts falsify a CUDA
or SM89 PTX-generation defect and isolate the result to CMake code selection.
