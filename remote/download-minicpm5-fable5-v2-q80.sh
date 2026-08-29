#!/bin/sh
set -eu

# The Fable5 V2 fine-tune of stock MiniCPM5-1B this tree admits alongside its
# stock counterpart. The publisher's model card names openbmb/MiniCPM5-1B as
# base_model and states the fine-tune keeps MiniCPM5's native chat template
# embedded in the GGUF files, which
# evidence/model-admission/minicpm5-static-admission.md confirms over a
# ranged header read: the two artifacts carry the identical chat template
# digest and an unchanged architecture fingerprint.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/candidate-staging/minicpm5-1b-fable5-v2"}
artifact_name=MiniCPM5-1B-Claude-Opus-Fable5-V2-Thinking-Q8_0.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=GnLOLot/MiniCPM5-1B-Claude-Opus-Fable5-V2-Thinking-GGUF
source_revision=1c5821260e77c42e0b350f0248fabcf3c90ecade
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/$artifact_name
expected_bytes=1153529184
expected_sha256=fc3ee1eddd305c155f63b6bd7bb189daa4d5f226ca325ab219bd7acd3b00ec77

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
