#!/bin/sh
set -eu

# Compose the trace-capable source tree and build it as its own arm.
#
# `remote/prepare-llama-vulkan-source.sh` prepares the serving tree from five
# patches -- low priority, no CPU fallback, duty cycle, runtime submit limit,
# and the router tools proxy -- and reports `patch_count=5`. The submission
# trace is the sixth patch and it stays off that tree, so the production binary
# carries no trace ring and the diagnostic binary is a separate artifact rather
# than a mode of the serving one.
#
# The trace tree is the production series plus
# `patches/llama-vulkan-submit-trace.patch`, applied in the order
# `remote/verify-llama-patch-series.sh` replays them, which is what makes the
# resulting file digests the ones that verifier already records. A tree whose
# `tools/server/server.cpp` still carries the pre-router-tools content is a
# tree from before that patch and it fails the digest gate here rather than
# producing a binary a campaign would then have to distrust.
#
# The build itself runs through `remote/build-llama-preset.sh`, so the trace
# arm gets the production preset's flags, its output-timestamp proof, and its
# artifact manifest with the full load closure.

usage() {
    printf 'usage: %s [BASE_SOURCE [TRACE_SOURCE]]\n' "$0" >&2
    printf '\nBASE_SOURCE supplies the pinned upstream commit and defaults to\n' >&2
    printf 'src/llama.cpp under the home directory; TRACE_SOURCE receives the\n' >&2
    printf 'six patches and defaults to src/llama.cpp-qwen-nvidia-trace there.\n' >&2
    printf '\nenvironment:\n' >&2
    printf '  QWEN_TRACE_PREPARE_ONLY=1  compose the source and stop\n' >&2
    printf '  QWEN_BUILD_JOBS            forwarded to build-llama-preset.sh\n' >&2
    exit 2
}

[ "$#" -le 2 ] || usage
case ${1:-} in
    -h | --help) usage ;;
esac

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
base_source=${1:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
trace_source=${2:-"${HOME:?}/src/llama.cpp-qwen-nvidia-trace"}
expected_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0
trace_preset=raven2-vulkan-production

# The digests the six-patch replay produces, which is the set
# remote/verify-llama-patch-series.sh records.
trace_ggml_vulkan_sha256=d81e9093b4a3d98bf5cde8dc710ec187ddbaffca84540369cec72ecd132e575c
trace_pacing_sha256=16abd2face079cad962bb722026d7418e65de67c18c1e1f954df733c1598a70a
trace_submit_limit_sha256=4b8befd927e9b0c83cfc7cfe843d2f853a9a9db7f6a55c147ffcd4129afd95f8
trace_submit_trace_sha256=ac957254c09afda811983801e7dd59d7e4829d40e572804ea7e23dadba521867
trace_llama_context_sha256=ecc818cdce4a7265f6f932962c325a582f42b91cb2661916fa28b5a79a49d1ad
trace_model_loader_sha256=d0d6c8725891ac4baf68fd947ab4be75cc93ba37b1e988ca1c556881a49d0abc
trace_server_sha256=d2d5cb43a83c6b2b459b85f2df181a3d976efcaef351e5cbc6b418ba839390e3
# tools/server/server.cpp before the router tools proxy patch. Naming it lets
# the refusal say which patch a stale tree is missing.
pre_router_server_sha256=2833d9d237e77a70a75736426f11432b964bc66f8e85c5751451f77444338703

if [ ! -d "$base_source/.git" ]; then
    printf 'base llama.cpp source repository is missing: %s\n' "$base_source" >&2
    exit 1
fi

if [ ! -e "$trace_source" ]; then
    git clone --local --no-hardlinks --no-checkout "$base_source" "$trace_source"
    git -C "$trace_source" checkout --quiet --detach "$expected_commit"
fi
if [ ! -d "$trace_source/.git" ]; then
    printf 'trace source repository is invalid: %s\n' "$trace_source" >&2
    exit 1
fi
actual_commit=$(git -C "$trace_source" rev-parse HEAD)
if [ "$actual_commit" != "$expected_commit" ]; then
    printf 'unexpected trace source commit: expected %s, found %s\n' \
        "$expected_commit" "$actual_commit" >&2
    exit 1
fi

source_matches() {
    expected_sha256=$1
    relative_path=$2
    [ -r "$trace_source/$relative_path" ] || return 1
    actual_sha256=$(sha256sum "$trace_source/$relative_path" | awk '{ print $1 }')
    [ "$actual_sha256" = "$expected_sha256" ]
}

trace_series_matches() {
    source_matches "$trace_ggml_vulkan_sha256" \
        ggml/src/ggml-vulkan/ggml-vulkan.cpp &&
    source_matches "$trace_pacing_sha256" \
        ggml/src/ggml-vulkan/ggml-vulkan-pacing.h &&
    source_matches "$trace_submit_limit_sha256" \
        ggml/src/ggml-vulkan/ggml-vulkan-submit-limit.h &&
    source_matches "$trace_submit_trace_sha256" \
        ggml/src/ggml-vulkan/ggml-vulkan-submit-trace.h &&
    source_matches "$trace_llama_context_sha256" src/llama-context.cpp &&
    source_matches "$trace_model_loader_sha256" src/llama-model-loader.cpp &&
    source_matches "$trace_server_sha256" tools/server/server.cpp
}

if trace_series_matches; then
    prepared_state=already_verified
else
    current_status=$(git -C "$trace_source" status --porcelain)
    if [ -n "$current_status" ]; then
        if source_matches "$pre_router_server_sha256" tools/server/server.cpp; then
            printf 'trace source predates llama-router-tools-proxy.patch; use a fresh TRACE_SOURCE\n' >&2
        else
            printf 'trace source has unrecognized changes; refusing to overwrite %s\n' \
                "$trace_source" >&2
        fi
        git -C "$trace_source" status --short >&2
        exit 1
    fi
    for patch_name in \
        llama-vulkan-low-priority.patch \
        llama-no-cpu-fallback.patch \
        llama-vulkan-duty-cycle.patch \
        llama-vulkan-runtime-submit-limit.patch \
        llama-vulkan-submit-trace.patch \
        llama-router-tools-proxy.patch; do
        git -C "$trace_source" apply --check \
            "$repository_directory/patches/$patch_name"
        git -C "$trace_source" apply \
            "$repository_directory/patches/$patch_name"
    done
    git -C "$trace_source" diff --check
    prepared_state=prepared
fi

if ! trace_series_matches; then
    printf 'trace source does not match the replayed six-patch digests\n' >&2
    exit 1
fi

printf 'trace_source=%s path=%s commit=%s patch_count=6\n' \
    "$prepared_state" "$trace_source" "$actual_commit"

if [ "${QWEN_TRACE_PREPARE_ONLY:-0}" = 1 ]; then
    printf 'trace_build=skipped reason=prepare-only\n'
    exit 0
fi

"$script_directory/build-llama-preset.sh" "$trace_preset" "$trace_source"
printf 'trace_build=accepted directory=%s\n' \
    "$trace_source/build-$trace_preset"
