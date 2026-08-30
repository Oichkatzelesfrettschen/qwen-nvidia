#!/bin/sh
set -eu

# The tier tree decides what the model picker offers, so a defect here exposes a
# checkpoint the evidence says to keep out of reach rather than producing a
# visible error. Every check below runs against a fabricated model root so it
# needs no weights and no device.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
registry=$script_directory/models.tsv
quarantine=$script_directory/quarantine.tsv
speculation_profiles=$script_directory/speculation-profiles.tsv
builder=$script_directory/build-router-presets.sh
reader=$script_directory/model-registry.sh
failures=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

# A fabricated model root carrying an empty file at every registry path. The
# builder tests for a regular file rather than reading it, so an empty file
# exercises the whole reconciliation without a single weight on disk.
model_root=$work/models
awk -F'\t' '!/^#/ && NF { print $3 }' "$registry" | while read -r model_file; do
    mkdir -p "$model_root/$(dirname -- "$model_file")"
    : >"$model_root/$model_file"
done

presets=$work/router-presets.ini
build() {
    QWEN_MODEL_ROOT=$model_root \
    QWEN_QUARANTINE_REGISTRY=$quarantine \
    QWEN_QUARANTINE_REASONS=$repository_root/evidence/quarantine \
        "$builder" "$presets"
}

if build >"$work/build.log" 2>"$work/build.err"; then
    report reconciliation accepted
else
    report reconciliation rejected
    cat "$work/build.err" >&2
fi

section_ids=$(awk -F'[][]' '/^\[/ { print $2 }' "$presets")

# Every tier value in the registry must be one the readers handle. A sixth tier
# reaches the builder as an unclaimed row rather than as an error.
tier_vocabulary=0
for tier in $(awk -F'\t' '!/^#/ && NF { print $16 }' "$registry" | sort -u); do
    "$reader" validate-tier "$tier" ||
        { printf 'tier outside the vocabulary: %s\n' "$tier" >&2
          tier_vocabulary=$((tier_vocabulary + 1)); }
done
if [ "$tier_vocabulary" -eq 0 ]; then
    report tier_vocabulary accepted
else
    report tier_vocabulary rejected
fi

# Speculation is a per-section setting, so the emitted geometry rather than the
# registry field is what proves the policy reached the child. A section whose
# row names a profile carries that profile's spec_type; a section whose row
# names `off` carries no speculation key at all, since an empty
# `LLAMA_ARG_SPEC_TYPE` reaches llama-server as an argument rather than as an
# absence.
speculation_emission_failures=0
for spec_row in $(awk -F'\t' '!/^#/ && NF >= 25 { print $1 ":" $24 }' "$registry"); do
    spec_section=${spec_row%%:*}
    spec_profile=${spec_row##*:}
    case $section_ids in
        *"$spec_section"*) ;;
        *) continue ;;
    esac
    emitted_spec=$(awk -v want="[$spec_section]" '
        $0 == want { inside = 1; next }
        /^\[/ { inside = 0 }
        inside && /^LLAMA_ARG_SPEC_TYPE/ { print $NF }
    ' "$presets")
    if [ "$spec_profile" = off ]; then
        [ -z "$emitted_spec" ] && continue
        printf 'section %s names speculation profile off and emits spec type %s\n' \
            "$spec_section" "$emitted_spec" >&2
        speculation_emission_failures=$((speculation_emission_failures + 1))
        continue
    fi
    expected_spec=$(awk -F'\t' -v id="$spec_profile" \
        '!/^#/ && $1 == id { print $2 }' "$speculation_profiles")
    if [ "$emitted_spec" != "$expected_spec" ] || [ -z "$emitted_spec" ]; then
        printf 'section %s names profile %s expecting spec type %s and emits %s\n' \
            "$spec_section" "$spec_profile" "$expected_spec" "$emitted_spec" >&2
        speculation_emission_failures=$((speculation_emission_failures + 1))
    fi
done
if [ "$speculation_emission_failures" -eq 0 ]; then
    report speculation_emission accepted
else
    report speculation_emission rejected
fi

# A quarantined subject reaching production/ or candidates/ is the failure the
# tier tree exists to prevent, and it is checked against the link tree rather
# than against the registry, because the link is what the router scans.
quarantine_leak=0
for subject in $("$reader" quarantine-subjects); do
    model_file=$("$reader" id "$subject" model_file)
    model_directory=$(basename -- "$(dirname -- "$model_file")")
    for open_tier in production candidates; do
        if [ -e "$model_root/$open_tier/$model_directory" ]; then
            printf 'quarantined subject %s is linked into %s\n' \
                "$subject" "$open_tier" >&2
            quarantine_leak=$((quarantine_leak + 1))
        fi
    done
    case " $section_ids " in
        *" $subject "*)
            printf 'quarantined subject %s carries a preset section\n' \
                "$subject" >&2
            quarantine_leak=$((quarantine_leak + 1))
            ;;
    esac
done
if [ "$quarantine_leak" -eq 0 ]; then
    report quarantine_excluded accepted
else
    report quarantine_excluded rejected
fi

# One checkpoint directory in two tiers means one of the two claims is stale,
# and the picker would show whichever the router scanned first.
duplicate_tier=$(
    for open_tier in production candidates quarantine; do
        [ -d "$model_root/$open_tier" ] || continue
        for entry in "$model_root/$open_tier"/*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            basename -- "$entry"
        done
    done | sort | uniq -d
)
if [ -z "$duplicate_tier" ]; then
    report single_tier accepted
else
    report single_tier rejected
    printf 'checkpoint appears in more than one tier: %s\n' "$duplicate_tier" >&2
fi

# A quarantine without a reason record is an unexplained exclusion, and a reason
# record naming evidence that is absent is an unsupported one.
reason_failures=0
# The builder deploys a record under the row's own id rather than under its
# subject, because one subject can carry several rows and a by-subject name
# would let the second overwrite the first.
for reason_id in $(awk -F'\t' '!/^#/ && NF { print $1 }' "$quarantine"); do
    reason_record=$repository_root/evidence/quarantine/$reason_id.md
    if [ ! -r "$reason_record" ]; then
        printf 'quarantine %s carries no reason record\n' "$reason_id" >&2
        reason_failures=$((reason_failures + 1))
    fi
    if [ ! -r "$model_root/quarantine-reasons/$reason_id.md" ]; then
        printf 'quarantine %s has no deployed reason record\n' "$reason_id" >&2
        reason_failures=$((reason_failures + 1))
    fi
done
for subject in $("$reader" quarantine-subjects); do
    model_file=$("$reader" id "$subject" model_file)
    model_directory=$(basename -- "$(dirname -- "$model_file")")
    if [ ! -L "$model_root/quarantine/$model_directory" ]; then
        printf 'quarantined subject %s is not linked into quarantine/\n' \
            "$subject" >&2
        reason_failures=$((reason_failures + 1))
    fi
done
if [ "$reason_failures" -eq 0 ]; then
    report quarantine_reasons accepted
else
    report quarantine_reasons rejected
fi

# Both evidence pointers of every quarantine row resolve inside the tree, so a
# quarantine is never carried by prose that names a file nobody retained. The
# check is unconditional on both machines: the appliance is where a quarantine
# is enforced, and a reason record there that cites a measurement that host
# cannot show is the same defect as one in the repository.
evidence_failures=0
while IFS='	' read -r quarantine_id _scope _subject _class _depth _batch \
    _ubatch _ctk _ctv _fa first_evidence latest_evidence _record _runtime_mode; do
    case $quarantine_id in '#'* | '') continue ;; esac
    for evidence_path in "$first_evidence" "$latest_evidence"; do
        [ "$evidence_path" = - ] && continue
        if [ ! -r "$repository_root/$evidence_path" ]; then
            printf 'quarantine %s names absent evidence: %s\n' \
                "$quarantine_id" "$evidence_path" >&2
            evidence_failures=$((evidence_failures + 1))
        fi
    done
done <"$quarantine"
if [ "$evidence_failures" -eq 0 ]; then
    report evidence_paths accepted
else
    report evidence_paths rejected
fi

# llama-server refuses a preset key it does not recognise and fails the whole
# router at startup, so an invented name reaches the appliance as a dead service
# rather than as an ignored line. The vocabulary is the set_env() names in
# common/arg.cpp at the pinned build; LLAMA_ARG_BATCH_SIZE is not among them and
# LLAMA_ARG_BATCH is, which is the failure this check exists for.
preset_key_failures=0
for preset_key in $(sed -n 's/^\(LLAMA_ARG_[A-Z_]*\) *=.*/\1/p' "$presets" |
    sort -u); do
    case $preset_key in
        LLAMA_ARG_MODEL | LLAMA_ARG_ALIAS | LLAMA_ARG_TAGS | \
        LLAMA_ARG_CTX_SIZE | LLAMA_ARG_CACHE_TYPE_K | LLAMA_ARG_CACHE_TYPE_V | \
        LLAMA_ARG_FLASH_ATTN | LLAMA_ARG_BATCH | LLAMA_ARG_UBATCH | \
        LLAMA_ARG_MMPROJ | LLAMA_ARG_SPEC_TYPE | LLAMA_ARG_SPEC_DRAFT_N_MAX | \
        LLAMA_ARG_SPEC_DRAFT_P_MIN | LLAMA_ARG_SPEC_BACKEND_SAMPLING) ;;
        *)
            printf 'preset key is outside the llama-server vocabulary: %s\n' \
                "$preset_key" >&2
            preset_key_failures=$((preset_key_failures + 1))
            ;;
    esac
done
if [ "$preset_key_failures" -eq 0 ]; then
    report preset_key_vocabulary accepted
else
    report preset_key_vocabulary rejected
fi

# Every section carries all six per-checkpoint keys. The router argv omits them
# so the preset decides, and a key absent from a section falls through to the
# llama.cpp defaults, where batch 2048 and ubatch 512 is the quarantined
# geometry. An incomplete section is therefore how a quarantined tuple would
# reach a child without any row asking for it.
section_completeness=0
for section in $section_ids; do
    for required_key in LLAMA_ARG_CTX_SIZE LLAMA_ARG_CACHE_TYPE_K \
        LLAMA_ARG_CACHE_TYPE_V LLAMA_ARG_FLASH_ATTN LLAMA_ARG_BATCH \
        LLAMA_ARG_UBATCH; do
        if ! awk -F'[][]' -v want="$section" -v key="$required_key" '
            /^\[/ { in_section = ($2 == want); next }
            in_section && index($0, key) == 1 { found = 1 }
            END { exit found ? 0 : 1 }' "$presets"; then
            printf 'preset section %s omits %s\n' "$section" "$required_key" >&2
            section_completeness=$((section_completeness + 1))
        fi
    done
done
# A preset key grants what a CLI flag grants, so the tool surface is refused on
# this path too. LLAMA_ARG_TOOLS in one section would put exec_shell_command and
# write_file behind that section's child while every other section stayed clean.
if grep -q '^LLAMA_ARG_TOOLS' "$presets"; then
    report tool_grant_absent rejected
else
    report tool_grant_absent accepted
fi

if [ "$section_completeness" -eq 0 ]; then
    report section_completeness accepted
else
    report section_completeness rejected
fi

# A profile quarantine removes one tuple, so the check is against the geometry
# each section serves at rather than against the section's presence. The tuple
# is all six keys the child takes from its section, matching the seven fields
# qwen-capacity-policy.sh compares on the single-model path: a future safe tuple
# that keeps 16384/2048/512 and moves to a different cache representation or
# turns Flash Attention off is a different tuple, and a check reading three
# fields would call it quarantined.
section_key() {
    awk -F'[][]' -v want="$2" -v key="^$3 " '
        /^\[/ { in_section = ($2 == want); next }
        in_section && $0 ~ key { print $0 }' "$1" | sed 's/.*= *//'
}

# The speculation keys a section carries follow the row's own
# speculation_profile selection rather than a global setting: an mtp1 row
# carries exactly one LLAMA_ARG_SPEC_TYPE of draft-mtp and exactly one
# LLAMA_ARG_SPEC_DRAFT_N_MAX of 1, and an off row carries neither key.
speculation_key_failures=$work/speculation-key-failures
: >"$speculation_key_failures"
awk -F'\t' '!/^#/ && NF { print $1, $23, $24 }' "$registry" |
    while read -r subject _mtp_layers speculation_profile; do
        [ -n "$subject" ] || continue
        case " $section_ids " in
            *" $subject "*) ;;
            *) continue ;;
        esac
        spec_type_lines=$(section_key "$presets" "$subject" LLAMA_ARG_SPEC_TYPE)
        draft_n_max_lines=$(section_key "$presets" "$subject" LLAMA_ARG_SPEC_DRAFT_N_MAX)
        spec_type_count=$(printf '%s\n' "$spec_type_lines" | grep -c .)
        draft_n_max_count=$(printf '%s\n' "$draft_n_max_lines" | grep -c .)
        if [ "$speculation_profile" = mtp1 ]; then
            if [ "$spec_type_count" -ne 1 ] || [ "$spec_type_lines" != draft-mtp ] ||
                [ "$draft_n_max_count" -ne 1 ] || [ "$draft_n_max_lines" != 1 ]; then
                printf 'section %s selects mtp1 but the spec keys read type=%s(%s) n_max=%s(%s)\n' \
                    "$subject" "$spec_type_lines" "$spec_type_count" \
                    "$draft_n_max_lines" "$draft_n_max_count" >&2
                echo fail >>"$speculation_key_failures"
            fi
        else
            if [ "$spec_type_count" -ne 0 ] || [ "$draft_n_max_count" -ne 0 ]; then
                printf 'section %s selects speculation profile %s but carries a spec key\n' \
                    "$subject" "$speculation_profile" >&2
                echo fail >>"$speculation_key_failures"
            fi
        fi
    done
if [ ! -s "$speculation_key_failures" ]; then
    report speculation_keys_match_profile accepted
else
    report speculation_keys_match_profile rejected
fi

# A row selecting a non-none speculation profile without the mtp_layers claim
# the multi-token-prediction context needs is refused before the generator
# writes anything, on the same discipline the quarantine authority already
# enforces. Each fixture is the shipped registry with one field mutated in a
# copy under the work directory; the shipped scripts/models.tsv is never
# opened for writing.
mutate_speculation_profile() {
    mutate_source=$1
    mutate_target_id=$2
    mutate_new_profile=$3
    mutate_output=$4
    awk -F'\t' -v OFS='\t' -v target="$mutate_target_id" \
        -v profile="$mutate_new_profile" '
        /^#/ || NF < 24 { print; next }
        $1 == target { $24 = profile }
        { print }
    ' "$mutate_source" >"$mutate_output"
}
models_checksum_before=$(sha256sum "$registry")

mtp_zero_registry=$work/mutant-mtp-zero-models.tsv
mutate_speculation_profile "$registry" qwen35-2b-heretic mtp1 "$mtp_zero_registry"
mtp_zero_preset=$work/mutant-mtp-zero-presets.ini
set +e
QWEN_MODEL_REGISTRY=$mtp_zero_registry QWEN_MODEL_ROOT=$model_root \
QWEN_QUARANTINE_REGISTRY=$quarantine \
QWEN_QUARANTINE_REASONS=$repository_root/evidence/quarantine \
    "$builder" "$mtp_zero_preset" >"$work/mutant-mtp-zero.out" \
    2>"$work/mutant-mtp-zero.err"
mtp_zero_status=$?
set -e
if [ "$mtp_zero_status" -ne 0 ] && [ ! -e "$mtp_zero_preset" ] &&
   grep -F 'mtp_layers=0' "$work/mutant-mtp-zero.err" >/dev/null; then
    report speculation_refuses_mtp_layers_zero accepted
else
    report speculation_refuses_mtp_layers_zero rejected
fi

mtp_uninspected_registry=$work/mutant-mtp-uninspected-models.tsv
mutate_speculation_profile "$registry" qwen35-4b-base mtp1 \
    "$mtp_uninspected_registry"
mtp_uninspected_preset=$work/mutant-mtp-uninspected-presets.ini
set +e
QWEN_MODEL_REGISTRY=$mtp_uninspected_registry QWEN_MODEL_ROOT=$model_root \
QWEN_QUARANTINE_REGISTRY=$quarantine \
QWEN_QUARANTINE_REASONS=$repository_root/evidence/quarantine \
    "$builder" "$mtp_uninspected_preset" >"$work/mutant-mtp-uninspected.out" \
    2>"$work/mutant-mtp-uninspected.err"
mtp_uninspected_status=$?
set -e
if [ "$mtp_uninspected_status" -ne 0 ] && [ ! -e "$mtp_uninspected_preset" ] &&
   grep -F 'mtp_layers uninspected (-)' \
       "$work/mutant-mtp-uninspected.err" >/dev/null; then
    report speculation_refuses_mtp_layers_uninspected accepted
else
    report speculation_refuses_mtp_layers_uninspected rejected
fi

unknown_profile_registry=$work/mutant-unknown-profile-models.tsv
mutate_speculation_profile "$registry" qwen38-2b-distill bogus-profile \
    "$unknown_profile_registry"
unknown_profile_preset=$work/mutant-unknown-profile-presets.ini
set +e
QWEN_MODEL_REGISTRY=$unknown_profile_registry QWEN_MODEL_ROOT=$model_root \
QWEN_QUARANTINE_REGISTRY=$quarantine \
QWEN_QUARANTINE_REASONS=$repository_root/evidence/quarantine \
    "$builder" "$unknown_profile_preset" >"$work/mutant-unknown-profile.out" \
    2>"$work/mutant-unknown-profile.err"
unknown_profile_status=$?
set -e
if [ "$unknown_profile_status" -ne 0 ] && [ ! -e "$unknown_profile_preset" ] &&
   grep -F 'names speculation_profile bogus-profile, absent from' \
       "$work/mutant-unknown-profile.err" >/dev/null; then
    report speculation_refuses_unknown_profile accepted
else
    report speculation_refuses_unknown_profile rejected
fi

models_checksum_after=$(sha256sum "$registry")
if [ "$models_checksum_before" = "$models_checksum_after" ]; then
    report models_registry_untouched accepted
else
    report models_registry_untouched rejected
fi

# Counts the sections of a preset file that serve a quarantined tuple whole.
# Printing the count rather than reporting lets the same detector run over the
# real file and over two fabricated ones, which is what proves it discriminates.
count_profile_leaks() {
    count_presets=$1
    count_profiles=$2
    leaks=0
    while IFS='	' read -r subject depth batch ubatch cache_k cache_v flash; do
        [ -n "$subject" ] || continue
        section_batch=$(section_key "$count_presets" "$subject" LLAMA_ARG_BATCH)
        [ -n "$section_batch" ] || continue
        if [ "$(section_key "$count_presets" "$subject" LLAMA_ARG_CTX_SIZE)" = "$depth" ] &&
            [ "$section_batch" = "$batch" ] &&
            [ "$(section_key "$count_presets" "$subject" LLAMA_ARG_UBATCH)" = "$ubatch" ] &&
            [ "$(section_key "$count_presets" "$subject" LLAMA_ARG_CACHE_TYPE_K)" = "$cache_k" ] &&
            [ "$(section_key "$count_presets" "$subject" LLAMA_ARG_CACHE_TYPE_V)" = "$cache_v" ] &&
            [ "$(section_key "$count_presets" "$subject" LLAMA_ARG_FLASH_ATTN)" = "$flash" ]; then
            printf 'preset %s serves the quarantined tuple %s/%s/%s/%s/%s/%s\n' \
                "$subject" "$depth" "$batch" "$ubatch" "$cache_k" "$cache_v" "$flash" >&2
            leaks=$((leaks + 1))
        fi
    done <"$count_profiles"
    printf '%s' "$leaks"
}

# The profile list is a file rather than a command substitution so the same
# detector runs over the shipped authority and over a fabricated one. The
# shipped ledger carries no profile-scope row on this host, and a detector
# fed an empty list reports every preset file clean, so the positive control
# below supplies its own row rather than borrowing the registry's.
live_profiles=$work/live-quarantine-profiles.tsv
"$reader" quarantine-profiles >"$live_profiles"

if [ "$(count_profile_leaks "$presets" "$live_profiles" 2>/dev/null)" -eq 0 ]; then
    report quarantine_profiles accepted
else
    count_profile_leaks "$presets" "$live_profiles" >/dev/null
    report quarantine_profiles rejected
fi

# The detector fires on a section built to serve the quarantined tuple whole. A
# detector that never fires reports every preset file clean, including one that
# leaks, so the positive control runs beside the real check.
control_profiles=$work/control-quarantine-profiles.tsv
printf 'control-model\t16384\t2048\t512\tq8_0\tq4_0\ton\n' >"$control_profiles"
leaking_presets=$work/leaking-presets.ini
while IFS='	' read -r subject depth batch ubatch cache_k cache_v flash; do
    [ -n "$subject" ] || continue
    printf '[%s]\nLLAMA_ARG_CTX_SIZE = %s\nLLAMA_ARG_BATCH = %s\n' \
        "$subject" "$depth" "$batch"
    printf 'LLAMA_ARG_UBATCH = %s\nLLAMA_ARG_CACHE_TYPE_K = %s\n' \
        "$ubatch" "$cache_k"
    printf 'LLAMA_ARG_CACHE_TYPE_V = %s\nLLAMA_ARG_FLASH_ATTN = %s\n\n' \
        "$cache_v" "$flash"
done <"$control_profiles" >"$leaking_presets"
if [ "$(count_profile_leaks "$leaking_presets" "$control_profiles" 2>/dev/null)" -gt 0 ]; then
    report quarantine_profile_detector accepted
else
    report quarantine_profile_detector rejected
fi

# One key away from the quarantined tuple is a different tuple. The cache
# representation is the discriminator here because the geometry stays identical,
# which is exactly what a check reading depth, batch, and ubatch alone would
# call quarantined.
distinct_presets=$work/distinct-presets.ini
sed 's/^LLAMA_ARG_CACHE_TYPE_K = .*/LLAMA_ARG_CACHE_TYPE_K = f16/' \
    "$leaking_presets" >"$distinct_presets"
if [ "$(count_profile_leaks "$distinct_presets" "$control_profiles" 2>/dev/null)" -eq 0 ]; then
    report quarantine_profile_cache_discriminated accepted
else
    report quarantine_profile_cache_discriminated rejected
fi

# runtime_mode is a fixed vocabulary for the same reason failure_class is: a
# free-text value here would let a reader infer an execution path the evidence
# never isolated.
runtime_mode_vocabulary=0
for runtime_mode in $(awk -F'\t' '/^#/ { next } NF { print $14 }' "$quarantine" |
    sort -u); do
    case $runtime_mode in
        any | router-child | standalone) ;;
        *)
            printf 'runtime mode outside the vocabulary: %s\n' "$runtime_mode" >&2
            runtime_mode_vocabulary=$((runtime_mode_vocabulary + 1))
            ;;
    esac
done
if [ "$runtime_mode_vocabulary" -eq 0 ]; then
    report runtime_mode_vocabulary accepted
else
    report runtime_mode_vocabulary rejected
fi

# Runtime-mode queries include `any` and the requested execution path. A
# router-child-only failure must not become a standalone prohibition, while the
# router builder must still see it.
# The `any` half runs against a fixture because the shipped ledger carries one
# router-child row alone, and an assertion that reads only what the registry
# happens to hold stops testing the filter the day a row leaves.
runtime_filter_registry=$work/runtime-filter-models.tsv
runtime_filter_quarantine=$work/runtime-filter-quarantine.tsv
runtime_filter_reasons=$work/runtime-filter-reasons
runtime_filter_root=$work/runtime-filter-models
mkdir -p "$runtime_filter_reasons" "$runtime_filter_root/Any" \
    "$runtime_filter_root/Child"
: >"$runtime_filter_root/Any/model.gguf"
: >"$runtime_filter_root/Child/model.gguf"
: >"$runtime_filter_reasons/any-record.md"
: >"$runtime_filter_reasons/child-record.md"
printf '%s\n' \
    'any-model	fixture	Any/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	production	128	32	-	-	unmeasured	refused	0	off' \
    'child-model	fixture	Child/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	production	128	32	-	-	unmeasured	refused	0	off' \
    >"$runtime_filter_registry"
printf '%s\n' \
    'any-record	model	any-model	device-lost	-	-	-	-	-	-	-	-	evidence/quarantine/any-record.md	any' \
    'child-record	model	child-model	graph-assert-abort	-	-	-	-	-	-	-	-	evidence/quarantine/child-record.md	router-child' \
    >"$runtime_filter_quarantine"
runtime_filter_subjects() {
    QWEN_MODEL_REGISTRY=$runtime_filter_registry \
    QWEN_MODEL_ROOT=$runtime_filter_root \
    QWEN_QUARANTINE_REGISTRY=$runtime_filter_quarantine \
    QWEN_QUARANTINE_REASONS=$runtime_filter_reasons \
        "$reader" quarantine-subjects "$1"
}
if runtime_filter_subjects router-child | grep -qx child-model &&
   ! runtime_filter_subjects standalone | grep -qx child-model &&
   runtime_filter_subjects standalone | grep -qx any-model &&
   runtime_filter_subjects router-child | grep -qx any-model &&
   "$reader" quarantine-subjects router-child | grep -qx ministral3-3b &&
   ! "$reader" quarantine-subjects standalone | grep -qx ministral3-3b; then
    report quarantine_runtime_filter accepted
else
    report quarantine_runtime_filter rejected
fi

# Reconciliation removes symlinks and must refuse a real directory, because
# emptying one would delete a checkpoint and skipping one would leave it in a
# tier no row claims.
mkdir -p "$model_root/production/hand-placed"
set +e
build >"$work/refuse.log" 2>"$work/refuse.err"
refuse_status=$?
set -e
rmdir "$model_root/production/hand-placed"
if [ "$refuse_status" -ne 0 ] &&
    grep -q 'real entry where a symlink belongs' "$work/refuse.err"; then
    report real_directory_refused accepted
else
    report real_directory_refused rejected
fi

# The research override is the only path that names a quarantined checkpoint,
# and the policy forces the listener to loopback while it is set.
build_override=$(QWEN_MODEL_ROOT=$model_root \
    QWEN_QUARANTINE_REGISTRY=$quarantine \
    QWEN_QUARANTINE_REASONS=$repository_root/evidence/quarantine \
    QWEN_ROUTER_INCLUDE_QUARANTINE=1 "$builder" "$presets" 2>&1)
if printf '%s' "$build_override" | grep -q 'quarantine_override=on' &&
    awk -F'[][]' '/^\[/ { print $2 }' "$presets" | grep -qx nanbeige42-3b; then
    report quarantine_override accepted
else
    report quarantine_override rejected
fi

# The quarantine registry overrides a stale tier and rejects an exact profile
# inside the generator itself. This fixture uses a separate registry to prove
# that safety does not depend on running this test after generation.
fixture_registry=$work/quarantine-fixture-models.tsv
fixture_quarantine=$work/quarantine-fixture.tsv
fixture_reasons=$work/quarantine-fixture-reasons
fixture_model_root=$work/quarantine-fixture-models
fixture_presets=$work/quarantine-fixture.ini
mkdir -p "$fixture_reasons" "$fixture_model_root/Hidden" \
    "$fixture_model_root/Profile" "$fixture_model_root/Archived"
: >"$fixture_model_root/Hidden/model.gguf"
: >"$fixture_model_root/Profile/model.gguf"
: >"$fixture_model_root/Archived/model.gguf"
: >"$fixture_reasons/hidden-record.md"
: >"$fixture_reasons/profile-record.md"
: >"$fixture_reasons/archived-record.md"
printf '%s\n' \
    'hidden-model	fixture	Hidden/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	production	128	32	-	-	unmeasured	refused	0	off' \
    'profile-model	fixture	Profile/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	production	128	32	-	-	unmeasured	refused	0	off' \
    'archived-model	fixture	Archived/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	archive	128	32	-	-	unmeasured	refused	0	off' \
    >"$fixture_registry"
printf '%s\n' \
    'hidden-record	model	hidden-model	device-lost	-	-	-	-	-	-	-	-	evidence/quarantine/hidden-record.md	any' \
    'profile-record	profile	profile-model	ring-timeout-only	8192	128	32	q8_0	q4_0	on	-	-	evidence/quarantine/profile-record.md	router-child' \
    'archived-record	model	archived-model	device-lost	-	-	-	-	-	-	-	-	evidence/quarantine/archived-record.md	any' \
    >"$fixture_quarantine"
QWEN_MODEL_REGISTRY=$fixture_registry QWEN_MODEL_ROOT=$fixture_model_root \
QWEN_QUARANTINE_REGISTRY=$fixture_quarantine \
QWEN_QUARANTINE_REASONS=$fixture_reasons \
    "$builder" "$fixture_presets" >"$work/quarantine-fixture.log"
if ! grep -q '^\[' "$fixture_presets" &&
   [ -L "$fixture_model_root/quarantine/Hidden" ] &&
   [ -L "$fixture_model_root/production/Profile" ]; then
    report quarantine_registry_enforced accepted
else
    report quarantine_registry_enforced rejected
fi

QWEN_MODEL_REGISTRY=$fixture_registry QWEN_MODEL_ROOT=$fixture_model_root \
QWEN_QUARANTINE_REGISTRY=$fixture_quarantine \
QWEN_QUARANTINE_REASONS=$fixture_reasons QWEN_ROUTER_INCLUDE_QUARANTINE=1 \
QWEN_DEFAULT_MODEL_ID=hidden-model \
    "$builder" "$fixture_presets" >"$work/quarantine-fixture-override.log"
fixture_sections=$(awk -F'[][]' '/^\[/ { print $2 }' "$fixture_presets" | sort)
hidden_tags=$(awk -F' = ' '
    /^\[hidden-model\]$/ { wanted = 1; next }
    /^\[/ { wanted = 0 }
    wanted && $1 == "LLAMA_ARG_TAGS" { print $2; exit }
' "$fixture_presets")
profile_tags=$(awk -F' = ' '
    /^\[profile-model\]$/ { wanted = 1; next }
    /^\[/ { wanted = 0 }
    wanted && $1 == "LLAMA_ARG_TAGS" { print $2; exit }
' "$fixture_presets")
if [ "$fixture_sections" = "$(printf '%s\n' hidden-model profile-model)" ] &&
   grep -qx '# qwen_router_include_quarantine=1' "$fixture_presets" &&
   [ ! -L "$fixture_model_root/quarantine/Archived" ] &&
   [ "$hidden_tags" = quarantine,fixture ] &&
   [ "$profile_tags" = quarantine,fixture ]; then
    report quarantine_registry_override accepted
else
    report quarantine_registry_override rejected
    printf 'override tags hidden=%s profile=%s\n' \
        "$hidden_tags" "$profile_tags" >&2
fi

if [ "$failures" -eq 0 ]; then
    printf 'model_tiers=accepted\n'
    exit 0
fi
printf 'model_tiers=rejected failures=%s\n' "$failures" >&2
exit 1
