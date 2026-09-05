#!/bin/sh
set -eu

# gpu-ownership: delegated to the serving session, which takes the owner lock on
# the far side of the tmux boundary qwen-webui-control.sh opens. The image lane
# runs under that owner and takes the compute lease around each generation.

# Start the appliance in web router mode with the image generation lane armed,
# on the loopback alone.
#
# An image section reaches the device rather than the network: its MCP child
# hands a job to image-service.py, which takes the Vulkan workload lease and
# spawns the pinned image runtime. The grant that authorizes one generation is
# signed by the same approval broker a search grant comes from, so this wrapper
# is qwen-web-launch.sh with the image authority resolved first: it reads the
# preset's image markers, rejoins them to the ledger, proves the deadline stack
# is ordered, exports the image service's own settings, and hands the launch on.
# qwen-webui-control.sh forwards every QWEN_IMAGE_* value inside the tmux
# command string, and qwen-webui-session.sh starts the service as a guarded
# child and records its pid on the session status line.
#
# The listener is 127.0.0.1 and a caller asking for any other one is refused
# rather than silently rewritten, for the reason qwen-web-launch.sh states: an
# operator who typed 0.0.0.0 wants an exposure this launch declines to provide.
#
# One checked-in row of scripts/image-profiles.tsv reads `validator-gated`, so
# the preset a generator writes against the shipped ledger under
# QWEN_WEB_AUTHORIZER_READY=1 names that image profile and this launch arms the
# path. A preset naming none refuses and says so, and promoting a further row
# is a measurement on the appliance.
#
# The ledger row's `review_model` decides whether a second section serves. A
# named reviewer makes the preset two sections -- the language profile and one
# review-only vision section carrying that row's validated tuple and its
# projector -- and the page's Review button then appears, because it appears
# where `GET /props?model=` reports a vision modality for some roster row. Two
# resident checkpoints share one Vulkan carve-out that the 4B alone fills to
# 2029 of 2048 MiB, so the pair is measured before it is served: this wrapper
# sums every model and projector the preset names, adds the image runtime's own
# resident cost, hands the total to model-memory-preflight.sh, and refuses on
# the `device_budget_headroom=short` line the probe reports. The preflight
# stays the single authority for what the device has, and the launch is a
# reader of it. A `-` review_model leaves one section, and the review runs
# through scripts/image-review.py against a separate launch.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [PROFILE]\n' "$0" >&2
    printf '  cuda-runtime-env.sh takes the one profile vocabulary:\n' >&2
    printf '  default, no-graphs, no-fusion, pdl, unified, custom\n' >&2
    printf 'web preset file comes from QWEN_WEB_PRESETS, default $HOME/qwen-webui-state/web-presets.ini\n' >&2
    printf 'the preset must name an image profile, which requires a validator-gated row in scripts/image-profiles.tsv\n' >&2
    printf 'QWEN_IMAGE_PROFILES_JSON names the validated profile parameters the image service runs a job under\n' >&2
    printf 'QWEN_IMAGE_RUNTIME_RESIDENT_MIB is the image runtime cost charged against the Vulkan budget, default 480\n' >&2
    printf 'the listener is 127.0.0.1; QWEN_BIND_HOST set to any other value refuses the launch\n' >&2
    exit 2
fi

profile=${1:-default}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
web_launcher=$script_directory/qwen-web-launch.sh
image_service_program=${QWEN_IMAGE_SERVICE_PROGRAM:-$script_directory/image-service.py}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
web_presets=${QWEN_WEB_PRESETS:-$state_directory/web-presets.ini}

requested_bind_host=${QWEN_BIND_HOST:-127.0.0.1}
if [ "$requested_bind_host" != 127.0.0.1 ]; then
    printf 'image router mode serves the loopback alone, and QWEN_BIND_HOST requests %s\n' \
        "$requested_bind_host" >&2
    printf 'an image section spawns a device runtime through its MCP server; unset QWEN_BIND_HOST or set it to 127.0.0.1\n' >&2
    exit 2
fi

if [ ! -r "$web_presets" ]; then
    printf 'web presets are unreadable: %s\n' "$web_presets" >&2
    printf 'generate them with scripts/build-web-presets.sh\n' >&2
    exit 2
fi

# The generator records the image profile it emitted, the ledger it read, and
# that ledger's digest, so the launch reads one authority out of the file it
# launches rather than re-deriving it from an environment that may have moved.
preset_image_profile=$(sed -n 's/^# qwen_image_profile=//p' "$web_presets")
preset_image_profiles=$(sed -n 's/^# qwen_image_profiles_path=//p' "$web_presets")
preset_image_profiles_sha256=$(sed -n \
    's/^# qwen_image_profiles_sha256=//p' "$web_presets")
if [ -z "$preset_image_profile" ]; then
    printf 'the preset carries no image markers: %s\n' "$web_presets" >&2
    printf 'regenerate it with a scripts/build-web-presets.sh that reads scripts/image-profiles.tsv\n' >&2
    exit 2
fi
if [ "$preset_image_profile" = '-' ]; then
    printf 'every image profile in %s withholds an executing policy, so the preset arms no generation\n' \
        "${preset_image_profiles:-scripts/image-profiles.tsv}" >&2
    printf 'every checked-in row reads refused; a validator-gated row is a measurement on the appliance and the only thing this launch runs\n' >&2
    printf 'launch the ordinary web router with scripts/qwen-web-launch.sh\n' >&2
    exit 2
fi

case $preset_image_profiles in
    /*) ;;
    *)
        printf 'the preset omits an absolute image profile ledger path: %s\n' \
            "$web_presets" >&2
        exit 2
        ;;
esac
if [ "${#preset_image_profiles_sha256}" -ne 64 ]; then
    printf 'image preset ledger SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
    exit 2
fi
case $preset_image_profiles_sha256 in
    *[!0-9a-f]*)
        printf 'image preset ledger SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
        exit 2
        ;;
esac
if ! image_profiles_identity=$(sha256sum -- "$preset_image_profiles"); then
    printf 'image profile ledger identity cannot be measured: %s\n' \
        "$preset_image_profiles" >&2
    exit 2
fi
image_profiles_actual_sha256=${image_profiles_identity%% *}
if [ "$image_profiles_actual_sha256" != "$preset_image_profiles_sha256" ]; then
    printf 'image profile ledger identity changed: expected %s, measured %s\n' \
        "$preset_image_profiles_sha256" "$image_profiles_actual_sha256" >&2
    printf 'regenerate the preset tree with scripts/build-web-presets.sh\n' >&2
    exit 2
fi

# A preset persists across an edit to the ledger, so the row it names is read
# again here: a row moved to `refused` or removed outright refuses the launch
# rather than serving a persisted MCP configuration that still names it.
QWEN_IMAGE_PROFILES=$preset_image_profiles
export QWEN_IMAGE_PROFILES
if ! image_profile_row=$("$script_directory/image-registry.sh" profile \
    "$preset_image_profile" 2>/dev/null); then
    printf 'the preset names image profile %s, which %s holds no row for\n' \
        "$preset_image_profile" "$preset_image_profiles" >&2
    exit 2
fi
image_profile_field() {
    printf '%s\n' "$image_profile_row" | sed -n "s/^$1=//p"
}
image_execution_policy=$(image_profile_field execution_policy)
if [ "$image_execution_policy" != validator-gated ]; then
    printf 'image profile %s carries execution_policy %s, and only validator-gated reaches a runtime\n' \
        "$preset_image_profile" "${image_execution_policy:-<absent>}" >&2
    exit 2
fi

# The reviewer is a property of the image row, so the preset's own marker is
# rejoined to the ledger the way the image profile is: a row whose review_model
# changed since generation refuses rather than serving a persisted section that
# names a checkpoint the ledger no longer pairs with this shape.
preset_review_model=$(sed -n 's/^# qwen_image_review_model=//p' "$web_presets")
preset_review_section=$(sed -n 's/^# qwen_image_review_section=//p' "$web_presets")
if [ -z "$preset_review_model" ] || [ -z "$preset_review_section" ]; then
    printf 'the preset carries no review markers: %s\n' "$web_presets" >&2
    printf 'regenerate it with a scripts/build-web-presets.sh that reads review_model\n' >&2
    exit 2
fi
ledger_review_model=$(image_profile_field review_model)
if [ "$preset_review_model" != "$ledger_review_model" ]; then
    printf 'image profile %s pairs review_model %s where the preset carries %s\n' \
        "$preset_image_profile" "${ledger_review_model:-<absent>}" \
        "$preset_review_model" >&2
    printf 'regenerate the preset tree with scripts/build-web-presets.sh\n' >&2
    exit 2
fi
if [ "$preset_review_model" = '-' ]; then
    if [ "$preset_review_section" != '-' ]; then
        printf 'the preset names review section %s against review_model -\n' \
            "$preset_review_section" >&2
        exit 2
    fi
    review_section=
    expected_section_count=1
else
    if [ "$preset_review_section" != "$preset_review_model" ]; then
        printf 'the preset names review section %s for review_model %s\n' \
            "$preset_review_section" "$preset_review_model" >&2
        exit 2
    fi
    review_section=$preset_review_section
    expected_section_count=2
fi

# The section shape is read out of the file the launch hands on, because a
# preset persists across the generation that wrote it. A third section would
# leave the broker signing for one profile while two others served, and a
# review section stripped of its projector would answer an image request from
# nothing while the roster still advertises a vision modality.
preset_section_count=$(grep -c '^\[[^]]*\]$' "$web_presets" || true)
if [ "$preset_section_count" -ne "$expected_section_count" ]; then
    printf 'image router mode serves %s section(s) and %s carries %s\n' \
        "$expected_section_count" "$web_presets" "$preset_section_count" >&2
    printf 'one language section serves the turn, and a review_model adds one review-only vision section\n' >&2
    exit 2
fi
if [ -n "$review_section" ]; then
    if ! review_section_shape=$(awk -v wanted="$review_section" '
        /^[[:space:]]*\[/ {
            section = $0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            next
        }
        section != wanted { next }
        {
            separator = index($0, "=")
            if (separator == 0) next
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key == "LLAMA_ARG_MMPROJ") projector = value
            if (key == "LLAMA_ARG_MCP_SERVERS_CONFIG") configuration = value
            if (key == "LLAMA_ARG_TAGS") tags = value
        }
        END {
            if (projector == "") {
                print "the review section names no LLAMA_ARG_MMPROJ" > "/dev/stderr"
                exit 1
            }
            if (configuration != "") {
                print "the review section names an MCP configuration: " configuration > "/dev/stderr"
                exit 1
            }
            if (tags !~ /(^|,)review-only(,|$)/) {
                print "the review section carries tags " tags > "/dev/stderr"
                exit 1
            }
            print projector
        }
    ' "$web_presets"); then
        printf 'the review section %s is unusable in %s\n' \
            "$review_section" "$web_presets" >&2
        printf 'a reviewer reads an image through its own projector and holds no execution grant\n' >&2
        exit 2
    fi
    printf 'image_launch review_section=%s projector=%s\n' \
        "$review_section" "$review_section_shape"
fi

authorizer_ready=${QWEN_WEB_AUTHORIZER_READY:-0}
if [ "$authorizer_ready" != 1 ]; then
    printf 'an image section requires QWEN_WEB_AUTHORIZER_READY=1, which asserts that the argument-authorization validator runs\n' >&2
    exit 2
fi

# The approval broker is the only issuer of the grant an image call carries, so
# a section armed for generation without one serves a tool every call is
# refused. qwen-web-launch.sh applies every rule the signing key must meet;
# this wrapper requires the file to be named, because the image MCP child reads
# it under its own name and a launch that named none would reach the model as a
# per-call refusal.
signing_key_file=${QWEN_WEB_TOKEN_KEY_FILE:-}
if [ -z "$signing_key_file" ]; then
    printf 'the image grant signing key is unset\n' >&2
    printf 'QWEN_WEB_TOKEN_KEY_FILE names a regular file at mode 0600, owned by this user, holding the HMAC key\n' >&2
    exit 2
fi
QWEN_IMAGE_TOKEN_KEY_FILE=${QWEN_IMAGE_TOKEN_KEY_FILE:-$signing_key_file}
if [ "$QWEN_IMAGE_TOKEN_KEY_FILE" != "$signing_key_file" ]; then
    printf 'QWEN_IMAGE_TOKEN_KEY_FILE names %s where the broker signs with %s\n' \
        "$QWEN_IMAGE_TOKEN_KEY_FILE" "$signing_key_file" >&2
    printf 'one key signs both grant contexts, which the context string separates\n' >&2
    exit 2
fi

# The service runs a job under validated profile parameters rather than under
# the ledger row, because the row names no runtime binary and no argv template.
# The launch validates the file against the row it claims to serve, so a
# parameter set naming another geometry, another ceiling, or another policy
# refuses here rather than at the first approved generation.
image_profiles_json=${QWEN_IMAGE_PROFILES_JSON:-}
if [ ! -r "$image_profiles_json" ]; then
    printf 'QWEN_IMAGE_PROFILES_JSON names no readable file: %s\n' \
        "${image_profiles_json:-<unset>}" >&2
    printf 'the file holds validated profile parameters keyed by profile_id, which image-service.py runs a job under\n' >&2
    exit 2
fi
if ! image_parameters=$(python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    profiles = json.load(handle)
profile = profiles.get(sys.argv[2])
if not isinstance(profile, dict):
    raise SystemExit("the parameter file holds no object for " + sys.argv[2])
for name in ("width", "height", "steps", "max_steps", "max_dimension",
             "timeout_s", "execution_policy", "runtime_path"):
    if name not in profile:
        raise SystemExit("the parameters omit " + name)
    print("%s=%s" % (name, profile[name]))
' "$image_profiles_json" "$preset_image_profile"); then
    printf 'the image parameter file fails its own shape: %s\n' \
        "$image_profiles_json" >&2
    exit 2
fi
image_parameter_field() {
    printf '%s\n' "$image_parameters" | sed -n "s/^$1=//p"
}
for compared_field in width height steps max_steps max_dimension timeout_s \
    execution_policy; do
    ledger_value=$(image_profile_field "$compared_field")
    parameter_value=$(image_parameter_field "$compared_field")
    if [ "$ledger_value" != "$parameter_value" ]; then
        printf 'image profile %s carries %s %s in %s and %s in %s\n' \
            "$preset_image_profile" "$compared_field" "$ledger_value" \
            "$preset_image_profiles" "$parameter_value" "$image_profiles_json" >&2
        exit 2
    fi
done
image_runtime_path=$(image_parameter_field runtime_path)
if [ ! -x "$image_runtime_path" ]; then
    printf 'the image runtime is absent or not executable: %s\n' \
        "$image_runtime_path" >&2
    exit 2
fi

# The deadline stack is verified from the value each layer is configured with,
# because a number typed here would assert an ordering the system does not
# have. Four layers configure one: the profile row and image-service.py's own
# ceiling bound the runtime, image-service.py bounds the whole job, the
# emitted MCP configuration bounds the tool call, and webui/index.html bounds
# the page's wait. The router proxy configures none in this tree -- the patched
# router proxies with llama-server's own read timeout, 3600 s -- so the launch
# reads that default rather than claiming a 600 s bound nothing sets, and
# QWEN_IMAGE_ROUTER_PROXY_TIMEOUT_S states another where a deployment sets one.
# What the ordering buys is that the innermost deadline fires first: a stalled
# generation is ended by the process that owns it, and the proxy outlasts the
# tool call it is carrying.
runtime_hard_timeout=$(sed -n \
    's/^RUNTIME_HARD_TIMEOUT_SECONDS = \([0-9]\{1,\}\)$/\1/p' \
    "$image_service_program")
service_job_deadline=$(sed -n \
    's/^SERVICE_JOB_DEADLINE_SECONDS = \([0-9]\{1,\}\)$/\1/p' \
    "$image_service_program")
image_profile_timeout=$(image_profile_field timeout_s)
runtime_timeout=$image_profile_timeout
if [ "$runtime_hard_timeout" -lt "$runtime_timeout" ]; then
    runtime_timeout=$runtime_hard_timeout
fi

static_path=${QWEN_STATIC_PATH:-"$script_directory/../webui"}
browser_timeout_ms=$(sed -n \
    's/^const IMAGE_GENERATION_TIMEOUT_MS = \([0-9]\{1,\}\);$/\1/p' \
    "$static_path/index.html")
router_proxy_timeout=${QWEN_IMAGE_ROUTER_PROXY_TIMEOUT_S:-3600}

# The tool deadline is read from the configuration llama-server hands the
# child, rather than from the generator's own marker, because that file is what
# the running child applies. The same read proves the section names the five
# settings the child needs.
image_mcp_configuration=$(sed -n \
    's/^[[:space:]]*LLAMA_ARG_MCP_SERVERS_CONFIG[[:space:]]*=[[:space:]]*//p' \
    "$web_presets" | sed -n '1p')
if [ ! -r "${image_mcp_configuration:-}" ]; then
    printf 'the preset names no readable MCP configuration: %s\n' \
        "${image_mcp_configuration:-<absent>}" >&2
    exit 2
fi
if ! image_mcp_timeout_ms=$(python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    configuration = json.load(handle)
image = configuration.get("mcpServers", {}).get("image")
if not isinstance(image, dict):
    raise SystemExit("the configuration names no image server")
for name in ("QWEN_IMAGE_LANGUAGE_PROFILE", "QWEN_IMAGE_PROFILE",
             "QWEN_IMAGE_TOKEN_KEY_FILE", "QWEN_IMAGE_STATE_DIR",
             "QWEN_IMAGE_SERVICE_SOCKET", "QWEN_IMAGE_MCP_TIMEOUT_S"):
    if not image.get("env", {}).get(name):
        raise SystemExit("the image server names no " + name)
if image["env"]["QWEN_IMAGE_PROFILE"] != sys.argv[2]:
    raise SystemExit("the image server names another profile")
# The router bounds the call at timeout_ms and the child bounds its own socket
# read at QWEN_IMAGE_MCP_TIMEOUT_S. Two numbers for one deadline let the router
# wait past the point the child gave up, so the launch requires them to agree.
router_limit = int(image["timeout_ms"])
child_limit = float(image["env"]["QWEN_IMAGE_MCP_TIMEOUT_S"])
if abs(router_limit / 1000.0 - child_limit) > 0.001:
    raise SystemExit(
        "the image server bounds its call at %d ms and its own read at %g s"
        % (router_limit, child_limit)
    )
print(router_limit)
' "$image_mcp_configuration" "$preset_image_profile"); then
    printf 'the image MCP configuration is unusable: %s\n' \
        "$image_mcp_configuration" >&2
    exit 2
fi
image_mcp_timeout=$((image_mcp_timeout_ms / 1000))
browser_timeout=$((browser_timeout_ms / 1000))

for measured_deadline in "$runtime_timeout" "$service_job_deadline" \
    "$image_mcp_timeout" "$router_proxy_timeout" "$browser_timeout"; do
    case $measured_deadline in
        '' | 0 | *[!0-9]*)
            printf 'a deadline in the stack is unreadable: runtime=%s service=%s mcp=%s proxy=%s browser=%s\n' \
                "$runtime_timeout" "$service_job_deadline" \
                "$image_mcp_timeout" "$router_proxy_timeout" \
                "$browser_timeout" >&2
            exit 2
            ;;
    esac
done

deadline_breach=''
if [ "$runtime_timeout" -ge "$service_job_deadline" ]; then
    deadline_breach='runtime>=service'
elif [ "$service_job_deadline" -ge "$image_mcp_timeout" ]; then
    deadline_breach='service>=mcp'
elif [ "$image_mcp_timeout" -ge "$browser_timeout" ]; then
    deadline_breach='mcp>=browser'
elif [ "$image_mcp_timeout" -ge "$router_proxy_timeout" ]; then
    deadline_breach='mcp>=proxy'
fi
if [ -n "$deadline_breach" ]; then
    printf 'the image deadline stack is out of order at %s: runtime=%s service=%s mcp=%s proxy=%s browser=%s\n' \
        "$deadline_breach" "$runtime_timeout" "$service_job_deadline" \
        "$image_mcp_timeout" "$router_proxy_timeout" "$browser_timeout" >&2
    printf 'a stalled generation is ended by the process that owns it, so each deadline sits inside the one above it\n' >&2
    exit 2
fi
printf 'image_launch timeouts runtime=%s service=%s mcp=%s proxy=%s browser=%s proxy_source=%s\n' \
    "$runtime_timeout" "$service_job_deadline" "$image_mcp_timeout" \
    "$router_proxy_timeout" "$browser_timeout" \
    "${QWEN_IMAGE_ROUTER_PROXY_TIMEOUT_S:+configured}${QWEN_IMAGE_ROUTER_PROXY_TIMEOUT_S:-llama-server-default}"

# Two resident checkpoints and a running image runtime draw on one Vulkan
# carve-out, so the requirement is summed from what the preset names and the
# probe answers whether the device holds it. model-memory-preflight.sh reports
# and admits every launch by design -- a prediction that a model will not fit
# was wrong once and read as a hardware limit -- so this launch reads its
# `device_budget_headroom` line and makes the refusal its own, where the pair
# is a configuration choice rather than the single load the report was written
# for. The runtime's resident cost is a measured figure from the standalone
# campaign rather than a derived one, and it is charged whole because a
# generation runs while both children stay loaded.
image_runtime_resident_mib=${QWEN_IMAGE_RUNTIME_RESIDENT_MIB:-480}
case $image_runtime_resident_mib in
    '' | *[!0-9]*)
        printf 'QWEN_IMAGE_RUNTIME_RESIDENT_MIB must be a non-negative integer of MiB: %s\n' \
            "$image_runtime_resident_mib" >&2
        exit 2
        ;;
esac
memory_preflight_program=${QWEN_MEMORY_PREFLIGHT_PROGRAM:-$script_directory/model-memory-preflight.sh}
# The named paths reach the loop through a file rather than through command
# substitution, which field-splits a path holding a space, and the loop reads
# from a redirection so its running total survives it.
resident_artifact_list=$(mktemp)
trap 'rm -f -- "$resident_artifact_list"' EXIT HUP INT TERM
awk '
    {
        separator = index($0, "=")
        if (separator == 0) next
        key = substr($0, 1, separator - 1)
        value = substr($0, separator + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (key == "LLAMA_ARG_MODEL" || key == "LLAMA_ARG_MMPROJ") print value
    }
' "$web_presets" >"$resident_artifact_list"
if [ ! -s "$resident_artifact_list" ]; then
    printf 'the preset names no weights to size the device against: %s\n' \
        "$web_presets" >&2
    exit 2
fi
resident_artifact_bytes=0
while IFS= read -r resident_artifact; do
    [ -n "$resident_artifact" ] || continue
    if [ ! -f "$resident_artifact" ]; then
        printf 'the preset names an artifact this machine holds no file for: %s\n' \
            "$resident_artifact" >&2
        exit 2
    fi
    resident_artifact_bytes=$((resident_artifact_bytes + $(wc -c <"$resident_artifact")))
done <"$resident_artifact_list"
rm -f -- "$resident_artifact_list"
trap - EXIT HUP INT TERM
mebibyte=1048576
resident_artifact_mib=$(((resident_artifact_bytes + mebibyte - 1) / mebibyte))
required_vulkan_mib=$((resident_artifact_mib + image_runtime_resident_mib))
preflight_subject=$(sed -n \
    's/^[[:space:]]*LLAMA_ARG_MODEL[[:space:]]*=[[:space:]]*//p' \
    "$web_presets" | sed -n '1p')
if ! image_budget_report=$("$memory_preflight_program" "$preflight_subject" \
    "$required_vulkan_mib"); then
    printf 'the memory preflight failed to measure the device\n' >&2
    printf '%s\n' "$image_budget_report" >&2
    exit 2
fi
printf '%s\n' "$image_budget_report"
printf 'image_launch budget artifacts_mib=%s runtime_mib=%s required_mib=%s sections=%s\n' \
    "$resident_artifact_mib" "$image_runtime_resident_mib" \
    "$required_vulkan_mib" "$preset_section_count"
# The refusal belongs to the pairing rather than to the lane. A one-section
# launch is the shape evidence/image-appliance/served-turn-admission/ ran and
# passed without this arithmetic, and model-memory-preflight.sh reports rather
# than refuses because a prediction of this kind was wrong once and read as a
# hardware limit; the number is printed on both paths and decides only the
# launch that adds a second resident checkpoint the appliance has never held.
if [ -n "$review_section" ] &&
    printf '%s\n' "$image_budget_report" |
    grep -q '^device_budget_headroom=short'; then
    printf 'the Vulkan budget holds less than the %s MiB this preset needs, plus the margin the probe adds\n' \
        "$required_vulkan_mib" >&2
    printf '%s\n' "$image_budget_report" | grep '^device_budget_headroom=' >&2
    printf 'pair the image row with a smaller review_model, or set review_model to - and review through scripts/image-review.py\n' >&2
    exit 2
fi
# The session runs its own preflight against the same denominator, so the two
# reports read one requirement rather than this launch measuring the pair and
# the session measuring a fixed default.
QWEN_REQUIRED_VULKAN_MIB=$required_vulkan_mib
export QWEN_REQUIRED_VULKAN_MIB
if [ -n "$review_section" ]; then
    QWEN_WEB_REVIEW_SECTION=$review_section
    export QWEN_WEB_REVIEW_SECTION
fi

QWEN_IMAGE_SERVICE=1
QWEN_IMAGE_SERVICE_PROGRAM=$image_service_program
QWEN_IMAGE_PROFILES_JSON=$image_profiles_json
QWEN_IMAGE_PROFILE=$preset_image_profile
export QWEN_IMAGE_SERVICE QWEN_IMAGE_SERVICE_PROGRAM QWEN_IMAGE_PROFILES_JSON
export QWEN_IMAGE_PROFILE QWEN_IMAGE_TOKEN_KEY_FILE
printf 'image_launch profile=%s ledger=%s runtime=%s parameters=%s\n' \
    "$preset_image_profile" "$preset_image_profiles" "$image_runtime_path" \
    "$image_profiles_json"

exec "$web_launcher" "$profile"
