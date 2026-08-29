#!/bin/sh
set -eu

# Build one named arm of llama.cpp into its own directory and prove what it
# produced.
#
# A shared build tree makes an experiment overwrite its own reference. An H1
# reconfigure replaces the H0 kernels while the recorded launcher hash still
# verifies, a copied tree keeps a nested CMakeCache pointing at another prefix,
# and a stale binary passes an -x test that a waiter reads as success. Each
# preset here owns a directory, a cache, a compile database, and a manifest, so
# an arm can only be replaced by rebuilding it.
#
# A build is accepted when every declared output was removed before compilation
# and exists afterwards with an mtime at or past the start stamp. Timestamps
# rather than existence, because existence is what a stale copy also satisfies.

usage() {
    printf 'usage: %s PRESET [SOURCE_DIRECTORY]\n' "$0" >&2
    printf '\npresets:\n' >&2
    printf '  raven2-vulkan-production  serving build, znver1\n' >&2
    printf '  raven2-vulkan-reference   production without the znver1 target\n' >&2
    printf '  raven2-vulkan-profile     production plus RelWithDebInfo for captures\n' >&2
    printf '  raven2-vulkan-tests       tests and fatal warnings\n' >&2
    printf '  raven2-cpu-control        CPU backend alone, the placement control\n' >&2
    printf '  raven2-hip-h0             HIP under the gfx900 override\n' >&2
    printf '  raven2-hip-h1-mmq         H0 plus GGML_CUDA_FORCE_MMQ\n' >&2
    printf '  raven2-hip-h2-native      HIP compiled for gfx902 directly\n' >&2
    printf '\nenvironment:\n' >&2
    printf '  QWEN_BUILD_JOBS      parallel jobs, defaults to nproc\n' >&2
    printf '  QWEN_ALLOW_ANY_COMMIT=1  build a source tree off the pinned commit\n' >&2
    printf '  QWEN_CONFIGURE_ONLY=1    configure and stop, for flag checks\n' >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

preset=$1
source_directory=${2:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
build_jobs=${QWEN_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

# Zen+ is GCC's znver1 target: Family 17h, and the switch selects AVX2, FMA,
# F16C, BMI2, and SHA together with the scheduling model. -march=native is
# wrong in the workstation container, which holds a 5600X3D rather than the
# Raven2 the binary runs on, so the target is named rather than detected.
zen_target='-march=znver1 -mtune=znver1'

# Every arm builds the same host code, so the flags that decide which
# instructions the CPU backend emits are stated once and shared.
cpu_instruction_flags='-DGGML_NATIVE=OFF -DGGML_SSE42=ON -DGGML_AVX=ON
    -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON'

# Serving flags common to the Vulkan arms. The appliance loads one model, binds
# loopback, and reaches the network through an SSH tunnel, so HTTPS, the
# unified app binary, and the bundled UI build nothing that runs.
serving_flags="-DCMAKE_BUILD_TYPE=Release
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON
    -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
    -DLLAMA_OPENSSL=OFF
    -DGGML_CCACHE=ON -DGGML_LTO=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=OFF
    -DGGML_LLAMAFILE=OFF -DGGML_CPU=ON
    -DGGML_CUDA=OFF -DGGML_HIP=OFF -DGGML_OPENCL=OFF -DGGML_RPC=OFF
    -DGGML_SYCL=OFF"

case $preset in
    raven2-vulkan-production)
        # LLAMA_SUBPROCESS stays on, which is upstream's Linux default.
        # common/subproc.cpp compiles create() to an unconditional failure when
        # it is off, and that one function is what router mode spawns children
        # through and what the MCP tool servers behind --tools run, so a
        # production build without it serves one model and refuses both. Router
        # mode therefore needs no separate arm.
        preset_flags="$serving_flags -DGGML_VULKAN=ON -DLLAMA_SUBPROCESS=ON"
        preset_targets='llama-server llama-cli llama-bench llama-mtmd-cli'
        preset_outputs='bin/llama-server bin/llama-cli bin/llama-bench bin/llama-mtmd-cli'
        compiler_flags=$zen_target
        ;;
    raven2-vulkan-reference)
        # The znver1 arm is a claim about scheduling and instruction selection,
        # and a claim needs a control that differs in that alone. This preset
        # holds every other flag of the production arm and names no
        # microarchitecture, so the two binaries differ in the target and in
        # nothing else.
        preset_flags="$serving_flags -DGGML_VULKAN=ON -DLLAMA_SUBPROCESS=ON"
        preset_targets='llama-server llama-cli llama-bench llama-mtmd-cli'
        preset_outputs='bin/llama-server bin/llama-cli bin/llama-bench bin/llama-mtmd-cli'
        compiler_flags=''
        ;;
    raven2-vulkan-profile)
        # Per-operator captures name kernels and call sites, which needs frame
        # pointers and symbols that a Release build discards.
        preset_flags="$(printf '%s' "$serving_flags" |
            sed 's/-DCMAKE_BUILD_TYPE=Release/-DCMAKE_BUILD_TYPE=RelWithDebInfo/') \
            -DGGML_VULKAN=ON -DLLAMA_SUBPROCESS=ON"
        preset_targets='llama-server llama-bench'
        preset_outputs='bin/llama-server bin/llama-bench'
        compiler_flags="$zen_target -fno-omit-frame-pointer"
        ;;
    raven2-vulkan-tests)
        preset_flags="$(printf '%s' "$serving_flags" |
            sed 's/-DLLAMA_BUILD_TESTS=OFF/-DLLAMA_BUILD_TESTS=ON/') \
            -DGGML_VULKAN=ON -DLLAMA_FATAL_WARNINGS=ON -DGGML_FATAL_WARNINGS=ON"
        preset_targets='all'
        preset_outputs='bin/llama-server'
        compiler_flags=$zen_target
        ;;
    raven2-cpu-control)
        # The placement control. Vulkan off rather than layers set to zero, so
        # a comparison against it carries no Vulkan initialization at all.
        preset_flags="$serving_flags -DGGML_VULKAN=OFF -DLLAMA_SUBPROCESS=ON"
        preset_targets='llama-bench llama-server'
        preset_outputs='bin/llama-bench bin/llama-server'
        compiler_flags=$zen_target
        ;;
    raven2-hip-h0|raven2-hip-h1-mmq|raven2-hip-h2-native)
        # The HIP arms build against TheRock rather than the distribution, and
        # they leave Vulkan off so that shader generation stays out of the
        # rebuild path: it is the longest step in the dual tree and it has no
        # bearing on a HIP row.
        hip_flags='-DCMAKE_BUILD_TYPE=Release
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
            -DGGML_VULKAN=OFF -DGGML_HIP=ON
            -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
            -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
            -DLLAMA_OPENSSL=OFF'
        case $preset in
            raven2-hip-h0)
                preset_flags="$hip_flags -DGPU_TARGETS=gfx900" ;;
            raven2-hip-h1-mmq)
                preset_flags="$hip_flags -DGPU_TARGETS=gfx900 -DGGML_CUDA_FORCE_MMQ=ON" ;;
            raven2-hip-h2-native)
                preset_flags="$hip_flags -DGPU_TARGETS=gfx902" ;;
        esac
        preset_targets='llama-bench'
        preset_outputs='bin/llama-bench'
        compiler_flags=$zen_target
        ;;
    *)
        printf 'unknown preset: %s\n' "$preset" >&2
        usage
        ;;
esac

if [ ! -d "$source_directory/.git" ] && [ ! -f "$source_directory/.git" ]; then
    printf 'llama.cpp checkout is missing: %s\n' "$source_directory" >&2
    exit 1
fi
actual_commit=$(git -C "$source_directory" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ] && [ "${QWEN_ALLOW_ANY_COMMIT:-0}" != 1 ]; then
    printf 'unexpected llama.cpp commit: expected %s, found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    printf 'set QWEN_ALLOW_ANY_COMMIT=1 to build it anyway\n' >&2
    exit 1
fi
worktree_state=clean
git -C "$source_directory" diff --quiet HEAD 2>/dev/null || worktree_state=dirty

# A build someone is waiting on runs at normal priority and finishes sooner;
# inference keeps nice 19 because it competes with the desktop compositor for
# the two cores. QWEN_BACKGROUND_BUILD=1 selects the idle classes for a build
# started beside interactive work.
build_nice=${QWEN_BUILD_NICE:-0}
build_ionice_class=${QWEN_BUILD_IONICE_CLASS:-2}
if [ "${QWEN_BACKGROUND_BUILD:-0}" = 1 ]; then
    build_nice=19
    build_ionice_class=3
fi
case $build_nice in
    '' | *[!0-9-]*)
        printf 'build nice must be an integer: %s\n' "$build_nice" >&2
        exit 2
        ;;
esac
case $build_ionice_class in
    1 | 2 | 3) ;;
    *)
        printf 'build I/O class must be 1, 2, or 3: %s\n' "$build_ionice_class" >&2
        exit 2
        ;;
esac
if [ "$build_nice" -ne 0 ]; then
    renice -n "$build_nice" -p $$ >/dev/null 2>&1 || true
fi
ionice -c "$build_ionice_class" -p $$ >/dev/null 2>&1 || true

build_directory=$source_directory/build-$preset
mkdir -p "$build_directory"

# A nested ExternalProject cache copied from another prefix refuses to
# configure. Clearing it is cheaper than diagnosing the refusal each time.
shader_generator_prefix=$build_directory/ggml/src/ggml-vulkan/vulkan-shaders-gen-prefix
if [ -f "$shader_generator_prefix/src/vulkan-shaders-gen-build/CMakeCache.txt" ] &&
    ! grep -q "^CMAKE_CACHEFILE_DIR:INTERNAL=$shader_generator_prefix/" \
        "$shader_generator_prefix/src/vulkan-shaders-gen-build/CMakeCache.txt"
then
    printf 'shader_generator_cache=stale removing=%s\n' "$shader_generator_prefix"
    rm -rf "$shader_generator_prefix"
fi

printf 'preset=%s source=%s commit=%s worktree=%s jobs=%s\n' \
    "$preset" "$source_directory" "$actual_commit" "$worktree_state" "$build_jobs"

# Removal before compilation is what makes the timestamp proof meaningful: a
# surviving output could otherwise satisfy it by predating the build.
for output in $preset_outputs; do
    rm -f "$build_directory/$output"
done
rm -f "$build_directory"/bin/libggml*.so "$build_directory"/bin/libllama*.so \
      "$build_directory"/bin/libmtmd*.so 2>/dev/null || true

# shellcheck disable=SC2086
cmake -S "$source_directory" -B "$build_directory" -G Ninja \
    -DCMAKE_C_FLAGS="$compiler_flags" \
    -DCMAKE_CXX_FLAGS="$compiler_flags" \
    $preset_flags $cpu_instruction_flags

if [ "${QWEN_CONFIGURE_ONLY:-0}" = 1 ]; then
    printf 'preset=%s configure=complete build=skipped\n' "$preset"
    exit 0
fi

build_started=$(date +%s)
# shellcheck disable=SC2086
cmake --build "$build_directory" --parallel "$build_jobs" --target $preset_targets

for output in $preset_outputs; do
    output_path=$build_directory/$output
    if [ ! -e "$output_path" ]; then
        printf 'declared output is missing after the build: %s\n' "$output_path" >&2
        exit 1
    fi
    output_mtime=$(stat -c %Y "$output_path")
    if [ "$output_mtime" -lt "$build_started" ]; then
        printf 'declared output predates the build: %s\n' "$output_path" >&2
        exit 1
    fi
done

manifest_path=$build_directory/artifact-manifest.tsv
{
    printf 'preset\t%s\n' "$preset"
    printf 'commit\t%s\n' "$actual_commit"
    printf 'worktree\t%s\n' "$worktree_state"
    printf 'compiler_flags\t%s\n' "$compiler_flags"
    printf 'cmake_flags\t%s\n' "$(printf '%s %s' "$preset_flags" "$cpu_instruction_flags" | tr -s ' \n' ' ')"
} > "$manifest_path"

for output in $preset_outputs; do
    case $output in
        bin/*)
            "$script_directory/hash-load-closure.sh" "$build_directory/$output" |
                sed 1d >> "$manifest_path"
            ;;
    esac
done

printf 'preset=%s build=accepted manifest=%s\n' "$preset" "$manifest_path"
cat "$manifest_path"
