#!/bin/sh
set -eu

if [ "$#" -gt 2 ]; then
    printf 'usage: %s [LLAMA_SOURCE] [PATCH_DIRECTORY]\n' "$0" >&2
    exit 2
fi

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
source_directory=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
patch_directory=${2:-"$repository_directory/patches"}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

if [ ! -d "$source_directory/.git" ]; then
    printf 'llama.cpp source repository is missing: %s\n' "$source_directory" >&2
    exit 1
fi

git clone --quiet --shared --no-checkout "$source_directory" \
    "$temporary_directory/llama.cpp"
git -C "$temporary_directory/llama.cpp" checkout --quiet --detach \
    "$expected_commit"
for patch_name in \
    llama-vulkan-low-priority.patch \
    llama-no-cpu-fallback.patch \
    llama-vulkan-duty-cycle.patch \
    llama-vulkan-runtime-submit-limit.patch \
    llama-vulkan-submit-trace.patch \
    llama-router-tools-proxy.patch; do
    git -C "$temporary_directory/llama.cpp" apply --check \
        "$patch_directory/$patch_name"
    git -C "$temporary_directory/llama.cpp" apply \
        "$patch_directory/$patch_name"
done
git -C "$temporary_directory/llama.cpp" diff --check

verify_source() {
    expected_sha256=$1
    relative_path=$2
    actual_sha256=$(sha256sum "$temporary_directory/llama.cpp/$relative_path" | cut -d ' ' -f 1)
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'source replay mismatch: %s expected %s found %s\n' \
            "$relative_path" "$expected_sha256" "$actual_sha256" >&2
        exit 1
    fi
    printf 'patch_replay_match=%s sha256=%s\n' "$relative_path" "$actual_sha256"
}

verify_source d81e9093b4a3d98bf5cde8dc710ec187ddbaffca84540369cec72ecd132e575c \
    ggml/src/ggml-vulkan/ggml-vulkan.cpp
verify_source 16abd2face079cad962bb722026d7418e65de67c18c1e1f954df733c1598a70a \
    ggml/src/ggml-vulkan/ggml-vulkan-pacing.h
verify_source 4b8befd927e9b0c83cfc7cfe843d2f853a9a9db7f6a55c147ffcd4129afd95f8 \
    ggml/src/ggml-vulkan/ggml-vulkan-submit-limit.h
verify_source ac957254c09afda811983801e7dd59d7e4829d40e572804ea7e23dadba521867 \
    ggml/src/ggml-vulkan/ggml-vulkan-submit-trace.h
verify_source ecc818cdce4a7265f6f932962c325a582f42b91cb2661916fa28b5a79a49d1ad \
    src/llama-context.cpp
verify_source d0d6c8725891ac4baf68fd947ab4be75cc93ba37b1e988ca1c556881a49d0abc \
    src/llama-model-loader.cpp
verify_source d2d5cb43a83c6b2b459b85f2df181a3d976efcaef351e5cbc6b418ba839390e3 \
    tools/server/server.cpp
printf 'patch_series=accepted commit=%s\n' "$expected_commit"

# A candidate patch is a backport under measurement rather than a member of the
# production series. Its stage runs after every production digest is verified
# and mutates the replay tree afterwards, so the loop above and the expected
# sums it compares against stay byte-identical whether the stage runs or not.
# QWEN_LLAMA_CANDIDATE_PATCHES=1 arms it; the printed post-apply digest is what
# a promotion would move into verify_source once its evidence lane closes.
# The order is the apply order: llama-server-vulkan-workload-lease encodes
# post-series offsets in tools/server/server-context.cpp, which no earlier
# candidate touches, so the two stay independent while the list stays ordered.
# llama-cuda-paged-kv-buffer adds a KV buffer type in the buffer section of
# ggml-cuda.cu and a proc-address entry at its registry, regions no other
# candidate writes, and takes the last position because the diagnostic stage
# below cuts its ggml-cuda.cu hunks against the tree this stage produces.
candidate_patch_names="llama-vulkan-view-alias-deps.patch llama-server-vulkan-workload-lease.patch llama-cuda-mmvq-crossover-ad104.patch llama-cuda-paged-kv-buffer.patch"
# One digest line per file the candidate stage rewrites. Retained evidence
# quotes the ggml-vulkan.cpp line, so it keeps its format and its position.
# mmq.cuh belongs in the list exactly while a candidate rewrites it, and no
# candidate does: llama-cuda-mmq-stream-k-grid and llama-cuda-mmq-fixup-pipeline
# were each its sole writer in turn and both were rejected. mmf.cu, mmq.cu, and
# mmvf.cu left the list with the census patch, whose hook lines were their only
# candidate-stage writer.
candidate_digest_paths="ggml/src/ggml-vulkan/ggml-vulkan.cpp tools/server/server-context.cpp ggml/src/ggml-cuda/mmvq.cu ggml/src/ggml-cuda/mmvq.cuh ggml/src/ggml-cuda/CMakeLists.txt ggml/src/ggml-cuda/ggml-cuda.cu src/llama-kv-cache.cpp"
if [ "${QWEN_LLAMA_CANDIDATE_PATCHES:-0}" = 1 ]; then
    for candidate_name in $candidate_patch_names; do
        git -C "$temporary_directory/llama.cpp" apply --check \
            "$patch_directory/$candidate_name"
        git -C "$temporary_directory/llama.cpp" apply \
            "$patch_directory/$candidate_name"
        git -C "$temporary_directory/llama.cpp" diff --check
        printf 'candidate_patch=%s applies=yes\n' "$candidate_name"
    done
    for candidate_digest_path in $candidate_digest_paths; do
        printf 'candidate_sha256=%s path=%s\n' \
            "$(sha256sum "$temporary_directory/llama.cpp/$candidate_digest_path" | cut -d ' ' -f 1)" \
            "$candidate_digest_path"
    done
else
    printf 'candidate_patches=not_run reason=QWEN_LLAMA_CANDIDATE_PATCHES_unset\n'
fi

# A diagnostic patch is instrumentation whose campaign has closed or whose
# output is a record rather than a serving change: it applies to a closure
# built to answer a question and to no closure this repository promotes, so it
# earns no promotion_candidate line and its digests name diagnostic closures
# alone. llama-cuda-dispatch-census counts where every quantized mat-mul
# launch goes (evidence/ada/cuda-dispatch-census/), and
# llama-cuda-graph-lifecycle records every CUDA graph decision the backend
# takes (evidence/ada/graph-lifecycle/, which closed #43 on measurement).
# Both hook ggml-cuda.cu, and the lifecycle hunks were cut against the tree the
# census produces, so the two stay ordered. The census hunks in mmvq.cu sit
# below the crossover patch's, so the stage requires the candidate stage and
# applies on top of it; QWEN_LLAMA_DIAGNOSTIC_PATCHES=1 beside
# QWEN_LLAMA_CANDIDATE_PATCHES=1 arms it.
diagnostic_patch_names="llama-cuda-dispatch-census.patch llama-cuda-graph-lifecycle.patch"
diagnostic_digest_paths="ggml/src/ggml-cuda/dispatch-census.cu ggml/src/ggml-cuda/dispatch-census.cuh ggml/src/ggml-cuda/graph-lifecycle.cu ggml/src/ggml-cuda/graph-lifecycle.cuh ggml/src/ggml-cuda/ggml-cuda.cu ggml/src/ggml-cuda/mmf.cu ggml/src/ggml-cuda/mmq.cu ggml/src/ggml-cuda/mmvf.cu ggml/src/ggml-cuda/mmvq.cu"
if [ "${QWEN_LLAMA_DIAGNOSTIC_PATCHES:-0}" = 1 ] &&
    [ "${QWEN_LLAMA_CANDIDATE_PATCHES:-0}" = 1 ]; then
    for diagnostic_name in $diagnostic_patch_names; do
        git -C "$temporary_directory/llama.cpp" apply --check \
            "$patch_directory/$diagnostic_name"
        git -C "$temporary_directory/llama.cpp" apply \
            "$patch_directory/$diagnostic_name"
        git -C "$temporary_directory/llama.cpp" diff --check
        printf 'diagnostic_patch=%s applies=yes promotion_candidate=no\n' \
            "$diagnostic_name"
    done
    for diagnostic_digest_path in $diagnostic_digest_paths; do
        printf 'diagnostic_sha256=%s path=%s\n' \
            "$(sha256sum "$temporary_directory/llama.cpp/$diagnostic_digest_path" | cut -d ' ' -f 1)" \
            "$diagnostic_digest_path"
    done
elif [ "${QWEN_LLAMA_DIAGNOSTIC_PATCHES:-0}" = 1 ]; then
    printf 'diagnostic_patches=not_run reason=QWEN_LLAMA_CANDIDATE_PATCHES_unset\n'
else
    printf 'diagnostic_patches=not_run reason=QWEN_LLAMA_DIAGNOSTIC_PATCHES_unset\n'
fi

# A rejected patch is neither a production member nor a candidate under
# measurement: its campaign closed against it, so it applies to no tree this
# repository builds and contributes no digest a promotion could move into
# verify_source. llama-cuda-mmvq-ncols-19 raises the Q8_0 MMVQ column ceiling
# to nineteen and failed the exact-token-identity gate on the 0.8B
# (evidence/ada/mmvq-q8-b17-b20/). llama-cuda-mmq-stream-k-grid makes the
# Ada stream-K tiling threshold build-configurable and failed the same gate on
# the 2B at threshold 80
# (evidence/ada/mmq-stream-k-grid/phase-c-identity/), which is why it moved out
# of the candidate list rather than staying there for a later arm: a rejected
# patch left in the candidate stack would put the next mmq.cuh candidate on top
# of arithmetic this repository already declined. Neither patch collides with
# the other's files, and both sit below the candidate stage's own hunks, so the
# tree they would apply against is the one that stage produces, and the check
# runs only where that stage ran. `apply --check` reports whether the
# diff still lands and writes nothing, so the replay tree the candidate digests
# were taken from stays as those digests found it. Setting
# QWEN_LLAMA_REJECTED_PATCHES=1 beside QWEN_LLAMA_CANDIDATE_PATCHES=1 proves the
# retained diff still applies against the pinned commit; every other setting
# prints the refusal alone.
# The reason is per patch, because a campaign closes against a candidate for
# more than one kind of reason and a shared string would misattribute them. Two
# patches changed the emitted tokens and lost the exact-identity gate; one held
# identity, passed compute-sanitizer, and moved no counter it was built to move
# (evidence/ada/mmq-fixup-pipeline/), which is a different verdict about a
# different property and steers a later reader differently.
rejected_patch_names="llama-cuda-mmvq-ncols-19.patch llama-cuda-mmq-stream-k-grid.patch llama-cuda-mmq-fixup-pipeline.patch"
for rejected_name in $rejected_patch_names; do
    case $rejected_name in
    llama-cuda-mmq-fixup-pipeline.patch) rejected_reason=no_measured_gain ;;
    *) rejected_reason=numerical_gate_failed ;;
    esac
    if [ "${QWEN_LLAMA_REJECTED_PATCHES:-0}" = 1 ] &&
        [ "${QWEN_LLAMA_CANDIDATE_PATCHES:-0}" = 1 ]; then
        git -C "$temporary_directory/llama.cpp" apply --check \
            "$patch_directory/$rejected_name"
        printf 'rejected_patch=%s applies=yes promotion=refused reason=%s\n' \
            "$rejected_name" "$rejected_reason"
    else
        printf 'rejected_patch=%s applies=not_checked promotion=refused reason=%s\n' \
            "$rejected_name" "$rejected_reason"
    fi
done
