#!/bin/sh
set -eu

# MiniCPM5-1B, a code, tool-use, and CLI-control control at the 1B class. It
# gives the roster a small model whose declared strength is agentic tool
# selection rather than prose, which the graded suite's tool-call rows read
# against. The digest below is the publisher's own LFS object id at the
# pinned revision.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/MiniCPM5-1B-GGUF"}
artifact_name=MiniCPM5-1B-Q4_K_M.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=openbmb/MiniCPM5-1B-GGUF
source_revision=3d55fac80935ae6456986ad2384b5cbcc4d6c948
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/MiniCPM5-1B-Q4_K_M.gguf
expected_bytes=688065920
expected_sha256=81b64d05a23b17b34c475f42b3e72fbde62d4b92cc34541f7a8031d0752deafa

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
