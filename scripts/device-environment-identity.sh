#!/bin/sh
set -eu

# A measured threshold, rate, or launch cost holds for the device software stack
# it was taken under. This tree records the closure that produced a number --
# `build-configuration.sha256` names the source commit, the patch series, and
# every compile definition -- and records nothing about the driver that executed
# it, so a retained figure and a later one are comparable only by assumption.
# `evidence/ada/` holds per-launch costs, dispatch crossovers, and paired rates
# whose authority is the AD104 driver, the CUDA runtime, and the kernel module
# in force when they ran.
#
# This helper emits one identity block every measurement harness writes beside
# its ownership and latch records. It is the key a later invalidation policy
# needs; it asserts no freshness of its own, because a policy that expired a
# retained record would expire every record in the tree written before it.
#
# The GPU UUID stays out. It identifies the physical board rather than the
# software stack a threshold depends on, which puts it in the class this tree
# scrubs beside MAC addresses and private hostnames, and the four fields that do
# carry the invalidation signal -- driver version, CUDA runtime, kernel release,
# device name -- carry it without it. `gpu_uuid_sha256` retains the first
# sixteen hex of its digest instead, so two records can be compared for the same
# board without the record naming it.
#
# gpu-ownership: reads driver metadata and opens no device context

usage() {
    printf 'usage: %s [OUTPUT_FILE]\n' "$0" >&2
    printf '\n' >&2
    printf 'Writes the device environment identity block to OUTPUT_FILE, or to\n' >&2
    printf 'standard output where no file is named.\n' >&2
    printf '\n' >&2
    printf 'environment: QWEN_IDENTITY_NVIDIA_SMI  nvidia-smi, default the one on PATH\n' >&2
    exit 2
}
[ "$#" -le 1 ] || usage
case ${1:-} in -h | --help) usage ;; esac

nvidia_smi=${QWEN_IDENTITY_NVIDIA_SMI:-$(command -v nvidia-smi 2>/dev/null || echo /usr/bin/nvidia-smi)}

# Every field reads `unavailable` rather than empty where its source is absent,
# so a record taken without the driver present is distinguishable from one whose
# field was never written.
query() {
    value=$("$nvidia_smi" --query-gpu="$1" --format=csv,noheader 2>/dev/null | head -1 || :)
    value=$(printf '%s' "$value" | sed 's/^ *//; s/ *$//')
    [ -n "$value" ] || value=unavailable
    printf '%s' "$value"
}

gpu_name=$(query name)
driver_version=$(query driver_version)
vbios_version=$(query vbios_version)
gpu_uuid=$(query uuid)
if [ "$gpu_uuid" = unavailable ]; then
    gpu_uuid_digest=unavailable
else
    gpu_uuid_digest=$(printf '%s' "$gpu_uuid" | sha256sum | cut -c1-16)
fi
unset gpu_uuid

# The runtime version the driver reports and the toolkit version that compiled
# the closure are two claims: a JIT of compute_89 PTX runs under the first while
# the SASS in the fatbin came from the second, and a stack can move one without
# the other.
cuda_driver_version=$("$nvidia_smi" -q 2>/dev/null |
    sed -n 's/^ *CUDA Version *: *\([0-9.]*\).*/\1/p' | head -1 || :)
[ -n "$cuda_driver_version" ] || cuda_driver_version=unavailable
cuda_toolkit_version=$(nvcc --version 2>/dev/null |
    sed -n 's/.*release \([0-9.]*\),.*/\1/p' | head -1 || :)
[ -n "$cuda_toolkit_version" ] || cuda_toolkit_version=unavailable
kernel_module_version=$(cat /sys/module/nvidia/version 2>/dev/null || echo unavailable)

emit() {
    printf 'gpu_name\t%s\n' "$gpu_name"
    printf 'gpu_uuid_sha256\t%s\n' "$gpu_uuid_digest"
    printf 'driver_version\t%s\n' "$driver_version"
    printf 'kernel_module_version\t%s\n' "$kernel_module_version"
    printf 'vbios_version\t%s\n' "$vbios_version"
    printf 'cuda_driver_version\t%s\n' "$cuda_driver_version"
    printf 'cuda_toolkit_version\t%s\n' "$cuda_toolkit_version"
    printf 'kernel_release\t%s\n' "$(uname -r)"
}

if [ "$#" -eq 1 ]; then
    emit >"$1"
else
    emit
fi
