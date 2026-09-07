#!/bin/sh
# Materialize the patch sets a retained provenance manifest names and write a
# manifest whose paths this host can read.
#
# The retained manifest carries `$HOME` and `$WORK` in place of the paths its
# run used, because the tree scrubs a home prefix from every checked-in
# surface. A TSV field is read as bytes rather than expanded by a shell, so the
# retained file is a record rather than an input, and this script is what turns
# it back into one: it writes each historical patch set out of this
# repository's own history into a work directory and emits a manifest naming
# those directories.
#
# The patch sets come from `evidence/lease-coverage/source-provenance/
# patch-trees.tsv`, which names every distinct `patches/` tree by the earliest
# commit carrying it, so the materialization is a read of committed objects
# rather than a copy of whatever a working tree holds now.
set -eu

usage() {
    printf 'usage: %s WORK_DIRECTORY [OUTPUT_MANIFEST]\n' "$0" >&2
    printf '  writes the historical patch sets and a manifest naming them\n' >&2
    printf '  OUTPUT_MANIFEST defaults to WORK_DIRECTORY/provenance-manifest.tsv\n' >&2
    exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
work_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
output_manifest=${2:-"$work_directory/provenance-manifest.tsv"}

patch_tree_index="$repository_root/evidence/lease-coverage/source-provenance/patch-trees.tsv"
[ -f "$patch_tree_index" ] || {
    printf 'the patch-tree index is absent: %s\n' "$patch_tree_index" >&2
    exit 1
}

mkdir -p "$work_directory"

production_series='llama-vulkan-low-priority llama-no-cpu-fallback llama-vulkan-duty-cycle llama-vulkan-runtime-submit-limit llama-vulkan-submit-trace llama-router-tools-proxy'
# verify-llama-patch-series.sh's own candidate order
candidate_series='llama-vulkan-view-alias-deps llama-server-vulkan-workload-lease llama-cuda-mmvq-crossover-ad104'
candidate_digest=76f4b8e888cde28f354482e4fea3d91e609ce634fb9d6654608b68f496a96768
promoted_digest=0d6e3be391768d5b0aaa8854904b268fbe3867ff4e76c8cba25c201bc5038b0

# The control is the one closure whose source reproduces, so a run that cannot
# reproduce it is refused before any historical subject publishes a reading.
printf 'control\tcandidate-15bc632adf7f\t%s\t%s\t%s %s\n' \
    "$repository_root/patches" "$candidate_digest" \
    "$production_series" "$candidate_series" > "$output_manifest"
printf 'subject\tcompanion-lease-off\t%s\t-\t%s llama-vulkan-view-alias-deps llama-cuda-mmvq-crossover-ad104\n' \
    "$repository_root/patches" "$production_series" >> "$output_manifest"

materialized=0
while IFS='	' read -r patches_tree tree_commit tree_date; do
    case $patches_tree in '' | '#'*) continue ;; esac
    [ "$patches_tree" != patches_tree ] || continue
    patch_directory="$work_directory/patches-$patches_tree"
    # Every blob is written on every run, so a directory left by an earlier run
    # holding stale bytes is overwritten rather than trusted. A name the tree
    # does not carry survives that write, so the directory is compared against
    # the tree's own name list afterwards and an extra file refuses the run:
    # a manifest row naming a directory whose contents are not the recorded
    # tree reconstructs something other than the closure it claims.
    mkdir -p "$patch_directory"
    tree_names="$work_directory/.names-$patches_tree"
    git -C "$repository_root" ls-tree --name-only "$tree_commit" patches/ |
        grep '\.patch$' | sed 's|.*/||' | LC_ALL=C sort > "$tree_names"
    while IFS= read -r patch_name; do
        [ -n "$patch_name" ] || continue
        git -C "$repository_root" cat-file blob "$tree_commit:patches/$patch_name" \
            > "$patch_directory/$patch_name"
    done < "$tree_names"
    present_names="$work_directory/.present-$patches_tree"
    find "$patch_directory" -maxdepth 1 -mindepth 1 -printf '%f\n' |
        LC_ALL=C sort > "$present_names"
    if ! cmp -s "$tree_names" "$present_names"; then
        printf 'the materialized patch set differs from tree %s: %s\n' \
            "$patches_tree" "$patch_directory" >&2
        printf 'unexpected entries:\n' >&2
        LC_ALL=C comm -13 "$tree_names" "$present_names" >&2
        exit 1
    fi
    materialized=$((materialized + 1))
    # Every subset of the three candidate patches, applied in the fixed order.
    for subset_mask in 0 1 2 3 4 5 6 7; do
        subset=''
        subset_index=0
        for candidate_name in $candidate_series; do
            subset_index=$((subset_index + 1))
            if [ $(( (subset_mask >> (subset_index - 1)) & 1 )) -eq 1 ]; then
                subset="$subset $candidate_name"
            fi
        done
        printf 'subject\tpromoted-%s-%s-m%s\t%s\t%s\t%s%s\n' \
            "$tree_date" "$(printf '%s' "$tree_commit" | cut -c1-8)" "$subset_mask" \
            "$patch_directory" "$promoted_digest" "$production_series" "$subset" \
            >> "$output_manifest"
    done
done < "$patch_tree_index"

printf 'patch_sets_materialized\t%s\n' "$materialized"
printf 'manifest\t%s\n' "$output_manifest"
printf 'manifest_rows\t%s\n' "$(wc -l < "$output_manifest" | tr -d ' ')"
