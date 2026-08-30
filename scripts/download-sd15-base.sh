#!/bin/sh
set -eu

# SD 1.5 as the quality control against SDXS-512 and LCM-4-step in the model
# funnel evidence/image-appliance/stable-diffusion-cpp-pin.md's pin table
# names. A single merged safetensors checkpoint, so ModelLoader::init_from_file
# reads it through init_from_safetensors_file rather than the three-path
# diffusers loader SDXS-512 needs.
# stable-diffusion-v1-5/stable-diffusion-v1-5 is the maintained mirror of the
# original runwayml/stable-diffusion-v1-5 repository, which is gone from
# Hugging Face; the mirror carries the same weights under the same
# creativeml-openrail-m license.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/image/sd15-base"}
artifact_name=v1-5-pruned-emaonly.safetensors
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=stable-diffusion-v1-5/stable-diffusion-v1-5
source_revision=451f4fe16113bff5a5d2269ed5ad43b0592e9a14
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/$artifact_name
expected_bytes=4265146304
expected_sha256=6ce0161689b3853acaa03779ec93eafe75a02f4ced659bee03f50797806fa2fa

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
