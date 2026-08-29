#!/bin/sh
set -eu

# Configure llama.cpp with the CUDA and Vulkan backends in one build tree.
#
# One binary carrying both backends makes `llama-bench --device` a backend
# selector, so a CUDA row and a Vulkan row differ by the backend alone where
# two builds also differ by compiler, flags, and source state. CUDA is the
# serving backend on this host and Vulkan is the fallback the same binary
# reaches when the CUDA runtime is unavailable.
#
# CMAKE_CUDA_ARCHITECTURES is 89 because the installed device is AD104, the
# GeForce RTX 4070 Ti, whose compute capability is 8.9. A build for that
# architecture alone emits one SASS variant rather than a fat binary.
#
# GGML_CUDA_FA_ALL_QUANTS is ON because remote/models.tsv serves every row at
# cache_type_k=q8_0 with cache_type_v=q4_0, and the default CUDA build compiles
# flash-attention kernels for a subset of KV type combinations that excludes a
# mixed pair. Without the option the served cache triple leaves the flash
# attention path at run time.
#
# nvcc reads crt/host_config.h and refuses a host compiler newer than GCC 15,
# where the distribution's default is GCC 16, so the whole tree builds with
# g++-15 rather than mixing two front ends across one link.
#
# GGML_CUDA_FORCE_MMQ is a compile-time option rather than an environment
# variable, so the kernel-policy arm is a separate build tree.

usage() {
    printf 'usage: %s [SOURCE_DIRECTORY]\n' "$0" >&2
    printf '  QWEN_CUDA_ARCHITECTURES  compute capability, default 89\n' >&2
    printf '  QWEN_FORCE_MMQ           ON builds the MMQ kernel-policy arm\n' >&2
    printf '  QWEN_BUILD_VULKAN        OFF drops the fallback backend\n' >&2
    printf '  QWEN_HOST_COMPILER       C++ compiler, default g++-15\n' >&2
    printf '  QWEN_BUILD_DIRECTORY     build tree, defaults from the two above\n' >&2
    printf '  QWEN_BUILD_JOBS          parallel jobs, defaults to nproc\n' >&2
    printf '  QWEN_ALLOW_ANY_COMMIT    1 builds a tree off the pinned commit\n' >&2
    exit 2
}

[ "$#" -le 1 ] || usage

source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
cuda_architectures=${QWEN_CUDA_ARCHITECTURES:-89}
force_mmq=${QWEN_FORCE_MMQ:-OFF}
build_vulkan=${QWEN_BUILD_VULKAN:-ON}
host_cxx=${QWEN_HOST_COMPILER:-/usr/bin/g++-15}
host_cc=${QWEN_HOST_C_COMPILER:-/usr/bin/gcc-15}
build_jobs=${QWEN_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

case $build_vulkan in
    ON|OFF) ;;
    *) printf 'QWEN_BUILD_VULKAN takes ON or OFF: %s\n' "$build_vulkan" >&2; exit 2 ;;
esac

case $force_mmq in
    ON)  build_suffix=sm$cuda_architectures-mmq ;;
    OFF) build_suffix=sm$cuda_architectures ;;
    *)   printf 'QWEN_FORCE_MMQ takes ON or OFF: %s\n' "$force_mmq" >&2; exit 2 ;;
esac
build_directory=${QWEN_BUILD_DIRECTORY:-$source_directory/build-qwen-cuda-$build_suffix}

[ -d "$source_directory/.git" ] || {
    printf 'llama.cpp checkout is missing: %s\n' "$source_directory" >&2
    exit 1
}

actual_commit=$(git -C "$source_directory" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ] && [ "${QWEN_ALLOW_ANY_COMMIT:-0}" != 1 ]; then
    printf 'unexpected llama.cpp commit: expected %s, found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    printf 'set QWEN_ALLOW_ANY_COMMIT=1 to build it anyway\n' >&2
    exit 1
fi

# The tree that produces a measurement is the commit plus the applied patch
# series, so the state is printed rather than assumed clean.
worktree_state=clean
if [ -n "$(git -C "$source_directory" status --porcelain)" ]; then
    worktree_state=dirty
fi
printf 'source_commit=%s worktree=%s\n' "$actual_commit" "$worktree_state"
git -C "$source_directory" diff --stat | tail -1

for compiler in "$host_cc" "$host_cxx"; do
    [ -x "$compiler" ] || {
        printf 'host compiler is absent: %s\n' "$compiler" >&2
        exit 1
    }
done

command -v nvcc >/dev/null 2>&1 || [ -x /opt/cuda/bin/nvcc ] || {
    printf 'nvcc is absent from PATH and /opt/cuda/bin\n' >&2
    exit 1
}
if ! command -v nvcc >/dev/null 2>&1; then
    PATH=/opt/cuda/bin:$PATH
    export PATH
fi

# ggml builds its Vulkan shader compiler as a nested ExternalProject whose
# CMakeCache.txt records the absolute path it was created under, so a tree
# copied to seed a second arm carries a cache naming the first arm and the
# subbuild refuses to configure against it.
shader_generator_prefix=$build_directory/ggml/src/ggml-vulkan/vulkan-shaders-gen-prefix
if [ -f "$shader_generator_prefix/src/vulkan-shaders-gen-build/CMakeCache.txt" ] &&
    ! grep -q "^CMAKE_CACHEFILE_DIR:INTERNAL=$shader_generator_prefix/" \
        "$shader_generator_prefix/src/vulkan-shaders-gen-build/CMakeCache.txt"
then
    printf 'shader_generator_cache=stale removing=%s\n' "$shader_generator_prefix"
    rm -rf "$shader_generator_prefix"
fi

# The Vulkan backend compiles its shaders through a nested generator that
# includes the SPIR-V headers, which the distribution ships in a package
# separate from the Vulkan headers themselves.
if [ "$build_vulkan" = ON ] && [ ! -d /usr/include/spirv ]; then
    printf 'the SPIR-V headers are absent from /usr/include/spirv\n' >&2
    printf 'install them with: sudo pacman -S --needed spirv-headers\n' >&2
    printf 'or set QWEN_BUILD_VULKAN=OFF to build the CUDA backend alone\n' >&2
    exit 1
fi

printf 'cuda_build=starting architectures=%s vulkan=%s force_mmq=%s jobs=%s tree=%s\n' \
    "$cuda_architectures" "$build_vulkan" "$force_mmq" "$build_jobs" "$build_directory"

cmake -S "$source_directory" -B "$build_directory" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$host_cc" \
    -DCMAKE_CXX_COMPILER="$host_cxx" \
    -DCMAKE_CUDA_HOST_COMPILER="$host_cxx" \
    -DGGML_CUDA=ON \
    -DGGML_VULKAN="$build_vulkan" \
    -DCMAKE_CUDA_ARCHITECTURES="$cuda_architectures" \
    -DGGML_CUDA_FA_ALL_QUANTS=ON \
    -DGGML_CUDA_FORCE_MMQ="$force_mmq" \
    -DLLAMA_CURL=ON \
    -DLLAMA_BUILD_TESTS=OFF

cmake --build "$build_directory" --parallel "$build_jobs" \
    --target llama-bench llama-server llama-cli llama-mtmd-cli llama-quantize

for artifact in llama-bench llama-server llama-cli llama-mtmd-cli llama-quantize; do
    [ -x "$build_directory/bin/$artifact" ] || {
        printf 'the build produced no %s\n' "$artifact" >&2
        exit 1
    }
done

printf 'cuda_build=complete tree=%s\n' "$build_directory"
"$build_directory/bin/llama-bench" --version 2>&1 | head -2
