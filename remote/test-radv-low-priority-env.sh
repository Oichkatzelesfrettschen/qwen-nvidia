#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
wrapper=$script_directory/radv-low-priority-env.sh

# The wrapper refuses to run without the RADV ICD it pins, so a host serving on
# CUDA with no AMD driver installed cannot exercise it at all. Reporting that as
# a skip keeps the Vulkan-on-AMD path testable where it exists and stops it from
# reading as a failure where the driver is simply absent.
radv_icd=${QWEN_RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}
if [ ! -r "$radv_icd" ]; then
    printf 'radv_low_priority_env=skipped reason=radv_icd_absent path=%s\n' \
        "$radv_icd"
    exit 0
fi

capture_environment() {
    profile=$1
    # The nested shell expands its own runtime environment after the wrapper runs.
    # shellcheck disable=SC2016
    QWEN_VULKAN_PROFILE=$profile AMD_PRIORITY=1023 \
        QWEN_ONE_CORE_ACTIVE=1 QWEN_GUARD_CPU_ACTIVE=1 \
        GGML_VK_ENABLE_MEMORY_PRIORITY=1 GGML_VK_ALLOW_GRAPHICS_QUEUE=1 \
        RADV_PERFTEST=nogttspill \
        GGML_VK_DUTY_CYCLE_PERCENT=99 \
        GGML_VK_SERIALIZE_SUBMISSIONS=unexpected \
        GGML_VK_MAX_NODES_PER_SUBMIT=999 \
        "$wrapper" sh -c '
        printf "affinity=%s\n" "$(awk "/Cpus_allowed_list/ { print \$2 }" /proc/self/status)"
        printf "nice=%s\n" "$(ps -o ni= -p $$ | tr -d " ")"
        printf "io=%s\n" "$(ionice -p $$)"
        printf "profile=%s low=%s duty=%s serialized=%s max_nodes=%s strict=%s\n" \
            "$QWEN_VULKAN_PROFILE" "$GGML_VK_LOW_PRIORITY" \
            "${GGML_VK_DUTY_CYCLE_PERCENT-unset}" \
            "${GGML_VK_SERIALIZE_SUBMISSIONS-unset}" \
            "${GGML_VK_MAX_NODES_PER_SUBMIT-unset}" "$LLAMA_NO_CPU_FALLBACK"
        printf "driver=%s compatibility_driver=%s\n" "$VK_DRIVER_FILES" "$VK_ICD_FILENAMES"
        printf "display=%s wayland=%s sysmem_fallback=%s amd_priority=%s memory_priority=%s allow_graphics=%s radv_perftest=%s\n" \
            "${DISPLAY-unset}" "${WAYLAND_DISPLAY-unset}" \
            "${GGML_VK_ALLOW_SYSMEM_FALLBACK-unset}" "${AMD_PRIORITY-unset}" \
            "${GGML_VK_ENABLE_MEMORY_PRIORITY-unset}" \
            "${GGML_VK_ALLOW_GRAPHICS_QUEUE-unset}" "${RADV_PERFTEST-unset}"
        printf "model_cpu_sentinel=%s guard_cpu_sentinel=%s\n" \
            "${QWEN_ONE_CORE_ACTIVE-unset}" "${QWEN_GUARD_CPU_ACTIVE-unset}"
    '
}

environment_output=$(capture_environment paced-60)

printf '%s\n' "$environment_output"
printf '%s\n' "$environment_output" | grep -F 'affinity=0' >/dev/null
printf '%s\n' "$environment_output" | grep -F 'nice=19' >/dev/null
printf '%s\n' "$environment_output" | grep -F 'io=idle' >/dev/null
printf '%s\n' "$environment_output" | grep -F \
    'profile=paced-60 low=1 duty=60 serialized=1 max_nodes=32 strict=1' >/dev/null
printf '%s\n' "$environment_output" | grep -F \
    'display=unset wayland=unset sysmem_fallback=unset amd_priority=unset memory_priority=unset allow_graphics=unset radv_perftest=unset' >/dev/null
printf '%s\n' "$environment_output" | grep -F \
    'model_cpu_sentinel=unset guard_cpu_sentinel=unset' >/dev/null

environment_output=$(capture_environment low-serialized)
printf '%s\n' "$environment_output" | grep -F \
    'profile=low-serialized low=1 duty=unset serialized=1 max_nodes=32 strict=1' >/dev/null

environment_output=$(capture_environment low-async)
printf '%s\n' "$environment_output" | grep -F \
    'profile=low-async low=1 duty=unset serialized=unset max_nodes=16 strict=1' >/dev/null

if QWEN_VULKAN_PROFILE=unknown "$wrapper" true \
    > /dev/null 2> /dev/null; then
    printf 'RADV environment wrapper accepted an unknown profile\n' >&2
    exit 1
fi

device_output=$(QWEN_VULKAN_PROFILE=low-serialized \
    "$wrapper" vulkaninfo --summary 2>&1)
printf '%s\n' "$device_output" | grep -F 'AMD Radeon Graphics (RADV RAVEN2)' >/dev/null
printf 'radv_environment=accepted\n'
