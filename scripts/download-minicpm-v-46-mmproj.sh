#!/bin/sh
set -eu

# The vision encoder for MiniCPM-V 4.6, a SigLIP2-400M tower packaged at
# Q8_0. It resolves through its own directory, so pairing depends on nothing
# beyond `select-projector.sh` finding one projector beside one checkpoint.
# The digest below is the publisher's own LFS object id at the pinned
# revision.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/MiniCPM-V-4.6-GGUF"}
artifact_name=mmproj-MiniCPM-V-4.6-Q8_0.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=ggml-org/MiniCPM-V-4.6-GGUF
source_revision=1d73353fab60fe6040ab73eb1e457e2aab210100
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/mmproj-MiniCPM-V-4.6-Q8_0.gguf
expected_bytes=727954528
expected_sha256=3d8249cdd0e1cb699644eb021fbcc04320aad89fa5dc9234ef94db0846556581

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
