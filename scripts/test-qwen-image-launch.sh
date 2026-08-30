#!/bin/sh
set -eu

# Tests scripts/qwen-image-launch.sh against fabricated preset, ledger, and
# parameter files, so an arm that must fail never depends on editing the
# checked-in authorities.
#
# The launch arms replace qwen-web-launch.sh with a recorder, so each one
# measures the environment the wrapper hands the web launch rather than
# starting a server. The image registry, the image service program, and the
# fallback page reach the harness as symbolic links to the tree's own files,
# because the wrapper reads each from its own directory.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
failures=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = ok ] || failures=$((failures + 1))
}

# scripts/image-registry.sh resolves a retained evidence path against its own
# parent directory, so the harness mirrors the tree at that one point: the
# ledger fixture names an evidence file, and validation reads it there.
ln -s "$script_directory/../evidence" "$work/evidence"
harness=$work/harness
mkdir -p "$harness"
cp "$script_directory/qwen-image-launch.sh" "$harness/qwen-image-launch.sh"
for linked_name in image-registry.sh image-service.py image-artifacts.tsv \
    image-models.tsv image-quarantine.tsv; do
    ln -s "$script_directory/$linked_name" "$harness/$linked_name"
done
cat >"$harness/qwen-web-launch.sh" <<'EOF'
#!/bin/sh
set -eu
{
    printf 'profile=%s\n' "${1:-unset}"
    printf 'QWEN_IMAGE_SERVICE=%s\n' "${QWEN_IMAGE_SERVICE:-unset}"
    printf 'QWEN_IMAGE_SERVICE_PROGRAM=%s\n' "${QWEN_IMAGE_SERVICE_PROGRAM:-unset}"
    printf 'QWEN_IMAGE_PROFILES_JSON=%s\n' "${QWEN_IMAGE_PROFILES_JSON:-unset}"
    printf 'QWEN_IMAGE_PROFILE=%s\n' "${QWEN_IMAGE_PROFILE:-unset}"
    printf 'QWEN_IMAGE_PROFILES=%s\n' "${QWEN_IMAGE_PROFILES:-unset}"
    printf 'QWEN_IMAGE_TOKEN_KEY_FILE=%s\n' "${QWEN_IMAGE_TOKEN_KEY_FILE:-unset}"
    printf 'QWEN_WEB_REVIEW_SECTION=%s\n' "${QWEN_WEB_REVIEW_SECTION:-unset}"
    printf 'QWEN_REQUIRED_VULKAN_MIB=%s\n' "${QWEN_REQUIRED_VULKAN_MIB:-unset}"
} >"$QWEN_IMAGE_LAUNCH_RECORD"
EOF
chmod +x "$harness/qwen-web-launch.sh"
launcher=$harness/qwen-image-launch.sh

# The ledger fixture names the checked-in bundle and differs from the shipped
# row in execution_policy alone, so scripts/image-registry.sh validates it whole
# against the artifact and model authorities the harness links.
# write_ledger names the reviewer the row pairs, because that field decides
# whether the preset serves one section or two and the launch rejoins the
# marker to it.
write_ledger() {
    printf 'image-fixture-a\tsdxs-512\tA\t512\t512\t1\teuler\t1.0\t4\t512\t300\t%s\t%s\t%s\n' \
        "$2" "$3" "$4" >"$1"
}
image_profiles_gated=$work/image-profiles-gated.tsv
write_ledger "$image_profiles_gated" validator-gated \
    evidence/image-appliance/design.md -
image_profiles_reviewed=$work/image-profiles-reviewed.tsv
write_ledger "$image_profiles_reviewed" validator-gated \
    evidence/image-appliance/design.md vision-fixture
image_profiles_refused=$work/image-profiles-refused.tsv
write_ledger "$image_profiles_refused" refused - -

state_directory=$work/state
mkdir -p "$state_directory"
signing_key_file=$work/private/token.key
mkdir -p "$work/private"
printf 'fixture-token-secret\n' >"$signing_key_file"
chmod 600 "$signing_key_file"

image_runtime=$work/fake-image-runtime.sh
printf '#!/bin/sh\nexit 0\n' >"$image_runtime"
chmod +x "$image_runtime"

image_parameters=$work/image-parameters.json
write_parameters() {
    cat >"$image_parameters" <<PARAMETERS
{
  "image-fixture-a": {
    "profile_id": "image-fixture-a",
    "model_id": "sdxs-512",
    "placement": "A",
    "width": 512,
    "height": 512,
    "steps": 1,
    "sampler": "euler",
    "cfg": 1.0,
    "max_steps": ${1:-4},
    "max_dimension": 512,
    "timeout_s": 300,
    "execution_policy": "validator-gated",
    "runtime_path": "$image_runtime",
    "runtime_argv": ["--output", "{output}"]
  }
}
PARAMETERS
}
write_parameters

image_configuration=$work/image-mcp-config.json
write_configuration() {
    cat >"$image_configuration" <<CONFIGURATION
{
  "mcpServers": {
    "image": {
      "command": "python3",
      "timeout_ms": ${1:-360000},
      "args": ["$script_directory/image-mcp/server.py"],
      "env": {
        "QWEN_IMAGE_LANGUAGE_PROFILE": "web-fixture",
        "QWEN_IMAGE_PROFILE": "image-fixture-a",
        "QWEN_IMAGE_TOKEN_KEY_FILE": "$signing_key_file",
        "QWEN_IMAGE_STATE_DIR": "$state_directory/images",
        "QWEN_IMAGE_SERVICE_SOCKET": "$state_directory/images/image-service.sock",
        "QWEN_IMAGE_MCP_TIMEOUT_S": "${2:-360}"
      }
    }
  }
}
CONFIGURATION
}
write_configuration

# The preset is written directly rather than generated, because these arms
# measure what the launch reads out of one; scripts/test-web-presets.sh measures
# what the generator writes into it.
# The fourth argument names the reviewer the preset markers claim, and the
# fifth chooses what the review section itself carries: `section` is the shape
# the generator writes, `no-projector` strips the projector a reviewer reads an
# image through, and `third` adds one more section than the launch admits.
write_preset() {
    preset_path=$1
    preset_profile=$2
    preset_ledger=$3
    preset_review_model=${4:--}
    preset_review_shape=${5:-}
    preset_ledger_sha256=$(sha256sum "$preset_ledger" | cut -d' ' -f1)
    {
        printf '# qwen_web_presets=1\n'
        printf '# qwen_image_profile=%s\n' "$preset_profile"
        printf '# qwen_image_profiles_path=%s\n' "$preset_ledger"
        printf '# qwen_image_profiles_sha256=%s\n' "$preset_ledger_sha256"
        printf '# qwen_image_mcp_timeout_ms=360000\n'
        printf '# qwen_image_review_model=%s\n' "$preset_review_model"
        if [ "$preset_review_model" = '-' ]; then
            printf '# qwen_image_review_section=-\n'
        else
            printf '# qwen_image_review_section=%s\n' "$preset_review_model"
        fi
        printf '\n'
        printf '[web-fixture]\n'
        printf 'LLAMA_ARG_MODEL = %s\n' "$work/fixture.gguf"
        printf 'LLAMA_ARG_MCP_SERVERS_CONFIG = %s\n' "$image_configuration"
        printf 'LLAMA_ARG_TAGS = web-research,ui-mediated,image\n'
        if [ -n "$preset_review_shape" ]; then
            printf '\n'
            printf '[%s]\n' "$preset_review_model"
            printf 'LLAMA_ARG_MODEL = %s\n' "$work/vision-fixture.gguf"
            if [ "$preset_review_shape" != no-projector ]; then
                printf 'LLAMA_ARG_MMPROJ = %s\n' "$work/vision-fixture-mmproj.gguf"
            fi
            printf 'LLAMA_ARG_TAGS = vision-review,review-only\n'
        fi
        if [ "$preset_review_shape" = third ]; then
            printf '\n'
            printf '[web-fixture-second]\n'
            printf 'LLAMA_ARG_MODEL = %s\n' "$work/fixture.gguf"
            printf 'LLAMA_ARG_TAGS = web-research,ui-mediated\n'
        fi
    } >"$preset_path"
}

# The launch sizes the device against every model and projector the preset
# names, so the fixtures carry bytes rather than being empty. The numbers are
# small and arbitrary; what the arms measure is the sum and the refusal, and
# the budget itself comes from the stubbed preflight.
head -c 2097152 /dev/zero >"$work/fixture.gguf"
head -c 1048576 /dev/zero >"$work/vision-fixture.gguf"
head -c 524288 /dev/zero >"$work/vision-fixture-mmproj.gguf"

# model-memory-preflight.sh compiles a Vulkan probe and requires a physical
# GPU device, so the arms replace it with a stub that reports the shape the
# launch reads. QWEN_MEMORY_PREFLIGHT_BUDGET_MIB is what the stub admits.
memory_preflight_stub=$work/memory-preflight-stub.sh
cat >"$memory_preflight_stub" <<'PREFLIGHT'
#!/bin/sh
set -eu
printf 'model_bytes=%s\n' "$(wc -c <"$1")"
printf 'required_vulkan_bytes=%s\n' "$(($2 * 1048576))"
printf 'host_memory_headroom=ample surplus_bytes=0\n'
if [ "$2" -le "${QWEN_MEMORY_PREFLIGHT_BUDGET_MIB:-8192}" ]; then
    printf 'device_budget_headroom=ample surplus_bytes=0\n'
else
    printf 'device_budget_headroom=short shortfall_bytes=%s\n' \
        "$((($2 - ${QWEN_MEMORY_PREFLIGHT_BUDGET_MIB:-8192}) * 1048576))"
fi
printf 'model_memory_preflight=observe\n'
PREFLIGHT
chmod +x "$memory_preflight_stub"

presets_armed=$work/presets-armed.ini
write_preset "$presets_armed" image-fixture-a "$image_profiles_gated"
presets_unarmed=$work/presets-unarmed.ini
write_preset "$presets_unarmed" - "$image_profiles_refused"
presets_unmarked=$work/presets-unmarked.ini
printf '# qwen_web_presets=1\n\n[web-fixture]\nLLAMA_ARG_MODEL = %s\n' \
    "$work/fixture.gguf" >"$presets_unmarked"

launch_record=$work/launch.record
run_launch() {
    run_presets=$1
    shift
    env QWEN_IMAGE_LAUNCH_RECORD="$launch_record" \
        QWEN_WEB_PRESETS="$run_presets" \
        QWEN_WEBUI_STATE_DIRECTORY="$state_directory" \
        QWEN_WEB_TOKEN_KEY_FILE="$signing_key_file" \
        QWEN_WEB_AUTHORIZER_READY=1 \
        QWEN_IMAGE_PROFILES_JSON="$image_parameters" \
        QWEN_MEMORY_PREFLIGHT_PROGRAM="$memory_preflight_stub" \
        QWEN_STATIC_PATH="$script_directory/../webui" \
        "$@" "$launcher"
}

# The shipped state: every image row reads refused, so the generator names no
# image profile and the launch refuses rather than arming a path nothing
# authorized.
if run_launch "$presets_unarmed" env \
    >"$work/unarmed.log" 2>"$work/unarmed.err"; then
    report refused_ledger_refuses_the_launch accepted
else
    if grep -q 'withholds an executing policy' "$work/unarmed.err"; then
        report refused_ledger_refuses_the_launch ok
    else
        report refused_ledger_refuses_the_launch wrong_refusal
    fi
fi

# A preset generated before the image path existed carries no marker at all.
if run_launch "$presets_unmarked" env \
    >"$work/unmarked.log" 2>"$work/unmarked.err"; then
    report unmarked_preset_refuses_the_launch accepted
else
    if grep -q 'carries no image markers' "$work/unmarked.err"; then
        report unmarked_preset_refuses_the_launch ok
    else
        report unmarked_preset_refuses_the_launch wrong_refusal
    fi
fi

# An armed preset reaches the web launch with the image authority exported and
# the deadline stack reported.
rm -f "$launch_record"
if run_launch "$presets_armed" env \
    >"$work/armed.log" 2>"$work/armed.err"; then
    outcome=ok
    grep -qx 'QWEN_IMAGE_SERVICE=1' "$launch_record" || outcome=marker_absent
    grep -qx 'QWEN_IMAGE_PROFILE=image-fixture-a' "$launch_record" ||
        outcome=profile_absent
    grep -Fqx "QWEN_IMAGE_PROFILES_JSON=$image_parameters" "$launch_record" ||
        outcome=parameters_absent
    grep -Fqx "QWEN_IMAGE_PROFILES=$image_profiles_gated" "$launch_record" ||
        outcome=ledger_absent
    grep -Fqx "QWEN_IMAGE_TOKEN_KEY_FILE=$signing_key_file" "$launch_record" ||
        outcome=key_absent
    grep -qx 'profile=default' "$launch_record" || outcome=profile_argument
    grep -q 'image_launch timeouts runtime=300 service=330 mcp=360 proxy=3600 browser=660' \
        "$work/armed.log" || outcome=timeouts_unreported
    report armed_preset_exports_the_image_authority "$outcome"
else
    report armed_preset_exports_the_image_authority failed
    cat "$work/armed.err" >&2
fi

# The launch names the source of every deadline it did not read from a
# configured layer, and the router proxy is the one llama-server defaults.
if grep -q 'proxy_source=llama-server-default' "$work/armed.log"; then
    report proxy_deadline_names_its_source ok
else
    report proxy_deadline_names_its_source unnamed
fi

# A deadline stack out of order refuses: a tool call bounded below the service
# deadline abandons a generation the service is still running.
write_configuration 20000 20
if run_launch "$presets_armed" env \
    >"$work/disordered.log" 2>"$work/disordered.err"; then
    report disordered_deadlines_refuse_the_launch accepted
else
    if grep -q 'out of order at service>=mcp' "$work/disordered.err"; then
        report disordered_deadlines_refuse_the_launch ok
    else
        report disordered_deadlines_refuse_the_launch wrong_refusal
    fi
fi
write_configuration

# The router bounds the call at timeout_ms and the child bounds its own socket
# read at QWEN_IMAGE_MCP_TIMEOUT_S, so two numbers for one deadline would leave
# the router waiting past the point the child gave up.
write_configuration 400000 360
if run_launch "$presets_armed" env \
    >"$work/split-deadline.log" 2>"$work/split-deadline.err"; then
    report split_tool_deadline_refuses_the_launch accepted
else
    if grep -q 'bounds its call at 400000 ms and its own read at 360 s' \
        "$work/split-deadline.err"; then
        report split_tool_deadline_refuses_the_launch ok
    else
        report split_tool_deadline_refuses_the_launch wrong_refusal
    fi
fi
write_configuration

# A preset persists across an edit to the ledger, so the digest is measured
# again at launch.
printf '# an edit after generation\n' >>"$image_profiles_gated"
if run_launch "$presets_armed" env \
    >"$work/drift.log" 2>"$work/drift.err"; then
    report ledger_drift_refuses_the_launch accepted
else
    if grep -q 'ledger identity changed' "$work/drift.err"; then
        report ledger_drift_refuses_the_launch ok
    else
        report ledger_drift_refuses_the_launch wrong_refusal
    fi
fi
write_ledger "$image_profiles_gated" refused - -
write_preset "$presets_armed" image-fixture-a "$image_profiles_gated"
if run_launch "$presets_armed" env \
    >"$work/demoted.log" 2>"$work/demoted.err"; then
    report demoted_row_refuses_the_launch accepted
else
    if grep -q 'only validator-gated reaches a runtime' "$work/demoted.err"; then
        report demoted_row_refuses_the_launch ok
    else
        report demoted_row_refuses_the_launch wrong_refusal
    fi
fi
write_ledger "$image_profiles_gated" validator-gated \
    evidence/image-appliance/design.md -
write_preset "$presets_armed" image-fixture-a "$image_profiles_gated"

# The parameter file states what a job runs under, so a ceiling it raises above
# the ledger's refuses rather than serving a shape the ledger never admitted.
write_parameters 99
if run_launch "$presets_armed" env \
    >"$work/parameters.log" 2>"$work/parameters.err"; then
    report parameter_drift_refuses_the_launch accepted
else
    if grep -q 'carries max_steps 4' "$work/parameters.err"; then
        report parameter_drift_refuses_the_launch ok
    else
        report parameter_drift_refuses_the_launch wrong_refusal
    fi
fi
write_parameters

# The listener is the loopback alone, and a caller asking for the LAN is
# refused rather than served a rewritten request.
if run_launch "$presets_armed" env QWEN_BIND_HOST=0.0.0.0 \
    >"$work/bind.log" 2>"$work/bind.err"; then
    report lan_listener_refuses_the_launch accepted
else
    if grep -q 'serves the loopback alone' "$work/bind.err"; then
        report lan_listener_refuses_the_launch ok
    else
        report lan_listener_refuses_the_launch wrong_refusal
    fi
fi

# The authorizer marker gates the image grant the way it gates the web one.
if env QWEN_IMAGE_LAUNCH_RECORD="$launch_record" \
    QWEN_WEB_PRESETS="$presets_armed" \
    QWEN_WEBUI_STATE_DIRECTORY="$state_directory" \
    QWEN_WEB_TOKEN_KEY_FILE="$signing_key_file" \
    QWEN_IMAGE_PROFILES_JSON="$image_parameters" \
    QWEN_MEMORY_PREFLIGHT_PROGRAM="$memory_preflight_stub" \
    QWEN_STATIC_PATH="$script_directory/../webui" \
    "$launcher" >"$work/authorizer.log" 2>"$work/authorizer.err"; then
    report absent_authorizer_refuses_the_launch accepted
else
    if grep -q 'QWEN_WEB_AUTHORIZER_READY=1' "$work/authorizer.err"; then
        report absent_authorizer_refuses_the_launch ok
    else
        report absent_authorizer_refuses_the_launch wrong_refusal
    fi
fi

# A ledger row pairing a reviewer serves two sections, and the launch names the
# review section to the web launch so the router admits both children.
presets_reviewed=$work/presets-reviewed.ini
write_preset "$presets_reviewed" image-fixture-a "$image_profiles_reviewed" \
    vision-fixture section
rm -f "$launch_record"
if run_launch "$presets_reviewed" env \
    >"$work/reviewed.log" 2>"$work/reviewed.err"; then
    outcome=ok
    grep -qx 'QWEN_WEB_REVIEW_SECTION=vision-fixture' "$launch_record" ||
        outcome=review_section_absent
    grep -q 'image_launch review_section=vision-fixture projector=' \
        "$work/reviewed.log" || outcome=review_unreported
    # 2 MiB of language weights, 1 MiB of vision weights, and 0.5 MiB of
    # projector round to 4 MiB, and the runtime's own 480 MiB is charged whole.
    grep -q 'image_launch budget artifacts_mib=4 runtime_mib=480 required_mib=484 sections=2' \
        "$work/reviewed.log" || outcome=budget_unreported
    grep -qx 'QWEN_REQUIRED_VULKAN_MIB=484' "$launch_record" ||
        outcome=denominator_absent
    report review_pairing_serves_two_sections "$outcome"
else
    report review_pairing_serves_two_sections failed
    cat "$work/reviewed.err" >&2
fi

# The broker signs for one language profile, so a third section refuses rather
# than launching two profiles against one signature.
presets_three=$work/presets-three.ini
write_preset "$presets_three" image-fixture-a "$image_profiles_reviewed" \
    vision-fixture third
if run_launch "$presets_three" env \
    >"$work/three.log" 2>"$work/three.err"; then
    report third_section_refuses_the_launch accepted
else
    if grep -q 'image router mode serves 2 section(s)' "$work/three.err"; then
        report third_section_refuses_the_launch ok
    else
        report third_section_refuses_the_launch wrong_refusal
    fi
fi

# A reviewer reads an image through its own projector, so a review section that
# lost one answers from nothing while the roster still advertises vision.
presets_unprojected=$work/presets-unprojected.ini
write_preset "$presets_unprojected" image-fixture-a "$image_profiles_reviewed" \
    vision-fixture no-projector
if run_launch "$presets_unprojected" env \
    >"$work/unprojected.log" 2>"$work/unprojected.err"; then
    report review_section_without_projector_refuses accepted
else
    if grep -q 'names no LLAMA_ARG_MMPROJ' "$work/unprojected.err"; then
        report review_section_without_projector_refuses ok
    else
        report review_section_without_projector_refuses wrong_refusal
    fi
fi

# A preset persists across an edit to the ledger, so a row that stopped pairing
# a reviewer refuses rather than serving the persisted second section.
if run_launch "$presets_reviewed" env QWEN_WEB_PRESETS="$presets_reviewed" \
    >"$work/review-drift.log" 2>"$work/review-drift.err"; then
    unpaired=$work/presets-unpaired.ini
    write_preset "$unpaired" image-fixture-a "$image_profiles_gated" \
        vision-fixture section
    if run_launch "$unpaired" env \
        >"$work/unpaired.log" 2>"$work/unpaired.err"; then
        report review_drift_refuses_the_launch accepted
    else
        if grep -q 'pairs review_model - where the preset carries vision-fixture' \
            "$work/unpaired.err"; then
            report review_drift_refuses_the_launch ok
        else
            report review_drift_refuses_the_launch wrong_refusal
        fi
    fi
else
    report review_drift_refuses_the_launch setup_failed
fi

# Two resident checkpoints share one Vulkan carve-out, and a budget that holds
# less than the pair needs refuses the launch rather than discovering it at the
# second load.
if run_launch "$presets_reviewed" env \
    QWEN_MEMORY_PREFLIGHT_BUDGET_MIB=400 \
    >"$work/budget.log" 2>"$work/budget.err"; then
    report short_budget_refuses_the_launch accepted
else
    if grep -q 'Vulkan budget holds less than the 484 MiB' "$work/budget.err"; then
        report short_budget_refuses_the_launch ok
    else
        report short_budget_refuses_the_launch wrong_refusal
    fi
fi

# A one-section launch reports the same figure and is admitted whatever it
# says. That shape has served an approved generation on the appliance without
# this arithmetic, and the preflight reports rather than refuses by design, so
# the refusal belongs to the second resident checkpoint alone.
rm -f "$launch_record"
if run_launch "$presets_armed" env \
    QWEN_MEMORY_PREFLIGHT_BUDGET_MIB=1 \
    >"$work/single-budget.log" 2>"$work/single-budget.err"; then
    outcome=ok
    grep -q 'image_launch budget artifacts_mib=2 runtime_mib=480 required_mib=482 sections=1' \
        "$work/single-budget.log" || outcome=budget_unreported
    grep -q '^device_budget_headroom=short' "$work/single-budget.log" ||
        outcome=shortfall_unreported
    grep -qx 'QWEN_WEB_REVIEW_SECTION=unset' "$launch_record" ||
        outcome=review_section_exported
    report short_budget_admits_one_section "$outcome"
else
    report short_budget_admits_one_section refused
    cat "$work/single-budget.err" >&2
fi

# The same preset under a budget that holds the pair launches, so the refusal
# above is the budget rather than the pairing.
if run_launch "$presets_reviewed" env \
    QWEN_MEMORY_PREFLIGHT_BUDGET_MIB=484 \
    >"$work/budget-fits.log" 2>"$work/budget-fits.err"; then
    report exact_budget_admits_the_launch ok
else
    report exact_budget_admits_the_launch failed
    cat "$work/budget-fits.err" >&2
fi

# A launch that never armed the image lane leaves nothing for the teardown to
# prove gone, and the check reports that state rather than an attempt.
if "$script_directory/image-teardown-check.sh" "$state_directory" \
    >"$work/teardown.log" 2>"$work/teardown.err"; then
    if grep -q 'image teardown verified' "$work/teardown.log"; then
        report empty_state_passes_the_teardown_check ok
    else
        report empty_state_passes_the_teardown_check unreported
    fi
else
    report empty_state_passes_the_teardown_check failed
    cat "$work/teardown.err" >&2
fi

# A partial artifact is what an interrupted generation leaves, so the teardown
# check fails on one rather than reporting a clean stop.
mkdir -p "$state_directory/images/artifacts"
: >"$state_directory/images/artifacts/interrupted.part"
if "$script_directory/image-teardown-check.sh" "$state_directory" \
    >"$work/teardown-residue.log" 2>"$work/teardown-residue.err"; then
    report partial_artifact_fails_the_teardown_check accepted
else
    if grep -q 'partial artifacts survive' "$work/teardown-residue.err"; then
        report partial_artifact_fails_the_teardown_check ok
    else
        report partial_artifact_fails_the_teardown_check wrong_refusal
    fi
fi
rm -f "$state_directory/images/artifacts/interrupted.part"

# image-service.py names its partial file `<job>.part.png`, since the pinned
# runtime picks its encoder from the output path's own extension and appends
# `.png` itself to an extensionless name; the teardown check's glob has to
# catch that suffix too, not only the bare `.part` a prior version wrote.
: >"$state_directory/images/artifacts/interrupted.part.png"
if "$script_directory/image-teardown-check.sh" "$state_directory" \
    >"$work/teardown-residue-png.log" 2>"$work/teardown-residue-png.err"; then
    report partial_png_artifact_fails_the_teardown_check accepted
else
    if grep -q 'partial artifacts survive' "$work/teardown-residue-png.err"; then
        report partial_png_artifact_fails_the_teardown_check ok
    else
        report partial_png_artifact_fails_the_teardown_check wrong_refusal
    fi
fi
rm -f "$state_directory/images/artifacts/interrupted.part.png"

if [ "$failures" -ne 0 ]; then
    printf 'test-qwen-image-launch: %d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'test-qwen-image-launch: all checks passed\n'
