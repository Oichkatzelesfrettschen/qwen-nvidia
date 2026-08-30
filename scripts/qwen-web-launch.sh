#!/bin/sh
set -eu

# Start the appliance in router mode against the web preset file that
# scripts/build-web-presets.sh produces, on the loopback alone.
#
# A web preset section reaches a network the appliance otherwise never touches:
# a validator-gated section carries LLAMA_ARG_MCP_SERVERS_CONFIG, and the
# configured server performs searches and fetches on the model's behalf. The
# appliance binds 0.0.0.0 by default so the laptop serves the LAN, which would
# put that retrieval capability on every host of that network. This wrapper
# therefore sets QWEN_BIND_HOST=127.0.0.1 and refuses a caller who asked for any
# other listener, rather than forcing the value silently: the operator who typed
# 0.0.0.0 wants an exposure this launch declines to provide, and a refusal says
# so where a rewrite would leave the request looking honoured.
#
# The wrapper reads every path its sections name, because a preset persists
# across the generation that resolved it: an MCP configuration llama-server
# cannot read fails the child at startup, and a projector that has moved since
# generation leaves the vision child answering an image request from nothing.
#
# qwen-capacity-policy.sh forces the same loopback for a preset carrying the
# unvalidated-depth marker, so the restriction survives a launch that reaches
# the policy another way.
#
# QWEN_ROUTER_MAX is 1. The 4B alone peaks at 2029 MiB of a 2048 MiB VRAM
# carve-out, so a second resident model competes for a pool one model already
# saturates. qwen-webui-control.sh forwards QWEN_ROUTER_MAX inside the tmux
# command string, so the value reaches qwen-capacity-policy.sh across the tmux
# boundary that a plain export stops at.
#
# QWEN_WEB_REVIEW_SECTION raises both numbers by one. qwen-image-launch.sh sets
# it to the review-only vision section build-web-presets.sh emits beside the
# language one, having proved that pair fits the Vulkan budget the memory
# preflight reports; the page then reads two ids from `GET /v1/models` and its
# Review button reaches the vision row. The name is required to be a section the
# preset actually carries, so a marker that survived a regeneration refuses the
# launch rather than raising the model limit for a section that left.
#
# The wrapper reports the preset's marker state and the QWEN_WEB_AUTHORIZER_READY
# setting before it launches, because those two decide what the running server
# can do: the marker says a section serves a depth no run has filled and
# decoded, and the authorizer setting says whether the generator admitted
# validator-gated rows at all.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [PROFILE]\n' "$0" >&2
    printf '  the profile vocabulary belongs to the backend that serves: cuda-runtime-env.sh takes\n' >&2
    printf '  default, no-graphs, no-fusion, pdl, unified, custom; vulkan-runtime-env.sh, reached with\n' >&2
    printf '  QWEN_SERVING_BACKEND=vulkan, takes default, custom\n' >&2
    printf 'web preset file comes from QWEN_WEB_PRESETS, default $HOME/qwen-webui-state/web-presets.ini\n' >&2
    printf 'the listener is 127.0.0.1; QWEN_BIND_HOST set to any other value refuses the launch\n' >&2
    exit 2
fi

profile=${1:-default}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
launcher=$script_directory/qwen-launch.sh
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
web_presets=${QWEN_WEB_PRESETS:-$state_directory/web-presets.ini}

# The caller's own listener request is read before it is replaced, so an
# explicit LAN bind refuses rather than serving retrieval on the loopback while
# the operator believes the LAN is listening.
requested_bind_host=${QWEN_BIND_HOST:-127.0.0.1}
if [ "$requested_bind_host" != 127.0.0.1 ]; then
    printf 'web router mode serves the loopback alone, and QWEN_BIND_HOST requests %s\n' \
        "$requested_bind_host" >&2
    printf 'a web preset section reaches the network through its MCP server; unset QWEN_BIND_HOST or set it to 127.0.0.1\n' >&2
    exit 2
fi

if [ ! -r "$web_presets" ]; then
    printf 'web presets are unreadable: %s\n' "$web_presets" >&2
    printf 'generate them with scripts/build-web-presets.sh\n' >&2
    exit 2
fi

if ! grep -qx '# qwen_web_presets=1' "$web_presets"; then
    printf 'preset file carries no web provenance marker: %s\n' "$web_presets" >&2
    printf 'scripts/build-web-presets.sh writes `# qwen_web_presets=1`; regenerate the file\n' >&2
    exit 2
fi

# The preset binds the complete web-policy ledger used to generate its
# sections. The ledger identity markers define the launch authority and reject
# callers naming a different ledger.
preset_web_profiles=$(sed -n 's/^# qwen_web_profiles_path=//p' "$web_presets")
preset_web_profiles_sha256=$(sed -n \
    's/^# qwen_web_profiles_sha256=//p' "$web_presets")
case $preset_web_profiles in
    /*) ;;
    *)
        printf 'web presets omit an absolute web profile ledger path: %s\n' \
            "$web_presets" >&2
        exit 2
        ;;
esac
if [ "${#preset_web_profiles_sha256}" -ne 64 ]; then
    printf 'web preset ledger SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
    exit 2
fi
case $preset_web_profiles_sha256 in
    *[!0-9a-f]*)
        printf 'web preset ledger SHA-256 must hold 64 lowercase hexadecimal characters\n' >&2
        exit 2
        ;;
esac
if [ -n "${QWEN_WEB_PROFILES:-}" ] &&
    [ "$QWEN_WEB_PROFILES" != "$preset_web_profiles" ]; then
    printf 'QWEN_WEB_PROFILES names %s where the preset binds %s\n' \
        "$QWEN_WEB_PROFILES" "$preset_web_profiles" >&2
    exit 2
fi
if ! preset_web_profiles_identity=$(sha256sum -- "$preset_web_profiles"); then
    printf 'web profile ledger identity cannot be measured: %s\n' \
        "$preset_web_profiles" >&2
    exit 2
fi
preset_web_profiles_actual_sha256=${preset_web_profiles_identity%% *}
if [ "$preset_web_profiles_actual_sha256" != "$preset_web_profiles_sha256" ]; then
    printf 'web profile ledger identity changed: expected %s, measured %s\n' \
        "$preset_web_profiles_sha256" "$preset_web_profiles_actual_sha256" >&2
    exit 2
fi
QWEN_WEB_PROFILES=$preset_web_profiles
export QWEN_WEB_PROFILES

authorizer_ready=${QWEN_WEB_AUTHORIZER_READY:-0}
case $authorizer_ready in
    0 | 1) ;;
    *)
        printf 'QWEN_WEB_AUTHORIZER_READY must be 0 or 1: %s\n' \
            "$authorizer_ready" >&2
        exit 2
        ;;
esac
if grep -E '^[[:space:]]*LLAMA_ARG_TAGS[[:space:]]*=([[:space:]]*[^,]+,)*[[:space:]]*validator-gated([[:space:]]*,|[[:space:]]*$)' \
    "$web_presets" >/dev/null && [ "$authorizer_ready" != 1 ]; then
    printf 'validator-gated web presets require QWEN_WEB_AUTHORIZER_READY=1\n' >&2
    exit 2
fi

# Every artifact a section names is read here, because llama-server reports an
# unreadable mcp-servers-config as a child startup failure well after the
# listener is up, and reads a section's projector only when a request selects
# that child, so an absent projector answers an image request from nothing while
# the listener has already reported ready. A preset persists across the
# generation that resolved both paths, so a file deleted or moved since then is
# found before the launch rather than by the request that needs it.
#
# The named paths reach the loop one line at a time through a file rather than
# through command substitution, which field-splits a path holding a space into
# several unreadable fragments; $HOME, QWEN_WEBUI_STATE_DIRECTORY, and
# QWEN_WEB_PRESETS each place one in the generated tree. The loop reads from a
# redirection rather than a pipeline so its count survives the loop, since a
# pipeline runs the body in a subshell and leaves the count at zero.
named_artifact_list=$(mktemp)
trap 'rm -f -- "$named_artifact_list"' EXIT HUP INT TERM
missing_named_artifacts=0
count_missing_named_artifacts() {
    artifact_key=$1
    artifact_description=$2
    sed -n "s/^[[:space:]]*${artifact_key}[[:space:]]*=[[:space:]]*//p" \
        "$web_presets" >"$named_artifact_list"
    while IFS= read -r named_artifact; do
        [ -n "$named_artifact" ] || continue
        if [ ! -f "$named_artifact" ]; then
            printf 'preset names %s: %s\n' \
                "$artifact_description" "$named_artifact" >&2
            missing_named_artifacts=$((missing_named_artifacts + 1))
        fi
    done <"$named_artifact_list"
}
count_missing_named_artifacts LLAMA_ARG_MCP_SERVERS_CONFIG \
    'an unreadable MCP configuration'
count_missing_named_artifacts LLAMA_ARG_MMPROJ \
    'a projector that is not a regular file'
rm -f -- "$named_artifact_list"
trap - EXIT HUP INT TERM
if [ "$missing_named_artifacts" -ne 0 ]; then
    printf 'regenerate the preset tree with scripts/build-web-presets.sh\n' >&2
    exit 2
fi

if grep -qx '# qwen-web-presets: unvalidated-depth-override' "$web_presets"; then
    depth_marker_state=present
else
    depth_marker_state=absent
fi
printf 'web_launch presets=%s unvalidated_depth_marker=%s authorizer_ready=%s bind=127.0.0.1\n' \
    "$web_presets" "$depth_marker_state" "${QWEN_WEB_AUTHORIZER_READY:-0}"

# The approval broker's lifetime is this launch's. A section reaching the
# network through its MCP server signs each search from one human approval, and
# `authorize-broker.py` is the only issuer of that signature, so a web router
# running while nothing issues grants serves a tool every call is refused. This
# marker travels to qwen-webui-session.sh through qwen-webui-control.sh, which
# starts the broker as a guarded child; the ordinary qwen-launch.sh path leaves
# the marker unset and starts no broker.
#
# The signing key is required whole before the launch: nonempty path, regular
# file rather than a symlink, owned by the serving user, mode 0600 or tighter,
# readable, and nonempty. A broker that starts without a usable key answers
# `listening` and then refuses the first approval a human has already given, so
# every rule the broker applies at its own startup is applied here first, where
# the refusal names the rule. The path alone crosses into the child; the
# contents stay in the broker's address space.
QWEN_WEB_BROKER=1
# Browser calls and broker approvals share the server API key. Web mode always
# creates or reuses the API key; callers cannot downgrade the session to the
# unauthenticated default used by ordinary local serving.
QWEN_REQUIRE_API_KEY=1
QWEN_WEB_BROKER_PORT=${QWEN_WEB_BROKER_PORT:-8571}
QWEN_WEB_STATE_DIR=${QWEN_WEB_STATE_DIR:-$state_directory/web-mcp}
signing_key_file=${QWEN_WEB_TOKEN_KEY_FILE:-}
refuse_signing_key() {
    printf 'the grant signing key %s: %s\n' "$1" "${signing_key_file:-<unset>}" >&2
    printf 'QWEN_WEB_TOKEN_KEY_FILE names a regular file at mode 0600, owned by this user, holding the HMAC key\n' >&2
    exit 2
}
if [ -z "$signing_key_file" ]; then
    refuse_signing_key 'is unset'
fi
if [ -L "$signing_key_file" ]; then
    refuse_signing_key 'is a symbolic link'
fi
if [ ! -f "$signing_key_file" ]; then
    refuse_signing_key 'is not a regular file'
fi
signing_key_owner=$(stat -c %u "$signing_key_file" 2>/dev/null || echo unknown)
if [ "$signing_key_owner" != "$(id -u)" ]; then
    refuse_signing_key "is owned by uid $signing_key_owner rather than $(id -u)"
fi
if [ ! -r "$signing_key_file" ]; then
    refuse_signing_key 'is unreadable'
fi
if [ ! -s "$signing_key_file" ]; then
    refuse_signing_key 'is empty'
fi
signing_key_mode=$(stat -c %a "$signing_key_file" 2>/dev/null || echo unknown)
case $signing_key_mode in
    400 | 600) ;;
    *) refuse_signing_key "carries mode $signing_key_mode rather than 0600" ;;
esac
export QWEN_WEB_TOKEN_KEY_FILE

# One broker signs for one profile: `POST /grant` refuses a `profile_id` other
# than the `--profile` the broker started with, so a preset holding several
# language sections would leave every section but one with a broker that
# refuses it, and the browser would learn that after a human approved the
# search. The profile is therefore read from the preset rather than typed: the
# launch requires exactly one language section, names it QWEN_WEB_PROFILE, and
# refuses a caller whose own QWEN_WEB_PROFILE names anything else.
#
# A review-only vision section is the one section that joins it, and the broker
# signs nothing for it: the page posts one chat completion to that model and
# the request body omits `tools`, so the reviewer reaches neither the network
# nor the device. The section name is therefore subtracted here before the
# language profile is read, since a second header would otherwise make
# preset_profile two lines and hand the broker a profile spelled across a
# newline.
review_section=${QWEN_WEB_REVIEW_SECTION:-}
case $review_section in
    '' | *[!A-Za-z0-9._-]*)
        if [ -n "$review_section" ]; then
            printf 'QWEN_WEB_REVIEW_SECTION is not a section name: %s\n' \
                "$review_section" >&2
            exit 2
        fi
        ;;
esac
expected_section_count=1
if [ -n "$review_section" ]; then
    if ! grep -qxF "[$review_section]" "$web_presets"; then
        printf 'QWEN_WEB_REVIEW_SECTION names %s, which %s carries no section for\n' \
            "$review_section" "$web_presets" >&2
        printf 'regenerate the preset tree with scripts/build-web-presets.sh\n' >&2
        exit 2
    fi
    expected_section_count=2
fi
preset_section_count=$(grep -c '^\[[^]]*\]$' "$web_presets" || true)
if [ "$preset_section_count" -ne "$expected_section_count" ]; then
    printf 'web router mode starts one broker for one profile, and %s carries %s sections where %s are admitted\n' \
        "$web_presets" "$preset_section_count" "$expected_section_count" >&2
    printf 'generate a preset holding one language section, and one review-only vision section where an image row pairs a review_model\n' >&2
    exit 2
fi
preset_profile=$(sed -n 's/^\[\([^]]*\)\]$/\1/p' "$web_presets" |
    grep -vxF "${review_section:-}" || true)
case $preset_profile in
    '' | *[!A-Za-z0-9._-]*)
        printf 'web preset section name is not a profile id: %s\n' "$preset_profile" >&2
        exit 2
        ;;
esac
if [ -n "${QWEN_WEB_PROFILE:-}" ] && [ "$QWEN_WEB_PROFILE" != "$preset_profile" ]; then
    printf 'QWEN_WEB_PROFILE names %s where the preset serves %s\n' \
        "$QWEN_WEB_PROFILE" "$preset_profile" >&2
    exit 2
fi
QWEN_WEB_PROFILE=$preset_profile
preset_provider=$(sed -n 's/^# qwen_web_provider=//p' "$web_presets")
case $preset_provider in
    exa | fake | searxng) ;;
    *)
        printf 'web preset provider must be exa, fake, or searxng: %s\n' \
            "${preset_provider:-<absent>}" >&2
        exit 2
        ;;
esac
if [ -n "${QWEN_WEB_PROVIDER:-}" ] && \
   [ "$QWEN_WEB_PROVIDER" != "$preset_provider" ]; then
    printf 'QWEN_WEB_PROVIDER names %s where the preset serves %s\n' \
        "$QWEN_WEB_PROVIDER" "$preset_provider" >&2
    exit 2
fi
QWEN_WEB_PROVIDER=$preset_provider
export QWEN_WEB_PROFILE QWEN_WEB_PROVIDER
printf 'web_launch broker_port=%s broker_state_dir=%s signing_key=configured profile=%s provider=%s review_section=%s models_max=%s\n' \
    "$QWEN_WEB_BROKER_PORT" "$QWEN_WEB_STATE_DIR" "$QWEN_WEB_PROFILE" \
    "$QWEN_WEB_PROVIDER" "${review_section:--}" "$expected_section_count"

# The page the router serves is the executor the browser runs, and the pinned
# llama UI build neither scopes GET /tools by model nor posts the routing key
# beside the tool, so web mode serves the repository fallback page.
# qwen-webui-control.sh reads QWEN_STATIC_PATH before its own default, and
# the page is read here for the two route shapes the broker path depends on,
# so a directory holding some other index.html refuses before the listener
# exists.
QWEN_STATIC_PATH=${QWEN_STATIC_PATH:-"$script_directory/../webui"}
if [ ! -f "$QWEN_STATIC_PATH/index.html" ]; then
    printf 'web mode serves the fallback page and finds no index.html under %s\n' \
        "$QWEN_STATIC_PATH" >&2
    exit 2
fi
if ! grep -qF 'tools?model=' "$QWEN_STATIC_PATH/index.html" || \
   ! grep -qF 'model, tool: toolName, params' "$QWEN_STATIC_PATH/index.html"; then
    printf 'the page under %s composes no model-scoped /tools request; web mode serves webui/index.html\n' \
        "$QWEN_STATIC_PATH" >&2
    exit 2
fi
export QWEN_STATIC_PATH
printf 'web_launch static_path=%s\n' "$QWEN_STATIC_PATH"

QWEN_ROUTER=1
QWEN_ROUTER_PRESETS=$web_presets
# The router holds one child per admitted section, so a review section raises
# the limit to the pair the launch already proved resident.
QWEN_ROUTER_MAX=$expected_section_count
QWEN_BIND_HOST=127.0.0.1
export QWEN_ROUTER QWEN_ROUTER_PRESETS QWEN_ROUTER_MAX QWEN_BIND_HOST
export QWEN_WEB_BROKER QWEN_WEB_BROKER_PORT QWEN_WEB_STATE_DIR
export QWEN_REQUIRE_API_KEY

exec "$launcher" "$profile"
