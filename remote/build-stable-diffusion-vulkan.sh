#!/bin/sh
set -eu

# Build sd-cli from a pinned stable-diffusion.cpp commit with the Vulkan
# backend, record every identity the resulting binary depends on, and refuse
# to configure against a device this appliance does not own.
#
# evidence/image-appliance/stable-diffusion-cpp-pin.md carries the audit this
# pin rests on: SD_VULKAN=ON sets GGML_VULKAN=ON (CMakeLists.txt:116-119),
# device selection runs through sd-cli's own --backend flag rather than a
# GGML_VK_VISIBLE_DEVICES-style variable, and an unresolvable device name
# refuses the run with a nonzero exit rather than falling back to the CPU
# backend silently.

renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true
build_jobs=${QWEN_BUILD_JOBS:-2}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
source_directory=${1:-"${HOME:?}/src/stable-diffusion.cpp-qwen-apu"}
build_directory=${2:-$source_directory/build-raven2}
expected_commit=de298c225bed97c3f9026b73cd7b71e7879bd41b
expected_ggml_commit=8e800cef2948046cc47f9db6090491c6128ca42c

if [ ! -d "$source_directory/.git" ] && [ ! -f "$source_directory/.git" ]; then
    printf 'stable-diffusion.cpp checkout is missing: %s\n' "$source_directory" >&2
    exit 1
fi

actual_commit=$(git -C "$source_directory" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
    printf 'unexpected stable-diffusion.cpp commit: expected %s, found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    exit 1
fi

# The gitlink in the pinned tree is the authority for the expected submodule
# commit, not whatever an ambient `git submodule update` last checked out --
# a submodule update run before the source tree is on the pinned commit reads
# the gitlink of whichever commit HEAD was actually on, and that mismatch is
# silent until this check catches it.
pinned_ggml_gitlink=$(git -C "$source_directory" ls-tree "$expected_commit" ggml |
    awk '{ print $3 }')
if [ "$pinned_ggml_gitlink" != "$expected_ggml_commit" ]; then
    printf 'pin mismatch: expected_ggml_commit %s does not match the gitlink %s recorded at %s\n' \
        "$expected_ggml_commit" "$pinned_ggml_gitlink" "$expected_commit" >&2
    exit 1
fi

if [ ! -f "$source_directory/ggml/CMakeLists.txt" ]; then
    printf 'ggml submodule is not checked out: %s/ggml\n' "$source_directory" >&2
    printf 'run: git -C %s submodule update --init ggml\n' "$source_directory" >&2
    exit 1
fi
actual_ggml_commit=$(git -C "$source_directory/ggml" rev-parse HEAD)
if [ "$actual_ggml_commit" != "$expected_ggml_commit" ]; then
    printf 'unexpected ggml submodule commit: expected %s, found %s\n' \
        "$expected_ggml_commit" "$actual_ggml_commit" >&2
    exit 1
fi

for required_command in cmake ninja glslc cc c++ sha256sum vulkaninfo; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'missing build command: %s\n' "$required_command" >&2
        exit 1
    fi
done

radv_icd=${QWEN_RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}
if [ ! -r "$radv_icd" ]; then
    printf 'RADV ICD is not readable: %s\n' "$radv_icd" >&2
    exit 1
fi

# The device this build serves, read twice. The unrestricted pass records how
# many software devices this host's Vulkan loader enumerates ordinarily --
# Mesa installs lavapipe beside radeon_icd, so a summary that lists llvmpipe
# as a second physical device is the appliance's ordinary state rather than a
# fault -- and the restricted pass pins VK_DRIVER_FILES and VK_ICD_FILENAMES
# to the RADV ICD alone, the way remote/radv-icd-env.sh pins every inference
# and image process, so the gate itself sees only the device the build
# serves. Reject a vendor stack this appliance does not run, a summary this
# host's vulkaninfo cannot produce, or a restricted summary that still lists
# a software device, and require the device description to name RAVEN2
# through RADV -- the description --list-devices later prints for the same
# device, not a hardcoded device index.
vulkaninfo_command=${QWEN_VULKANINFO_COMMAND:-vulkaninfo}
vulkan_summary_unrestricted=$($vulkaninfo_command --summary 2>&1) || {
    printf 'vulkaninfo --summary failed:\n%s\n' "$vulkan_summary_unrestricted" >&2
    exit 1
}
software_devices=$(printf '%s\n' "$vulkan_summary_unrestricted" |
    grep -Eci 'llvmpipe|lavapipe' || true)

vulkan_summary=$(VK_DRIVER_FILES=$radv_icd VK_ICD_FILENAMES=$radv_icd \
    $vulkaninfo_command --summary 2>&1) || {
    printf 'vulkaninfo --summary failed under the RADV ICD restriction:\n%s\n' \
        "$vulkan_summary" >&2
    exit 1
}
if printf '%s\n' "$vulkan_summary" | grep -Eqi 'llvmpipe|lavapipe'; then
    printf 'the RADV ICD restriction at %s still let the loader enumerate a software device:\n%s\n' \
        "$radv_icd" "$vulkan_summary" >&2
    exit 1
fi
if printf '%s\n' "$vulkan_summary" | grep -Eqi 'AMDGPU-PRO'; then
    printf 'refusing to build against a non-RADV Vulkan stack:\n%s\n' \
        "$vulkan_summary" >&2
    exit 1
fi
if ! printf '%s\n' "$vulkan_summary" | grep -Eq 'RADV RAVEN2'; then
    printf 'vulkaninfo --summary names no RADV RAVEN2 device:\n%s\n' "$vulkan_summary" >&2
    exit 1
fi
mesa_radv_version=$(printf '%s\n' "$vulkan_summary" |
    awk -F': *' '/driverInfo/ { print $2; exit }')
[ -n "$mesa_radv_version" ] || mesa_radv_version=-

vulkan_header_version=-
if [ -r /usr/include/vulkan/vulkan_core.h ]; then
    vulkan_header_version=$(awk '
        /#define VK_HEADER_VERSION /   { patch = $3 }
        /#define VK_HEADER_VERSION_COMPLETE/ { line = $0 }
        END {
            if (patch != "") { print patch } else { print "-" }
        }' /usr/include/vulkan/vulkan_core.h)
fi

kernel_release=$(uname -r)
amdgpu_module_version=-
if command -v modinfo >/dev/null 2>&1; then
    parsed_module=$(modinfo amdgpu 2>/dev/null |
        awk -F': *' '/^version:/ { print $2; exit }')
    [ -z "$parsed_module" ] || amdgpu_module_version=$parsed_module
fi

worktree_state=clean
git -C "$source_directory" diff --quiet HEAD 2>/dev/null || worktree_state=dirty

mkdir -p "$build_directory"

# CMAKE_C_FLAGS/CMAKE_CXX_FLAGS name no microarchitecture target: this build
# ships the distribution compiler's default tuning, matching
# remote/build-llama-vulkan.sh rather than the znver1 arms
# remote/build-llama-preset.sh names for llama.cpp production builds. Only
# sd-cli is built; the Web UI-facing HTTP server under examples/server has no
# consumer in this tree.
cmake -S "$source_directory" -B "$build_directory" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DSD_VULKAN=ON \
    -DSD_BUILD_EXAMPLES=ON \
    -DSD_CUDA=OFF -DSD_HIPBLAS=OFF -DSD_METAL=OFF -DSD_OPENCL=OFF \
    -DSD_SYCL=OFF -DSD_MUSA=OFF \
    -DSD_BUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF -DGGML_CCACHE=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=OFF

build_started=$(date +%s)
cmake --build "$build_directory" --parallel "$build_jobs" --target sd-cli

binary_path=$build_directory/bin/sd-cli
if [ ! -x "$binary_path" ]; then
    printf 'the build produced no sd-cli binary: %s\n' "$binary_path" >&2
    exit 1
fi
binary_mtime=$(stat -c %Y "$binary_path")
if [ "$binary_mtime" -lt "$build_started" ]; then
    printf 'sd-cli predates this build, a stale binary from an earlier configure: %s\n' \
        "$binary_path" >&2
    exit 1
fi
binary_sha256=$(sha256sum "$binary_path" | awk '{ print $1 }')

manifest_path=$build_directory/build-manifest.tsv
{
    printf 'field\tvalue\n'
    printf 'source_commit\t%s\n' "$actual_commit"
    printf 'ggml_submodule_commit\t%s\n' "$actual_ggml_commit"
    printf 'worktree_state\t%s\n' "$worktree_state"
    printf 'build_directory\t%s\n' "$build_directory"
    printf 'binary_path\t%s\n' "$binary_path"
    printf 'binary_sha256\t%s\n' "$binary_sha256"
    printf 'compiler\t%s\n' "$(cc --version | head -n 1)"
    printf 'cmake_version\t%s\n' "$(cmake --version | head -n 1)"
    printf 'ninja_version\t%s\n' "$(ninja --version)"
    printf 'vulkan_header_version\t%s\n' "$vulkan_header_version"
    printf 'mesa_radv_driver_info\t%s\n' "$mesa_radv_version"
    printf 'software_vulkan_devices_listed\t%s\n' "$software_devices"
    printf 'kernel_release\t%s\n' "$kernel_release"
    printf 'amdgpu_module_version\t%s\n' "$amdgpu_module_version"
    printf 'cmake_flags\tSD_VULKAN=ON SD_BUILD_EXAMPLES=ON GGML_NATIVE=OFF\n'
    printf 'parallel_jobs\t%s\n' "$build_jobs"
} >"$manifest_path"

"$script_directory/hash-load-closure.sh" "$binary_path" |
    sed 1d >>"$manifest_path"

printf 'build_commit=%s ggml_commit=%s build_directory=%s vulkan_backend=enabled device=RADV_RAVEN2 binary=%s binary_sha256=%s manifest=%s\n' \
    "$actual_commit" "$actual_ggml_commit" "$build_directory" "$binary_path" \
    "$binary_sha256" "$manifest_path"
cat "$manifest_path"
