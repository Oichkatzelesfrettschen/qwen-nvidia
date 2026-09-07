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

# `git -C DIR` changes the working directory and honors the repository-routing
# environment all the same, so an inherited GIT_INDEX_FILE or GIT_DIR would
# aim this tool's checkout, clean, and staging at whatever they name. Pointing
# GIT_INDEX_FILE at the live source repository's index and running a
# reconstruction erased that repository's staged diff, which is the one copy of
# a candidate closure's source identity. The routing is therefore removed
# before the first git invocation; the configuration is left alone, because
# diff serialization is part of what a reconstruction has to reproduce.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX \
      GIT_INDEX_VERSION 2>/dev/null || true

# The filesystem monitor writes IPC diagnostics onto stderr that no
# reconstruction reads and that a caller's exact-output check would trip over.
#
# QWEN_RECONSTRUCT_GIT_OPTIONS carries additional `-c` settings into every
# invocation, which is how a caller asks whether a digest is a property of the
# content or of the serialization. core.abbrev, diff.context, and diff.noprefix
# each move a digest over identical content while the four diff.algorithm
# values do not, so a search for a historical digest sweeps the first three.
git_quiet="git -c core.fsmonitor=false ${QWEN_RECONSTRUCT_GIT_OPTIONS:-}"

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

# Absolute from the outset, because every git invocation below runs with `-C`
# inside the clone and a relative patch directory would resolve there instead
# of where the caller wrote it. The existence check and the apply then read one
# path rather than two.
absolute_path() {
    case $1 in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$(pwd)" "$1" ;;
    esac
}
manifest_tsv=$(absolute_path "$manifest_tsv")

# A populated work directory would leave a reconstruction reading a tree an
# earlier run left behind, so the clone target is required to be fresh.
reconstruction_clone="$work_directory/reconstruction-clone"
if [ -e "$reconstruction_clone" ]; then
    printf 'work directory already holds a reconstruction clone: %s\n' "$reconstruction_clone" >&2
    exit 2
fi
mkdir -p "$work_directory"
reconstruction_diff="$work_directory/reconstruction.diff"
reconstruction_tally="$work_directory/reconstruction.tally"

# --shared borrows the source repository's object store and writes nothing to
# it, so the clone costs no copy of a multi-gigabyte history and the live tree
# is never checked out, cleaned, or reset.
$git_quiet clone --quiet --no-checkout --shared "$source_repository" "$reconstruction_clone"
$git_quiet -C "$reconstruction_clone" checkout --quiet "$pin_commit"

actual_pin=$($git_quiet -C "$reconstruction_clone" rev-parse HEAD)
printf 'pin_commit\t%s\n' "$actual_pin"
printf 'pin_tree\t%s\n' "$($git_quiet -C "$reconstruction_clone" rev-parse 'HEAD^{tree}')"

reconstruct_one() {
    reconstruct_patch_directory=$1
    shift
    $git_quiet -C "$reconstruction_clone" checkout --quiet --force "$pin_commit"
    $git_quiet -C "$reconstruction_clone" clean --quiet -fdx
    $git_quiet -C "$reconstruction_clone" reset --quiet
    for reconstruct_patch_name in "$@"; do
        # A name is a base name and nothing else, so a manifest cannot reach
        # outside its own patch directory or name a path component of its own.
        case $reconstruct_patch_name in
            '' | */* | .. | .)
                printf 'invalid:%s' "$reconstruct_patch_name"
                return 0 ;;
        esac
        reconstruct_patch_path="$reconstruct_patch_directory/$reconstruct_patch_name.patch"
        if [ ! -f "$reconstruct_patch_path" ]; then
            printf 'absent:%s' "$reconstruct_patch_name"
            return 0
        fi
        if ! $git_quiet -C "$reconstruction_clone" apply --whitespace=nowarn \
            "$reconstruct_patch_path" 2>/dev/null; then
            printf 'refused:%s' "$reconstruct_patch_name"
            return 0
        fi
    done
    # Staging is what makes an added file appear in `git diff HEAD`, which is
    # the whole reason the builder stages the headers its Vulkan patches add.
    $git_quiet -C "$reconstruction_clone" add -A >/dev/null 2>&1
    # The diff lands in a file before it is hashed, because a pipeline reports
    # the last stage's status: `git diff | sha256sum` returns sha256sum's
    # success while git failed, and an external diff helper that exits nonzero
    # then produces the digest of no bytes -- a value a caller would read as a
    # clean tree rather than as a broken run.
    if ! $git_quiet -C "$reconstruction_clone" diff --binary HEAD -- \
        > "$reconstruction_diff" 2>/dev/null; then
        printf 'diff_failed'
        return 0
    fi
    sha256sum < "$reconstruction_diff" | cut -d ' ' -f 1
}

control_rows=0
control_failures=0
subject_rows=0
subject_matches=0

# Pathname expansion stays off for the whole manifest read. The patch list is a
# space-separated apply order and word splitting is the reading intended, while
# a token carrying `*` would otherwise select whatever the caller's directory
# happens to hold rather than the patch the manifest named.
set -f

# A row whose final line carries no terminating newline is still a row, so the
# read's failure status is accepted where it delivered content. A manifest
# ending mid-row would otherwise drop its last subject and the run would report
# `accepted` over a set smaller than the one it was given.
read_manifest_rows() {
    read_manifest_role_wanted=$1
    while IFS='	' read -r row_role row_label row_patch_directory row_expected row_patches ||
        [ -n "$row_role" ]; do
        case $row_role in
            '' | '#'*) row_role=; continue ;;
            control | subject) ;;
            *) printf 'manifest role takes control or subject: %s\n' "$row_role" >&2; exit 2 ;;
        esac
        [ "$row_role" = "$read_manifest_role_wanted" ] || { row_role=; continue; }
        row_patch_directory=$(absolute_path "$row_patch_directory")
        # shellcheck disable=SC2086
        # word splitting is the apply order; globbing is off for this read
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
        row_role=
    done < "$manifest_tsv"
    printf '%s\t%s\t%s\t%s\n' \
        "$control_rows" "$control_failures" "$subject_rows" "$subject_matches" \
        > "$reconstruction_tally"
}

# Controls run first and gate whether any subject runs at all, rather than
# gating the exit status after every subject has already published a match.
# A subject reconstructed under a broken procedure would otherwise carry a
# `match=` reading that a reader could quote out of a refused run.
read_manifest_rows control
control_rows=$(cut -f 1 "$reconstruction_tally")
control_failures=$(cut -f 2 "$reconstruction_tally")

if [ "$control_rows" -eq 0 ]; then
    printf 'controls\t0\tfailed=0\n'
    printf 'subjects\t0\tmatched=0\n'
    printf 'reconstruction=refused reason=no_control_row\n' >&2
    exit 1
fi
if [ "$control_failures" -ne 0 ]; then
    printf 'controls\t%s\tfailed=%s\n' "$control_rows" "$control_failures"
    printf 'subjects\t0\tmatched=0\n'
    printf 'reconstruction=refused reason=control_did_not_reproduce\n' >&2
    exit 1
fi

control_rows_seen=$control_rows
read_manifest_rows subject
subject_rows=$(cut -f 3 "$reconstruction_tally")
subject_matches=$(cut -f 4 "$reconstruction_tally")
control_rows=$control_rows_seen

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
