#!/bin/sh
set -eu

# An uncensored fine-tune of Qwen3.5-2B at the same architecture the served
# qwen35-2b row runs: 24 blocks, 2048 embedding width, 6144 feed-forward width,
# 8 heads over 2 KV heads. Its chat template hash and tokenizer identity match
# the served Qwen3.8-2B distill, so thinking-off requests gate the same way.
# The digest is the publisher's own LFS object id at the pinned revision.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-GGUF"}
artifact_name=Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=HauhauCS/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive
source_revision=2bcf35c1ebf62c837c12c1aa90b578ff4717e831
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/Qwen3.5-2B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf
expected_bytes=1270808032
expected_sha256=be3ccca13a9d1bc8b67165ea80bd103cd6151a37ad131183cc7ca388f78d9517

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
