#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

if [ "$#" -gt 2 ]; then
    printf 'usage: %s [VARIANT|all [DESTINATION_DIRECTORY]]\n' "$0" >&2
    exit 2
fi

selected_variant=${1:-all}
destination_directory=${2:-"${HOME:?}/models/Qwen3.8-27B-GGUF"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
manifest_path=$script_directory/../benchmarks/models/qwen38-27b-files.tsv
source_revision=4ca720788d1e01f1bff70c033e0d0028fd02e502
source_base=https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/$source_revision

if [ ! -r "$manifest_path" ]; then
    printf 'model manifest is unavailable: %s\n' "$manifest_path" >&2
    exit 1
fi
case $selected_variant in
    all | UD-Q2_K_XL | UD-IQ3_XXS | UD-IQ3_S | UD-IQ4_XS) ;;
    *)
        printf 'unknown Qwen3.8-27B variant: %s\n' "$selected_variant" >&2
        exit 2
        ;;
esac

umask 077
mkdir -p "$destination_directory"
matched_variants=0
while IFS="$(printf '\t')" read -r variant filename expected_bytes expected_sha256; do
    if [ "$variant" = variant ]; then
        continue
    fi
    if [ "$selected_variant" != all ] && [ "$selected_variant" != "$variant" ]; then
        continue
    fi
    matched_variants=$((matched_variants + 1))
    final_path=$destination_directory/$filename
    partial_path=$final_path.part

    if [ -f "$final_path" ]; then
        actual_bytes=$(wc -c <"$final_path")
        actual_sha256=$(sha256sum "$final_path" | awk '{ print $1 }')
        if [ "$actual_bytes" = "$expected_bytes" ] && \
           [ "$actual_sha256" = "$expected_sha256" ]; then
            printf 'model_verified variant=%s bytes=%s sha256=%s path=%s\n' \
                "$variant" "$actual_bytes" "$actual_sha256" "$final_path"
            continue
        fi
        printf 'existing final model fails manifest verification: %s\n' \
            "$final_path" >&2
        exit 1
    fi

    printf 'download_start variant=%s revision=%s expected_bytes=%s\n' \
        "$variant" "$source_revision" "$expected_bytes"
    curl --fail --location --retry 5 --retry-all-errors --continue-at - \
        --output "$partial_path" "$source_base/$filename?download=true"
    actual_bytes=$(wc -c <"$partial_path")
    if [ "$actual_bytes" != "$expected_bytes" ]; then
        printf 'byte-count mismatch for %s: expected %s, got %s\n' \
            "$variant" "$expected_bytes" "$actual_bytes" >&2
        exit 1
    fi
    actual_sha256=$(sha256sum "$partial_path" | awk '{ print $1 }')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'SHA-256 mismatch for %s\n' "$variant" >&2
        exit 1
    fi
    mv "$partial_path" "$final_path"
    printf 'model_verified variant=%s bytes=%s sha256=%s path=%s\n' \
        "$variant" "$actual_bytes" "$actual_sha256" "$final_path"
done <"$manifest_path"

if [ "$matched_variants" -eq 0 ]; then
    printf 'manifest contains no selected model: %s\n' "$selected_variant" >&2
    exit 1
fi
