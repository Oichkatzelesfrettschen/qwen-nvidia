#!/bin/sh
set -eu

if [ "$#" -gt 3 ]; then
    printf 'usage: %s [LLAMA_SOURCE] [RETAINED_PATCH] [SUPERSEDING_PATCH]\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
retained_patch=${2:-"$repository_directory/evidence/ada/mmvq-crossover-ad104/mmvq12-per-type-source.patch"}
superseding_patch=${3:-"$repository_directory/patches/llama-cuda-mmvq-crossover-ad104.patch"}

expected_base=f280b26983ad0fdb705a0d9ebf0503e76f2899b0
expected_retained_patch_sha256=1c24aec7a88974b9471a979a6126b9890373e2ddc46dd67609f8b27dad800e03
expected_retained_tree=f0dfae3e08010071264f47c296ad6fb5b624f668
expected_superseding_patch_sha256=7a1a140ea45439d319c2e76b39354e1d6dcdd8be7a7c8f5c0371d22502a2a34b
expected_superseding_tree=bf008e6802aa206c780d0c15e3f9a6980be0c759

# The replay owns every repository and index it reads. A hook or parent Git
# process must not redirect either clone through inherited routing state, and a
# replacement object must not stand in for the registered upstream commit.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_NAMESPACE GIT_QUARANTINE_PATH GIT_SHALLOW_FILE
GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_REPLACE_OBJECTS

source_directory=$(CDPATH='' cd -- "$source_directory" 2>/dev/null && pwd -P) || {
    printf 'llama.cpp source repository is unreadable: %s\n' "$source_directory" >&2
    exit 1
}

canonical_file() {
    file_path=$1
    file_name=$(basename -- "$file_path")
    file_directory=$(dirname -- "$file_path")
    file_directory=$(CDPATH='' cd -- "$file_directory" 2>/dev/null && pwd -P) || {
        printf 'patch directory is unreadable: %s\n' "$file_path" >&2
        exit 1
    }
    canonical_path=$file_directory/$file_name
    [ -f "$canonical_path" ] || {
        printf 'patch is missing: %s\n' "$canonical_path" >&2
        exit 1
    }
    printf '%s\n' "$canonical_path"
}

retained_patch=$(canonical_file "$retained_patch")
superseding_patch=$(canonical_file "$superseding_patch")

git --no-replace-objects -C "$source_directory" rev-parse --git-dir \
    >/dev/null 2>&1 || {
    printf 'llama.cpp source repository is unreadable: %s\n' "$source_directory" >&2
    exit 1
}
git --no-replace-objects -C "$source_directory" cat-file -e \
    "$expected_base^{commit}" || {
    printf 'registered llama.cpp base is unavailable: %s\n' "$expected_base" >&2
    exit 1
}

actual_retained_patch_sha256=$(sha256sum "$retained_patch" | cut -d ' ' -f 1)
if [ "$actual_retained_patch_sha256" != "$expected_retained_patch_sha256" ]; then
    printf 'retained patch digest mismatch: expected %s found %s\n' \
        "$expected_retained_patch_sha256" "$actual_retained_patch_sha256" >&2
    exit 1
fi
actual_superseding_patch_sha256=$(sha256sum "$superseding_patch" | cut -d ' ' -f 1)
if [ "$actual_superseding_patch_sha256" != "$expected_superseding_patch_sha256" ]; then
    printf 'superseding patch digest mismatch: expected %s found %s\n' \
        "$expected_superseding_patch_sha256" "$actual_superseding_patch_sha256" >&2
    exit 1
fi

grep -Fqx '+#define MMVQ_KERNEL_MAX_NCOLS 12' "$retained_patch" || {
    printf 'retained patch does not declare the registered 12-column ceiling\n' >&2
    exit 1
}
grep -Fqx '+#define MMVQ_KERNEL_MAX_NCOLS 16' "$superseding_patch" || {
    printf 'superseding patch does not declare the registered 16-column ceiling\n' >&2
    exit 1
}
for threshold_macro in \
    GGML_CUDA_ADA_MMVQ_Q6_K_MAX_BATCH_SIZE \
    GGML_CUDA_ADA_MMVQ_Q8_0_MAX_BATCH_SIZE
do
    grep -Fq "$threshold_macro" "$retained_patch" || {
        printf 'retained patch lacks per-type threshold: %s\n' "$threshold_macro" >&2
        exit 1
    }
    grep -Fq "$threshold_macro" "$superseding_patch" || {
        printf 'superseding patch lacks per-type threshold: %s\n' "$threshold_macro" >&2
        exit 1
    }
done

temporary_root=$repository_directory/.local-artifacts/tmp
mkdir -p "$temporary_root"
temporary_directory=$(mktemp -d "$temporary_root/mmvq12-retain.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

replay_patch() {
    replay_name=$1
    replay_patch_path=$2
    replay_directory=$temporary_directory/$replay_name

    git --no-replace-objects clone --quiet --shared --no-checkout \
        "$source_directory" "$replay_directory"
    git --no-replace-objects -C "$replay_directory" checkout --quiet --detach \
        "$expected_base"
    actual_base=$(git --no-replace-objects -C "$replay_directory" rev-parse HEAD)
    if [ "$actual_base" != "$expected_base" ]; then
        printf 'patch base mismatch: expected %s found %s\n' \
            "$expected_base" "$actual_base" >&2
        exit 1
    fi
    git --no-replace-objects -C "$replay_directory" apply --check \
        "$replay_patch_path"
    git --no-replace-objects -C "$replay_directory" apply "$replay_patch_path"
    git --no-replace-objects -C "$replay_directory" diff --check
    git --no-replace-objects -C "$replay_directory" add -A
    git --no-replace-objects -C "$replay_directory" write-tree
}

actual_retained_tree=$(replay_patch retained "$retained_patch")
if [ "$actual_retained_tree" != "$expected_retained_tree" ]; then
    printf 'retained patch replay tree mismatch: expected %s found %s\n' \
        "$expected_retained_tree" "$actual_retained_tree" >&2
    exit 1
fi
actual_superseding_tree=$(replay_patch superseding "$superseding_patch")
if [ "$actual_superseding_tree" != "$expected_superseding_tree" ]; then
    printf 'superseding patch replay tree mismatch: expected %s found %s\n' \
        "$expected_superseding_tree" "$actual_superseding_tree" >&2
    exit 1
fi
if [ "$actual_retained_tree" = "$actual_superseding_tree" ]; then
    printf 'retained and superseding patches unexpectedly produce one tree\n' >&2
    exit 1
fi

printf 'retained_patch=%s sha256=%s\n' \
    "$(basename -- "$retained_patch")" "$actual_retained_patch_sha256"
printf 'retained_patch_base=%s replay_tree=%s\n' \
    "$expected_base" "$actual_retained_tree"
printf 'superseding_patch=%s sha256=%s replay_tree=%s\n' \
    "$(basename -- "$superseding_patch")" \
    "$actual_superseding_patch_sha256" "$actual_superseding_tree"
printf 'source_relationship=distinct mechanism=per-type-mmvq retained_ceiling=12 superseding_ceiling=16\n'
printf 'retained_patch_replay=accepted promotion=refused\n'
