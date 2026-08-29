#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/Nanbeige4.2-3B-GGUF"}
artifact_name=Nanbeige4.2-3B-Q4_K_M.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=Abiray/Nanbeige4.2-3B-GGUF
source_revision=774a61f8217ad18e7e102107fb7abcfecfae6a99
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/$artifact_name
expected_bytes=2574807986
expected_sha256=18a659d0c1744e5bd2f4b8da55e0dcabf42ec7f005b74ec8eb66593b3380f958

# Every other fetch here pins an official publisher's own GGUF. This one pins a
# community conversion, because Nanbeige publishes weights rather than GGUFs and
# convert_hf_to_gguf.py at the pinned llama.cpp commit carries no Nanbeige class.
# The revision, byte count, and digest hold it to the same bar; what they cannot
# establish is that the converter wrote {arch}.num_loops, which
# src/models/nanbeige.cpp reads with a non-required lookup defaulting to 1. A
# file missing that key runs 22 layers instead of 44 and answers wrongly rather
# than failing, so remote/gguf-tensor-census.py reports it after the fetch.
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
