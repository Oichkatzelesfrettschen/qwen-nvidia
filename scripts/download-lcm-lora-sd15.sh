#!/bin/sh
set -eu

# The LCM-LoRA the ~4-step lane in the model funnel loads by naming it inside
# the prompt: docs/lcm.md in the pinned stable-diffusion.cpp tree shows
# <lora:lcm-lora-sdv1-5:1> against --lora-model-dir. SDGenerationParams::
# extract_and_remove_lora resolves that NAME against lora_model_dir/NAME with
# the extension inferred, so this script names its destination file
# lcm-lora-sdv1-5.safetensors -- the publisher's own file name is
# pytorch_lora_weights.safetensors, and renaming it changes no byte the pinned
# digest covers.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/image/lcm-lora-sd15"}
artifact_name=lcm-lora-sdv1-5.safetensors
publisher_file_name=pytorch_lora_weights.safetensors
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=latent-consistency/lcm-lora-sdv1-5
source_revision=cf2fced511dbe7e26c8d1d397e728fbab875db4b
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/$publisher_file_name
expected_bytes=134621556
expected_sha256=8f90d840e075ff588a58e22c6586e2ae9a6f7922996ee6649a7f01072333afe4

umask 077
mkdir -p "$destination_directory"

verify_artifact() {
    candidate_path=$1
    actual_bytes=$(wc -c <"$candidate_path")
    if [ "$actual_bytes" != "$expected_bytes" ]; then
        printf 'artifact byte count mismatch: expected %s, found %s at %s\n' \
            "$expected_bytes" "$actual_bytes" "$candidate_path" >&2
        return 1
    fi
    actual_sha256=$(sha256sum "$candidate_path" | awk '{ print $1 }')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'artifact SHA-256 mismatch: expected %s, found %s at %s\n' \
            "$expected_sha256" "$actual_sha256" "$candidate_path" >&2
        return 1
    fi
}

if [ -f "$artifact_path" ]; then
    verify_artifact "$artifact_path"
    printf 'artifact_status=already_verified path=%s bytes=%s sha256=%s source_repository=%s source_revision=%s\n' \
        "$artifact_path" "$expected_bytes" "$expected_sha256" \
        "$source_repository" "$source_revision"
    exit 0
fi

if [ -f "$partial_path" ]; then
    partial_bytes=$(wc -c <"$partial_path")
    if [ "$partial_bytes" -gt "$expected_bytes" ]; then
        printf 'partial artifact exceeds expected size: %s > %s at %s\n' \
            "$partial_bytes" "$expected_bytes" "$partial_path" >&2
        exit 1
    fi
    printf 'artifact_status=resuming partial_bytes=%s path=%s\n' \
        "$partial_bytes" "$partial_path"
else
    printf 'artifact_status=starting path=%s\n' "$partial_path"
fi

curl --fail --location --retry 5 --retry-all-errors --continue-at - \
    --output "$partial_path" "$source_url?download=true"

verify_artifact "$partial_path"
mv "$partial_path" "$artifact_path"

printf 'artifact_status=verified path=%s bytes=%s sha256=%s source_repository=%s source_revision=%s\n' \
    "$artifact_path" "$expected_bytes" "$expected_sha256" \
    "$source_repository" "$source_revision"
