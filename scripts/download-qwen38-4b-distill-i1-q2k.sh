#!/bin/sh
set -eu

# The lowest published quantization of the balanced-text checkpoint, fetched to
# test whether fewer streamed bytes convert to proportional decode on this APU.
# The imatrix build is chosen over the static one because the two differ by 256
# bytes of metadata and share a tensor mixture, so the rate they measure is the
# same while the calibrated build removes one explanation for a quality failure.
# The file lands in its own directory, which leaves it text-only under the
# projector pairing rule in scripts/select-projector.sh.

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    exit 2
fi

destination_directory=${1:-"${HOME:?}/models/Qwen3.8-4B-Distill-Q2_K-GGUF"}
artifact_name=Qwen3.8-4B-i1-Q2_K.gguf
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
source_repository=mradermacher/Qwen3.8-4B-Distill-i1-GGUF
source_revision=928c6e4495232aee6780d27b79056b4ce63855dc
source_url=https://huggingface.co/$source_repository/resolve/$source_revision/Qwen3.8-4B-Distill.i1-Q2_K.gguf
expected_bytes=1959168512
expected_sha256=434c68a076c5e62da6f0ae01d5eff5211a04f3ff76092756d5d8ccfaf6534736

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
