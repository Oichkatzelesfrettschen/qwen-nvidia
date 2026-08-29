#!/bin/sh
# Prove the five-to-six-patch transition of prepare-llama-vulkan-source.sh:
# a tree prepared by the four-patch series upgrades by the router patch alone,
# the upgraded tree is then reported already verified, and a tree carrying an
# unrelated edit refuses. The script pins commit f280b269 of llama.cpp, so the
# fixture is a local clone of a checkout holding that commit; a workstation
# without one reports the test as not run rather than as passed.
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
base_source=${QWEN_LLAMA_BASE_SOURCE:-"${HOME:?}/src/llama.cpp"}
pinned_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

if [ ! -d "$base_source/.git" ] || \
   ! git -C "$base_source" cat-file -e "$pinned_commit^{commit}" 2>/dev/null; then
    printf 'prepare_llama_vulkan_source=not_run reason=no checkout of %s at %s\n' \
        "$pinned_commit" "$base_source"
    exit 0
fi

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/qwen-prepare-source.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT INT TERM
patched_source=$fixture_root/llama.cpp-qwen-nvidia

expect_output() {
    expected=$1
    shift
    output=$("$@" 2>&1) || {
        printf 'command failed: %s\n%s\n' "$*" "$output" >&2
        exit 1
    }
    case $output in
        *"$expected"*) ;;
        *)
            printf 'expected %s in:\n%s\n' "$expected" "$output" >&2
            exit 1
            ;;
    esac
}

# Stage one: the tree a workstation prepared under the prior revision, which
# applied four patches and left tools/server/server.cpp upstream.
git clone --quiet --local --no-hardlinks --no-checkout "$base_source" "$patched_source"
git -C "$patched_source" checkout --quiet --detach "$pinned_commit"
for patch_name in \
    llama-vulkan-low-priority.patch \
    llama-no-cpu-fallback.patch \
    llama-vulkan-duty-cycle.patch \
    llama-vulkan-runtime-submit-limit.patch; do
    git -C "$patched_source" apply "$repository_directory/patches/$patch_name"
done

expect_output 'patched_source=upgraded' \
    sh "$script_directory/prepare-llama-vulkan-source.sh" "$base_source" "$patched_source"
expect_output 'patched_source=already_verified' \
    sh "$script_directory/prepare-llama-vulkan-source.sh" "$base_source" "$patched_source"

# Stage two: an unrelated edit beside the recognized prefix still refuses.
git -C "$patched_source" checkout --quiet -- tools/server/server.cpp
printf '\n' >> "$patched_source/README.md"
if output=$(sh "$script_directory/prepare-llama-vulkan-source.sh" \
        "$base_source" "$patched_source" 2>&1); then
    printf 'a tree with an unrecognized edit was accepted:\n%s\n' "$output" >&2
    exit 1
fi
case $output in
    *'unrecognized changes'*) ;;
    *)
        printf 'the refusal names the wrong reason:\n%s\n' "$output" >&2
        exit 1
        ;;
esac

# Stage three: a clean pinned checkout receives the whole series.
rm -rf "$patched_source"
git clone --quiet --local --no-hardlinks --no-checkout "$base_source" "$patched_source"
git -C "$patched_source" checkout --quiet --detach "$pinned_commit"
expect_output 'patched_source=prepared' \
    sh "$script_directory/prepare-llama-vulkan-source.sh" "$base_source" "$patched_source"

printf 'prepare_llama_vulkan_source=accepted transitions=upgraded,already_verified,refused,prepared\n'
