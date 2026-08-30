#!/bin/sh
set -eu

# empero-ai/Qwen3.8-2B-Distill-GGUF publishes BF16 and no F16 model file, so the
# 2B arm of evidence/representation-gate-16-bit.md rests on an artifact this
# tree produces rather than fetches. That arm measures 4.96 decode tok/s against
# the Q4_K_M control's 10.02, which is the 0.496 ratio the representation gate
# records, so the artifact behind it needs a retained derivation path rather
# than the BF16 digest alone. The census reports the same 3,764,747,520 streamed
# bytes per token before and after, with 99.66% of the file's bytes moving from
# BF16 to F16.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [DESTINATION_DIRECTORY]\n' "$0" >&2
    printf 'environment: QWEN_LLAMA_QUANTIZE QWEN_QUANTIZE_THREADS GGUF_PY_PATH\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec "$script_directory/derive-f16-artifact.sh" \
    download-qwen38-2b-distill-bf16.sh \
    Qwen3.8-2B-BF16.gguf \
    Qwen3.8-2B-F16.gguf \
    "${1:-"${HOME:?}/models/Qwen3.8-2B-Distill-GGUF"}"
