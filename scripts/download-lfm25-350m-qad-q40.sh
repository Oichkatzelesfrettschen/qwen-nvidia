#!/bin/sh
set -eu

# LFM2.5-350M QAD, an extreme-small tool agent at quantization-aware-
# distilled Q4_0. The LFM2.5-350M-GGUF repository carries two Q4_0 artifacts
# that differ by one filename token: LFM2.5-350M-Q4_0.gguf is the ordinary
# post-training quantization and LFM2.5-350M-QAD-Q4_0.gguf is the
# quantization-aware-distilled checkpoint this script pins. The destination
# directory names QAD explicitly, separate from the repository name, so the
# artifact's own identity rather than an ambient path decides which
# checkpoint a later reader loads. The digest below is the publisher's own
# LFS object id at the pinned revision.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/LFM2.5-350M-QAD-GGUF"}
artifact_name=LFM2.5-350M-QAD-Q4_0.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=LiquidAI/LFM2.5-350M-GGUF
source_revision=9969000761ce34de907bf20017cbfc3d52d6eaf9
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/LFM2.5-350M-QAD-Q4_0.gguf
expected_bytes=219312832
expected_sha256=3d10b6ab8fc91a919534b9558e266255aca0bbc7f6d015963599aa9e74e05b1d

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
