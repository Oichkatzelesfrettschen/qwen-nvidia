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

# One grep over the whole candidate list per pattern: the tracked tree runs
# to thousands of evidence files, and a grep process per file put this gate
# past the hosted job's fifteen minutes once the authority-consistency test
# ran it once per case. grep -l lists the files that match, and a list with
# no match is the accepted case rather than a failure of the pipeline.
scan_files() {
    # scan_files PATTERN SKIP_LEGACY: the matching regular files, one per line
    for candidate in $active_files; do
        [ "$2" = yes ] && is_legacy_path "$candidate" && continue
        [ -f "$candidate" ] || continue
        printf '%s\0' "$candidate"
    done | xargs -0 -r grep -lI "$1" 2>/dev/null || :
}

apu_pattern='Raven2\|RAVEN2\|gfx902\|RADV\|radv\|amdgpu\|ROCm\|TheRock\|hipcc\|HSA_ENABLE_SDMA\|/dev/kfd'
apu_hits=$(scan_files "$apu_pattern" yes | tr '\n' ' ' | sed 's/ $//')
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
local_path_hits=$(scan_files '^/home/[a-z_][a-z0-9_-]*/\|[^A-Za-z0-9_]/home/[a-z_][a-z0-9_-]*/' no | tr '\n' ' ' | sed 's/ $//')
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

# An image profile emits only where a served admission on this device retained
# it: the row reads validator-gated rather than unguarded, its validated_evidence
# names a retained directory holding the admission's summary, its review_model
# names a registry row, and it is the one such row, since the promotion record
# evidence/image-appliance/serialized-review-admission/ promotes one tuple.
image_binding_faults=''
emitting_image_count=0
while IFS='	' read -r image_id image_policy image_evidence image_reviewer; do
    [ -n "$image_id" ] || continue
    emitting_image_count=$((emitting_image_count + 1))
    case $image_policy in
        validator-gated) ;;
        *) image_binding_faults="$image_binding_faults $image_id:policy=$image_policy" ;;
    esac
    # The evidence has to be this lane's own admission rather than any
    # retained directory holding a summary. One accepted promotion row names
    # this profile and this reviewer as whole space-separated tokens, so a
    # suffixed name and a pairing assembled from two rows both fail; the run
    # reached its own terminal accept with no refused row, so a promotion
    # cannot rest on an admission that refused after recording the ledger
    # change; and the parameters the service ran under carry the ledger row's
    # own geometry, so a row edited after its run loses the binding.
    case $image_evidence in
        evidence/*/)
            image_summary=${image_evidence}summary.tsv
            image_parameters=${image_evidence}image-parameters.json
            if [ ! -f "$image_summary" ]; then
                image_binding_faults="$image_binding_faults $image_id:evidence=$image_evidence"
            elif ! awk -F'	' -v id="$image_id" -v reviewer="review_model=$image_reviewer" '
                $1 == "image_ledger_promoted" && $2 == "accepted" {
                    names_profile = 0
                    names_reviewer = 0
                    split($3, token, " ")
                    for (index_of_token in token) {
                        if (token[index_of_token] == id) { names_profile = 1 }
                        if (token[index_of_token] == reviewer) { names_reviewer = 1 }
                    }
                    if (names_profile && names_reviewer) { found = 1 }
                }
                END { exit found ? 0 : 1 }' "$image_summary"; then
                image_binding_faults="$image_binding_faults $image_id:evidence_names_another_profile_or_review_model"
            elif ! awk -F'	' '$1 == "generation_completed" && $2 == "accepted" { generated = 1 }
                $1 == "browser_review_rendered" && $2 == "accepted" { reviewed = 1 }
                $1 == "review_serialized_after_lease_release" && $2 == "accepted" { serialized = 1 }
                END { exit (generated && reviewed && serialized) ? 0 : 1 }' "$image_summary"; then
                image_binding_faults="$image_binding_faults $image_id:evidence_lacks_a_serialized_generation_and_review"
            elif ! awk -F'	' '$1 == "admit_image_router" && $2 == "accepted" { accepted = 1 }
                $2 == "refused" { refused = 1 }
                END { exit (accepted && !refused) ? 0 : 1 }' "$image_summary"; then
                image_binding_faults="$image_binding_faults $image_id:evidence_admission_did_not_accept"
            elif ! python3 - "$image_parameters" "$image_id" <<PARAMETERS
import json, sys
path, profile = sys.argv[1], sys.argv[2]
expected = {}
for line in open("scripts/image-profiles.tsv", encoding="utf-8"):
    if line.startswith("#"):
        continue
    field = line.rstrip("\n").split("\t")
    if len(field) > 13 and field[0] == profile:
        expected = {"model_id": field[1], "placement": field[2], "width": int(field[3]),
                    "height": int(field[4]), "steps": int(field[5]), "sampler": field[6],
                    "cfg": float(field[7]), "max_steps": int(field[8]),
                    "max_dimension": int(field[9]), "timeout_s": int(field[10])}
        break
try:
    ran = json.load(open(path, encoding="utf-8")).get(profile, {})
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if expected and all(ran.get(key) == value for key, value in expected.items()) else 1)
PARAMETERS
            then
                image_binding_faults="$image_binding_faults $image_id:evidence_ran_another_geometry"
            fi
            ;;
        *) image_binding_faults="$image_binding_faults $image_id:evidence=$image_evidence" ;;
    esac
    if ! awk -F'	' -v id="$image_reviewer" '!/^#/ && $1 == id { found = 1 } END { exit found ? 0 : 1 }' scripts/models.tsv; then
        image_binding_faults="$image_binding_faults $image_id:review_model=$image_reviewer"
    fi
done <<EOF_IMAGE
$(awk -F'	' -v OFS='	' '!/^#/ && NF > 13 && $12 != "refused" { print $1, $12, $13, $14 }' scripts/image-profiles.tsv 2>/dev/null)
EOF_IMAGE
# Exactly one row emits: the promotion record promotes one tuple, and a tree
# where every row fell back to refused states a promotion this repository's
# own doctrine and evidence contradict.
if [ -z "$image_binding_faults" ] && [ "$emitting_image_count" -eq 1 ]; then
    report image_profiles_bound accepted "emitting=$emitting_image_count"
else
    report image_profiles_bound rejected "emitting=$emitting_image_count faults=${image_binding_faults:-none}"
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
