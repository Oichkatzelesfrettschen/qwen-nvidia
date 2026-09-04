#!/bin/sh
set -eu

# Compile scripts/physics-runtime/physx-rigid-runtime.cpp against the PhysX
# SDK the physx-sdk package installs under /opt/nvidia/physx and print the
# binary's SHA-256, which physics-service.py records in every result. The
# runtime opens a CUDA context, so it is never executed here.

usage() {
    printf 'usage: %s OUTPUT_BINARY\n' "$0" >&2
    exit 2
}
[ "$#" -eq 1 ] || usage
output=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
physx_prefix=${QWEN_PHYSX_PREFIX:-/opt/nvidia/physx}
cuda_prefix=${QWEN_CUDA_PREFIX:-/opt/cuda}
host_cxx=${QWEN_HOST_COMPILER:-/usr/bin/g++-15}
[ -d "$physx_prefix/include" ] || { printf 'PhysX SDK is absent at %s\n' "$physx_prefix" >&2; exit 1; }
library_directory=$physx_prefix/bin/linux.x86_64/release

"$host_cxx" -std=c++17 -O2 -DNDEBUG -DPX_PHYSX_STATIC_LIB -o "$output" \
    "$script_directory/physics-runtime/physx-rigid-runtime.cpp" \
    -I"$physx_prefix/include" -I"$cuda_prefix/include" \
    -L"$library_directory" -L"$cuda_prefix/lib64" \
    -lPhysXExtensions_static_64 -lPhysX_64 -lPhysXCooking_64 -lPhysXPvdSDK_static_64 -lPhysXCommon_64 -lPhysXFoundation_64 \
    -lcuda -lpthread -ldl \
    -Wl,-rpath,"$library_directory"
printf 'physics_runtime_sha256=%s\n' "$(sha256sum "$output" | cut -d ' ' -f 1)"
