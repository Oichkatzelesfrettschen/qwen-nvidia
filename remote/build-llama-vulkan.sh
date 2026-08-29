#!/bin/sh
set -eu

# The desktop is the highest-priority workload on this machine and the laptop is
# in use while these run, so every long job here yields to it: nice 19 and idle
# I/O, which the kernel hands the CPU only when nothing the user is waiting on
# wants it. Two 2.3 GHz cores make a build long enough that normal priority is
# felt at the desktop, and a measurement taken while the desktop stutters
# describes a machine nobody would run.
renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true
build_jobs=${QWEN_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-apu"}
build_directory=${2:-$source_directory/build-qwen-vulkan}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0
ui_dist_directory=$build_directory/tools/ui/dist

if [ ! -d "$source_directory/.git" ]; then
    printf 'llama.cpp checkout is missing: %s\n' "$source_directory" >&2
    exit 1
fi

actual_commit=$(git -C "$source_directory" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
    printf 'unexpected llama.cpp commit: expected %s, found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    exit 1
fi

for required_command in cmake ninja glslc cc c++; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'missing build command: %s\n' "$required_command" >&2
        exit 1
    fi
done

# LLAMA_BUILD_UI disables the npm build, while LLAMA_USE_PREBUILT_UI controls
# the independent Hugging Face asset path.  Remove prior build-tree assets so
# an incremental configure cannot embed a stale Web UI in the server binary.
if [ -d "$ui_dist_directory" ]; then
    cmake -E remove_directory "$ui_dist_directory"
fi

if [ ! -r /usr/include/spirv/unified1/spirv.hpp ] && \
   [ ! -r /usr/include/spirv-headers/spirv.hpp ] && \
   [ ! -r /usr/include/spirv.hpp ]; then
    printf 'SPIR-V C++ headers are missing\n' >&2
    exit 1
fi

cmake -S "$source_directory" -B "$build_directory" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_FATAL_WARNINGS=ON \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=ON \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DGGML_BLAS=OFF \
    -DGGML_CCACHE=OFF \
    -DGGML_CPU=ON \
    -DGGML_CUDA=OFF \
    -DGGML_FATAL_WARNINGS=ON \
    -DGGML_HIP=OFF \
    -DGGML_LLAMAFILE=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENCL=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_RPC=OFF \
    -DGGML_SYCL=OFF \
    -DGGML_VULKAN=ON

# llama-mtmd-cli is how a projector is exercised outside the server. The server
# links libmtmd either way, so a vision failure seen through the HTTP path
# cannot be attributed between the projector, the chat template, and the
# request shape without a second consumer of the same library.
# llama-quantize converts between GGUF value formats without a Python
# toolchain. The publishers of this tree's small checkpoints ship BF16 as their
# only 16-bit artifact, and RADV on Raven2 reports shaderFloat16 true while
# exposing no bfloat16 extension, so measuring what the device advertises means
# producing F16 from BF16 on the appliance itself.
cmake --build "$build_directory" --parallel "$build_jobs" \
    --target llama-server llama-cli llama-mtmd-cli llama-quantize
"$script_directory/test-vulkan-pacing-math.sh" "$source_directory"
"$script_directory/test-vulkan-submit-limit.sh" "$source_directory"

for required_output in llama-server llama-cli llama-mtmd-cli llama-quantize; do
    if [ ! -x "$build_directory/bin/$required_output" ]; then
        printf 'the build produced no %s\n' "$required_output" >&2
        exit 1
    fi
done

printf 'build_commit=%s build_directory=%s cpu_backend=required vulkan_backend=enabled duty_cycle_test=accepted submit_limit_test=accepted multimodal_cli=built quantize_tool=built parallel_jobs=%s\n' \
    "$actual_commit" "$build_directory" "$build_jobs"
