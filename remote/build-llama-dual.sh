#!/bin/sh
set -eu

# Configure llama.cpp with the Vulkan and HIP backends in one build tree.
#
# One binary carrying both backends makes `llama-bench --device` a backend
# selector: two rows from it differ by the backend alone, where two rows from
# two builds also differ by compiler, flags, and source state. That is what lets
# a HIP measurement be compared against the Vulkan row that sets the default.
#
# HIP compiles against TheRock rather than the distribution. Ubuntu Noble ships
# HIP 5.7.31921 and `ggml/src/ggml-hip/CMakeLists.txt` requires 6.1 or newer, so
# the distribution packages cannot configure this backend at all. TheRock's
# headers also collide with `/usr/include/hip` when both are installed, and its
# clang selects GCC 14's libstdc++, so the environment checks below fail early
# and name what is missing.
#
# GGML_CUDA_FORCE_MMQ is a compile-time option rather than an environment
# variable, so the kernel-policy arm is a separate build tree rather than a
# separate run.

usage() {
    printf 'usage: %s [SOURCE_DIRECTORY]\n' "$0" >&2
    printf '  QWEN_HIP_TARGET      offload target, default gfx900\n' >&2
    printf '  QWEN_FORCE_MMQ       ON builds the MMQ kernel-policy arm\n' >&2
    printf '  QWEN_BUILD_DIRECTORY build tree, defaults from the two above\n' >&2
    printf '  QWEN_BUILD_JOBS      parallel jobs, defaults to nproc\n' >&2
    exit 2
}

[ "$#" -le 1 ] || usage

source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
hip_target=${QWEN_HIP_TARGET:-gfx900}
force_mmq=${QWEN_FORCE_MMQ:-OFF}
build_jobs=${QWEN_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}
rocm_path=${ROCM_PATH:-"${HOME:?}/.venvs/rocm-gfx900/lib/python3.12/site-packages/_rocm_sdk_devel"}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

# The tree name carries the target and the kernel policy, so the arms of a
# factorial run coexist and a stale cache cannot be mistaken for a fresh one.
case $force_mmq in
    ON)  build_suffix=$hip_target-mmq ;;
    OFF) build_suffix=$hip_target ;;
    *)   printf 'QWEN_FORCE_MMQ takes ON or OFF: %s\n' "$force_mmq" >&2; exit 2 ;;
esac
build_directory=${QWEN_BUILD_DIRECTORY:-$source_directory/build-qwen-dual-$build_suffix}

# ggml builds its Vulkan shader compiler as a nested ExternalProject, and that
# subbuild's CMakeCache.txt records the absolute path it was created under.
# Copying a configured tree to seed a second arm therefore carries a cache
# naming the first arm's directory, and the subbuild refuses to configure
# against it.
#
# Removing the prefix regenerates the generator and with it
# `ggml-vulkan-shaders.hpp`, which every shader translation unit includes, so
# the whole Vulkan backend recompiles. Those units are among the largest here
# and GCC 13 has taken an internal compiler error in `mul_mm.comp.cpp` under
# memory pressure on this machine, which makes copy-to-seed the expensive path
# rather than the cheap one. Reconfiguring the existing tree with a different
# GGML_CUDA_FORCE_MMQ rebuilds the HIP objects alone and leaves the Vulkan side
# untouched; the arms then replace each other instead of coexisting.
shader_generator_prefix=$build_directory/ggml/src/ggml-vulkan/vulkan-shaders-gen-prefix
if [ -f "$shader_generator_prefix/src/vulkan-shaders-gen-build/CMakeCache.txt" ] &&
    ! grep -q "^CMAKE_CACHEFILE_DIR:INTERNAL=$shader_generator_prefix/" \
        "$shader_generator_prefix/src/vulkan-shaders-gen-build/CMakeCache.txt"
then
    printf 'shader_generator_cache=stale removing=%s\n' "$shader_generator_prefix"
    rm -rf "$shader_generator_prefix"
fi

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

# The repository applies a patch series on top of the pinned commit, so the
# tree that produces a measurement is the commit plus that diff. A revision
# alone names a different tree, which is why the state is printed and recorded
# rather than assumed clean; `verify-llama-patch-series.sh` checks its content.
worktree_state=clean
if [ -n "$(git -C "$source_directory" status --porcelain)" ]; then
    worktree_state=dirty
fi
printf 'source_commit=%s worktree=%s\n' "$actual_commit" "$worktree_state"
git -C "$source_directory" diff --stat | tail -1

hip_compiler=$rocm_path/lib/llvm/bin/clang++
[ -x "$hip_compiler" ] || {
    printf 'TheRock clang++ is absent: %s\n' "$hip_compiler" >&2
    printf 'install it with: pip install --index-url <therock-index> \\\n' >&2
    printf '    "rocm[libraries,devel,device-gfx900]"\n' >&2
    exit 1
}

# TheRock's hipcc resolves /usr/include/hip ahead of its own headers, and those
# headers compiled by its clang fail on __AMDGCN_WAVEFRONT_SIZE and the __ocml_*
# intrinsics. Naming the compiler directly avoids hipcc's doubled `hipconfig -l`
# path; the collision itself needs the distribution packages gone.
if [ -d /usr/include/hip ]; then
    printf 'the distribution ROCm headers are present at /usr/include/hip\n' >&2
    printf 'they shadow TheRock and break the build; purge the Ubuntu ROCm packages\n' >&2
    exit 1
fi

# LLVM 24 selects GCC 14's libstdc++ where Ubuntu 24.04 installs only GCC 13's.
if [ ! -d /usr/lib/gcc/x86_64-linux-gnu/14 ]; then
    printf 'libstdc++-14-dev is absent and TheRock clang selects GCC 14\n' >&2
    printf 'install it with: sudo apt-get install libstdc++-14-dev\n' >&2
    exit 1
fi

# The desktop is the highest-priority workload on this machine and the laptop is
# in use while these run, so every long job here yields to it: nice 19 and idle
# I/O, which the kernel hands the CPU only when nothing the user is waiting on
# wants it. Two 2.3 GHz cores make a build long enough that normal priority is
# felt at the desktop, and a measurement taken while the desktop stutters
# describes a machine nobody would run.
renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true

printf 'dual_build=starting target=%s force_mmq=%s jobs=%s tree=%s\n' \
    "$hip_target" "$force_mmq" "$build_jobs" "$build_directory"

PATH=$rocm_path/bin:$PATH
export PATH ROCM_PATH
export LD_LIBRARY_PATH=$rocm_path/lib:$rocm_path/lib64:${LD_LIBRARY_PATH:-}

cmake -S "$source_directory" -B "$build_directory" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=ON \
    -DGGML_HIP=ON \
    -DAMDGPU_TARGETS="$hip_target" \
    -DCMAKE_HIP_COMPILER="$hip_compiler" \
    -DGGML_CUDA_FORCE_MMQ="$force_mmq" \
    -DLLAMA_BUILD_TESTS=OFF

cmake --build "$build_directory" --parallel "$build_jobs" \
    --target llama-bench llama-server llama-cli

[ -x "$build_directory/bin/llama-bench" ] || {
    printf 'the build produced no llama-bench\n' >&2
    exit 1
}

printf 'dual_build=complete tree=%s\n' "$build_directory"
"$build_directory/bin/llama-bench" --version 2>&1 | head -2
printf 'measure it with: remote/run-rocm-vulkan-matrix.sh\n'
