#!/bin/sh
set -eu

# Refuse a tree in which prior-host authority still speaks as current policy.
#
# This repository was derived from an appliance built on an AMD Raven2 APU over
# Mesa RADV. Its measurements, its device controls, and its driver verdicts
# belong to that machine, and a default here changes when a measurement on this
# host moves it. The gate reads the active tree for the terms that name the
# other machine's hardware, driver, and compute stack, and it admits them only
# where a path declares itself prior-host or where the mechanism they name is
# this host's own.
#
# Vulkan itself is legitimate: llama-server carries the CUDA and Vulkan backends
# in one binary and enumerates CUDA0 and Vulkan0 for the same card, so the gate
# rejects RADV and amdgpu rather than the word Vulkan. `Vulkan0` names the
# fallback device and is admitted; what is refused is a Vulkan claim resting on
# the other driver.

usage() {
    printf 'usage: %s [REPOSITORY_ROOT]\n' "$0" >&2
    exit 2
}

[ "$#" -le 1 ] || usage
repository_root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
# A linked worktree carries .git as a gitdir pointer file, so existence
# rather than directoryness identifies a repository root.
[ -e "$repository_root/.git" ] || {
    printf 'not a repository root: %s\n' "$repository_root" >&2
    exit 2
}
cd "$repository_root"

failures=0
report() {
    printf '%s=%s%s\n' "$1" "$2" "${3:+ $3}"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

# Paths that carry prior-host evidence by declaration. A file here states the
# other machine's results as history, which is the one place those terms belong.
is_legacy_path() {
    case $1 in
        evidence/legacy/* | docs/APU_UPSTREAM.md | evidence/quarantine/*) return 0 ;;
        # The gate states the terms it refuses, so it matches itself.
        scripts/check-nvidia-authority.sh) return 0 ;;
        *) return 1 ;;
    esac
}

# The active tree is what a launch reads: the scripts, the registries, the
# patches, and the root documents. Evidence outside evidence/legacy/ is included,
# because a retained record that speaks in the present tense is what a later
# reader mistakes for a current default.
active_files=$(git ls-files)

apu_pattern='Raven2\|RAVEN2\|gfx902\|RADV\|radv\|amdgpu\|ROCm\|TheRock\|hipcc\|HSA_ENABLE_SDMA\|/dev/kfd'
apu_hits=''
for candidate in $active_files; do
    is_legacy_path "$candidate" && continue
    [ -f "$candidate" ] || continue
    if grep -qI "$apu_pattern" "$candidate" 2>/dev/null; then
        apu_hits="$apu_hits $candidate"
    fi
done
if [ -z "$apu_hits" ]; then
    report apu_terms accepted
else
    report apu_terms rejected "$apu_hits"
    for candidate in $apu_hits; do
        grep -nI "$apu_pattern" "$candidate" | sed "s|^|  $candidate:|" >&2
    done
fi

# CLAUDE.md keeps local absolute paths and private hostnames out of commits, and
# ARTIFACTS.md states that Git copies carry `$HOME` in place of the home prefix.
# A term list does not see a path shape, so the home prefix is matched directly:
# a router `/v1/models` capture embeds every child's argv and preset, which is
# where an unsanitized path reaches the tree without any banned term beside it.
local_path_hits=''
for candidate in $active_files; do
    [ -f "$candidate" ] || continue
    if grep -qI '^/home/[a-z_][a-z0-9_-]*/\|[^A-Za-z0-9_]/home/[a-z_][a-z0-9_-]*/' \
        "$candidate" 2>/dev/null; then
        local_path_hits="$local_path_hits $candidate"
    fi
done
if [ -z "$local_path_hits" ]; then
    report local_paths accepted
else
    report local_paths rejected "$local_path_hits"
fi

# Every performance row the registry serves names a rate this host measured.
# scripts/models.tsv carries decode_tok_s and prefill_tok_s in fields 13 and 14,
# and a row that states one names no evidence path of its own, so the check is
# that the ledger backing them is this host's: scripts/validated-tuples.tsv
# admits a backend column, and a row on any other backend cannot support a
# depth claim here.
foreign_backend=$(awk -F'\t' '!/^#/ && NF > 13 && $13 != "cuda" { print $1 }' \
    scripts/validated-tuples.tsv 2>/dev/null || :)
if [ -z "$foreign_backend" ]; then
    report tuple_backend accepted
else
    report tuple_backend rejected "$foreign_backend"
fi

# A depth claim requires a ledger row, which scripts/check-validated-tuples.sh
# proves in full. The gate calls it rather than restating its rule.
if scripts/check-validated-tuples.sh >/dev/null 2>&1; then
    report validated_tuples accepted
else
    report validated_tuples rejected
fi

# Every image profile stays refused until an image runtime is admitted on this
# device. The lane's runtime, its build, and its standalone harness were pinned
# to the other driver and are absent here.
emitting_image=$(awk -F'\t' '!/^#/ && NF > 1 && $0 !~ /\trefused\t|\trefused$/ { print $1 }' \
    scripts/image-profiles.tsv 2>/dev/null | grep -v '^profile_id$' || :)
if [ -z "$emitting_image" ]; then
    report image_profiles_refused accepted
else
    report image_profiles_refused rejected "$emitting_image"
fi

# Every legacy record declares that it sets nothing.
legacy_readme=evidence/legacy/raven2/README.md
if [ -r "$legacy_readme" ] &&
    grep -qE '^[[:space:]]*performance_authority=none[[:space:]]*$' "$legacy_readme" &&
    grep -qE '^[[:space:]]*current_defaults_authority=none[[:space:]]*$' "$legacy_readme"; then
    report legacy_declaration accepted
else
    report legacy_declaration rejected "$legacy_readme"
fi

# The upstream remote is fetch-only where it exists. A fresh clone carries no
# such remote at all, which is the same guarantee by absence.
upstream_push=$(git remote get-url --push apu-upstream 2>/dev/null || :)
case $upstream_push in
    '')
        report upstream_push accepted absent ;;
    DISABLED_no_push)
        report upstream_push accepted disabled ;;
    *)
        report upstream_push rejected "$upstream_push" ;;
esac

if [ "$failures" -eq 0 ]; then
    printf 'check_nvidia_authority=accepted\n'
    exit 0
fi
printf 'check_nvidia_authority=rejected failures=%s\n' "$failures" >&2
exit 1
