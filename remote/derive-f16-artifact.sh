#!/bin/sh
set -eu

# Produce an F16 GGUF from a publisher's BF16 artifact on the appliance.
#
# RADV on Raven2 reports shaderFloat16 true and names no bfloat16 extension, so
# F16 is the 16-bit format the device advertises, and both publishers of this
# tree's small checkpoints ship BF16 as their only 16-bit artifact.
# llama-quantize accepts F16 as type 1 and rewrites the value type in place.
#
# A derived artifact carries no pinned digest, because the bytes depend on the
# converter rather than on a publisher's revision. Its identity therefore rests
# on two properties this script checks against the just-verified source: the
# streamed byte count per token is unchanged, since the value type is the only
# thing the conversion may change, and no tensor remains BF16. Both checks run
# on an artifact found already in place as well as on one derived here, because
# a stale, truncated, or hand-converted file under the artifact name would
# otherwise be served and benchmarked on its existence alone.

renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true

if [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; then
    printf 'usage: %s FETCH_SCRIPT SOURCE_NAME ARTIFACT_NAME [DESTINATION_DIRECTORY]\n' "$0" >&2
    printf 'environment: QWEN_LLAMA_QUANTIZE QWEN_QUANTIZE_THREADS GGUF_PY_PATH\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fetch_script=$script_directory/$1
source_name=$2
artifact_name=$3
destination_directory=${4:?destination directory is required}
source_path=$destination_directory/$source_name
artifact_path=$destination_directory/$artifact_name
partial_path=$artifact_path.part
quantize=${QWEN_LLAMA_QUANTIZE:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-quantize"}
quantize_threads=${QWEN_QUANTIZE_THREADS:-2}
census=${QWEN_GGUF_CENSUS:-$script_directory/gguf-tensor-census.py}

if [ ! -x "$fetch_script" ]; then
    printf 'fetch script is not executable: %s\n' "$fetch_script" >&2
    exit 2
fi
if [ ! -x "$quantize" ]; then
    printf 'llama-quantize is absent: %s\n' "$quantize" >&2
    printf 'remote/build-llama-vulkan.sh builds it\n' >&2
    exit 1
fi

# Report the streamed bytes per token and the 16-bit type mix of one file. The
# census excludes the multi-token-prediction block an ordinary load skips, which
# is the figure a conversion must leave unchanged.
census_facts() {
    GGUF_PY_PATH=${GGUF_PY_PATH:-"${HOME:?}/src/llama.cpp-qwen-nvidia/gguf-py"} \
        "$census" --json "$1" | python3 -c '
import json
import sys

record = json.load(sys.stdin)[0]
by_type = record["summary"]["by_type"]
streamed = sum(
    count for family, count in record["summary"]["by_family"].items()
    if family != "mtp")
print(streamed)
print(by_type.get("BF16", 0))
print(by_type.get("F16", 0))
'
}

# The source is the fetch script's verified artifact, so the derivation rests on
# a pinned revision and digest rather than on whatever file holds the name.
"$fetch_script" "$destination_directory"

source_facts=$(census_facts "$source_path")
source_streamed=$(printf '%s\n' "$source_facts" | sed -n 1p)

validate_artifact() {
    validate_path=$1
    validate_state=$2
    validate_facts=$(census_facts "$validate_path")
    validate_streamed=$(printf '%s\n' "$validate_facts" | sed -n 1p)
    validate_bf16=$(printf '%s\n' "$validate_facts" | sed -n 2p)
    validate_f16=$(printf '%s\n' "$validate_facts" | sed -n 3p)
    if [ "$validate_streamed" != "$source_streamed" ]; then
        printf '%s artifact streams %s bytes against the source %s\n' \
            "$validate_state" "$validate_streamed" "$source_streamed" >&2
        return 1
    fi
    if [ "$validate_bf16" != "0" ]; then
        printf '%s artifact still holds %s bytes of BF16 tensors\n' \
            "$validate_state" "$validate_bf16" >&2
        return 1
    fi
    if [ "$validate_f16" = "0" ]; then
        printf '%s artifact holds no F16 tensors\n' "$validate_state" >&2
        return 1
    fi
    derived_streamed=$validate_streamed
    return 0
}

if [ -f "$artifact_path" ]; then
    if validate_artifact "$artifact_path" retained; then
        printf 'artifact_status=already_derived path=%s bytes=%s streamed_bytes_per_token=%s source=%s\n' \
            "$artifact_path" "$(wc -c <"$artifact_path")" "$derived_streamed" \
            "$source_name"
        exit 0
    fi
    printf 'the retained artifact fails validation and is not replaced: %s\n' \
        "$artifact_path" >&2
    printf 'remove it to derive a new one\n' >&2
    exit 1
fi

rm -f "$partial_path"
nice -n 19 "$quantize" "$source_path" "$partial_path" F16 "$quantize_threads"

if ! validate_artifact "$partial_path" derived; then
    rm -f "$partial_path"
    exit 1
fi

mv "$partial_path" "$artifact_path"
printf 'artifact_status=derived path=%s bytes=%s streamed_bytes_per_token=%s source=%s\n' \
    "$artifact_path" "$(wc -c <"$artifact_path")" "$derived_streamed" \
    "$source_name"
