#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

# The projector must come from the same repository revision as the language
# GGUF. A projector converted from a different checkpoint produces embeddings
# the language model was never trained against, and the failure is silent: the
# server loads, images are accepted, and the descriptions are wrong. This
# revision is the one download-qwen35-4b-q4km.sh pins.
destination_directory=${1:-"${HOME:?}/models/Qwen3.5-4B-GGUF"}
artifact_name=mmproj-F16.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_revision=e87f176479d0855a907a41277aca2f8ee7a09523
source_url=https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/$source_revision/$artifact_name
expected_bytes=672423616
expected_sha256=cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864

install -d -m 0755 "$destination_directory"

verify_artifact() {
    candidate_path=$1
    actual_bytes=$(stat -c %s "$candidate_path")
    if [ "$actual_bytes" -ne "$expected_bytes" ]; then
        printf 'artifact byte count mismatch: expected %s, found %s at %s\n' \
            "$expected_bytes" "$actual_bytes" "$candidate_path" >&2
        return 1
    fi
    actual_sha256=$(sha256sum "$candidate_path" | cut -d ' ' -f 1)
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'artifact SHA-256 mismatch: expected %s, found %s at %s\n' \
            "$expected_sha256" "$actual_sha256" "$candidate_path" >&2
        return 1
    fi
}

if [ -f "$artifact_path" ]; then
    verify_artifact "$artifact_path"
    printf 'artifact_status=already_verified path=%s bytes=%s sha256=%s source_revision=%s\n' \
        "$artifact_path" "$expected_bytes" "$expected_sha256" "$source_revision"
    exit 0
fi

if [ -f "$partial_path" ]; then
    partial_bytes=$(stat -c %s "$partial_path")
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
    --output "$partial_path" "$source_url"

verify_artifact "$partial_path"
mv "$partial_path" "$artifact_path"

printf 'artifact_status=verified path=%s bytes=%s sha256=%s source_revision=%s\n' \
    "$artifact_path" "$expected_bytes" "$expected_sha256" "$source_revision"
