#!/bin/sh
set -eu

# Choose the projector that belongs to a checkpoint, and print nothing when
# there is none.
#
# A projector encodes images into the embedding space of the checkpoint it was
# exported with, and a mismatched one of matching dimensions loads without error
# while placing image tokens where the language model does not read them, which
# answers wrongly rather than failing. Binding the search to the model's own
# directory makes the pairing structural.
#
# Publishers name the file differently. Qwen ships mmproj-F16.gguf and Ornith
# ships mmproj-Ornith-1.5-9B-BF16.gguf, so an exact filename finds one and
# leaves the other running text-only with its projector sitting beside it. The
# exact name wins where it exists, and otherwise a sole mmproj*.gguf in the
# directory is taken. Several candidates print nothing, because choosing one of
# two projectors by sort order is the mismatch this pairing prevents.

if [ "$#" -ne 1 ]; then
    printf 'usage: %s MODEL_PATH\n' "$0" >&2
    exit 2
fi

model_directory=$(dirname -- "$1")
exact_projector=$model_directory/mmproj-F16.gguf

if [ -f "$exact_projector" ]; then
    printf '%s\n' "$exact_projector"
    exit 0
fi

candidate_count=0
selected_projector=
for candidate_path in "$model_directory"/mmproj*.gguf; do
    [ -f "$candidate_path" ] || continue
    candidate_count=$((candidate_count + 1))
    selected_projector=$candidate_path
done

if [ "$candidate_count" -gt 1 ]; then
    printf 'projector=ambiguous directory=%s candidates=%s\n' \
        "$model_directory" "$candidate_count" >&2
    printf 'set QWEN_MMPROJ to choose one; running text-only\n' >&2
    exit 0
fi

[ "$candidate_count" -eq 1 ] && printf '%s\n' "$selected_projector"
exit 0
