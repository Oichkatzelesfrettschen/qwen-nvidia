#!/bin/sh
set -eu

if [ "$#" -gt 2 ]; then
    printf 'usage: %s [LLAMA_SOURCE] [PATCH]\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
patch_path=${2:-"$repository_directory/patches/superseded/llama-cuda-dispatch-trace-force-mmvq.patch"}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0
expected_patch_sha256=46b7a05e4fb636cd59166c20a5f77c6f1b5168f2eb953e6af9d08d7b5c663795
expected_tree=ca89214846cf056897a949059b11e92fcd01580c

git -C "$source_directory" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'llama.cpp source repository is unreadable: %s\n' "$source_directory" >&2
    exit 1
}
[ -f "$patch_path" ] || {
    printf 'superseded patch is missing: %s\n' "$patch_path" >&2
    exit 1
}

actual_patch_sha256=$(sha256sum "$patch_path" | cut -d ' ' -f 1)
if [ "$actual_patch_sha256" != "$expected_patch_sha256" ]; then
    printf 'superseded patch digest mismatch: expected %s found %s\n' \
        "$expected_patch_sha256" "$actual_patch_sha256" >&2
    exit 1
fi

temporary_directory=$(mktemp -d)
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

git clone --quiet --shared --no-checkout "$source_directory" \
    "$temporary_directory/llama.cpp"
git -C "$temporary_directory/llama.cpp" checkout --quiet --detach \
    "$expected_commit"
actual_commit=$(git -C "$temporary_directory/llama.cpp" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
    printf 'superseded patch base mismatch: expected %s found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    exit 1
fi

git -C "$temporary_directory/llama.cpp" apply --check "$patch_path"
git -C "$temporary_directory/llama.cpp" apply "$patch_path"
git -C "$temporary_directory/llama.cpp" diff --check
git -C "$temporary_directory/llama.cpp" add -A
actual_tree=$(git -C "$temporary_directory/llama.cpp" write-tree)
if [ "$actual_tree" != "$expected_tree" ]; then
    printf 'superseded patch replay tree mismatch: expected %s found %s\n' \
        "$expected_tree" "$actual_tree" >&2
    exit 1
fi

printf 'superseded_patch=%s sha256=%s\n' \
    "$(basename -- "$patch_path")" "$actual_patch_sha256"
printf 'superseded_patch_base=%s replay_tree=%s\n' \
    "$actual_commit" "$actual_tree"
printf 'superseded_patch_replay=accepted promotion=refused\n'
