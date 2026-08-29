# Compiler and OpenCL Admission Evidence

## Claims and falsifiers

| Claim | Authority and lookup | Falsifier | Durable result |
|---|---|---|---|
| The installed OpenCL stack exposes Raven2 | ICD manifests, `dpkg -L`, and `clinfo -l` | No ICD file or no GPU platform | Falsified: mesarc's package contains documentation only |
| Pinned llama.cpp accepts Raven2 through OpenCL | `ggml_opencl_is_device_supported()` source trace | AMD reaches backend initialization | Falsified: only Adreno and Intel families are accepted |
| A newer compiler is required for the Vulkan build | Pinned llama.cpp CMake configuration and dependency probe | GCC 13 builds warning-clean and passes tests | Hypothesis; the production build remains GCC 13 |
| Noble needs an LLVM PPA for a modern compiler | `apt-cache policy` and simulated transaction | Noble publishes a maintained compiler | Falsified: Noble publishes Clang/LLVM 20 |
| GCC 16 can be added without changing the desktop runtime | Toolchain Test PPA `Packages.gz` | The archive publishes replacement runtime libraries | Falsified: it publishes `libgcc-s1` and `libstdc++6` from GCC 16 |
| apt.llvm.org can provide a side-by-side recent LLVM | apt.llvm.org Noble Release and package indexes | Unversioned replacement packages or unmet Noble dependencies | Known for versioned LLVM 21 and 22 packages; not yet admitted |

## Observed package state

The 2026-08-24 APT transaction upgraded the mesarc Mesa family from 26.2.0 to
26.2.1 and installed `mesa-opencl-icd`, `libclc-19`, OpenCL headers and loader,
and `clinfo`. RADV remains functional and reports
`AMD Radeon Graphics (RADV RAVEN2)` with Mesa 26.2.1.

The OpenCL package is not functional. `dpkg -L mesa-opencl-icd` lists only bug
and documentation paths. `/etc/OpenCL/vendors` has no manifest, and `clinfo -l`
reports no platform. The package metadata promises an ICD that its payload does
not contain. Installing headers, `libOpenCL.so`, and `libclc` cannot create a
device platform without a vendor implementation.

PoCL is excluded because the operating policy forbids CPU model execution.
ROCm and AMDGPU-PRO are excluded as assumptions because Raven2 support and
package compatibility have not been proven.

The pinned llama.cpp source adds an independent blocker. Function
`ggml_opencl_is_device_supported()` classifies only Adreno and Intel device
names; every other family logs `unsupported GPU` and returns false. A working
Rusticl ICD would therefore remain unusable by this revision. OpenCL becomes a
valid research lane only after implementing and verifying AMD family detection,
kernel compile options, operation coverage, memory reporting, and strict
fallback handling. Vulkan remains the sole production backend.

## Compiler sources

Ubuntu Noble updates publishes Clang/LLVM 20.1.2 and GCC/G++ 14.2.0. Simulating
`clang-20 lld-20` adds 18 packages with zero upgrades or removals. Simulating
`gcc-14 g++-14` adds seven packages with zero upgrades or removals. Neither
transaction changes `/usr/bin/cc` or `/usr/bin/c++` unless an operator later
changes alternatives, which this project forbids.

Primary apt.llvm.org metadata lists Noble branches 21 and 22. LLVM 22 packages
are versioned and depend on the Noble runtime versions already present. The
archive's published signing fingerprint is
`6084F3CF814B57C1CF12EFD515CF4D18AF4F7421`. If LLVM 22 gains a measured use,
its source must use a dedicated keyring and `signed-by`; the legacy `apt-key`
example on the upstream page is not an acceptable configuration mechanism.

The Ubuntu Toolchain Test PPA publishes Noble GCC 16 snapshot
`16-20260315-1ubuntu1~24~ppa1` and signing fingerprint
`C8EC952E2A0E1FBDC5090F6A2C277A0A352154E5`. Its archive also publishes GCC 16
builds of the unversioned `libgcc-s1` and `libstdc++6`. Enabling the PPA would
therefore place the desktop's global C and C++ runtimes in the same candidate
domain as a test compiler snapshot. This project rejects that repository for
the production laptop baseline.

Primary indexes:

- https://apt.llvm.org/
- https://apt.llvm.org/noble/dists/llvm-toolchain-noble-22/Release
- https://ppa.launchpadcontent.net/ubuntu-toolchain-r/test/ubuntu/dists/noble/main/binary-amd64/Packages.gz

## Immediate transaction

The Vulkan build requires no compiler PPA. The simulated transaction for
`glslc`, `libshaderc1`, `spirv-headers`, and `shellcheck` adds exactly four Noble
packages, upgrades none, and removes none. GCC 13 remains the production
compiler. A Clang 20 or GCC 14 build becomes useful only as a measured compiler
comparator after the production binary passes its warning, parser, device,
strict-fallback, and runtime gates.
