#!/bin/sh
# Derive the RADV ICD path and export VK_DRIVER_FILES and VK_ICD_FILENAMES to
# it, so the Vulkan loader enumerates RADV alone and lavapipe or llvmpipe
# never appears. remote/radv-low-priority-env.sh derives and exports the
# identical pair from QWEN_RADV_ICD, defaulting to
# /usr/share/vulkan/icd.d/radeon_icd.x86_64.json, ahead of every inference
# launch; this file carries only that derivation because
# radv-low-priority-env.sh also renices the caller, retargets it to one CPU,
# scrubs every GGML_VK_* variable, and ends by exec'ing its own argv, none of
# which a caller that only wants the ICD pin wants applied to itself. Source
# this file rather than running it; under `set -eu` in the calling script, an
# unreadable ICD file exits the caller before any Vulkan process starts.

radv_icd_path=${QWEN_RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}
if [ ! -r "$radv_icd_path" ]; then
    printf 'RADV ICD is not readable: %s\n' "$radv_icd_path" >&2
    exit 1
fi
export VK_DRIVER_FILES="$radv_icd_path"
export VK_ICD_FILENAMES="$radv_icd_path"
