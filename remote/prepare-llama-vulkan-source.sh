#!/bin/sh
set -eu

if [ "$#" -gt 2 ]; then
    printf 'usage: %s [BASE_SOURCE [PATCHED_SOURCE]]\n' "$0" >&2
    exit 2
fi

ionice -c 3 -p $$

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
base_source=${1:-"${HOME:?}/src/llama.cpp"}
patched_source=${2:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

if [ ! -d "$base_source/.git" ]; then
    printf 'base llama.cpp source repository is missing: %s\n' "$base_source" >&2
    exit 1
fi

if [ ! -e "$patched_source" ]; then
    git clone --local --no-hardlinks --no-checkout "$base_source" "$patched_source"
    git -C "$patched_source" checkout --quiet --detach "$expected_commit"
fi
if [ ! -d "$patched_source/.git" ]; then
    printf 'patched llama.cpp source repository is invalid: %s\n' \
        "$patched_source" >&2
    exit 1
fi

actual_commit=$(git -C "$patched_source" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
    printf 'unexpected patched source commit: expected %s, found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    exit 1
fi

source_matches() {
    expected_sha256=$1
    relative_path=$2
    [ -r "$patched_source/$relative_path" ] || return 1
    actual_sha256=$(sha256sum "$patched_source/$relative_path" | awk '{ print $1 }')
    [ "$actual_sha256" = "$expected_sha256" ]
}

if source_matches db34fbfc5ee5368ccc5999dc5a37c90dd3198ae0aff8138440cd7f5f0532eca4 \
        ggml/src/ggml-vulkan/ggml-vulkan.cpp && \
   source_matches 16abd2face079cad962bb722026d7418e65de67c18c1e1f954df733c1598a70a \
        ggml/src/ggml-vulkan/ggml-vulkan-pacing.h && \
   source_matches 4b8befd927e9b0c83cfc7cfe843d2f853a9a9db7f6a55c147ffcd4129afd95f8 \
        ggml/src/ggml-vulkan/ggml-vulkan-submit-limit.h && \
   source_matches ecc818cdce4a7265f6f932962c325a582f42b91cb2661916fa28b5a79a49d1ad \
        src/llama-context.cpp && \
   source_matches d0d6c8725891ac4baf68fd947ab4be75cc93ba37b1e988ca1c556881a49d0abc \
        src/llama-model-loader.cpp && \
   source_matches d2d5cb43a83c6b2b459b85f2df181a3d976efcaef351e5cbc6b418ba839390e3 \
        tools/server/server.cpp; then
    printf 'patched_source=already_verified path=%s commit=%s\n' \
        "$patched_source" "$actual_commit"
    exit 0
fi

apply_patches() {
    for patch_name in "$@"; do
        git -C "$patched_source" apply --check \
            "$repository_directory/patches/$patch_name"
        git -C "$patched_source" apply \
            "$repository_directory/patches/$patch_name"
    done
    git -C "$patched_source" diff --check
}

# The four-patch series left tools/server/server.cpp at its pinned upstream
# content and touched exactly five paths, so a tree carrying that series and
# nothing else is a recognized prefix of the current one: only the router
# patch is applied over it. The path set is compared whole, because a tree
# whose first five hashes match while a sixth file is modified holds an edit
# no patch in the series accounts for, and that tree still refuses.
prior_series_status=' M ggml/src/ggml-vulkan/ggml-vulkan.cpp
 M src/llama-context.cpp
 M src/llama-model-loader.cpp
?? ggml/src/ggml-vulkan/ggml-vulkan-pacing.h
?? ggml/src/ggml-vulkan/ggml-vulkan-submit-limit.h'
current_status=$(git -C "$patched_source" status --porcelain | LC_ALL=C sort)
if [ "$current_status" = "$prior_series_status" ] && \
   source_matches db34fbfc5ee5368ccc5999dc5a37c90dd3198ae0aff8138440cd7f5f0532eca4 \
        ggml/src/ggml-vulkan/ggml-vulkan.cpp && \
   source_matches 16abd2face079cad962bb722026d7418e65de67c18c1e1f954df733c1598a70a \
        ggml/src/ggml-vulkan/ggml-vulkan-pacing.h && \
   source_matches 4b8befd927e9b0c83cfc7cfe843d2f853a9a9db7f6a55c147ffcd4129afd95f8 \
        ggml/src/ggml-vulkan/ggml-vulkan-submit-limit.h && \
   source_matches ecc818cdce4a7265f6f932962c325a582f42b91cb2661916fa28b5a79a49d1ad \
        src/llama-context.cpp && \
   source_matches d0d6c8725891ac4baf68fd947ab4be75cc93ba37b1e988ca1c556881a49d0abc \
        src/llama-model-loader.cpp && \
   source_matches 2833d9d237e77a70a75736426f11432b964bc66f8e85c5751451f77444338703 \
        tools/server/server.cpp; then
    apply_patches llama-router-tools-proxy.patch
    prepared_state=upgraded
elif [ -n "$current_status" ]; then
    printf 'patched source has unrecognized changes; refusing to overwrite %s\n' \
        "$patched_source" >&2
    git -C "$patched_source" status --short >&2
    exit 1
else
    apply_patches \
        llama-vulkan-low-priority.patch \
        llama-no-cpu-fallback.patch \
        llama-vulkan-duty-cycle.patch \
        llama-vulkan-runtime-submit-limit.patch \
        llama-router-tools-proxy.patch
    prepared_state=prepared
fi

if ! source_matches db34fbfc5ee5368ccc5999dc5a37c90dd3198ae0aff8138440cd7f5f0532eca4 \
        ggml/src/ggml-vulkan/ggml-vulkan.cpp || \
   ! source_matches 16abd2face079cad962bb722026d7418e65de67c18c1e1f954df733c1598a70a \
        ggml/src/ggml-vulkan/ggml-vulkan-pacing.h || \
   ! source_matches 4b8befd927e9b0c83cfc7cfe843d2f853a9a9db7f6a55c147ffcd4129afd95f8 \
        ggml/src/ggml-vulkan/ggml-vulkan-submit-limit.h || \
   ! source_matches ecc818cdce4a7265f6f932962c325a582f42b91cb2661916fa28b5a79a49d1ad \
        src/llama-context.cpp || \
   ! source_matches d0d6c8725891ac4baf68fd947ab4be75cc93ba37b1e988ca1c556881a49d0abc \
        src/llama-model-loader.cpp || \
   ! source_matches d2d5cb43a83c6b2b459b85f2df181a3d976efcaef351e5cbc6b418ba839390e3 \
        tools/server/server.cpp; then
    printf 'patched source does not match the replayed source hashes\n' >&2
    exit 1
fi

printf 'patched_source=%s path=%s commit=%s patch_count=5\n' \
    "$prepared_state" "$patched_source" "$actual_commit"
