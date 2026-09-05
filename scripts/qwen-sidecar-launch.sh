#!/bin/sh
set -eu
# gpu-ownership: delegated to qwen-webui-session.sh through qwen-web-launch.sh,
# which takes the owner lock on the far side of tmux.
#
# Launch the web router with one or both device sidecars armed: the preset
# names a validator-gated physics or geometry profile, this script rejoins
# each marker to its ledger and requires the row to still read
# validator-gated, resolves the runtime binary each service spawns and
# proves its digest equals the one the preset's MCP configuration carries,
# and hands the session the lane's enable flag, program, ledger, and runtime
# beside the broker's profile. The session then starts each service under
# the compute lease it names, with the lease file's identity, so a service
# configured against another file refuses ahead of its first request.
#
# The image lane's rules hold here whole: loopback alone, one language
# section, one broker signing for the profile it serves.

usage() {
    printf 'usage: %s [PROFILE]\n' "$0" >&2
    printf '  QWEN_WEB_PRESETS names the preset tree (default: $QWEN_WEBUI_STATE_DIRECTORY/web-presets.ini)\n' >&2
    printf '  QWEN_PHYSICS_RUNTIME and QWEN_GEOMETRY_RUNTIME name the runtime binaries the armed lanes spawn\n' >&2
    exit 2
}
[ "$#" -le 1 ] || usage
profile=${1:-}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
web_launcher=$script_directory/qwen-web-launch.sh
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
web_presets=${QWEN_WEB_PRESETS:-$state_directory/web-presets.ini}
requested_bind_host=${QWEN_BIND_HOST:-127.0.0.1}
if [ "$requested_bind_host" != 127.0.0.1 ]; then
    printf 'sidecar router mode serves the loopback alone, and QWEN_BIND_HOST requests %s\n' "$requested_bind_host" >&2
    exit 2
fi
[ -r "$web_presets" ] || {
    printf 'web presets are unreadable: %s\n' "$web_presets" >&2
    exit 2
}
preset_marker() { sed -n "s/^# $1=//p" "$web_presets" | sed -n '1p'; }
armed_lanes=0

# check_lane LANE LEDGER_POLICY_COLUMN RUNTIME_PATH: rejoin the preset's marker
# to the ledger, require validator-gated, prove the runtime's digest against
# the preset's MCP configuration, and export the lane's session variables; a
# marker reading - leaves the lane unarmed and its runtime unread.
check_lane() {
    lane=$1
    policy_column=$2
    runtime_path=$3
    lane_upper=$(printf '%s' "$lane" | tr '[:lower:]' '[:upper:]')
    preset_profile=$(preset_marker "qwen_${lane}_profile")
    preset_ledger=$(preset_marker "qwen_${lane}_profiles_path")
    preset_ledger_sha256=$(preset_marker "qwen_${lane}_profiles_sha256")
    if [ -z "$preset_profile" ]; then
        printf 'the preset carries no %s markers: %s\n' "$lane" "$web_presets" >&2
        printf 'regenerate it with a scripts/build-web-presets.sh that reads scripts/%s-profiles.tsv\n' "$lane" >&2
        exit 2
    fi
    if [ "$preset_profile" = '-' ]; then
        printf '%s_launch lane=unarmed\n' "$lane"
        return 0
    fi
    case $preset_ledger in
        /*) ;;
        *) printf 'the preset omits an absolute %s ledger path\n' "$lane" >&2; exit 2 ;;
    esac
    ledger_actual_sha256=$(sha256sum -- "$preset_ledger" | cut -d ' ' -f 1)
    if [ "$ledger_actual_sha256" != "$preset_ledger_sha256" ]; then
        printf '%s ledger identity changed: expected %s, measured %s\n' "$lane" "$preset_ledger_sha256" "$ledger_actual_sha256" >&2
        printf 'regenerate the preset tree with scripts/build-web-presets.sh\n' >&2
        exit 2
    fi
    ledger_policy=$(awk -F '\t' -v id="$preset_profile" -v column="$policy_column" \
        '!/^#/ && $1 == id { print $column }' "$preset_ledger")
    if [ "$ledger_policy" != validator-gated ]; then
        printf '%s profile %s reads %s in %s where the preset was generated from validator-gated\n' \
            "$lane" "$preset_profile" "${ledger_policy:-<absent>}" "$preset_ledger" >&2
        exit 2
    fi
    if [ -z "$runtime_path" ] || [ ! -x "$runtime_path" ]; then
        printf 'the %s lane is armed and QWEN_%s_RUNTIME names no executable: %s\n' \
            "$lane" "$lane_upper" "${runtime_path:-<unset>}" >&2
        exit 2
    fi
    runtime_sha256=$(sha256sum -- "$runtime_path" | cut -d ' ' -f 1)
    mcp_config=$(sed -n 's/^LLAMA_ARG_MCP_SERVERS_CONFIG = //p' "$web_presets" | sed -n '1p')
    [ -r "$mcp_config" ] || {
        printf 'the preset names no readable MCP configuration for its section\n' >&2
        exit 2
    }
    # The configuration the child reads is the one source of the lane's
    # runtime digest, state directory, socket, and signing key; the session
    # is handed the same three paths so the service and the child meet on them.
    configured=$(python3 - "$mcp_config" "$lane" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
environment = ((document.get("mcpServers") or {}).get(sys.argv[2]) or {}).get("env") or {}
for key in ("QWEN_SIDECAR_RUNTIME_SHA256", "QWEN_SIDECAR_STATE_DIR", "QWEN_SIDECAR_SERVICE_SOCKET", "QWEN_SIDECAR_TOKEN_KEY_FILE"):
    print(environment.get(key, ""))
PY
)
    configured_sha256=$(printf '%s\n' "$configured" | sed -n '1p')
    configured_state_directory=$(printf '%s\n' "$configured" | sed -n '2p')
    configured_socket=$(printf '%s\n' "$configured" | sed -n '3p')
    configured_token_key_file=$(printf '%s\n' "$configured" | sed -n '4p')
    if [ "$configured_sha256" != "$runtime_sha256" ]; then
        printf 'the %s runtime %s digests %s where the preset configuration carries %s\n' \
            "$lane" "$runtime_path" "$runtime_sha256" "${configured_sha256:-<absent>}" >&2
        printf 'regenerate the preset with QWEN_%s_RUNTIME_SHA256 set to the runtime that will run\n' "$lane_upper" >&2
        exit 2
    fi
    for configured_path in "$configured_state_directory" "$configured_socket" "$configured_token_key_file"; do
        case $configured_path in
            /*) ;;
            *)
                printf 'the %s configuration names no absolute state directory, socket, and key file\n' "$lane" >&2
                exit 2 ;;
        esac
    done
    if [ ! -f "$configured_token_key_file" ]; then
        printf 'the %s configuration names a signing key file that is absent: %s\n' "$lane" "$configured_token_key_file" >&2
        exit 2
    fi
    armed_lanes=$((armed_lanes + 1))
    printf '%s_launch lane=armed profile=%s ledger=%s runtime=%s runtime_sha256=%s state=%s socket=%s\n' \
        "$lane" "$preset_profile" "$preset_ledger" "$runtime_path" "$runtime_sha256" \
        "$configured_state_directory" "$configured_socket"
    lane_armed=1
}

lane_armed=0
check_lane physics 9 "${QWEN_PHYSICS_RUNTIME:-}"
if [ "$lane_armed" = 1 ]; then
    QWEN_PHYSICS_SERVICE=1
    QWEN_PHYSICS_PROFILE=$preset_profile
    QWEN_PHYSICS_PROFILES=$preset_ledger
    QWEN_PHYSICS_STATE_DIR=$configured_state_directory
    QWEN_PHYSICS_SERVICE_SOCKET=$configured_socket
    QWEN_SIDECAR_TOKEN_KEY_FILE=$configured_token_key_file
    export QWEN_PHYSICS_SERVICE QWEN_PHYSICS_PROFILE QWEN_PHYSICS_PROFILES QWEN_PHYSICS_RUNTIME
    export QWEN_PHYSICS_STATE_DIR QWEN_PHYSICS_SERVICE_SOCKET QWEN_SIDECAR_TOKEN_KEY_FILE
fi
lane_armed=0
check_lane geometry 6 "${QWEN_GEOMETRY_RUNTIME:-}"
if [ "$lane_armed" = 1 ]; then
    QWEN_GEOMETRY_SERVICE=1
    QWEN_GEOMETRY_PROFILE=$preset_profile
    QWEN_GEOMETRY_PROFILES=$preset_ledger
    QWEN_GEOMETRY_STATE_DIR=$configured_state_directory
    QWEN_GEOMETRY_SERVICE_SOCKET=$configured_socket
    if [ -n "${QWEN_SIDECAR_TOKEN_KEY_FILE:-}" ] && [ "$QWEN_SIDECAR_TOKEN_KEY_FILE" != "$configured_token_key_file" ]; then
        printf 'the two lanes name different signing keys where one broker signs for both\n' >&2
        exit 2
    fi
    QWEN_SIDECAR_TOKEN_KEY_FILE=$configured_token_key_file
    export QWEN_GEOMETRY_SERVICE QWEN_GEOMETRY_PROFILE QWEN_GEOMETRY_PROFILES QWEN_GEOMETRY_RUNTIME
    export QWEN_GEOMETRY_STATE_DIR QWEN_GEOMETRY_SERVICE_SOCKET QWEN_SIDECAR_TOKEN_KEY_FILE
fi
if [ "$armed_lanes" -eq 0 ]; then
    printf 'every physics and geometry profile the preset read withholds an executing policy, so this launch arms no sidecar\n' >&2
    printf 'launch the ordinary web router with scripts/qwen-web-launch.sh\n' >&2
    exit 2
fi
exec "$web_launcher" "$profile"
