#!/bin/sh
set -eu

# SDXS-512, first in the model funnel: 512x512, batch 1, minimal steps.
# The publisher ships a diffusers export rather than a merged checkpoint, and
# ModelLoader::init_from_diffusers_file (src/model_loader.cpp:427-430 at the
# pinned stable-diffusion.cpp commit) resolves exactly three fixed relative
# paths under the directory named by -m: unet/diffusion_pytorch_model.safetensors,
# vae/diffusion_pytorch_model.safetensors, text_encoder/model.safetensors.
# This script fetches those three files into that layout rather than a single
# flat destination; -m must then name the destination directory itself, not
# one file inside it.
#
# The repository also carries a vae_large/ sibling for a second higher-fidelity
# decoder and a dreamshaper variant under a different license; neither is
# fetched here (evidence/image-appliance/stable-diffusion-cpp-pin.md's open
# questions).

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/image/sdxs-512"}
source_repository=IDKiro/sdxs-512-0.9
source_revision=c332f05f60eb4b453de513be52c2a18c48d8cfe6

umask 077
mkdir -p "$destination_directory/unet" "$destination_directory/vae" "$destination_directory/text_encoder"

verify_artifact() {
    candidate_path=$1
    candidate_expected_bytes=$2
    candidate_expected_sha256=$3
    actual_bytes=$(wc -c <"$candidate_path")
    if [ "$actual_bytes" != "$candidate_expected_bytes" ]; then
        printf 'artifact byte count mismatch: expected %s, found %s at %s\n' \
            "$candidate_expected_bytes" "$actual_bytes" "$candidate_path" >&2
        return 1
    fi
    actual_sha256=$(sha256sum "$candidate_path" | awk '{ print $1 }')
    if [ "$actual_sha256" != "$candidate_expected_sha256" ]; then
        printf 'artifact SHA-256 mismatch: expected %s, found %s at %s\n' \
            "$candidate_expected_sha256" "$actual_sha256" "$candidate_path" >&2
        return 1
    fi
}

fetch_one() {
    relative_path=$1
    fetch_expected_bytes=$2
    fetch_expected_sha256=$3
    artifact_path=$destination_directory/$relative_path
    partial_path=$artifact_path.part
    source_url=https://huggingface.co/$source_repository/resolve/$source_revision/$relative_path

    if [ -f "$artifact_path" ]; then
        verify_artifact "$artifact_path" "$fetch_expected_bytes" "$fetch_expected_sha256"
        printf 'artifact_status=already_verified path=%s bytes=%s sha256=%s\n' \
            "$artifact_path" "$fetch_expected_bytes" "$fetch_expected_sha256"
        return 0
    fi

    if [ -f "$partial_path" ]; then
        partial_bytes=$(wc -c <"$partial_path")
        if [ "$partial_bytes" -gt "$fetch_expected_bytes" ]; then
            printf 'partial artifact exceeds expected size: %s > %s at %s\n' \
                "$partial_bytes" "$fetch_expected_bytes" "$partial_path" >&2
            return 1
        fi
        printf 'artifact_status=resuming partial_bytes=%s path=%s\n' \
            "$partial_bytes" "$partial_path"
    else
        printf 'artifact_status=starting path=%s\n' "$partial_path"
    fi

    curl --fail --location --retry 5 --retry-all-errors --continue-at - \
        --output "$partial_path" "$source_url?download=true"

    verify_artifact "$partial_path" "$fetch_expected_bytes" "$fetch_expected_sha256"
    mv "$partial_path" "$artifact_path"
    printf 'artifact_status=verified path=%s bytes=%s sha256=%s\n' \
        "$artifact_path" "$fetch_expected_bytes" "$fetch_expected_sha256"
}

fetch_one text_encoder/model.safetensors 1361597018 \
    cce6febb0b6d876ee5eb24af35e27e764eb4f9b1d0b7c026c8c3333d4cfc916c
fetch_one unet/diffusion_pytorch_model.safetensors 1312752864 \
    c2afb7dbea11b64d0bfbc4d1a45854aa65408b8a74a732438225d3f2ec85c71c
fetch_one vae/diffusion_pytorch_model.safetensors 9793292 \
    d7956d561b1efbd861ad9b03fd8f01510f9e87eddc07bdfd20837009433f6ee5

printf 'artifact_status=verified model_directory=%s source_repository=%s source_revision=%s\n' \
    "$destination_directory" "$source_repository" "$source_revision"
