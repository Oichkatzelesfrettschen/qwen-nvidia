#!/bin/sh
set -eu

# Build the CUDA image runtime: stable-diffusion.cpp at the commit
# evidence/image-appliance/stable-diffusion-cpp-pin.md pins, with the ggml
# gitlink that commit names, under SD_CUDA=ON for SM89 alone, and print the
# binary's SHA-256 beside the source identity, which the image profile
# record carries as the runtime identity. The binary opens a CUDA context on
# its first run, so this script executes nothing it built; --list-devices
# and the first generation belong to the admission under the ownership lock.
#
# gpu-ownership: non-gpu-helper; executes no device binary.

usage() {
    cat >&2 <<'USAGE'
usage: build-image-runtime-cuda.sh [OUTPUT_DIRECTORY]

environment:
  QWEN_SD_SOURCE       the stable-diffusion.cpp checkout, default $HOME/src/stable-diffusion.cpp-qwen-nvidia
  QWEN_SD_COMMIT       the pinned commit, default de298c225bed97c3f9026b73cd7b71e7879bd41b
  QWEN_SD_GGML_COMMIT  the ggml gitlink at that commit, default 8e800cef2948046cc47f9db6090491c6128ca42c
  QWEN_CUDA_ARCHITECTURES  default 89-real
  QWEN_HOST_COMPILER   default /usr/bin/g++-15
USAGE
    exit 2
}
[ "$#" -le 1 ] || usage
source_directory=${QWEN_SD_SOURCE:-"${HOME:?}/src/stable-diffusion.cpp-qwen-nvidia"}
expected_commit=${QWEN_SD_COMMIT:-de298c225bed97c3f9026b73cd7b71e7879bd41b}
expected_ggml=${QWEN_SD_GGML_COMMIT:-8e800cef2948046cc47f9db6090491c6128ca42c}
cuda_architectures=${QWEN_CUDA_ARCHITECTURES:-89-real}
host_cxx=${QWEN_HOST_COMPILER:-/usr/bin/g++-15}
host_cc=${QWEN_HOST_C_COMPILER:-/usr/bin/gcc-15}
output_directory=${1:-"$source_directory/build-cuda-sm89"}

[ -d "$source_directory/.git" ] || { printf 'stable-diffusion.cpp checkout is absent: %s\n' "$source_directory" >&2; exit 1; }
actual_commit=$(git -C "$source_directory" rev-parse HEAD)
[ "$actual_commit" = "$expected_commit" ] || {
    printf 'checkout is at %s where the pin is %s\n' "$actual_commit" "$expected_commit" >&2
    exit 1
}
# The gitlink is read from the pinned tree rather than from the ambient
# submodule checkout, since a checkout that moved to the pin after an init
# holds the tip's gitlink instead.
gitlink=$(git -C "$source_directory" ls-tree "$expected_commit" ggml | awk '{ print $3 }')
[ "$gitlink" = "$expected_ggml" ] || {
    printf 'the pinned tree names ggml %s where the expectation is %s\n' "$gitlink" "$expected_ggml" >&2
    exit 1
}
actual_ggml=$(git -C "$source_directory/ggml" rev-parse HEAD 2>/dev/null || echo absent)
[ "$actual_ggml" = "$expected_ggml" ] || {
    printf 'ggml submodule is at %s where the gitlink is %s\n' "$actual_ggml" "$expected_ggml" >&2
    exit 1
}
dirty=$(git -C "$source_directory" status --porcelain --ignore-submodules=none | grep -v "^?? build-" || :)
[ -z "$dirty" ] || { printf 'checkout is dirty:\n%s\n' "$dirty" >&2; exit 1; }
[ -x "$host_cxx" ] && [ -x "$host_cc" ] || { printf 'host compiler is absent\n' >&2; exit 1; }
nvcc=$(command -v nvcc 2>/dev/null || echo /opt/cuda/bin/nvcc)
[ -x "$nvcc" ] || { printf 'nvcc is absent\n' >&2; exit 1; }

cmake -S "$source_directory" -B "$output_directory" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSD_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$cuda_architectures" \
    -DCMAKE_CUDA_COMPILER="$nvcc" \
    -DCMAKE_CUDA_HOST_COMPILER="$host_cxx" \
    -DCMAKE_C_COMPILER="$host_cc" \
    -DCMAKE_CXX_COMPILER="$host_cxx" \
    -DSD_BUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF
cmake --build "$output_directory" --target sd-cli --parallel "$(nproc)"

binary=$output_directory/bin/sd-cli
[ -x "$binary" ] || { printf 'sd-cli was not built at %s\n' "$binary" >&2; exit 1; }
printf 'source_commit=%s\n' "$expected_commit"
printf 'ggml_commit=%s\n' "$expected_ggml"
printf 'cuda_architectures=%s\n' "$cuda_architectures"
printf 'nvcc=%s\n' "$("$nvcc" --version | sed -n 's/^Cuda compilation tools, release \([0-9.]*\).*/\1/p')"
printf 'host_compiler=%s\n' "$("$host_cxx" -dumpfullversion)"
printf 'runtime_path=%s\n' "$binary"
printf 'runtime_sha256=%s\n' "$(sha256sum "$binary" | cut -d ' ' -f 1)"
printf 'runtime_execution=not_run reason=build_only\n'
