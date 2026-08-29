#!/bin/sh
set -eu

# bartowski/Qwen_Qwen3.5-0.8B-GGUF publishes bf16 and no f16 model file, so the
# format RADV advertises is produced on the appliance from the pinned BF16
# source. The census reports the same 1,505,783,040 streamed bytes per token
# before and after, with 99.17% of the file's bytes moving from BF16 to F16.
#
# evidence/representation-gate-16-bit.md measures the result at 15.68 decode
# tok/s against the Q8_0 rung's 20.15, which is 1.88 times the bytes for 1.29
# times the decode.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    printf 'environment: QWEN_LLAMA_QUANTIZE QWEN_QUANTIZE_THREADS GGUF_PY_PATH\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec "$script_directory/derive-f16-artifact.sh" \
    download-qwen35-08b-bf16.sh \
    Qwen3.5-0.8B-bf16.gguf \
    Qwen3.5-0.8B-F16.gguf \
    "${1:-"${HOME:?}/models/Qwen3.5-0.8B-GGUF"}"
