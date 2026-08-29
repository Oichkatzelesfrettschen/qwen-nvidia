#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

destination_directory=${1:-"${HOME:?}/models/Qwen3.5-4B-GGUF"}
artifact_name=Qwen3.5-4B-Q4_K_M.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_revision=e87f176479d0855a907a41277aca2f8ee7a09523
source_url=https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/$source_revision/$artifact_name
expected_bytes=2740937888
expected_sha256=00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4

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
