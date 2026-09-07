#!/bin/sh
# Reproduce the source_diff_sha256 a build closure recorded, from a pinned
# commit and a named patch set, and state whether each reconstruction matches
# the digest the closure carries.
#
# build-llama-cuda.sh derives that field as
# `git diff --binary HEAD -- | sha256sum` over the tree it is about to compile,
# after staging every added source file, since it refuses an untracked one. A
# reconstruction therefore checks out the pin into a scratch clone, applies the
# named patches in the caller's order, stages, and hashes the same way. The
# scratch clone is what keeps a live source tree out of the procedure: the
# candidate closure's identity exists as uncommitted working-tree bytes, and a
# checkout or clean in that tree would destroy it.
#
# Every run reconstructs its control rows before its subject rows and refuses
# the whole run where a control fails to reproduce its recorded digest. A
# control is a closure whose source is known to be reproducible, so a control
# miss names the environment -- a git version, a diff setting, a moved patch
# file -- rather than the subject, and reporting a subject miss under a broken
# procedure would turn an environment change into a provenance verdict.
#
# The manifest is a TSV of
#   role      control or subject
#   label     what the row reconstructs
#   patch_dir directory holding the named patch files
#   expected  the recorded source_diff_sha256, or - to report the digest alone
#   patches   space-separated patch base names, in apply order
set -eu

usage() {
    printf 'usage: %s SOURCE_REPOSITORY PIN_COMMIT WORK_DIRECTORY MANIFEST_TSV\n' "$0" >&2
    printf '  reconstructs each manifest row and reports match=yes|no per row\n' >&2
    printf '  refuses with status 1 where a control row fails to reproduce\n' >&2
    exit 2
}

[ $# -eq 4 ] || usage
source_repository=$1
pin_commit=$2
work_directory=$3
manifest_tsv=$4

[ -d "$source_repository" ] || { printf 'source repository is absent: %s\n' "$source_repository" >&2; exit 2; }
[ -f "$manifest_tsv" ] || { printf 'manifest is absent: %s\n' "$manifest_tsv" >&2; exit 2; }

# A populated work directory would leave a reconstruction reading a tree an
# earlier run left behind, so the clone target is required to be fresh.
reconstruction_clone="$work_directory/reconstruction-clone"
if [ -e "$reconstruction_clone" ]; then
    printf 'work directory already holds a reconstruction clone: %s\n' "$reconstruction_clone" >&2
    exit 2
fi
mkdir -p "$work_directory"

# --shared borrows the source repository's object store and writes nothing to
# it, so the clone costs no copy of a multi-gigabyte history and the live tree
# is never checked out, cleaned, or reset.
git clone --quiet --no-checkout --shared "$source_repository" "$reconstruction_clone"
git -C "$reconstruction_clone" checkout --quiet "$pin_commit"

actual_pin=$(git -C "$reconstruction_clone" rev-parse HEAD)
printf 'pin_commit\t%s\n' "$actual_pin"
printf 'pin_tree\t%s\n' "$(git -C "$reconstruction_clone" rev-parse 'HEAD^{tree}')"

reconstruct_one() {
    reconstruct_patch_directory=$1
    shift
    git -C "$reconstruction_clone" checkout --quiet --force "$pin_commit"
    git -C "$reconstruction_clone" clean --quiet -fdx
    git -C "$reconstruction_clone" reset --quiet
    for reconstruct_patch_name in "$@"; do
        reconstruct_patch_path="$reconstruct_patch_directory/$reconstruct_patch_name.patch"
        if [ ! -f "$reconstruct_patch_path" ]; then
            printf 'absent:%s' "$reconstruct_patch_name"
            return 0
        fi
        if ! git -C "$reconstruction_clone" apply --whitespace=nowarn \
            "$reconstruct_patch_path" 2>/dev/null; then
            printf 'refused:%s' "$reconstruct_patch_name"
            return 0
        fi
    done
    # Staging is what makes an added file appear in `git diff HEAD`, which is
    # the whole reason the builder stages the headers its Vulkan patches add.
    git -C "$reconstruction_clone" add -A >/dev/null 2>&1
    git -C "$reconstruction_clone" diff --binary HEAD -- | sha256sum | cut -d ' ' -f 1
}

control_rows=0
control_failures=0
subject_rows=0
subject_matches=0

while IFS='	' read -r row_role row_label row_patch_directory row_expected row_patches; do
    case $row_role in
        '' | '#'*) continue ;;
        control | subject) ;;
        *) printf 'manifest role takes control or subject: %s\n' "$row_role" >&2; exit 2 ;;
    esac
    # shellcheck disable=SC2086
    # row_patches is a space-separated apply order and word splitting is the
    # reading intended; a patch name carrying a space is refused by the schema.
    row_digest=$(reconstruct_one "$row_patch_directory" $row_patches)
    row_match=n/a
    if [ "$row_expected" != '-' ]; then
        if [ "$row_digest" = "$row_expected" ]; then row_match=yes; else row_match=no; fi
    fi
    printf 'reconstruction\trole=%s\tlabel=%s\tdigest=%s\tmatch=%s\n' \
        "$row_role" "$row_label" "$row_digest" "$row_match"
    if [ "$row_role" = control ]; then
        control_rows=$((control_rows + 1))
        [ "$row_match" = yes ] || control_failures=$((control_failures + 1))
    else
        subject_rows=$((subject_rows + 1))
        [ "$row_match" = yes ] && subject_matches=$((subject_matches + 1))
    fi
done < "$manifest_tsv"

printf 'controls\t%s\tfailed=%s\n' "$control_rows" "$control_failures"
printf 'subjects\t%s\tmatched=%s\n' "$subject_rows" "$subject_matches"

if [ "$control_rows" -eq 0 ]; then
    printf 'reconstruction=refused reason=no_control_row\n' >&2
    exit 1
fi
if [ "$control_failures" -ne 0 ]; then
    printf 'reconstruction=refused reason=control_did_not_reproduce\n' >&2
    exit 1
fi
printf 'reconstruction=accepted controls=%s subjects_matched=%s_of_%s\n' \
    "$control_rows" "$subject_matches" "$subject_rows"
