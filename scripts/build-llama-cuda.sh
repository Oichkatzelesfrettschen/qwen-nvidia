#!/bin/sh
set -eu

# Build llama.cpp for the RTX 4070 Ti with every material CMake choice named
# in one variable, validated, and folded into a configuration digest, so two
# trees differing in any lever carry different names and a directory can no
# longer hide 89 against 89-real, a backend, NCCL, a compression mode, LTO, a
# CPU target, or an MMVQ threshold behind one suffix.
#
# CMAKE_CUDA_ARCHITECTURES defaults to 89 because the build closure includes
# both native SM89 execution and inspectable compute_89 PTX. 89-real remains
# available for a compact, SASS-only binary whose consumer contract names an
# SM89 device and excludes PTX inspection and forward JIT.
#
# GGML_CUDA_FA_ALL_QUANTS is required rather than optional: scripts/models.tsv
# serves every row at cache_type_k=q8_0 with cache_type_v=q4_0, and the
# default flash-attention set excludes that mixed pair.
#
# GGML_CUDA_FORCE_MMQ and GGML_CUDA_FORCE_CUBLAS build kernel-policy arms in a
# separate tree. mmq.cu:320 reads FORCE_MMQ below a turing_mma_available(cc)
# return that already fires at 8.9, while mmq.cu:260 reads FORCE_CUBLAS ahead
# of everything, so FORCE_CUBLAS is the flag that changes dispatch here and
# only where MMVQ has already refused.
#
# The two ADA MMVQ thresholds reach the source through the candidate patch
# llama-cuda-mmvq-crossover-ad104.patch; against an unpatched tree they rest
# as unused cache entries and the build reproduces upstream dispatch.

usage() {
    printf 'usage: %s [SOURCE_DIRECTORY]\n' "$0" >&2
    printf '  QWEN_CUDA_ARCHITECTURES    89 (default, SASS and PTX) or 89-real (SASS only)\n' >&2
    printf '  QWEN_BUILD_VULKAN          ON adds the Vulkan diagnostic backend, default OFF\n' >&2
    printf '  QWEN_CUDA_GRAPHS           default ON\n' >&2
    printf '  QWEN_CUDA_FA               default ON\n' >&2
    printf '  QWEN_CUDA_FA_ALL_QUANTS    default ON\n' >&2
    printf '  QWEN_CUDA_NCCL             default OFF, single GPU links no collective\n' >&2
    printf '  QWEN_CUDA_NO_VMM           default OFF, VMM stays on\n' >&2
    printf '  QWEN_CUDA_COMPRESSION_MODE size (default), speed, balance, or none\n' >&2
    printf '  QWEN_GGML_NATIVE           default ON, Zen 3 host\n' >&2
    printf '  QWEN_GGML_LTO              default OFF\n' >&2
    printf '  QWEN_GGML_OPENMP           default ON\n' >&2
    printf '  QWEN_CUDA_MMVQ_Q6K_MAX     Ada Q6_K MMVQ ceiling, default 8, patched trees only\n' >&2
    printf '  QWEN_CUDA_MMVQ_Q8_0_MAX    Ada Q8_0 MMVQ ceiling, default 8, patched trees only\n' >&2
    printf '  QWEN_FORCE_MMQ             ON builds the MMQ kernel-policy arm\n' >&2
    printf '  QWEN_FORCE_CUBLAS          ON builds the cuBLAS differential arm\n' >&2
    printf '  QWEN_HOST_COMPILER         C++ compiler, default g++-15\n' >&2
    printf '  QWEN_BUILD_DIRECTORY       build tree, defaults from the configuration digest\n' >&2
    printf '  QWEN_BUILD_JOBS            parallel jobs, defaults to nproc\n' >&2
    printf '  QWEN_ALLOW_ANY_COMMIT      1 builds a tree off the pinned commit\n' >&2
    exit 2
}

[ "$#" -le 1 ] || usage

source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
cuda_architectures=${QWEN_CUDA_ARCHITECTURES:-89}
build_vulkan=${QWEN_BUILD_VULKAN:-OFF}
cuda_graphs=${QWEN_CUDA_GRAPHS:-ON}
cuda_fa=${QWEN_CUDA_FA:-ON}
cuda_fa_all_quants=${QWEN_CUDA_FA_ALL_QUANTS:-ON}
cuda_nccl=${QWEN_CUDA_NCCL:-OFF}
cuda_no_vmm=${QWEN_CUDA_NO_VMM:-OFF}
cuda_compression=${QWEN_CUDA_COMPRESSION_MODE:-size}
ggml_native=${QWEN_GGML_NATIVE:-ON}
ggml_lto=${QWEN_GGML_LTO:-OFF}
ggml_openmp=${QWEN_GGML_OPENMP:-ON}
mmvq_q6k_max=${QWEN_CUDA_MMVQ_Q6K_MAX:-8}
mmvq_q8_0_max=${QWEN_CUDA_MMVQ_Q8_0_MAX:-8}
force_mmq=${QWEN_FORCE_MMQ:-OFF}
force_cublas=${QWEN_FORCE_CUBLAS:-OFF}
host_cxx=${QWEN_HOST_COMPILER:-/usr/bin/g++-15}
host_cc=${QWEN_HOST_C_COMPILER:-/usr/bin/gcc-15}
build_jobs=${QWEN_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

case $cuda_architectures in
    89|89-real) ;;
    *) printf 'QWEN_CUDA_ARCHITECTURES takes 89 or 89-real: %s\n' \
        "$cuda_architectures" >&2; exit 2 ;;
esac
for pair in \
    "QWEN_BUILD_VULKAN=$build_vulkan" \
    "QWEN_CUDA_GRAPHS=$cuda_graphs" \
    "QWEN_CUDA_FA=$cuda_fa" \
    "QWEN_CUDA_FA_ALL_QUANTS=$cuda_fa_all_quants" \
    "QWEN_CUDA_NCCL=$cuda_nccl" \
    "QWEN_CUDA_NO_VMM=$cuda_no_vmm" \
    "QWEN_GGML_NATIVE=$ggml_native" \
    "QWEN_GGML_LTO=$ggml_lto" \
    "QWEN_GGML_OPENMP=$ggml_openmp" \
    "QWEN_FORCE_MMQ=$force_mmq" \
    "QWEN_FORCE_CUBLAS=$force_cublas"; do
    case ${pair#*=} in
        ON|OFF) ;;
        *) printf '%s takes ON or OFF\n' "${pair%%=*}" >&2; exit 2 ;;
    esac
done
case $cuda_compression in
    size|speed|balance|none) ;;
    *) printf 'QWEN_CUDA_COMPRESSION_MODE takes size, speed, balance, or none: %s\n' \
        "$cuda_compression" >&2; exit 2 ;;
esac
for threshold in "$mmvq_q6k_max" "$mmvq_q8_0_max"; do
    case $threshold in
        [1-9]|1[0-2]) ;;
        *) printf 'an MMVQ threshold takes an integer from 1 to 12: %s\n' \
            "$threshold" >&2; exit 2 ;;
    esac
done
if [ "$force_mmq" = ON ] && [ "$force_cublas" = ON ]; then
    printf 'QWEN_FORCE_MMQ and QWEN_FORCE_CUBLAS are exclusive arms\n' >&2
    exit 2
fi

# The configuration digest names the tree, so any lever change produces a new
# directory and the retained TSV states what the digest hashes.
configuration_tsv="arch	$cuda_architectures
vulkan	$build_vulkan
graphs	$cuda_graphs
fa	$cuda_fa
fa_all_quants	$cuda_fa_all_quants
nccl	$cuda_nccl
no_vmm	$cuda_no_vmm
compression	$cuda_compression
native	$ggml_native
lto	$ggml_lto
openmp	$ggml_openmp
mmvq_q6k_max	$mmvq_q6k_max
mmvq_q8_0_max	$mmvq_q8_0_max
force_mmq	$force_mmq
force_cublas	$force_cublas
host_cxx	$host_cxx
commit	$expected_commit"
configuration_sha256=$(printf '%s\n' "$configuration_tsv" | sha256sum | cut -d ' ' -f 1)
configuration_id=$(printf '%s' "$configuration_sha256" | cut -c 1-12)
build_directory=${QWEN_BUILD_DIRECTORY:-$source_directory/build-qwen-cuda-$configuration_id}

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

if [ "$build_vulkan" = ON ] && [ ! -d /usr/include/spirv ]; then
    printf 'the SPIR-V headers are absent from /usr/include/spirv\n' >&2
    printf 'install them with: sudo pacman -S --needed spirv-headers\n' >&2
    printf 'or leave QWEN_BUILD_VULKAN=OFF for the CUDA closure alone\n' >&2
    exit 1
fi

printf 'cuda_build=starting configuration=%s tree=%s\n' \
    "$configuration_id" "$build_directory"
printf '%s\n' "$configuration_tsv"

mkdir -p "$build_directory"
printf '%s\n' "$configuration_tsv" > "$build_directory/build-configuration.tsv"
printf '%s  build-configuration.tsv\n' "$configuration_sha256" \
    > "$build_directory/build-configuration.sha256"

cmake -S "$source_directory" -B "$build_directory" -G Ninja \
    -U LLAMA_CURL \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$host_cc" \
    -DCMAKE_CXX_COMPILER="$host_cxx" \
    -DCMAKE_CUDA_HOST_COMPILER="$host_cxx" \
    -DCMAKE_CUDA_ARCHITECTURES="$cuda_architectures" \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE="$ggml_native" \
    -DGGML_LTO="$ggml_lto" \
    -DGGML_CCACHE=ON \
    -DGGML_BLAS=OFF \
    -DGGML_OPENMP="$ggml_openmp" \
    -DGGML_RPC=OFF \
    -DGGML_CUDA=ON \
    -DGGML_VULKAN="$build_vulkan" \
    -DGGML_CUDA_FA="$cuda_fa" \
    -DGGML_CUDA_FA_ALL_QUANTS="$cuda_fa_all_quants" \
    -DGGML_CUDA_GRAPHS="$cuda_graphs" \
    -DGGML_CUDA_NCCL="$cuda_nccl" \
    -DGGML_CUDA_NO_VMM="$cuda_no_vmm" \
    -DGGML_CUDA_NO_PEER_COPY=OFF \
    -DGGML_CUDA_FORCE_MMQ="$force_mmq" \
    -DGGML_CUDA_FORCE_CUBLAS="$force_cublas" \
    -DGGML_CUDA_COMPRESSION_MODE="$cuda_compression" \
    -DGGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE="$mmvq_q6k_max" \
    -DGGML_CUDA_ADA_MMVQ_Q8_0_MAX_BATCH_SIZE="$mmvq_q8_0_max" \
    -DLLAMA_BUILD_TESTS=OFF

cmake --build "$build_directory" --parallel "$build_jobs" \
    --target llama-bench llama-server llama-cli llama-mtmd-cli llama-quantize

for artifact in llama-bench llama-server llama-cli llama-mtmd-cli llama-quantize; do
    [ -x "$build_directory/bin/$artifact" ] || {
        printf 'the build produced no %s\n' "$artifact" >&2
        exit 1
    }
done

cuobjdump_command=$(command -v cuobjdump 2>/dev/null || true)
if [ -z "$cuobjdump_command" ] && [ -x /opt/cuda/bin/cuobjdump ]; then
    cuobjdump_command=/opt/cuda/bin/cuobjdump
fi
[ -n "$cuobjdump_command" ] || {
    printf 'cuobjdump is absent from PATH and /opt/cuda/bin\n' >&2
    exit 1
}

cuda_library=$build_directory/bin/libggml-cuda.so
[ -e "$cuda_library" ] || {
    printf 'the build produced no CUDA backend library: %s\n' "$cuda_library" >&2
    exit 1
}
cubin_listing=$($cuobjdump_command --list-elf "$cuda_library" 2>&1) || {
    printf '%s\n' "$cubin_listing" >&2
    exit 1
}
ptx_listing=$($cuobjdump_command --list-ptx "$cuda_library" 2>&1) || {
    printf '%s\n' "$ptx_listing" >&2
    exit 1
}
cubin_count=$(printf '%s\n' "$cubin_listing" |
    awk '$1 == "ELF" && $2 == "file" { count++ } END { print count + 0 }')
ptx_count=$(printf '%s\n' "$ptx_listing" |
    awk '$1 == "PTX" && $2 == "file" { count++ } END { print count + 0 }')

[ "$cubin_count" -gt 0 ] || {
    printf 'the CUDA backend carries zero native cubins: %s\n' "$cuda_library" >&2
    exit 1
}
case $cuda_architectures in
    89-real)
        [ "$ptx_count" -eq 0 ] || {
            printf '89-real unexpectedly carries %s PTX payloads: %s\n' \
                "$ptx_count" "$cuda_library" >&2
            exit 1
        }
        ;;
    89)
        [ "$ptx_count" -gt 0 ] || {
            printf '89 carries zero PTX payloads: %s\n' "$cuda_library" >&2
            exit 1
        }
        ;;
esac
printf 'cuda_payload=verified arch=%s cubin=%s ptx=%s library=%s\n' \
    "$cuda_architectures" "$cubin_count" "$ptx_count" "$cuda_library"

printf 'cuda_build=complete configuration=%s tree=%s\n' \
    "$configuration_id" "$build_directory"
"$build_directory/bin/llama-bench" --version 2>&1 | head -2
