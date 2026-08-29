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
for reason_id in $(awk -F'\t' '!/^#/ && NF { print $1 }' "$quarantine"); do
    reason_record=$repository_root/evidence/quarantine/$reason_id.md
    if [ ! -r "$reason_record" ]; then
        printf 'quarantine %s carries no reason record\n' "$reason_id" >&2
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
    if [ ! -r "$model_root/quarantine-reasons/$subject.md" ]; then
        printf 'quarantine link for %s has no deployed reason record\n' \
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
        LLAMA_ARG_MMPROJ) ;;
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

# Counts the sections of a preset file that serve a quarantined tuple whole.
# Printing the count rather than reporting lets the same detector run over the
# real file and over two fabricated ones, which is what proves it discriminates.
count_profile_leaks() {
    count_presets=$1
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
    done <<COUNT_PROFILES
$("$reader" quarantine-profiles)
COUNT_PROFILES
    printf '%s' "$leaks"
}

if [ "$(count_profile_leaks "$presets" 2>/dev/null)" -eq 0 ]; then
    report quarantine_profiles accepted
else
    count_profile_leaks "$presets" >/dev/null
    report quarantine_profiles rejected
fi

# The detector fires on a section built to serve the quarantined tuple whole. A
# detector that never fires reports every preset file clean, including one that
# leaks, so the positive control runs beside the real check.
leaking_presets=$work/leaking-presets.ini
"$reader" quarantine-profiles |
    while IFS='	' read -r subject depth batch ubatch cache_k cache_v flash; do
        [ -n "$subject" ] || continue
        printf '[%s]\nLLAMA_ARG_CTX_SIZE = %s\nLLAMA_ARG_BATCH = %s\n' \
            "$subject" "$depth" "$batch"
        printf 'LLAMA_ARG_UBATCH = %s\nLLAMA_ARG_CACHE_TYPE_K = %s\n' \
            "$ubatch" "$cache_k"
        printf 'LLAMA_ARG_CACHE_TYPE_V = %s\nLLAMA_ARG_FLASH_ATTN = %s\n\n' \
            "$cache_v" "$flash"
    done >"$leaking_presets"
if [ "$(count_profile_leaks "$leaking_presets" 2>/dev/null)" -gt 0 ]; then
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
if [ "$(count_profile_leaks "$distinct_presets" 2>/dev/null)" -eq 0 ]; then
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
if "$reader" quarantine-subjects router-child | grep -qx ministral3-3b &&
   ! "$reader" quarantine-subjects standalone | grep -qx ministral3-3b &&
   "$reader" quarantine-subjects standalone | grep -qx nanbeige42-3b; then
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
    'hidden-model	fixture	Hidden/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	production	128	32	-	-	unmeasured	refused' \
    'profile-model	fixture	Profile/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	production	128	32	-	-	unmeasured	refused' \
    'archived-model	fixture	Archived/model.gguf	fetch.sh	8192	8192	8192	q8_0	q4_0	on	none	-	-	-	untested	archive	128	32	-	-	unmeasured	refused' \
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
