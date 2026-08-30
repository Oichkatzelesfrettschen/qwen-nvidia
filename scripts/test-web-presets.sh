#!/bin/sh
set -eu

# Tests scripts/build-web-presets.sh against temporary copies of models.tsv and
# web-profiles.tsv, so a case that must fail (an over-ceiling context, an
# unvalidated depth, a missing MCP config) never depends on editing the
# checked-in ledgers.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
builder=$script_directory/build-web-presets.sh
failures=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = ok ] || failures=$((failures + 1))
}

# The web-lane cases below read a temporary all-refused image ledger for the
# reason they read a temporary model registry: the checked-in
# scripts/image-profiles.tsv carries one validator-gated row, so a generator run
# that names no image ledger would require the five image MCP inputs of a lane
# these cases never arm. The image-lane cases further down set
# QWEN_IMAGE_PROFILES themselves, and an explicit setting wins because build()
# passes its callers' `env` prefix after this default.
image_profiles_none=$work/image-profiles-none.tsv
cat >"$image_profiles_none" <<'EOF'
# profile_id	model_id	placement	width	height	steps	sampler	cfg	max_steps	max_dimension	timeout_s	execution_policy	validated_evidence	review_model
image-fixture-refused	sdxs-512	A	512	512	1	euler	1.0	4	512	300	refused	-	-
EOF
QWEN_IMAGE_PROFILES=$image_profiles_none
export QWEN_IMAGE_PROFILES

# Four fabricated model rows, one per tier-and-depth combination the
# refusal rules below distinguish: a production row with a numeric validated
# depth, a candidate row with a numeric validated depth, a candidate row
# whose depth reads `-`, and an archive row.
model_registry=$work/models.tsv
cat >"$model_registry" <<'EOF'
# id	role	model_file	fetch_script	context_default	context_ceiling	context_target	cache_type_k	cache_type_v	flash_attention	projector	projector_fetch_script	decode_tok_s	prefill_tok_s	quality	tier	batch	ubatch	validated_filled_depth	validation_evidence	raw_tool_selection	guarded_tool_execution	mtp_layers	speculation_profile
fixture-production	fixture-role	Fixture-GGUF/production.gguf	download-fixture.sh	8192	16384	32768	q8_0	q4_0	on	none	-	1.00	1.00	untested	production	128	32	8192	evidence/fixture.md	9/10	refused	0	off	-
fixture-candidate-validated	fixture-role	Fixture-GGUF/candidate-validated.gguf	download-fixture.sh	8192	16384	32768	q8_0	q4_0	on	none	-	1.00	1.00	untested	candidate	128	32	8192	evidence/fixture.md	9/10	refused	0	off	-
fixture-candidate-unknown	fixture-role	Fixture-GGUF/candidate-unknown.gguf	download-fixture.sh	8192	16384	32768	q8_0	q4_0	on	none	-	1.00	1.00	untested	candidate	128	32	-	-	9/10	refused	0	off	-
fixture-archive	fixture-role	Fixture-GGUF/archive.gguf	download-fixture.sh	8192	16384	32768	q8_0	q4_0	on	none	-	1.00	1.00	untested	archive	128	32	-	-	9/10	refused	0	off	-
fixture-vision	fixture-role	Fixture-Vision-GGUF/vision.gguf	download-fixture.sh	8192	16384	32768	q8_0	q4_0	on	required	download-fixture-mmproj.sh	1.00	1.00	untested	production	128	32	8192	evidence/fixture.md	9/10	refused	0	off	-
EOF

web_profiles_ok=$work/web-profiles-ok.tsv
cat >"$web_profiles_ok" <<'EOF'
# profile_id	model_id	web_mode	context	validated_filled_depth	max_results	max_fetches	max_chars_per_fetch	multi_source	vision_allowed	tool_selection	execution_policy	provider	primary_category	fallback_category	minimum_results	searxng_url
web-fixture-ok	fixture-production	validator-gated	8192	8192	5	2	12000	yes	no	9/10	validator-gated	exa	-	-	-	-
EOF

web_profiles_over_ceiling=$work/web-profiles-over-ceiling.tsv
cat >"$web_profiles_over_ceiling" <<'EOF'
web-fixture-over-ceiling	fixture-production	validator-gated	32768	8192	5	2	12000	yes	no	9/10	validator-gated	exa	-	-	-	-
EOF

# Candidate tier, numeric validated_filled_depth of 8192, context 16384: the
# exceeded-numeric-depth case.
web_profiles_over_depth=$work/web-profiles-over-depth.tsv
cat >"$web_profiles_over_depth" <<'EOF'
web-fixture-over-depth	fixture-candidate-validated	validator-gated	16384	8192	5	2	12000	yes	no	9/10	validator-gated	exa	-	-	-	-
EOF

# Candidate tier, validated_filled_depth `-`: the unknown-depth case.
web_profiles_unknown_depth=$work/web-profiles-unknown-depth.tsv
cat >"$web_profiles_unknown_depth" <<'EOF'
web-fixture-unknown-depth	fixture-candidate-unknown	validator-gated	8192	-	5	2	12000	yes	no	9/10	validator-gated	exa	-	-	-	-
EOF

# Production tier at an unvalidated depth: the override admits this one as
# experimental, since production names the model_id's own tier and the
# override withholds the emitted section's claim to it rather than
# refusing the model_id.
web_profiles_production_unvalidated=$work/web-profiles-production-unvalidated.tsv
cat >"$web_profiles_production_unvalidated" <<'EOF'
web-fixture-production-unvalidated	fixture-production	validator-gated	16384	8192	5	2	12000	yes	no	9/10	validator-gated	exa	-	-	-	-
EOF

web_profiles_archive=$work/web-profiles-archive.tsv
cat >"$web_profiles_archive" <<'EOF'
web-fixture-archive	fixture-archive	validator-gated	8192	-	5	2	12000	yes	no	9/10	validator-gated	exa	-	-	-	-
EOF

# The generator skips a row whose weights are absent, so every arm that measures
# another rule runs against a model root holding one empty file per fixture row.
policy_model_root=$work/model-root
mkdir -p "$policy_model_root/Fixture-GGUF"
for fixture_weights in production candidate-validated candidate-unknown archive; do
    : >"$policy_model_root/Fixture-GGUF/$fixture_weights.gguf"
done
# The vision row sits in its own directory, because select-projector.sh searches
# the model file's own directory and a projector beside a text checkpoint would
# pair with it.
mkdir -p "$policy_model_root/Fixture-Vision-GGUF"
: >"$policy_model_root/Fixture-Vision-GGUF/vision.gguf"
: >"$policy_model_root/Fixture-Vision-GGUF/mmproj-F16.gguf"

mcp_server_program=$work/web-mcp-server.py
: >"$mcp_server_program"
search_key_file=$work/private/exa-api.key
token_key_file=$work/private/web-mcp-token.key
mkdir -p "$work/private"
printf 'fixture-search-secret-value\n' >"$search_key_file"
printf 'fixture-token-secret-value\n' >"$token_key_file"
web_state_directory=$work/private/web-mcp-state

# Every build arm supplies the same MCP inputs; an arm that measures their
# absence unsets one explicitly.
mcp_environment() {
    printf 'QWEN_WEB_MCP_SERVER=%s\n' "$mcp_server_program"
    printf 'QWEN_WEB_SEARCH_KEY_FILE=%s\n' "$search_key_file"
    printf 'QWEN_WEB_TOKEN_KEY_FILE=%s\n' "$token_key_file"
    printf 'QWEN_WEB_STATE_DIR=%s\n' "$web_state_directory"
}

# Every fixture row below states execution_policy validator-gated, so the build
# helper supplies the authorizer marker and each arm measures the rule it names
# rather than the execution gate. The gate has its own arms at the end.
build() {
    build_web_profiles=$1
    build_output=$2
    shift 2
    QWEN_MODEL_REGISTRY=$model_registry \
    QWEN_WEB_PROFILES=$build_web_profiles \
    QWEN_WEB_AUTHORIZER_READY=1 \
    QWEN_MODEL_ROOT=${QWEN_MODEL_ROOT:-$policy_model_root} \
        "$@" "$builder" "$build_output"
}

# A profile within the ceiling and within the validated depth is accepted,
# carries every required key, and carries no experimental tag or override
# marker.
presets_ok=$work/presets-ok.ini
if build "$web_profiles_ok" "$presets_ok" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/ok.log" 2>"$work/ok.err"; then
    report accepted_within_bounds ok
else
    report accepted_within_bounds failed
    cat "$work/ok.err" >&2
fi

required_keys='LLAMA_ARG_MODEL LLAMA_ARG_ALIAS LLAMA_ARG_CTX_SIZE LLAMA_ARG_BATCH LLAMA_ARG_UBATCH LLAMA_ARG_CACHE_TYPE_K LLAMA_ARG_CACHE_TYPE_V LLAMA_ARG_FLASH_ATTN LLAMA_ARG_MCP_SERVERS_CONFIG LLAMA_ARG_TAGS'
geometry_ok=ok
for key in $required_keys; do
    if ! awk -v key="$key" '
        /^\[/ { in_section = 1 }
        in_section && $0 ~ "^" key " *=" { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$presets_ok"; then
        geometry_ok=missing_$key
    fi
done
report section_carries_required_keys "$geometry_ok"

# LLAMA_ARG_MCP_SERVERS_CONFIG never appears before the first section header,
# which would place it outside every [profile_id] block.
preamble_clean=ok
if [ -f "$presets_ok" ] &&
    awk '
        /^\[/ { exit }
        /^LLAMA_ARG_MCP_SERVERS_CONFIG/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$presets_ok"; then
    preamble_clean=mcp_key_before_first_section
fi
report no_mcp_key_outside_section "$preamble_clean"

# A fully validated profile carries no unvalidated-depth-override marker and
# no experimental tag.
no_marker=ok
if grep -q 'unvalidated-depth-override' "$presets_ok"; then
    no_marker=marker_present
fi
report validated_profile_carries_no_marker "$no_marker"

no_experimental_tag=ok
if grep -q 'experimental' "$presets_ok"; then
    no_experimental_tag=tag_present
fi
report validated_profile_carries_no_experimental_tag "$no_experimental_tag"

# The generated MCP configuration path is read by qwen-web-launch.sh and by the
# llama-server child from their own working directories, so a relative
# OUTPUT_INI still resolves absolutely. The builder runs from a scratch
# directory with a bare relative argument, which is the documented
# `web-presets.ini` form.
relative_output_directory=$work/relative-out
mkdir -p "$relative_output_directory"
if (
    cd "$relative_output_directory" &&
    QWEN_MODEL_REGISTRY=$model_registry \
    QWEN_WEB_PROFILES=$web_profiles_ok \
    QWEN_WEB_AUTHORIZER_READY=1 \
    QWEN_MODEL_ROOT=$policy_model_root \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
        "$builder" web-presets.ini
) >"$work/relative.log" 2>"$work/relative.err"; then
    outcome=ok
    grep -q '^LLAMA_ARG_MCP_SERVERS_CONFIG = /' \
        "$relative_output_directory/web-presets.ini" ||
        outcome=mcp_path_relative
    grep -q '^web_presets=written path=/' "$work/relative.log" ||
        outcome=reported_path_relative
    named_relative_config=$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' \
        "$relative_output_directory/web-presets.ini")
    [ -r "$named_relative_config" ] || outcome=named_config_unreadable
    report relative_output_resolves_absolutely "$outcome"
else
    report relative_output_resolves_absolutely build_failed
    cat "$work/relative.err" >&2
fi

# A profile whose context exceeds the registry context_ceiling is refused.
presets_over_ceiling=$work/presets-over-ceiling.ini
if build "$web_profiles_over_ceiling" "$presets_over_ceiling" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/over-ceiling.log" 2>"$work/over-ceiling.err"; then
    report over_ceiling_refused failed
else
    report over_ceiling_refused ok
fi

# A profile whose context exceeds a numeric validated_filled_depth is refused
# by default.
presets_over_depth=$work/presets-over-depth.ini
if build "$web_profiles_over_depth" "$presets_over_depth" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/over-depth.log" 2>"$work/over-depth.err"; then
    report numeric_over_depth_refused_without_override failed
else
    report numeric_over_depth_refused_without_override ok
fi

# The same profile is admitted, tagged experimental, and warned with the
# numeric gap under the override, and the file carries the override marker.
presets_over_depth_allowed=$work/presets-over-depth-allowed.ini
if build "$web_profiles_over_depth" "$presets_over_depth_allowed" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" QWEN_WEB_ALLOW_UNVALIDATED_DEPTH=1 \
    >"$work/over-depth-allowed.log" 2>"$work/over-depth-allowed.err"; then
    outcome=ok
    grep -q 'validated_filled_depth_gap=8192' "$work/over-depth-allowed.err" ||
        outcome=missing_gap_warning
    grep -q ',experimental' "$presets_over_depth_allowed" ||
        outcome=missing_experimental_tag
    grep -q 'unvalidated-depth-override' "$presets_over_depth_allowed" ||
        outcome=missing_override_marker
    report numeric_over_depth_admitted_with_override "$outcome"
else
    report numeric_over_depth_admitted_with_override failed
    cat "$work/over-depth-allowed.err" >&2
fi

# A profile whose validated_filled_depth reads `-` is refused by default: the
# unmeasured case fails the same way the measured-too-shallow case does.
presets_unknown_depth=$work/presets-unknown-depth.ini
if build "$web_profiles_unknown_depth" "$presets_unknown_depth" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/unknown-depth.log" 2>"$work/unknown-depth.err"; then
    report unknown_depth_refused_without_override failed
else
    report unknown_depth_refused_without_override ok
fi

# The same profile is admitted, tagged experimental, and warned with the
# unknown state under the override, and the file carries the override
# marker.
presets_unknown_depth_allowed=$work/presets-unknown-depth-allowed.ini
if build "$web_profiles_unknown_depth" "$presets_unknown_depth_allowed" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" QWEN_WEB_ALLOW_UNVALIDATED_DEPTH=1 \
    >"$work/unknown-depth-allowed.log" 2>"$work/unknown-depth-allowed.err"; then
    outcome=ok
    grep -q 'validated_filled_depth=unknown' "$work/unknown-depth-allowed.err" ||
        outcome=missing_unknown_warning
    grep -q ',experimental' "$presets_unknown_depth_allowed" ||
        outcome=missing_experimental_tag
    grep -q 'unvalidated-depth-override' "$presets_unknown_depth_allowed" ||
        outcome=missing_override_marker
    report unknown_depth_admitted_with_override "$outcome"
else
    report unknown_depth_admitted_with_override failed
    cat "$work/unknown-depth-allowed.err" >&2
fi

# A production-tier profile at an unvalidated depth is admitted under the
# override: a production-tiered model_id is exactly the one an experimental
# web profile should be able to run. What the override withholds is the
# emitted section's own claim to that tier.
presets_production_unvalidated=$work/presets-production-unvalidated.ini
if build "$web_profiles_production_unvalidated" "$presets_production_unvalidated" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" QWEN_WEB_ALLOW_UNVALIDATED_DEPTH=1 \
    >"$work/production-unvalidated.log" 2>"$work/production-unvalidated.err"; then
    outcome=ok
    grep -q ',experimental' "$presets_production_unvalidated" ||
        outcome=missing_experimental_tag
    grep -q 'unvalidated-depth-override' "$presets_production_unvalidated" ||
        outcome=missing_override_marker
    report production_model_admitted_as_experimental_under_override "$outcome"
else
    report production_model_admitted_as_experimental_under_override failed
    cat "$work/production-unvalidated.err" >&2
fi

# The emitted section never carries a default tag: the override withholds
# the emitted profile's own claim to a tier it did not earn.
no_default_tag=ok
if grep -q 'default' "$presets_production_unvalidated"; then
    no_default_tag=default_tag_present
fi
report no_default_tag_under_override "$no_default_tag"

# A profile naming an archive-tiered model is refused.
presets_archive=$work/presets-archive.ini
if build "$web_profiles_archive" "$presets_archive" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/archive.log" 2>"$work/archive.err"; then
    report archive_tier_refused failed
else
    report archive_tier_refused ok
fi

# An absent MCP server program or key file path refuses the run: no default is
# safe to assume for a tool-bearing section.
presets_no_mcp=$work/presets-no-mcp.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_ok \
    QWEN_WEB_AUTHORIZER_READY=1 \
    env -u QWEN_WEB_MCP_SERVER QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    "$builder" "$presets_no_mcp" \
    >"$work/no-mcp.log" 2>"$work/no-mcp.err"; then
    report missing_mcp_server_refused failed
else
    report missing_mcp_server_refused ok
fi

presets_no_key=$work/presets-no-key.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_ok \
    QWEN_WEB_AUTHORIZER_READY=1 \
    env -u QWEN_WEB_SEARCH_KEY_FILE QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    "$builder" "$presets_no_key" \
    >"$work/no-key.log" 2>"$work/no-key.err"; then
    report missing_search_key_file_refused failed
else
    report missing_search_key_file_refused ok
fi

# The generated file reaches llama-server through qwen-capacity-policy.sh, whose
# validate_router_preset_tuples is the authority on a complete section tuple.
# Running the generator's own output through that validator is what makes a
# misspelled key a test failure here rather than a launch failure on the
# appliance; a key-name check inside this script would only restate the
# generator's printf list.
policy=$script_directory/qwen-capacity-policy.sh
fake_server=$script_directory/test-fixtures/fake-llama-server.sh
fake_icd=$work/radeon_icd.x86_64.json
: >"$fake_icd"
policy_quarantine=$work/quarantine.tsv
printf '# reason_id\tscope\tsubject\tconsumers\tdepth\tbatch\tubatch\tcache_type_k\tcache_type_v\tflash_attention\n' \
    >"$policy_quarantine"
policy_output=$work/policy.out

# The policy rejoins each web section to the current ledger by its profile_id,
# so the arm names the ledger the preset was generated from. A second argument
# names another ledger, which is what the revocation arms below measure.
run_policy_over_presets() {
    QWEN_MODEL_REGISTRY=$model_registry \
    QWEN_MODEL_ROOT=$policy_model_root \
    QWEN_QUARANTINE_REGISTRY=$policy_quarantine \
    QWEN_WEB_PROFILES=${2:-$web_profiles_ok} \
    QWEN_WEB_AUTHORIZER_READY=1 \
    QWEN_VULKAN_ICD=$fake_icd \
    QWEN_POLICY_TEST_OUTPUT=$policy_output \
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$1 QWEN_ROUTER_MAX=1 \
        "$policy" "$fake_server" \
        "$policy_model_root/Fixture-GGUF/production.gguf" 8192 18080
}

presets_policy=$work/presets-policy.ini
if QWEN_MODEL_ROOT=$policy_model_root build "$web_profiles_ok" "$presets_policy" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/policy-build.log" 2>"$work/policy-build.err"; then
    if run_policy_over_presets "$presets_policy" \
        >"$work/policy.log" 2>"$work/policy.err"; then
        report generated_preset_passes_capacity_policy ok
    else
        report generated_preset_passes_capacity_policy failed
        cat "$work/policy.err" >&2
    fi
else
    report generated_preset_passes_capacity_policy build_failed
    cat "$work/policy-build.err" >&2
fi

# A ui-mediated section carries no LLAMA_ARG_MCP_SERVERS_CONFIG and a
# validator-gated one does, so a file holding both proves the policy reads the
# tuple keys and leaves the MCP key to the generator.
mkdir -p "$work/mixed-out"
web_profiles_mixed=$work/web-profiles-mixed.tsv
{
    printf 'web-fixture-gated\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n'
    printf 'web-fixture-ui\tfixture-candidate-validated\tui-mediated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tui-mediated\texa\t-\t-\t-\t-\n'
} >"$web_profiles_mixed"
presets_mixed=$work/mixed-out/presets-mixed.ini
if QWEN_MODEL_ROOT=$policy_model_root build "$web_profiles_mixed" \
    "$presets_mixed" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/mixed-build.log" 2>"$work/mixed-build.err"; then
    if run_policy_over_presets "$presets_mixed" "$web_profiles_mixed" \
        >"$work/mixed-policy.log" 2>"$work/mixed-policy.err"; then
        mixed_outcome=ok
        grep -q '^\[web-fixture-gated\]' "$presets_mixed" ||
            mixed_outcome=gated_section_absent
        grep -q '^\[web-fixture-ui\]' "$presets_mixed" ||
            mixed_outcome=ui_section_absent
        [ "$(grep -c '^LLAMA_ARG_MCP_SERVERS_CONFIG' "$presets_mixed")" = 1 ] ||
            mixed_outcome=wrong_mcp_key_count
        report mixed_policy_preset_passes_capacity_policy "$mixed_outcome"
    else
        report mixed_policy_preset_passes_capacity_policy failed
        cat "$work/mixed-policy.err" >&2
    fi
else
    report mixed_policy_preset_passes_capacity_policy build_failed
    cat "$work/mixed-build.err" >&2
fi

# The generated preset binds the path and complete digest of the source ledger,
# so substituting a revoked ledger refuses before any subset join.
revoked_profiles=$work/web-profiles-revoked.tsv
printf 'web-fixture-ok\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\t-\t-\t-\t-\n' \
    >"$revoked_profiles"
if run_policy_over_presets "$presets_policy" "$revoked_profiles" \
    >"$work/revoked-policy.log" 2>"$work/revoked-policy.err"; then
    report policy_refuses_revoked_web_profile accepted
else
    outcome=ok
    grep -q 'QWEN_WEB_PROFILES names .* where the preset binds' \
        "$work/revoked-policy.err" ||
        outcome=missing_message
    report policy_refuses_revoked_web_profile "$outcome"
fi

# A misspelled or absent tuple key fails that same validation. Each key is
# removed in turn, so the arm proves the validator reads every one rather than
# reading the file's first line.
for required_key in LLAMA_ARG_MODEL LLAMA_ARG_CTX_SIZE LLAMA_ARG_BATCH \
    LLAMA_ARG_UBATCH LLAMA_ARG_CACHE_TYPE_K LLAMA_ARG_CACHE_TYPE_V \
    LLAMA_ARG_FLASH_ATTN; do
    broken_presets=$work/presets-without-$required_key.ini
    sed "/^$required_key =/d" "$presets_policy" >"$broken_presets"
    if run_policy_over_presets "$broken_presets" \
        >"$work/broken.log" 2>"$work/broken.err"; then
        report "policy_rejects_missing_$required_key" accepted
    else
        report "policy_rejects_missing_$required_key" ok
    fi
done

# A key spelled in the CLI style the deployed router format leaves unread is a
# missing key, which is the defect this generator carried.
cli_style_presets=$work/presets-cli-style.ini
sed 's/^LLAMA_ARG_UBATCH =/ubatch-size =/' "$presets_policy" >"$cli_style_presets"
if run_policy_over_presets "$cli_style_presets" \
    >"$work/cli-style.log" 2>"$work/cli-style.err"; then
    report policy_rejects_cli_style_key accepted
else
    report policy_rejects_cli_style_key ok
fi

# execution_policy decides emission. A refused row emits nothing under every
# setting, which is the boundary no override crosses.
web_profiles_refused=$work/web-profiles-refused.tsv
printf 'web-fixture-refused\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_refused"
presets_refused=$work/presets-refused.ini
if build "$web_profiles_refused" "$presets_refused" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/refused.log" 2>"$work/refused.err"; then
    report refused_policy_emits_nothing emitted_a_section
else
    outcome=ok
    grep -q 'web_preset_skipped profile=web-fixture-refused execution_policy=refused' \
        "$work/refused.err" || outcome=missing_skip_line
    [ -f "$presets_refused" ] && grep -q '^\[web-fixture-refused\]' "$presets_refused" &&
        outcome=section_present
    report refused_policy_emits_nothing "$outcome"
fi

# The authorizer marker admits no refused row, so the same ledger emits nothing
# with the marker set.
presets_refused_marked=$work/presets-refused-marked.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_refused \
    QWEN_WEB_AUTHORIZER_READY=1 QWEN_WEB_ALLOW_UNVALIDATED_DEPTH=1 \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_refused_marked" \
    >"$work/refused-marked.log" 2>"$work/refused-marked.err"; then
    report refused_policy_survives_every_override emitted_a_section
else
    report refused_policy_survives_every_override ok
fi

# A validator-gated row emits only where the authorizer marker asserts the
# argument-authorization path runs.
web_profiles_gated=$work/web-profiles-gated.tsv
printf 'web-fixture-gated\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_gated"
presets_gated_absent=$work/presets-gated-absent.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_gated \
    env -u QWEN_WEB_AUTHORIZER_READY QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_gated_absent" \
    >"$work/gated-absent.log" 2>"$work/gated-absent.err"; then
    report validator_gated_withheld_without_authorizer emitted_a_section
else
    outcome=ok
    grep -q 'execution_policy=validator-gated authorizer=absent' \
        "$work/gated-absent.err" || outcome=missing_skip_line
    report validator_gated_withheld_without_authorizer "$outcome"
fi

mkdir -p "$work/gated-out"
presets_gated=$work/gated-out/presets-gated.ini
if build "$web_profiles_gated" "$presets_gated" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/gated.log" 2>"$work/gated.err"; then
    outcome=ok
    grep -q '^LLAMA_ARG_MCP_SERVERS_CONFIG = ' "$presets_gated" ||
        outcome=missing_mcp_key
    grep -q '^LLAMA_ARG_TAGS = web-research,validator-gated$' "$presets_gated" ||
        outcome=wrong_tags
    report validator_gated_emits_with_authorizer "$outcome"
else
    report validator_gated_emits_with_authorizer failed
    cat "$work/gated.err" >&2
fi

# A ui-mediated row emits a section the server runs no MCP client from, so the
# retrieval stays in the web UI.
web_profiles_ui=$work/web-profiles-ui.tsv
printf 'web-fixture-ui\tfixture-production\tui-mediated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tui-mediated\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_ui"
presets_ui=$work/presets-ui.ini
if build "$web_profiles_ui" "$presets_ui" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/ui.log" 2>"$work/ui.err"; then
    outcome=ok
    grep -q '^LLAMA_ARG_MCP_SERVERS_CONFIG' "$presets_ui" && outcome=mcp_key_present
    grep -q '^LLAMA_ARG_TAGS = web-research,ui-mediated$' "$presets_ui" ||
        outcome=wrong_tags
    report ui_mediated_emits_without_mcp_config "$outcome"
else
    report ui_mediated_emits_without_mcp_config failed
    cat "$work/ui.err" >&2
fi

# A ui-mediated row emits without the authorizer marker: the marker gates the
# server's own tool execution, which a ui-mediated section never performs.
presets_ui_unmarked=$work/presets-ui-unmarked.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_ui \
    QWEN_MODEL_ROOT=$policy_model_root \
    env -u QWEN_WEB_AUTHORIZER_READY QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_ui_unmarked" \
    >"$work/ui-unmarked.log" 2>"$work/ui-unmarked.err"; then
    report ui_mediated_emits_without_authorizer ok
else
    report ui_mediated_emits_without_authorizer failed
    cat "$work/ui-unmarked.err" >&2
fi

# An execution_policy outside the vocabulary stops the run: the ledger states a
# policy the generator has no rule for.
web_profiles_unknown_policy=$work/web-profiles-unknown-policy.tsv
printf 'web-fixture-unknown-policy\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tunguarded\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_unknown_policy"
presets_unknown_policy=$work/presets-unknown-policy.ini
if build "$web_profiles_unknown_policy" "$presets_unknown_policy" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/unknown-policy.log" 2>"$work/unknown-policy.err"; then
    report unknown_execution_policy_refused emitted_a_section
else
    outcome=ok
    grep -q 'outside the vocabulary' "$work/unknown-policy.err" ||
        outcome=missing_vocabulary_message
    report unknown_execution_policy_refused "$outcome"
fi

# Every numeric field is validated before it is compared, so a malformed value
# stops the run naming the field and the profile. The ledger row below is well
# formed except in the one field each arm rewrites.
emit_numeric_fixture() {
    # profile_id model_id web_mode context depth results fetches chars ...
    printf 'web-fixture-numeric\tfixture-production\tvalidator-gated\t%s\t%s\t%s\t%s\t%s\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n' \
        "$1" "$2" "$3" "$4" "$5"
}

check_numeric_field_refused() {
    numeric_case_name=$1
    shift
    numeric_profiles=$work/web-profiles-numeric-$numeric_case_name.tsv
    emit_numeric_fixture "$@" >"$numeric_profiles"
    numeric_presets=$work/presets-numeric-$numeric_case_name.ini
    if build "$numeric_profiles" "$numeric_presets" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
        >"$work/numeric-$numeric_case_name.log" \
        2>"$work/numeric-$numeric_case_name.err"; then
        report "numeric_${numeric_case_name}_refused" emitted_a_section
        return
    fi
    if grep -q 'web-fixture-numeric' "$work/numeric-$numeric_case_name.err"; then
        report "numeric_${numeric_case_name}_refused" ok
    else
        report "numeric_${numeric_case_name}_refused" message_omits_profile
    fi
}

check_numeric_field_refused context_text abc 8192 5 2 12000
check_numeric_field_refused context_leading_zero 08192 8192 5 2 12000
check_numeric_field_refused context_empty '' 8192 5 2 12000
check_numeric_field_refused context_sentinel - 8192 5 2 12000
check_numeric_field_refused ledger_depth_text 8192 later 5 2 12000
check_numeric_field_refused ledger_depth_leading_zero 8192 08192 5 2 12000
check_numeric_field_refused max_results_text 8192 8192 many 2 12000
check_numeric_field_refused max_results_zero 8192 8192 0 2 12000
check_numeric_field_refused max_fetches_leading_zero 8192 8192 5 02 12000
check_numeric_field_refused max_chars_negative 8192 8192 5 2 -12000

# multi_source and max_fetches state one retrieval budget twice, so the ledger
# holds them as a biconditional and the generator refuses both directions. A
# `no` row above one fetch emits a configuration granting every fetch while the
# ledger denies the combination, and a `yes` row at one fetch claims a
# combination one fetch cannot make.
check_multi_source_refused() {
    multi_case_name=$1
    multi_source_value=$2
    multi_fetches=$3
    multi_policy=${4:-validator-gated}
    multi_profiles=$work/web-profiles-multi-$multi_case_name.tsv
    printf 'web-fixture-multi\tfixture-production\tvalidator-gated\t8192\t8192\t5\t%s\t12000\t%s\tno\t9/10\t%s\texa\t-\t-\t-\t-\n' \
        "$multi_fetches" "$multi_source_value" "$multi_policy" >"$multi_profiles"
    multi_presets=$work/presets-multi-$multi_case_name.ini
    if build "$multi_profiles" "$multi_presets" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
        >"$work/multi-$multi_case_name.log" \
        2>"$work/multi-$multi_case_name.err"; then
        report "multi_source_${multi_case_name}_refused" emitted_a_section
        return
    fi
    if grep -q 'multi_source' "$work/multi-$multi_case_name.err"; then
        report "multi_source_${multi_case_name}_refused" ok
    else
        report "multi_source_${multi_case_name}_refused" message_omits_field
    fi
}

check_multi_source_refused no_above_one_fetch no 3
check_multi_source_refused yes_at_one_fetch yes 1
check_multi_source_refused outside_vocabulary maybe 2
# The ledger is one claimed policy document, so a refused row meets the
# invariant an emitting row meets.
check_multi_source_refused refused_row no 3 refused

# The two admitted spellings pass: one fetch reads `no` and several read `yes`.
multi_source_ok_profiles=$work/web-profiles-multi-ok.tsv
printf 'web-fixture-multi-single\tfixture-production\tui-mediated\t8192\t8192\t5\t1\t12000\tno\tno\t9/10\tui-mediated\texa\t-\t-\t-\t-\n' \
    >"$multi_source_ok_profiles"
multi_source_ok_presets=$work/presets-multi-ok.ini
if build "$multi_source_ok_profiles" "$multi_source_ok_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/multi-ok.log" 2>"$work/multi-ok.err"; then
    report single_fetch_reads_multi_source_no ok
else
    report single_fetch_reads_multi_source_no failed
    cat "$work/multi-ok.err" >&2
fi

# The sentinel stands where the registry defines the unmeasured state, so a
# ledger validated_filled_depth of `-` matching its registry row is admitted by
# the numeric rule. The depth override carries it past the unmeasured-depth
# refusal, which is a separate rule with its own arms above.
numeric_sentinel_profiles=$work/web-profiles-numeric-sentinel.tsv
printf 'web-fixture-sentinel\tfixture-candidate-unknown\tvalidator-gated\t8192\t-\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n' \
    >"$numeric_sentinel_profiles"
numeric_sentinel_presets=$work/presets-numeric-sentinel.ini
if build "$numeric_sentinel_profiles" "$numeric_sentinel_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" QWEN_WEB_ALLOW_UNVALIDATED_DEPTH=1 \
    >"$work/numeric-sentinel.log" 2>"$work/numeric-sentinel.err"; then
    report ledger_depth_sentinel_admitted ok
else
    report ledger_depth_sentinel_admitted refused
    cat "$work/numeric-sentinel.err" >&2
fi

# scripts/models.tsv is the authority for validated_filled_depth,
# vision_allowed, and tool_selection, so a ledger copy that diverges stops the
# run naming the profile, the field, and both values.
check_divergent_field_refused() {
    divergent_case_name=$1
    divergent_row=$2
    divergent_needle=$3
    divergent_profiles=$work/web-profiles-divergent-$divergent_case_name.tsv
    printf '%s\n' "$divergent_row" >"$divergent_profiles"
    divergent_presets=$work/presets-divergent-$divergent_case_name.ini
    if build "$divergent_profiles" "$divergent_presets" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
        >"$work/divergent-$divergent_case_name.log" \
        2>"$work/divergent-$divergent_case_name.err"; then
        report "divergent_${divergent_case_name}_refused" emitted_a_section
        return
    fi
    divergent_outcome=ok
    grep -q "$divergent_needle" "$work/divergent-$divergent_case_name.err" ||
        divergent_outcome=message_omits_values
    grep -q 'web-fixture-divergent' "$work/divergent-$divergent_case_name.err" ||
        divergent_outcome=message_omits_profile
    report "divergent_${divergent_case_name}_refused" "$divergent_outcome"
}

# fixture-production reads validated_filled_depth 8192, projector none, and
# raw_tool_selection 9/10; each row below diverges in one of the three.
check_divergent_field_refused validated_filled_depth \
    "$(printf 'web-fixture-divergent\tfixture-production\tvalidator-gated\t8192\t16384\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-')" \
    'validated_filled_depth 16384 where model fixture-production carries 8192'
check_divergent_field_refused vision_allowed \
    "$(printf 'web-fixture-divergent\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tyes\t9/10\tvalidator-gated\texa\t-\t-\t-\t-')" \
    'vision_allowed yes where model fixture-production carries no'
check_divergent_field_refused tool_selection \
    "$(printf 'web-fixture-divergent\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t2/10\tvalidator-gated\texa\t-\t-\t-\t-')" \
    'tool_selection 2/10 where model fixture-production carries 9/10'

# A registry-side numeric field is validated on the same rule, so a malformed
# batch stops the run rather than reaching the emitted geometry.
malformed_registry=$work/models-malformed-batch.tsv
sed 's/^\(fixture-production\t.*untested\tproduction\t\)128\t/\10128\t/' \
    "$model_registry" >"$malformed_registry"
malformed_registry_presets=$work/presets-malformed-batch.ini
if QWEN_MODEL_REGISTRY=$malformed_registry \
    QWEN_WEB_PROFILES=$web_profiles_ok QWEN_WEB_AUTHORIZER_READY=1 \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$malformed_registry_presets" \
    >"$work/malformed-batch.log" 2>"$work/malformed-batch.err"; then
    report registry_batch_leading_zero_refused emitted_a_section
else
    outcome=ok
    grep -q 'batch outside canonical positive decimal form: 0128' \
        "$work/malformed-batch.err" || outcome=message_omits_field
    report registry_batch_leading_zero_refused "$outcome"
fi

# One MCP configuration per emitting profile, carrying the profile's own
# budgets. The gated fixture emits one section, so its configuration is the
# subject.
# The configuration directory carries a version id derived from the inputs, so
# the emitted section rather than a fixed path names the file under test.
gated_mcp_config=$(sed -n \
    's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$presets_gated")
mcp_configs=$(dirname -- "$gated_mcp_config")

mcp_outcome=ok
[ -f "$gated_mcp_config" ] || mcp_outcome=config_absent
if [ "$mcp_outcome" = ok ]; then
    grep -q '"QWEN_WEB_PROFILE": "web-fixture-gated"' "$gated_mcp_config" ||
        mcp_outcome=missing_profile
    grep -q '"QWEN_WEB_MAX_RESULTS": "5"' "$gated_mcp_config" ||
        mcp_outcome=missing_max_results
    grep -q '"QWEN_WEB_MAX_FETCHES_PER_SEARCH": "2"' "$gated_mcp_config" ||
        mcp_outcome=missing_max_fetches
    grep -q '"QWEN_WEB_MAX_CHARS_PER_FETCH": "12000"' "$gated_mcp_config" ||
        mcp_outcome=missing_max_chars
    grep -q '"QWEN_WEB_SEARCH_AUTH": "required"' "$gated_mcp_config" ||
        mcp_outcome=missing_search_auth
    grep -q '"QWEN_WEB_STATE_DIR"' "$gated_mcp_config" ||
        mcp_outcome=missing_state_dir
    grep -q '"QWEN_WEB_EXA_KEY_FILE"' "$gated_mcp_config" ||
        mcp_outcome=missing_key_file_path
fi
report mcp_config_carries_profile_budgets "$mcp_outcome"

# The section points at a generated file under the output directory's own
# versioned configuration tree rather than at a path the caller supplied.
case $gated_mcp_config in
    "$work"/gated-out/web-mcp-configs-*/web-fixture-gated.json)
        report mcp_config_path_reaches_section ok
        ;;
    *)
        report mcp_config_path_reaches_section wrong_path
        ;;
esac

# The configuration parses as JSON, so the server reads what the generator
# meant rather than a file whose commas decide it.
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$gated_mcp_config" >/dev/null 2>&1; then
    report mcp_config_parses_as_json ok
else
    report mcp_config_parses_as_json malformed
fi

# A generated configuration carries key-file paths and never key contents. The
# check reads every env value: a *_KEY_FILE value must be an absolute path that
# names no file the run can read as a secret, and every other env key must come
# from the declared set. Its limit is that it recognises a secret by the shape
# of the value and by the fixture contents it knows, so a credential that
# happens to look like an absolute path, or one smuggled into a path component,
# passes; what it does catch is a key file's contents inlined where its path
# belongs, which is the substitution that turns a persisted preset tree into a
# credential store.
undeclared_env_keys() {
    python3 - "$1" <<'PYTHON'
import json
import sys

admitted = {
    "QWEN_WEB_PROFILE",
    "QWEN_WEB_PROVIDER",
    "QWEN_WEB_MAX_RESULTS",
    "QWEN_WEB_MAX_FETCHES_PER_SEARCH",
    "QWEN_WEB_MAX_CHARS_PER_FETCH",
    "QWEN_WEB_SEARCH_AUTH",
    "QWEN_WEB_EXA_KEY_FILE",
    "QWEN_WEB_FAKE_FIXTURES",
    "QWEN_WEB_SEARXNG_URL",
    "QWEN_WEB_SEARXNG_PRIMARY_CATEGORY",
    "QWEN_WEB_SEARXNG_FALLBACK_CATEGORY",
    "QWEN_WEB_SEARXNG_MINIMUM_RESULTS",
    "QWEN_WEB_SEARXNG_LANGUAGE",
    "QWEN_WEB_SEARXNG_SAFESEARCH",
    "QWEN_WEB_SEARXNG_ALLOW_REMOTE",
    "QWEN_WEB_TOKEN_KEY_FILE",
    "QWEN_WEB_STATE_DIR",
}
document = json.load(open(sys.argv[1]))
environment = document["mcpServers"]["web"]["env"]
for name, value in environment.items():
    if name not in admitted:
        print("undeclared env key: %s" % name)
    if name.endswith("_KEY_FILE") and not value.startswith("/"):
        print("key file value is no absolute path: %s" % name)
PYTHON
}

secret_leak_outcome=ok
for generated_config in "$mcp_configs"/*.json; do
    [ -f "$generated_config" ] || continue
    if grep -q 'fixture-search-secret-value\|fixture-token-secret-value' \
        "$generated_config"; then
        secret_leak_outcome=key_contents_present
        break
    fi
    unexpected_key=$(undeclared_env_keys "$generated_config") || unexpected_key='config unreadable'
    if [ -n "$unexpected_key" ]; then
        secret_leak_outcome=$unexpected_key
        break
    fi
done
report mcp_config_carries_paths_only "$secret_leak_outcome"

# A ui-mediated profile performs its retrieval in the UI, so its section names
# no configuration and the run writes none.
if grep -q '^LLAMA_ARG_MCP_SERVERS_CONFIG' "$presets_ui"; then
    report ui_mediated_section_names_no_mcp_config key_present
else
    report ui_mediated_section_names_no_mcp_config ok
fi

# QWEN_WEB_PROVIDER fake reaches no network, so it requires
# QWEN_WEB_FAKE_FIXTURES rather than a search key file: the generated section
# carries the fixture path under QWEN_WEB_FAKE_FIXTURES and names no
# QWEN_WEB_EXA_KEY_FILE, and the build succeeds with no search key file set.
fake_fixtures_file=$work/private/fake-fixtures.json
printf '{"search": {}, "contents": {}}\n' >"$fake_fixtures_file"
web_profiles_fake=$work/web-profiles-fake.tsv
cat >"$web_profiles_fake" <<'EOF'
web-fixture-fake	fixture-production	validator-gated	8192	8192	5	2	12000	yes	no	9/10	validator-gated	fake	-	-	-	-
EOF

# A profile row names the backend it expects, so an arm that varies
# QWEN_WEB_PROVIDER carries its own ledger. The searxng rows also name the
# category policy the emitted configuration must carry.
web_profiles_searxng=$work/web-profiles-searxng.tsv
cat >"$web_profiles_searxng" <<'EOF'
web-fixture-searxng	fixture-production	validator-gated	8192	8192	5	2	12000	yes	no	9/10	validator-gated	searxng	qwen-open	qwen-broad	3	http://127.0.0.1:8888
EOF

web_profiles_searxng_no_fallback=$work/web-profiles-searxng-no-fallback.tsv
cat >"$web_profiles_searxng_no_fallback" <<'EOF'
web-fixture-searxng	fixture-production	validator-gated	8192	8192	5	2	12000	yes	no	9/10	validator-gated	searxng	qwen-yacy	-	1	http://127.0.0.1:8888
EOF

presets_fake=$work/presets-fake.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_fake \
    QWEN_MODEL_ROOT=$policy_model_root QWEN_WEB_AUTHORIZER_READY=1 \
    env -u QWEN_WEB_SEARCH_KEY_FILE QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_PROVIDER=fake QWEN_WEB_FAKE_FIXTURES="$fake_fixtures_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_fake" \
    >"$work/fake-provider.log" 2>"$work/fake-provider.err"; then
    fake_mcp_config=$(sed -n \
        's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$presets_fake")
    fake_outcome=ok
    [ -f "$fake_mcp_config" ] || fake_outcome=config_absent
    if [ "$fake_outcome" = ok ]; then
        grep -q "\"QWEN_WEB_FAKE_FIXTURES\": \"$fake_fixtures_file\"" \
            "$fake_mcp_config" || fake_outcome=missing_fixtures_path
        if grep -q '"QWEN_WEB_EXA_KEY_FILE"' "$fake_mcp_config"; then
            fake_outcome=key_file_present
        fi
    fi
    report fake_provider_emits_fixtures_without_key_file "$fake_outcome"
else
    cat "$work/fake-provider.err" >&2
    report fake_provider_emits_fixtures_without_key_file build_failed
fi

# QWEN_WEB_PROVIDER fake with QWEN_WEB_FAKE_FIXTURES unset names no fixture
# file, so the build refuses the row rather than emitting a section the fake
# provider cannot serve.
presets_fake_missing=$work/presets-fake-missing.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_fake \
    QWEN_MODEL_ROOT=$policy_model_root QWEN_WEB_AUTHORIZER_READY=1 \
    env -u QWEN_WEB_SEARCH_KEY_FILE -u QWEN_WEB_FAKE_FIXTURES \
    QWEN_WEB_MCP_SERVER="$mcp_server_program" QWEN_WEB_PROVIDER=fake \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_fake_missing" \
    >"$work/fake-provider-missing.log" 2>"$work/fake-provider-missing.err"; then
    report fake_provider_without_fixtures_refused accepted
else
    report fake_provider_without_fixtures_refused ok
fi

# QWEN_WEB_PROVIDER searxng reaches an unauthenticated instance, so the profile
# row rather than a key file supplies what the child needs: the generated
# section carries the instance URL and the category policy the row names, names
# no QWEN_WEB_EXA_KEY_FILE, and the build succeeds with no search key file set.
presets_searxng=$work/presets-searxng.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_searxng \
    QWEN_MODEL_ROOT=$policy_model_root QWEN_WEB_AUTHORIZER_READY=1 \
    env -u QWEN_WEB_SEARCH_KEY_FILE QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_PROVIDER=searxng \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_searxng" \
    >"$work/searxng-provider.log" 2>"$work/searxng-provider.err"; then
    searxng_mcp_config=$(sed -n \
        's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$presets_searxng")
    searxng_outcome=ok
    [ -f "$searxng_mcp_config" ] || searxng_outcome=config_absent
    if [ "$searxng_outcome" = ok ]; then
        grep -q '"QWEN_WEB_SEARXNG_URL": "http://127.0.0.1:8888"' \
            "$searxng_mcp_config" || searxng_outcome=missing_instance_url
        grep -q '"QWEN_WEB_SEARXNG_PRIMARY_CATEGORY": "qwen-open"' \
            "$searxng_mcp_config" || searxng_outcome=missing_primary_category
        grep -q '"QWEN_WEB_SEARXNG_FALLBACK_CATEGORY": "qwen-broad"' \
            "$searxng_mcp_config" || searxng_outcome=missing_fallback_category
        grep -q '"QWEN_WEB_SEARXNG_MINIMUM_RESULTS": "3"' \
            "$searxng_mcp_config" || searxng_outcome=missing_minimum_results
        grep -q '"QWEN_WEB_PROVIDER": "searxng"' \
            "$searxng_mcp_config" || searxng_outcome=missing_provider_name
        if grep -q '"QWEN_WEB_EXA_KEY_FILE"' "$searxng_mcp_config"; then
            searxng_outcome=key_file_present
        fi
        if grep -q '"QWEN_WEB_SEARXNG_LANGUAGE"' "$searxng_mcp_config"; then
            searxng_outcome=unset_name_emitted
        fi
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
            "$searxng_mcp_config" >/dev/null 2>&1 ||
            searxng_outcome=config_unparseable
        # The declared-key check runs over this branch's own configuration,
        # since the shared directory the leak loop walks holds the exa arms
        # alone and a searxng name absent from the admitted set would pass
        # unread.
        searxng_undeclared=$(undeclared_env_keys "$searxng_mcp_config") ||
            searxng_undeclared='config unreadable'
        [ -z "$searxng_undeclared" ] || searxng_outcome=$searxng_undeclared
    fi
    report searxng_profile_row_carries_the_category_policy "$searxng_outcome"
else
    cat "$work/searxng-provider.err" >&2
    report searxng_profile_row_carries_the_category_policy build_failed
fi

# A row naming no fallback carries the sentinel through to the child, which
# reads it as the absence of a second query rather than as a category name.
presets_searxng_solo=$work/presets-searxng-solo.ini
if QWEN_MODEL_REGISTRY=$model_registry \
    QWEN_WEB_PROFILES=$web_profiles_searxng_no_fallback \
    QWEN_MODEL_ROOT=$policy_model_root QWEN_WEB_AUTHORIZER_READY=1 \
    env -u QWEN_WEB_SEARCH_KEY_FILE QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_PROVIDER=searxng \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_searxng_solo" \
    >"$work/searxng-solo.log" 2>"$work/searxng-solo.err"; then
    searxng_solo_config=$(sed -n \
        's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$presets_searxng_solo")
    searxng_solo_outcome=ok
    grep -q '"QWEN_WEB_SEARXNG_PRIMARY_CATEGORY": "qwen-yacy"' \
        "$searxng_solo_config" || searxng_solo_outcome=missing_primary_category
    grep -q '"QWEN_WEB_SEARXNG_FALLBACK_CATEGORY": "-"' \
        "$searxng_solo_config" || searxng_solo_outcome=missing_fallback_sentinel
    report searxng_absent_fallback_reaches_the_child "$searxng_solo_outcome"
else
    cat "$work/searxng-solo.err" >&2
    report searxng_absent_fallback_reaches_the_child build_failed
fi

# A row states which backend it expects, so a generator run under another
# provider refuses it rather than emitting a section the launch would serve
# under a backend the ledger never claimed.
presets_provider_drift=$work/presets-provider-drift.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_searxng \
    QWEN_MODEL_ROOT=$policy_model_root QWEN_WEB_AUTHORIZER_READY=1 \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_provider_drift" \
    >"$work/provider-drift.log" 2>"$work/provider-drift.err"; then
    report searxng_row_under_another_provider_refused accepted
elif grep -q 'names provider searxng where the run serves exa' \
    "$work/provider-drift.err"; then
    report searxng_row_under_another_provider_refused ok
else
    report searxng_row_under_another_provider_refused refused_without_naming_provider
fi

# The search policy is validated for every row whatever its execution_policy,
# so a malformed category, a non-loopback instance, and a minimum above the
# row's own result count each stop the run and name the profile.
searxng_policy_outcome=ok
for searxng_bad_row in \
    'searxng	qwen open	-	1	http://127.0.0.1:8888' \
    'searxng	-	-	1	http://127.0.0.1:8888' \
    'searxng	qwen-open	-	1	http://searxng.example.org' \
    'searxng	qwen-open	-	9	http://127.0.0.1:8888' \
    'searxng	qwen-open	qwen broad	1	http://127.0.0.1:8888'; do
    searxng_bad_ledger=$work/web-profiles-searxng-bad.tsv
    printf 'web-fixture-bad\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\trefused\t%s\n' \
        "$searxng_bad_row" >"$searxng_bad_ledger"
    if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$searxng_bad_ledger \
        QWEN_MODEL_ROOT=$policy_model_root \
        env -u QWEN_WEB_SEARCH_KEY_FILE QWEN_WEB_MCP_SERVER="$mcp_server_program" \
        QWEN_WEB_PROVIDER=searxng \
        QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
        "$builder" "$work/presets-searxng-bad.ini" \
        >"$work/searxng-bad.log" 2>"$work/searxng-bad.err"; then
        searxng_policy_outcome="accepted: $searxng_bad_row"
        break
    fi
    grep -q 'web-fixture-bad' "$work/searxng-bad.err" ||
        searxng_policy_outcome="refused_without_naming_profile: $searxng_bad_row"
done
report searxng_malformed_search_policy_refused "$searxng_policy_outcome"

# A row under provider exa or fake carries no search policy, so a value in one
# of the four columns states a policy that backend never reads.
searxng_stray_ledger=$work/web-profiles-stray-policy.tsv
printf 'web-fixture-stray\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\tqwen-open\t-\t-\t-\n' \
    >"$searxng_stray_ledger"
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$searxng_stray_ledger \
    QWEN_MODEL_ROOT=$policy_model_root \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$work/presets-stray-policy.ini" \
    >"$work/stray-policy.log" 2>"$work/stray-policy.err"; then
    report search_policy_under_a_keyed_provider_refused accepted
else
    report search_policy_under_a_keyed_provider_refused ok
fi

# A path holding a double quote would change the parsed JSON value, so the run
# refuses it.
presets_quoted_path=$work/presets-quoted-path.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_gated \
    QWEN_WEB_AUTHORIZER_READY=1 \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE='/private/exa".key' \
    "$builder" "$presets_quoted_path" \
    >"$work/quoted-path.log" 2>"$work/quoted-path.err"; then
    report json_unsafe_key_path_refused accepted
else
    report json_unsafe_key_path_refused ok
fi

# Output is atomic. A run that fails on a late row leaves a previously generated
# preset file byte-identical and leaves no temporary behind.
mkdir -p "$work/atomic-out"
atomic_presets=$work/atomic-out/presets.ini
printf 'seeded preset content that a failing run leaves alone\n' >"$atomic_presets"
atomic_digest_before=$(sha256sum "$atomic_presets" | cut -d' ' -f1)

# The first row emits and the second fails, so the failure arrives after the
# temporary file already carries a section.
web_profiles_late_failure=$work/web-profiles-late-failure.tsv
{
    printf 'web-fixture-first\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n'
    printf 'web-fixture-second\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tunguarded\texa\t-\t-\t-\t-\n'
} >"$web_profiles_late_failure"

if build "$web_profiles_late_failure" "$atomic_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/late-failure.log" 2>"$work/late-failure.err"; then
    report late_row_failure_refused emitted_a_file
else
    report late_row_failure_refused ok
fi

atomic_digest_after=$(sha256sum "$atomic_presets" | cut -d' ' -f1)
if [ "$atomic_digest_before" = "$atomic_digest_after" ]; then
    report existing_output_survives_late_failure ok
else
    report existing_output_survives_late_failure overwritten
fi

residue=$(find "$work/atomic-out" -name 'presets.ini.tmp.*' -o \
    -name 'web-mcp-configs.tmp.*' 2>/dev/null)
if [ -z "$residue" ]; then
    report temporary_output_removed_after_failure ok
else
    report temporary_output_removed_after_failure "$residue"
fi

# A ledger whose every row withholds an executing policy leaves the previous
# file alone for the same reason.
web_profiles_all_refused=$work/web-profiles-all-refused.tsv
printf 'web-fixture-all-refused\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_all_refused"
if build "$web_profiles_all_refused" "$atomic_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/all-refused.log" 2>"$work/all-refused.err"; then
    report empty_emission_refused emitted_a_file
else
    report empty_emission_refused ok
fi

if [ "$(sha256sum "$atomic_presets" | cut -d' ' -f1)" = "$atomic_digest_before" ]; then
    report existing_output_survives_empty_emission ok
else
    report existing_output_survives_empty_emission overwritten
fi

# A successful run replaces the file, so the atomicity arms above measure the
# refusal rather than a generator that never writes.
if build "$web_profiles_gated" "$atomic_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/atomic-success.log" 2>"$work/atomic-success.err"; then
    if [ "$(sha256sum "$atomic_presets" | cut -d' ' -f1)" = "$atomic_digest_before" ]; then
        report successful_run_replaces_output unchanged
    else
        report successful_run_replaces_output ok
    fi
else
    report successful_run_replaces_output failed
    cat "$work/atomic-success.err" >&2
fi

# A profile_id names a path component, an INI section, and the served alias. A
# traversal component would place the MCP configuration outside the temporary
# tree and overwrite an unrelated JSON file, which the assembled-file check
# never sees, so the vocabulary refuses it before any path is constructed.
mkdir -p "$work/traversal-out"
victim_json=$work/traversal-out/victim.json
printf '{"victim":true}\n' >"$victim_json"
victim_digest_before=$(sha256sum "$victim_json" | cut -d' ' -f1)
web_profiles_traversal=$work/web-profiles-traversal.tsv
printf '../victim\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_traversal"
if build "$web_profiles_traversal" "$work/traversal-out/presets.ini" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/traversal.log" 2>"$work/traversal.err"; then
    report traversal_profile_id_refused accepted
else
    report traversal_profile_id_refused ok
fi
if [ "$(sha256sum "$victim_json" | cut -d' ' -f1)" = "$victim_digest_before" ]; then
    report traversal_leaves_neighbour_file_intact ok
else
    report traversal_leaves_neighbour_file_intact overwritten
fi

# A bracket, a space, a slash, or a leading hyphen spells a section name the
# preset reader parses differently than the generator wrote it.
for noncanonical_id in 'web]fixture[x' 'web fixture' '-web-fixture' 'web/fixture'; do
    noncanonical_profiles=$work/web-profiles-noncanonical.tsv
    printf '%s\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n' \
        "$noncanonical_id" >"$noncanonical_profiles"
    if build "$noncanonical_profiles" "$work/presets-noncanonical.ini" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
        QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
        QWEN_WEB_STATE_DIR="$web_state_directory" \
        >"$work/noncanonical.log" 2>"$work/noncanonical.err"; then
        report noncanonical_profile_id_refused "accepted_$noncanonical_id"
    else
        report noncanonical_profile_id_refused ok
    fi
done

# Two rows of one profile_id write two sections of one name, and the second
# row's budgets own the single configuration file both point at.
web_profiles_duplicate=$work/web-profiles-duplicate.tsv
{
    printf 'web-fixture-dup\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n'
    printf 'web-fixture-dup\tfixture-candidate-validated\tvalidator-gated\t8192\t8192\t7\t3\t9000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n'
} >"$web_profiles_duplicate"
if build "$web_profiles_duplicate" "$work/presets-duplicate.ini" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/duplicate.log" 2>"$work/duplicate.err"; then
    report duplicate_profile_id_refused accepted
elif grep -q 'repeats profile_id web-fixture-dup' "$work/duplicate.err"; then
    report duplicate_profile_id_refused ok
else
    report duplicate_profile_id_refused message_omits_profile
fi

# RFC 8259 section 7 admits an unescaped character above U+001F apart from the
# quotation mark and the reverse solidus, so a path holding a newline or a tab
# emits a file no parser reads while the INI check still passes. The generator
# refuses the character instead.
for control_path_case in newline tab; do
    case $control_path_case in
        newline) control_key_file=$(printf '/private/exa\nkey') ;;
        tab) control_key_file=$(printf '/private/exa\tkey') ;;
    esac
    if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_gated \
        QWEN_WEB_AUTHORIZER_READY=1 \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
        QWEN_WEB_SEARCH_KEY_FILE="$control_key_file" \
        "$builder" "$work/presets-control-path.ini" \
        >"$work/control-path.log" 2>"$work/control-path.err"; then
        report "json_control_${control_path_case}_path_refused" accepted
    else
        report "json_control_${control_path_case}_path_refused" ok
    fi
done

# The state directory reaches the same JSON string, so the rule covers every
# configured path rather than the key file alone.
control_state_directory=$(printf '%s/state\nweb' "$work")
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_gated \
    QWEN_WEB_AUTHORIZER_READY=1 \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$control_state_directory" \
    "$builder" "$work/presets-control-state.ini" \
    >"$work/control-state.log" 2>"$work/control-state.err"; then
    report json_control_state_directory_refused accepted
else
    report json_control_state_directory_refused ok
fi

# A ui-mediated ledger names no MCP configuration and reaches no network, so it
# generates from the ledger alone rather than requiring a server program and a
# provider key its sections never reach.
presets_ui_no_mcp=$work/presets-ui-no-mcp.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_ui \
    QWEN_MODEL_ROOT=$policy_model_root \
    env -u QWEN_WEB_MCP_SERVER -u QWEN_WEB_SEARCH_KEY_FILE \
    -u QWEN_WEB_TOKEN_KEY_FILE -u QWEN_WEB_STATE_DIR \
    "$builder" "$presets_ui_no_mcp" \
    >"$work/ui-no-mcp.log" 2>"$work/ui-no-mcp.err"; then
    report ui_mediated_generates_without_mcp_inputs ok
else
    report ui_mediated_generates_without_mcp_inputs failed
    cat "$work/ui-no-mcp.err" >&2
fi

# A ui-mediated row writes no configuration file, so the emitted directory holds
# nothing an unreferenced section could point at.
ui_no_mcp_configs=$(dirname -- "$presets_ui_no_mcp")/web-mcp-configs
if [ -e "$ui_no_mcp_configs/web-fixture-ui.json" ]; then
    report ui_mediated_writes_no_mcp_config file_present
else
    report ui_mediated_writes_no_mcp_config ok
fi

# A validator-gated row that reaches emission still requires both inputs, and
# the refusal names the profile whose section would have carried the omission.
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_gated \
    QWEN_WEB_AUTHORIZER_READY=1 QWEN_MODEL_ROOT=$policy_model_root \
    env -u QWEN_WEB_MCP_SERVER QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$work/presets-absent-server.ini" \
    >"$work/absent-server.log" 2>"$work/absent-server.err"; then
    report gated_requires_mcp_server accepted
elif grep -q 'profile web-fixture-gated' "$work/absent-server.err"; then
    report gated_requires_mcp_server ok
else
    report gated_requires_mcp_server message_omits_profile
fi

if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_gated \
    QWEN_WEB_AUTHORIZER_READY=1 QWEN_MODEL_ROOT=$policy_model_root \
    env -u QWEN_WEB_SEARCH_KEY_FILE QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$work/presets-absent-key.ini" \
    >"$work/absent-key.log" 2>"$work/absent-key.err"; then
    report gated_requires_search_key_file accepted
elif grep -q 'profile web-fixture-gated' "$work/absent-key.err"; then
    report gated_requires_search_key_file ok
else
    report gated_requires_search_key_file message_omits_profile
fi

# The ledger is one claimed policy document, so a refused row meets the registry
# join, the copied-field comparison, the tier rule, and the ceiling rule that an
# emitting row meets. A run whose emitting row is sound still stops on the
# refused row's drift.
for refused_drift_case in depth tier ceiling unknown_model; do
    refused_drift_profiles=$work/web-profiles-refused-drift.tsv
    {
        printf 'web-fixture-emitting\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tui-mediated\texa\t-\t-\t-\t-\n'
        case $refused_drift_case in
            depth)
                printf 'web-fixture-stale\tfixture-production\tvalidator-gated\t8192\t16384\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\t-\t-\t-\t-\n'
                ;;
            tier)
                printf 'web-fixture-stale\tfixture-archive\tvalidator-gated\t8192\t-\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\t-\t-\t-\t-\n'
                ;;
            ceiling)
                printf 'web-fixture-stale\tfixture-production\tvalidator-gated\t32768\t8192\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\t-\t-\t-\t-\n'
                ;;
            unknown_model)
                printf 'web-fixture-stale\tfixture-absent\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\trefused\texa\t-\t-\t-\t-\n'
                ;;
        esac
    } >"$refused_drift_profiles"
    if build "$refused_drift_profiles" "$work/presets-refused-drift.ini" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
        QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
        QWEN_WEB_STATE_DIR="$web_state_directory" \
        >"$work/refused-drift.log" 2>"$work/refused-drift.err"; then
        report "refused_row_${refused_drift_case}_drift_refused" accepted
    elif grep -q 'web-fixture-stale' "$work/refused-drift.err"; then
        report "refused_row_${refused_drift_case}_drift_refused" ok
    else
        report "refused_row_${refused_drift_case}_drift_refused" message_omits_profile
    fi
done

# The checked-in ledger is read against the checked-in registry, so drift in
# either file fails here rather than at the first edit that turns a row into an
# executing policy. Every shipped row reads `refused`, so the run stops on the
# empty emission and every message before it names a skipped profile.
checked_in_out=$work/checked-in
mkdir -p "$checked_in_out"
if QWEN_MODEL_ROOT=$policy_model_root \
    env -u QWEN_WEB_SEARCH_KEY_FILE QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_PROVIDER=searxng \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$checked_in_out/presets.ini" \
    >"$work/checked-in.log" 2>"$work/checked-in.err"; then
    report checked_in_ledger_matches_registry emitted_a_section
elif grep -q 'withholds an executing policy' "$work/checked-in.err"; then
    report checked_in_ledger_matches_registry ok
else
    report checked_in_ledger_matches_registry diverges
    cat "$work/checked-in.err" >&2
fi

# Router preflight rejects a section whose model file is absent before the
# single-model fetch path runs, so one unfetched checkpoint would block every
# web profile of a machine that holds the rest. The absent row is skipped and
# named, and the present one still emits.
absent_model_root=$work/absent-model-root
mkdir -p "$absent_model_root/Fixture-GGUF"
: >"$absent_model_root/Fixture-GGUF/production.gguf"
web_profiles_partial=$work/web-profiles-partial.tsv
{
    printf 'web-fixture-present\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tui-mediated\texa\t-\t-\t-\t-\n'
    printf 'web-fixture-absent\tfixture-candidate-validated\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tui-mediated\texa\t-\t-\t-\t-\n'
} >"$web_profiles_partial"
mkdir -p "$work/partial-out"
presets_partial=$work/partial-out/presets.ini
if QWEN_MODEL_ROOT=$absent_model_root build "$web_profiles_partial" \
    "$presets_partial" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/partial.log" 2>"$work/partial.err"; then
    partial_outcome=ok
    grep -q '^\[web-fixture-present\]' "$presets_partial" ||
        partial_outcome=present_section_absent
    grep -q '^\[web-fixture-absent\]' "$presets_partial" &&
        partial_outcome=absent_section_emitted
    grep -q 'web_preset_skipped profile=web-fixture-absent reason=weights_absent' \
        "$work/partial.err" || partial_outcome=skip_unreported
    report absent_weights_skipped_and_named "$partial_outcome"
else
    report absent_weights_skipped_and_named build_failed
    cat "$work/partial.err" >&2
fi

# A run whose every emitting row names absent weights stops on that cause rather
# than reporting a ledger that withheld every executing policy.
empty_model_root=$work/empty-model-root
mkdir -p "$empty_model_root"
if QWEN_MODEL_ROOT=$empty_model_root build "$web_profiles_partial" \
    "$work/presets-all-absent.ini" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/all-absent.log" 2>"$work/all-absent.err"; then
    report all_weights_absent_refused emitted_a_section
elif grep -q 'names an artifact this machine holds no file for' "$work/all-absent.err"; then
    report all_weights_absent_refused ok
else
    report all_weights_absent_refused wrong_reason
fi

# Router mode reads a section's own LLAMA_ARG_MMPROJ and leaves the standalone
# QWEN_MMPROJ path unread, so a profile whose registry row requires a projector
# carries the resolved path in its section and the capacity policy still admits
# the tuple.
web_profiles_vision=$work/web-profiles-vision.tsv
printf 'web-fixture-vision\tfixture-vision\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tyes\t9/10\tui-mediated\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_vision"
mkdir -p "$work/vision-out"
presets_vision=$work/vision-out/presets.ini
if build "$web_profiles_vision" "$presets_vision" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/vision.log" 2>"$work/vision.err"; then
    if grep -qx "LLAMA_ARG_MMPROJ = $policy_model_root/Fixture-Vision-GGUF/mmproj-F16.gguf" \
        "$presets_vision"; then
        report vision_section_carries_projector ok
    else
        report vision_section_carries_projector key_absent
    fi
    if run_policy_over_presets "$presets_vision" "$web_profiles_vision" \
        >"$work/vision-policy.log" 2>"$work/vision-policy.err"; then
        report vision_section_passes_capacity_policy ok
    else
        report vision_section_passes_capacity_policy failed
        cat "$work/vision-policy.err" >&2
    fi
else
    report vision_section_carries_projector build_failed
    report vision_section_passes_capacity_policy build_failed
    cat "$work/vision.err" >&2
fi

# A text row keeps its section free of the key, so the projector follows the
# registry's projector column rather than every emitted section.
if grep -q '^LLAMA_ARG_MMPROJ' "$presets_ok"; then
    report text_section_carries_no_projector key_present
else
    report text_section_carries_no_projector ok
fi

# select-projector.sh prints nothing for both the absent and the ambiguous case,
# and either leaves the ledger's vision grant unserved, so the profile is
# skipped and named rather than emitted text-only.
for projector_case in absent ambiguous; do
    projector_model_root=$work/projector-$projector_case
    mkdir -p "$projector_model_root/Fixture-Vision-GGUF"
    : >"$projector_model_root/Fixture-Vision-GGUF/vision.gguf"
    if [ "$projector_case" = ambiguous ]; then
        : >"$projector_model_root/Fixture-Vision-GGUF/mmproj-one-BF16.gguf"
        : >"$projector_model_root/Fixture-Vision-GGUF/mmproj-two-BF16.gguf"
    fi
    if QWEN_MODEL_ROOT=$projector_model_root build "$web_profiles_vision" \
        "$work/presets-projector-$projector_case.ini" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
        QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
        QWEN_WEB_STATE_DIR="$web_state_directory" \
        >"$work/projector-$projector_case.log" \
        2>"$work/projector-$projector_case.err"; then
        report "projector_${projector_case}_skipped" emitted_a_section
    elif grep -q 'web_preset_skipped profile=web-fixture-vision reason=projector_unresolved' \
        "$work/projector-$projector_case.err"; then
        report "projector_${projector_case}_skipped" ok
    else
        report "projector_${projector_case}_skipped" skip_unreported
    fi
done

# qwen-launch.sh snapshots the INI alone and its sections keep naming the
# configuration paths they were generated with, and llama-server reads an MCP
# configuration when its child starts, so a regeneration under changed inputs
# writes a new versioned directory and leaves every file an earlier preset names
# byte-identical.
mkdir -p "$work/immutable-out"
immutable_presets=$work/immutable-out/presets.ini
web_profiles_immutable=$work/web-profiles-immutable.tsv
printf 'web-fixture-immutable\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n' \
    >"$web_profiles_immutable"
if build "$web_profiles_immutable" "$immutable_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/immutable-first.log" 2>"$work/immutable-first.err"; then
    first_config=$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$immutable_presets")
    first_config_digest=$(sha256sum "$first_config" | cut -d' ' -f1)
    rotated_key_file=$work/private/rotated-exa-api.key
    printf 'fixture-rotated-secret-value\n' >"$rotated_key_file"
    if build "$web_profiles_immutable" "$immutable_presets" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
        QWEN_WEB_SEARCH_KEY_FILE="$rotated_key_file" \
        QWEN_WEB_STATE_DIR="$web_state_directory" \
        >"$work/immutable-second.log" 2>"$work/immutable-second.err"; then
        second_config=$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$immutable_presets")
        immutable_outcome=ok
        [ "$second_config" != "$first_config" ] ||
            immutable_outcome=version_reused
        [ -f "$first_config" ] || immutable_outcome=earlier_config_removed
        if [ -f "$first_config" ] &&
            [ "$(sha256sum "$first_config" | cut -d' ' -f1)" != "$first_config_digest" ]; then
            immutable_outcome=earlier_config_rewritten
        fi
        report earlier_mcp_config_survives_regeneration "$immutable_outcome"
    else
        report earlier_mcp_config_survives_regeneration second_build_failed
        cat "$work/immutable-second.err" >&2
    fi
else
    report earlier_mcp_config_survives_regeneration first_build_failed
    cat "$work/immutable-first.err" >&2
fi

# Identical inputs resolve to one version, so a regeneration that changes
# nothing leaves the running session's own path valid.
if build "$web_profiles_immutable" "$immutable_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$rotated_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/immutable-third.log" 2>"$work/immutable-third.err"; then
    third_config=$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$immutable_presets")
    if [ "$third_config" = "$second_config" ]; then
        report identical_inputs_reuse_one_version ok
    else
        report identical_inputs_reuse_one_version version_changed
    fi
else
    report identical_inputs_reuse_one_version failed
    cat "$work/immutable-third.err" >&2
fi

# The emitted set follows the weights this machine holds, so fetching a
# checkpoint between two runs adds a configuration without touching either
# registry. A version id derived from the inputs alone would name the directory
# the first run wrote, keep it, and leave the second run's section pointing at a
# file that was discarded with the temporary tree.
fetch_model_root=$work/fetch-model-root
mkdir -p "$fetch_model_root/Fixture-GGUF"
: >"$fetch_model_root/Fixture-GGUF/production.gguf"
web_profiles_fetch=$work/web-profiles-fetch.tsv
{
    printf 'web-fixture-held\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n'
    printf 'web-fixture-fetched\tfixture-candidate-validated\tvalidator-gated\t8192\t8192\t7\t3\t9000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-\n'
} >"$web_profiles_fetch"
mkdir -p "$work/fetch-out"
fetch_presets=$work/fetch-out/presets.ini
build_fetch_arm() {
    QWEN_MODEL_ROOT=$fetch_model_root build "$web_profiles_fetch" \
        "$fetch_presets" \
        env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
        QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
        QWEN_WEB_STATE_DIR="$web_state_directory"
}
if build_fetch_arm >"$work/fetch-first.log" 2>"$work/fetch-first.err"; then
    : >"$fetch_model_root/Fixture-GGUF/candidate-validated.gguf"
    if build_fetch_arm >"$work/fetch-second.log" 2>"$work/fetch-second.err"; then
        fetch_outcome=ok
        while IFS= read -r fetched_config; do
            [ -r "$fetched_config" ] || fetch_outcome=unreadable_config
        done <<EOF
$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$fetch_presets")
EOF
        [ "$(grep -c '^LLAMA_ARG_MCP_SERVERS_CONFIG' "$fetch_presets")" = 2 ] ||
            fetch_outcome=wrong_config_count
        report fetched_model_reaches_a_written_config "$fetch_outcome"
    else
        report fetched_model_reaches_a_written_config second_build_failed
        cat "$work/fetch-second.err" >&2
    fi
else
    report fetched_model_reaches_a_written_config first_build_failed
    cat "$work/fetch-first.err" >&2
fi

# A final ledger record remains a record even when the file lacks a trailing
# newline. POSIX read reports a nonzero status after returning those bytes, so
# the generator must process the populated fields before ending the loop.
unterminated_profiles=$work/web-profiles-unterminated.tsv
printf 'web-fixture-unterminated\tfixture-production\tvalidator-gated\t8192\t8192\t5\t2\t12000\tyes\tno\t9/10\tvalidator-gated\texa\t-\t-\t-\t-' \
    >"$unterminated_profiles"
unterminated_presets=$work/presets-unterminated.ini
if build "$unterminated_profiles" "$unterminated_presets" \
    env QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/unterminated.log" 2>"$work/unterminated.err" &&
   grep -Fqx '[web-fixture-unterminated]' "$unterminated_presets"; then
    report final_unterminated_profile_emits_section ok
else
    report final_unterminated_profile_emits_section failed
    cat "$work/unterminated.err" >&2
fi

expected_ledger_path=$(CDPATH='' cd -- "$(dirname -- "$unterminated_profiles")" && pwd)/$(basename -- "$unterminated_profiles")
expected_ledger_sha256=$(sha256sum "$unterminated_profiles" | cut -d' ' -f1)
if grep -Fqx "# qwen_web_profiles_path=$expected_ledger_path" \
       "$unterminated_presets" &&
   grep -Fqx "# qwen_web_profiles_sha256=$expected_ledger_sha256" \
       "$unterminated_presets" &&
   grep -Fqx '# qwen_web_provider=exa' "$unterminated_presets"; then
    report preset_binds_complete_ledger_identity ok
else
    report preset_binds_complete_ledger_identity missing_identity
fi

# The image execution grant. scripts/image-registry.sh validates the four image
# authorities whole, so the fixture ledger names the checked-in bundle and
# differs from it in execution_policy alone; the artifact, model, and
# quarantine files stay the tree's own.
image_profiles_refused=$image_profiles_none
image_profiles_gated=$work/image-profiles-gated.tsv
printf 'image-fixture-a\tsdxs-512\tA\t512\t512\t1\teuler\t1.0\t4\t512\t300\tvalidator-gated\tevidence/image-appliance/design.md\t-\n' \
    >"$image_profiles_gated"
image_profiles_two_gated=$work/image-profiles-two-gated.tsv
{
    cat "$image_profiles_gated"
    printf 'image-fixture-b\tsdxs-512\tB\t512\t512\t1\teuler\t1.0\t4\t512\t300\tvalidator-gated\tevidence/image-appliance/design.md\t-\n'
} >"$image_profiles_two_gated"

image_mcp_server_program=$work/image-mcp-server.py
: >"$image_mcp_server_program"
image_token_key_file=$work/private/image-mcp-token.key
printf 'fixture-image-token-secret\n' >"$image_token_key_file"
image_state_directory=$work/private/image-state
image_service_socket=$image_state_directory/image-service.sock
# The MCP child reads this file for the geometry and ceilings its tool schema
# states, so the generated section names the same parameter file
# image-service.py runs a job under and the fixture carries the ledger row's
# own numbers.
image_profiles_json=$work/image-parameters.json
cat >"$image_profiles_json" <<'IMAGE_PARAMETERS'
{
  "image-fixture-a": {
    "profile_id": "image-fixture-a",
    "model_id": "sdxs-512",
    "placement": "A",
    "sampler": "euler",
    "execution_policy": "validator-gated",
    "runtime_path": "/nonexistent/sd-cli",
    "width": 512,
    "height": 512,
    "steps": 1,
    "max_steps": 4,
    "max_dimension": 512,
    "timeout_s": 300
  }
}
IMAGE_PARAMETERS

image_environment() {
    printf 'QWEN_IMAGE_MCP_SERVER=%s\n' "$image_mcp_server_program"
    printf 'QWEN_IMAGE_TOKEN_KEY_FILE=%s\n' "$image_token_key_file"
    printf 'QWEN_IMAGE_STATE_DIR=%s\n' "$image_state_directory"
    printf 'QWEN_IMAGE_SERVICE_SOCKET=%s\n' "$image_service_socket"
    printf 'QWEN_IMAGE_PROFILES_JSON=%s\n' "$image_profiles_json"
}

# A refused image row adds no server under any setting and is named where it is
# skipped, which is what every row of the fixture ledger carries.
presets_image_refused=$work/presets-image-refused.ini
if build "$web_profiles_ok" "$presets_image_refused" \
    env QWEN_IMAGE_PROFILES="$image_profiles_refused" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    QWEN_IMAGE_PROFILES_JSON="$image_profiles_json" \
    QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/image-refused.log" 2>"$work/image-refused.err"; then
    outcome=ok
    grep -q ',image$' "$presets_image_refused" && outcome=image_tag_present
    grep -Fqx '# qwen_image_profile=-' "$presets_image_refused" ||
        outcome=marker_names_a_profile
    grep -q 'image_preset_skipped .*execution_policy=refused' \
        "$work/image-refused.err" || outcome=skip_unreported
    while IFS= read -r refused_config; do
        grep -q '"image"' "$refused_config" && outcome=image_server_present
    done <<EOF
$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$presets_image_refused")
EOF
    report image_refused_rows_emit_no_server "$outcome"
else
    report image_refused_rows_emit_no_server failed
    cat "$work/image-refused.err" >&2
fi

# The authorizer marker gates the image grant the way it gates the web one.
presets_image_unmarked=$work/presets-image-unmarked.ini
if QWEN_MODEL_REGISTRY=$model_registry QWEN_WEB_PROFILES=$web_profiles_ui \
    QWEN_MODEL_ROOT=$policy_model_root \
    env -u QWEN_WEB_AUTHORIZER_READY \
    QWEN_IMAGE_PROFILES="$image_profiles_gated" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    QWEN_IMAGE_PROFILES_JSON="$image_profiles_json" \
    QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    "$builder" "$presets_image_unmarked" \
    >"$work/image-unmarked.log" 2>"$work/image-unmarked.err"; then
    outcome=ok
    grep -q '^LLAMA_ARG_MCP_SERVERS_CONFIG' "$presets_image_unmarked" &&
        outcome=configuration_written
    grep -q 'image_preset_skipped .*authorizer=absent' \
        "$work/image-unmarked.err" || outcome=skip_unreported
    report image_gated_row_waits_for_the_authorizer "$outcome"
else
    report image_gated_row_waits_for_the_authorizer failed
    cat "$work/image-unmarked.err" >&2
fi

# Under the authorizer the row emits one image server per section, naming the
# language profile beside the image profile because the grant binds both.
presets_image_gated=$work/presets-image-gated.ini
if build "$web_profiles_ok" "$presets_image_gated" \
    env QWEN_IMAGE_PROFILES="$image_profiles_gated" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    QWEN_IMAGE_PROFILES_JSON="$image_profiles_json" \
    QWEN_WEB_MCP_SERVER="$mcp_server_program" \
    QWEN_WEB_SEARCH_KEY_FILE="$search_key_file" \
    QWEN_WEB_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_WEB_STATE_DIR="$web_state_directory" \
    >"$work/image-gated.log" 2>"$work/image-gated.err"; then
    outcome=ok
    grep -q '^LLAMA_ARG_TAGS = web-research,validator-gated,image$' \
        "$presets_image_gated" || outcome=wrong_tags
    grep -Fqx '# qwen_image_profile=image-fixture-a' "$presets_image_gated" ||
        outcome=marker_absent
    gated_config=$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' \
        "$presets_image_gated")
    if [ -r "$gated_config" ]; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
            "$gated_config" || outcome=configuration_is_not_json
        for image_environment_name in QWEN_IMAGE_LANGUAGE_PROFILE \
            QWEN_IMAGE_PROFILE QWEN_IMAGE_TOKEN_KEY_FILE QWEN_IMAGE_STATE_DIR \
            QWEN_IMAGE_SERVICE_SOCKET QWEN_IMAGE_PROFILES_JSON; do
            grep -q "\"$image_environment_name\"" "$gated_config" ||
                outcome=missing_$image_environment_name
        done
        grep -Fq '"timeout_ms": 360000' "$gated_config" || outcome=wrong_timeout
        # The router bounds the call and the child bounds its own socket read,
        # so both numbers come from the one setting.
        grep -Fq '"QWEN_IMAGE_MCP_TIMEOUT_S": "360"' "$gated_config" ||
            outcome=child_deadline_absent
        grep -Fq "\"$image_mcp_server_program\"" "$gated_config" ||
            outcome=server_program_absent
        grep -Fq '"QWEN_IMAGE_LANGUAGE_PROFILE": "web-fixture-ok"' \
            "$gated_config" || outcome=language_profile_absent
        grep -Fq '"QWEN_IMAGE_PROFILE": "image-fixture-a"' "$gated_config" ||
            outcome=image_profile_absent
        grep -Fq '"web"' "$gated_config" || outcome=web_server_dropped
    else
        outcome=configuration_unreadable
    fi
    report image_gated_row_emits_its_server "$outcome"
else
    report image_gated_row_emits_its_server failed
    cat "$work/image-gated.err" >&2
fi

# The image tag is a third term in LLAMA_ARG_TAGS, and qwen-capacity-policy.sh
# rejoins each section to the ledger by the policy word its tags carry. The
# real policy runs over the armed preset here, because every other arm drives
# it over a two-term tag set and the armed path is the only one that produces
# three.
if run_policy_over_presets "$presets_image_gated" "$web_profiles_ok" \
    >"$work/image-policy.log" 2>"$work/image-policy.err"; then
    report image_tagged_section_passes_capacity_policy ok
else
    report image_tagged_section_passes_capacity_policy failed
    cat "$work/image-policy.err" >&2
fi

# A generation runs in the server child whatever the page does about search, so
# a ui-mediated section carries the image server and nothing else.
presets_image_ui=$work/presets-image-ui.ini
if build "$web_profiles_ui" "$presets_image_ui" \
    env QWEN_IMAGE_PROFILES="$image_profiles_gated" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    QWEN_IMAGE_PROFILES_JSON="$image_profiles_json" \
    >"$work/image-ui.log" 2>"$work/image-ui.err"; then
    outcome=ok
    grep -q '^LLAMA_ARG_TAGS = web-research,ui-mediated,image$' \
        "$presets_image_ui" || outcome=wrong_tags
    ui_config=$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' \
        "$presets_image_ui")
    if [ -r "$ui_config" ]; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
            "$ui_config" || outcome=configuration_is_not_json
        grep -Fq '"image"' "$ui_config" || outcome=image_server_absent
        grep -Fq '"web"' "$ui_config" && outcome=web_server_present
    else
        outcome=configuration_unreadable
    fi
    report ui_mediated_section_carries_the_image_server "$outcome"
else
    report ui_mediated_section_carries_the_image_server failed
    cat "$work/image-ui.err" >&2
fi

# Each name the image child reads is required before a section names it.
presets_image_incomplete=$work/presets-image-incomplete.ini
if build "$web_profiles_ui" "$presets_image_incomplete" \
    env -u QWEN_IMAGE_TOKEN_KEY_FILE \
    QWEN_IMAGE_PROFILES="$image_profiles_gated" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    QWEN_IMAGE_PROFILES_JSON="$image_profiles_json" \
    >"$work/image-incomplete.log" 2>"$work/image-incomplete.err"; then
    report image_gated_row_requires_its_inputs accepted
else
    if grep -q 'QWEN_IMAGE_TOKEN_KEY_FILE names nothing' \
        "$work/image-incomplete.err"; then
        report image_gated_row_requires_its_inputs ok
    else
        report image_gated_row_requires_its_inputs wrong_refusal
    fi
fi

# The parameter file is one of those names, because the child states the
# profile's ceilings in its tool schema from that file alone: a section emitted
# without it lists a tool whose bounds nothing measured.
presets_image_unbounded=$work/presets-image-unbounded.ini
if build "$web_profiles_ui" "$presets_image_unbounded" \
    env -u QWEN_IMAGE_PROFILES_JSON \
    QWEN_IMAGE_PROFILES="$image_profiles_gated" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    >"$work/image-unbounded.log" 2>"$work/image-unbounded.err"; then
    report image_gated_row_requires_its_parameter_file accepted
else
    if grep -q 'QWEN_IMAGE_PROFILES_JSON names nothing' \
        "$work/image-unbounded.err"; then
        report image_gated_row_requires_its_parameter_file ok
    else
        report image_gated_row_requires_its_parameter_file wrong_refusal
    fi
fi

# A section carries one mcpServers object, so one image profile emits.
presets_image_two=$work/presets-image-two.ini
if build "$web_profiles_ui" "$presets_image_two" \
    env QWEN_IMAGE_PROFILES="$image_profiles_two_gated" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    QWEN_IMAGE_PROFILES_JSON="$image_profiles_json" \
    >"$work/image-two.log" 2>"$work/image-two.err"; then
    report two_gated_image_rows_refused accepted
else
    if grep -q 'both emit' "$work/image-two.err"; then
        report two_gated_image_rows_refused ok
    else
        report two_gated_image_rows_refused wrong_refusal
    fi
fi

# The preset binds the image ledger the way it binds the web one, so
# qwen-image-launch.sh reads one authority out of the file it launches.
expected_image_ledger_sha256=$(sha256sum "$image_profiles_gated" | cut -d' ' -f1)
if grep -Fqx "# qwen_image_profiles_path=$image_profiles_gated" \
       "$presets_image_gated" &&
   grep -Fqx "# qwen_image_profiles_sha256=$expected_image_ledger_sha256" \
       "$presets_image_gated" &&
   grep -Fqx '# qwen_image_mcp_timeout_ms=360000' "$presets_image_gated"; then
    report preset_binds_image_ledger_identity ok
else
    report preset_binds_image_ledger_identity missing_identity
fi

# The checked-in image ledger is what a launch on the appliance reads, so its
# one validator-gated row emits one image server and the review-only vision
# section its review_model names. The fixture cases above prove the rules; this
# one proves the shipped file meets them against the shipped model registry and
# the shipped tuple ledger. GGUF weights stay outside Git, so the model root
# holds an empty stand-in at every path those authorities name -- the generator
# reads presence and the registry's own tuple rather than tensor bytes -- and
# the projector's file name comes from the projector_fetch_script the registry
# row names, which is the same authority that puts the file on the appliance.
checked_in_review_row=$(grep '^lfm25-vl-16b	' "$script_directory/models.tsv")
# scripts/validated-tuples.tsv is validated whole against the registry it is read
# with, so the registry this arm builds is the shipped file with the fixture
# rows appended rather than the fixture file with one shipped row added.
checked_in_registry=$work/model-registry-checked-in.tsv
cat "$script_directory/models.tsv" >"$checked_in_registry"
grep -v '^#' "$model_registry" >>"$checked_in_registry"
checked_in_review_file=$(printf '%s\n' "$checked_in_review_row" | cut -f3)
checked_in_review_projector=$(sed -n 's/^artifact_name=//p' \
    "$script_directory/$(printf '%s\n' "$checked_in_review_row" | cut -f12)")
checked_in_model_root=$work/model-root-checked-in
cp -R "$policy_model_root" "$checked_in_model_root"
mkdir -p "$checked_in_model_root/${checked_in_review_file%/*}"
: >"$checked_in_model_root/$checked_in_review_file"
: >"$checked_in_model_root/${checked_in_review_file%/*}/$checked_in_review_projector"

presets_image_checked_in=$work/presets-image-checked-in.ini
# The shipped image ledger reads `refused` on every row, because every image
# grant it carried rested on device evidence taken on the prior host's APU:
# the generation arms ran sd-cli against that Vulkan device and the paired
# review ran on that machine's own carve-out. A generator run against it
# therefore emits a language section and no image server at all, and says so
# rather than failing.
if build "$web_profiles_ui" "$presets_image_checked_in" \
    env QWEN_IMAGE_PROFILES="$script_directory/image-profiles.tsv" \
    QWEN_MODEL_REGISTRY="$checked_in_registry" \
    QWEN_MODEL_ROOT="$checked_in_model_root" \
    QWEN_VALIDATED_TUPLES="$script_directory/validated-tuples.tsv" \
    QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
    QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
    QWEN_IMAGE_STATE_DIR="$image_state_directory" \
    QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
    QWEN_IMAGE_PROFILES_JSON="$image_profiles_json" \
    >"$work/image-checked-in.log" 2>"$work/image-checked-in.err"; then
    outcome=ok
    grep -Fqx '# qwen_image_profile=-' "$presets_image_checked_in" ||
        outcome=image_marker_names_a_profile
    grep -Fqx '# qwen_image_review_model=-' "$presets_image_checked_in" ||
        outcome=review_marker_names_a_model
    grep -Fqx '# qwen_image_review_section=-' "$presets_image_checked_in" ||
        outcome=review_section_marker_names_a_section
    grep -q '^LLAMA_ARG_MCP_SERVERS_CONFIG' "$presets_image_checked_in" &&
        outcome=configuration_present_for_refused_ledger
    [ "$(grep -c '^\[' "$presets_image_checked_in")" -eq 1 ] ||
        outcome=section_count
    cat "$work/image-checked-in.log" "$work/image-checked-in.err" |
        grep -q 'image_preset_skipped' || outcome=skip_unreported
    report checked_in_image_ledger_emits_no_server "$outcome"
else
    report checked_in_image_ledger_emits_no_server failed
    cat "$work/image-checked-in.err" >&2
fi

# An image row pairing a review_model adds one review-only vision section. The
# reviewer serves at its registry default depth and geometry, and
# scripts/validated-tuples.tsv has to carry that exact arm with the projector
# loaded, since llama-bench allocates no projector buffers and a `none` row
# measures a different allocation.
validated_tuples=$work/validated-tuples.tsv
cat >"$validated_tuples" <<'EOF'
# tuple_id	model_id	runtime_mode	context	batch	ubatch	cache_k	cache_v	flash_attention	threads	parallel	projector_state	backend	status	evidence	llama_commit	runner_sha256	kernel	mesa	gpu_module	measured_at
fixture-vision-d8192-b128-ub32-proj	fixture-vision	standalone	8192	128	32	q8_0	q4_0	on	1	1	loaded	vulkan	validated	evidence/image-appliance/design.md	-	-	-	-	-	2026-08-29
EOF
validated_tuples_unloaded=$work/validated-tuples-unloaded.tsv
sed 's/	loaded	/	none	/' "$validated_tuples" >"$validated_tuples_unloaded"

image_profiles_reviewed=$work/image-profiles-reviewed.tsv
printf 'image-fixture-a\tsdxs-512\tA\t512\t512\t1\teuler\t1.0\t4\t512\t300\tvalidator-gated\tevidence/image-appliance/design.md\tfixture-vision\n' \
    >"$image_profiles_reviewed"
image_profiles_reviewed_absent=$work/image-profiles-reviewed-absent.tsv
printf 'image-fixture-a\tsdxs-512\tA\t512\t512\t1\teuler\t1.0\t4\t512\t300\tvalidator-gated\tevidence/image-appliance/design.md\tfixture-absent\n' \
    >"$image_profiles_reviewed_absent"
image_profiles_reviewed_text=$work/image-profiles-reviewed-text.tsv
printf 'image-fixture-a\tsdxs-512\tA\t512\t512\t1\teuler\t1.0\t4\t512\t300\tvalidator-gated\tevidence/image-appliance/design.md\tfixture-production\n' \
    >"$image_profiles_reviewed_text"

build_reviewed() {
    build "$web_profiles_ui" "$1" \
        env QWEN_VALIDATED_TUPLES="${3:-$validated_tuples}" \
        QWEN_IMAGE_PROFILES="$2" \
        QWEN_IMAGE_MCP_SERVER="$image_mcp_server_program" \
        QWEN_IMAGE_TOKEN_KEY_FILE="$image_token_key_file" \
        QWEN_IMAGE_STATE_DIR="$image_state_directory" \
        QWEN_IMAGE_SERVICE_SOCKET="$image_service_socket" \
        QWEN_IMAGE_PROFILES_JSON="$image_profiles_json"
}

presets_reviewed=$work/presets-reviewed.ini
if build_reviewed "$presets_reviewed" "$image_profiles_reviewed" \
    >"$work/reviewed.log" 2>"$work/reviewed.err"; then
    outcome=ok
    grep -Fqx '# qwen_image_review_model=fixture-vision' "$presets_reviewed" ||
        outcome=review_marker_absent
    grep -Fqx '# qwen_image_review_section=fixture-vision' "$presets_reviewed" ||
        outcome=review_section_marker_absent
    grep -Fqx '[fixture-vision]' "$presets_reviewed" || outcome=section_absent
    grep -Fqx 'LLAMA_ARG_TAGS = vision-review,review-only' "$presets_reviewed" ||
        outcome=wrong_tags
    grep -Fqx "LLAMA_ARG_MMPROJ = $policy_model_root/Fixture-Vision-GGUF/mmproj-F16.gguf" \
        "$presets_reviewed" || outcome=projector_absent
    grep -Fqx 'LLAMA_ARG_CTX_SIZE = 8192' "$presets_reviewed" ||
        outcome=depth_absent
    # The review section holds no execution grant, so the language section is
    # the only one naming an MCP configuration.
    [ "$(grep -c '^LLAMA_ARG_MCP_SERVERS_CONFIG' "$presets_reviewed")" -eq 1 ] ||
        outcome=configuration_count
    [ "$(grep -c '^\[' "$presets_reviewed")" -eq 2 ] || outcome=section_count
    grep -q 'review_section=fixture-vision' "$work/reviewed.log" ||
        outcome=unreported
    report review_model_emits_a_review_section "$outcome"
else
    report review_model_emits_a_review_section failed
    cat "$work/reviewed.err" >&2
fi

# qwen-capacity-policy.sh rejoins every web section to the ledger by profile_id,
# and the review section names a checkpoint rather than a profile. Its tags are
# what exempt it, and the tuple validator still binds it to its registry row.
if run_policy_over_presets "$presets_reviewed" "$web_profiles_ui" \
    >"$work/reviewed-policy.log" 2>"$work/reviewed-policy.err"; then
    report review_section_passes_capacity_policy ok
else
    report review_section_passes_capacity_policy failed
    cat "$work/reviewed-policy.err" >&2
fi

# A review section that acquired an MCP configuration would arm a tool the page
# never offers a reviewer, so the policy refuses it.
presets_reviewed_armed=$work/presets-reviewed-armed.ini
awk -v configuration="$image_profiles_json" '
    /^LLAMA_ARG_TAGS = vision-review,review-only$/ {
        printf "LLAMA_ARG_MCP_SERVERS_CONFIG = %s\n", configuration
    }
    { print }
' "$presets_reviewed" >"$presets_reviewed_armed"
if run_policy_over_presets "$presets_reviewed_armed" "$web_profiles_ui" \
    >"$work/reviewed-armed.log" 2>"$work/reviewed-armed.err"; then
    report armed_review_section_refused_by_policy accepted
else
    if grep -q 'is review-only and carries LLAMA_ARG_MCP_SERVERS_CONFIG' \
        "$work/reviewed-armed.err"; then
        report armed_review_section_refused_by_policy ok
    else
        report armed_review_section_refused_by_policy wrong_refusal
    fi
fi

presets_review_absent=$work/presets-review-absent.ini
if build_reviewed "$presets_review_absent" "$image_profiles_reviewed_absent" \
    >"$work/review-absent.log" 2>"$work/review-absent.err"; then
    report unknown_review_model_refused accepted
else
    if grep -q 'the model registry holds no row for' "$work/review-absent.err"; then
        report unknown_review_model_refused ok
    else
        report unknown_review_model_refused wrong_refusal
    fi
fi

# A reviewer reads an image through its own projector, so a text row cannot
# serve the role however well it answers.
presets_review_text=$work/presets-review-text.ini
if build_reviewed "$presets_review_text" "$image_profiles_reviewed_text" \
    >"$work/review-text.log" 2>"$work/review-text.err"; then
    report text_review_model_refused accepted
else
    if grep -q 'carries projector none' "$work/review-text.err"; then
        report text_review_model_refused ok
    else
        report text_review_model_refused wrong_refusal
    fi
fi

# The tuple the section serves has to be one measured with the projector
# loaded, since that allocation is what the section makes.
presets_review_unloaded=$work/presets-review-unloaded.ini
if build_reviewed "$presets_review_unloaded" "$image_profiles_reviewed" \
    "$validated_tuples_unloaded" \
    >"$work/review-unloaded.log" 2>"$work/review-unloaded.err"; then
    report unloaded_projector_tuple_refused accepted
else
    if grep -q 'carries no validated tuple at depth 8192' \
        "$work/review-unloaded.err"; then
        report unloaded_projector_tuple_refused ok
    else
        report unloaded_projector_tuple_refused wrong_refusal
    fi
fi

if [ "$failures" -ne 0 ]; then
    printf 'test-web-presets: %d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'test-web-presets: all checks passed\n'
