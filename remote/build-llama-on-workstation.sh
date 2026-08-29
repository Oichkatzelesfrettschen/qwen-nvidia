#!/bin/sh
set -eu

# Build llama.cpp for the appliance on a workstation and ship plain binaries.
#
# The appliance runs from the laptop alone: `remote/build-llama-vulkan.sh`
# builds there with the distribution toolchain, and that path stays the one the
# repository requires. It also spends 27 minutes of two 2.3 GHz cores on 772
# objects, which is the reality this script addresses.
#
# The container here holds the target's C library, and it lives on the
# workstation. Ubuntu 24.04 supplies the glibc 2.39 that Linux Mint 22.x links
# against, so a binary compiled inside it loads on the laptop while a binary
# compiled against a rolling-release glibc does not. What crosses the network
# is an ELF executable and its ggml shared objects. The laptop acquires no
# container runtime, no image, and no daemon.

usage() {
    printf 'usage: %s [SOURCE_DIRECTORY] [DESTINATION_HOST]\n' "$0" >&2
    printf '  QWEN_BUILD_BACKENDS  vulkan (default) or vulkan+hip\n' >&2
    printf '  QWEN_CONTAINER       podman (default) or docker\n' >&2
    printf '  QWEN_BUILD_JOBS      parallel jobs, defaults to nproc\n' >&2
    exit 2
}

[ "$#" -le 2 ] || usage

source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-apu"}
destination_host=${2:-${QWEN_LAPTOP_HOST:-qwen-laptop}}
destination_directory=${QWEN_DESTINATION_DIRECTORY:-src/llama.cpp-qwen-apu/build-qwen-vulkan/bin}
container=${QWEN_CONTAINER:-podman}
image=${QWEN_BUILD_IMAGE:-docker.io/library/ubuntu:24.04}
backends=${QWEN_BUILD_BACKENDS:-vulkan}
build_jobs=${QWEN_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

if ! command -v "$container" >/dev/null 2>&1; then
    printf 'container runtime is absent: %s\n' "$container" >&2
    exit 1
fi
if [ ! -d "$source_directory/.git" ]; then
    printf 'llama.cpp checkout is missing: %s\n' "$source_directory" >&2
    printf 'clone it and check out %s first\n' "$expected_commit" >&2
    exit 1
fi

actual_commit=$(git -C "$source_directory" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ] && [ "${QWEN_ALLOW_ANY_COMMIT:-0}" != 1 ]; then
    printf 'unexpected llama.cpp commit: expected %s, found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    printf 'set QWEN_ALLOW_ANY_COMMIT=1 to build it anyway\n' >&2
    exit 1
fi

case $backends in
    vulkan)     backend_flags='-DGGML_VULKAN=ON' ;;
    vulkan+hip) backend_flags='-DGGML_VULKAN=ON -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx900' ;;
    *)
        printf 'unknown backend selection: %s\n' "$backends" >&2
        exit 2
        ;;
esac

# HIP needs a ROCm the distribution does not carry, so that arm builds on the
# laptop against its own TheRock installation rather than here.
if [ "$backends" != vulkan ]; then
    printf 'the %s selection requires a ROCm inside the image and is unimplemented\n' \
        "$backends" >&2
    printf 'build HIP on the laptop against its TheRock SDK instead\n' >&2
    exit 2
fi

# The container build yields to the workstation desktop for the same reason the
# laptop builds do: someone is using the machine while it runs.
renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true

build_directory=$source_directory/build-workstation-vulkan
mkdir -p "$build_directory"

printf 'workstation_build=starting image=%s jobs=%s commit=%s\n' \
    "$image" "$build_jobs" "$actual_commit"

# The image installs the same toolchain the laptop uses, so the only difference
# between the two builds is the core count doing the work.
"$container" run --rm \
    --volume "$source_directory:/src:z" \
    --workdir /src \
    --env DEBIAN_FRONTEND=noninteractive \
    "$image" \
    /bin/sh -c "
        set -eu
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            build-essential cmake ninja-build git \
            libvulkan-dev glslc spirv-headers libcurl4-openssl-dev \
            >/dev/null
        cmake -S /src -B /src/build-workstation-vulkan -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            $backend_flags \
            -DGGML_NATIVE=OFF \
            -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
        cmake --build /src/build-workstation-vulkan \
            --parallel $build_jobs \
            --target llama-server llama-cli llama-bench llama-mtmd-cli
    "

for required_output in llama-server llama-cli llama-bench llama-mtmd-cli; do
    if [ ! -x "$build_directory/bin/$required_output" ]; then
        printf 'workstation build produced no %s\n' "$required_output" >&2
        exit 1
    fi
done

printf 'workstation_build=complete\n'
ls -l "$build_directory/bin/" | awk 'NR > 1 { print $9, $5 }'

if [ "${QWEN_SKIP_SHIP:-0}" = 1 ]; then
    printf 'ship=skipped destination=%s\n' "$destination_host"
    exit 0
fi

# Binaries and the ggml shared objects travel together, because the server
# dlopens the backend libraries by soname at startup.
rsync -av --copy-links \
    "$build_directory/bin/" \
    "$destination_host:$destination_directory/"

printf 'ship=complete host=%s directory=%s\n' \
    "$destination_host" "$destination_directory"
printf 'verify it there with: %s\n' \
    "$destination_directory/llama-server --version"
