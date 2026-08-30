#!/bin/sh
set -eu

# Start the guarded Web UI and return only once it answers HTTP. The service
# exists for as long as this script's session lives in tmux and no longer: no
# unit file, no crontab entry, and no login hook starts it, so a reboot leaves
# the laptop with nothing listening until someone runs this again.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [default|no-graphs|no-fusion|pdl|unified]\n' "$0" >&2
    exit 2
fi

profile=${1:-default}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
control=$script_directory/qwen-webui-control.sh
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
bind_host=${QWEN_BIND_HOST:-127.0.0.1}
server_port=${QWEN_SERVER_PORT:-8080}
ready_attempts=${QWEN_READY_ATTEMPTS:-3000}

if pgrep -x llama-server >/dev/null 2>&1; then
    printf 'llama-server is already running; run qwen-teardown.sh first\n' >&2
    exit 2
fi

# A driver-level failure ends the server through the hazard watcher, and the
# relaunch that follows it inside the same minute meets a device whose counters
# read free while the driver has not finished reclaiming. The latch refuses that
# launch rather than warning about it, and names which of the two recoveries the
# recorded class admits.
QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
    "$script_directory/gpu-state-latch.sh" require-clear

model_path=${QWEN_MODEL_PATH:-"${HOME:?}/models/Qwen3.8-2B-Distill-GGUF/Qwen3.8-2B-Q4_K_M.gguf"}
router_snapshot_owned=''
control_start_entered=0
cleanup_router_snapshot() {
    if [ -n "$router_snapshot_owned" ]; then
        rm -f -- "$router_snapshot_owned"
        router_snapshot_owned=''
    fi
}
terminate_router_launch() {
    signal_status=$1
    if [ "$control_start_entered" = 1 ]; then
        QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
        QWEN_SERVER_PORT=$server_port \
            "$script_directory/qwen-teardown.sh" >/dev/null 2>&1 || true
    fi
    cleanup_router_snapshot
    trap - EXIT HUP INT TERM
    exit "$signal_status"
}

# Snapshot the exact router preset before deriving the preflight denominator.
# Generation replaces the source file independently; the session receives the
# snapshot path and digest so a later source replacement cannot widen the model
# set after sizing completes.
if [ "${QWEN_ROUTER:-0}" = 1 ]; then
    source_router_presets=${QWEN_ROUTER_PRESETS:-"$state_directory/router-presets.ini"}
    if [ ! -r "$source_router_presets" ]; then
        printf 'router presets are unreadable: %s\n' "$source_router_presets" >&2
        exit 2
    fi
    mkdir -p "$state_directory"
    router_presets=$(mktemp \
        "$state_directory/.router-presets.active.XXXXXX")
    router_snapshot_owned=$router_presets
    trap cleanup_router_snapshot EXIT
    trap 'terminate_router_launch 129' HUP
    trap 'terminate_router_launch 130' INT
    trap 'terminate_router_launch 143' TERM
    cp -- "$source_router_presets" "$router_presets"
    chmod 600 "$router_presets"
    router_preset_identity=$(sha256sum "$router_presets")
    router_preset_sha256=${router_preset_identity%% *}
    QWEN_ROUTER_PRESETS=$router_presets
    QWEN_ROUTER_PRESET_SHA256=$router_preset_sha256
    export QWEN_ROUTER_PRESETS QWEN_ROUTER_PRESET_SHA256
fi

# Router mode sizes the machine against the largest checkpoint the picker can
# reach rather than against the one this launch names. `--models-max 1` unloads
# the resident model before loading the next, so any servable row can be the one
# holding the device, and a preflight run against the smallest of them reports
# headroom for a load that never happens. Router presets carry their own model
# and projector paths, so the largest registry subject replaces any explicit
# single-model path for fetch and preflight.
if [ "${QWEN_ROUTER:-0}" = 1 ]; then
    largest_servable=''
    largest_bytes=0
    preset_model_paths=$(awk '
        function finish_section() {
            if (section == "" || section == "*") return
            model_sections++
            if (model_count != 1) {
                printf "router preflight section %s requires exactly one LLAMA_ARG_MODEL, found %d\n", \
                    section, model_count > "/dev/stderr"
                invalid = 1
            } else {
                print model_path
            }
        }
        /^[[:space:]]*($|[#;])/ { next }
        /^[[:space:]]*\[/ {
            finish_section()
            section = $0
            if (section !~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
                printf "router preflight carries malformed section header: %s\n", \
                    section > "/dev/stderr"
                invalid = 1
                section = ""
                model_count = 0
                model_path = ""
                next
            }
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            model_count = 0
            model_path = ""
            next
        }
        {
            if (section == "" || section == "*") next
            separator = index($0, "=")
            if (separator == 0) next
            key = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key == "LLAMA_ARG_MODEL") {
                model_count++
                model_path = value
            }
        }
        END {
            finish_section()
            if (model_sections == 0) {
                print "router preflight carries no model section" > "/dev/stderr"
                invalid = 1
            }
            exit invalid
        }
    ' "$router_presets")
    while IFS= read -r servable_path; do
        if [ -z "$servable_path" ] || [ ! -f "$servable_path" ]; then
            printf 'router preflight model is not a regular file: %s\n' \
                "$servable_path" >&2
            exit 1
        fi
        if ! servable_bytes=$(stat -c %s "$servable_path" 2>/dev/null); then
            printf 'router preflight cannot measure model bytes: %s\n' \
                "$servable_path" >&2
            exit 1
        fi
        if [ "$servable_bytes" -gt "$largest_bytes" ]; then
            largest_bytes=$servable_bytes
            largest_servable=$servable_path
        fi
    done <<EOF
$preset_model_paths
EOF
    if [ -n "$largest_servable" ]; then
        printf 'router_preflight_subject=%s bytes=%s\n' \
            "$(basename -- "$largest_servable")" "$largest_bytes"
        model_path=$largest_servable
    fi
fi

# GGUF weights live outside Git because their size exceeds what Git LFS carries
# on a free account, so the checkpoint arrives from its pinned Hugging Face
# revision on first launch. The fetch script verifies an existing file against
# the recorded byte count and SHA-256 and exits without downloading when it
# matches, which makes this line a no-op on every launch after the first.
if [ ! -f "$model_path" ]; then
    fetch_script=''
    registry_fetch=$("$script_directory/model-registry.sh" path "$model_path" \
        fetch_script 2>/dev/null) || registry_fetch=''
    if [ -n "$registry_fetch" ]; then
        fetch_script=$script_directory/$registry_fetch
    fi
    if [ -z "$fetch_script" ] || [ ! -x "$fetch_script" ]; then
        printf 'model is absent and scripts/models.tsv holds no row for it: %s\n' \
            "$model_path" >&2
        exit 1
    fi
    printf 'model_fetch=starting path=%s\n' "$model_path"
    "$fetch_script" "$(dirname -- "$model_path")" || {
        printf 'model fetch failed for %s\n' "$model_path" >&2
        exit 1
    }
fi

# A mismatched projector loads without error and places image tokens where the
# language model does not read them, so scripts/select-projector.sh binds the
# search to the checkpoint's own directory and prints nothing where the pairing
# is absent or ambiguous. scripts/test-projector-pairing.sh covers selection and
# scripts/test-projector-fetch-dispatch.sh covers registry-directed fetching.
model_directory=$(dirname -- "$model_path")
if [ "${QWEN_MMPROJ+x}" = x ]; then
    mmproj=$QWEN_MMPROJ
else
    mmproj=$("$script_directory/select-projector.sh" "$model_path") || mmproj=''
fi
if [ -z "$mmproj" ] && [ "${QWEN_FETCH_MMPROJ:-0}" = 1 ]; then
    projector_fetch_script=$("$script_directory/model-registry.sh" path \
        "$model_path" projector_fetch_script 2>/dev/null) || projector_fetch_script=''
    case $projector_fetch_script in
        '' | -)
            printf 'model registry holds no projector fetch script for %s\n' \
                "$model_path" >&2
            exit 1
            ;;
    esac
    projector_fetch_path=$script_directory/$projector_fetch_script
    if [ ! -x "$projector_fetch_path" ]; then
        printf 'projector fetch script is not executable: %s\n' \
            "$projector_fetch_path" >&2
        exit 1
    fi
    "$projector_fetch_path" "$model_directory" || {
        printf 'projector fetch failed for %s\n' "$model_path" >&2
        exit 1
    }
    mmproj=$("$script_directory/select-projector.sh" "$model_path") || mmproj=''
    if [ -z "$mmproj" ]; then
        printf 'projector fetch produced no unambiguous match for %s\n' \
            "$model_path" >&2
        exit 1
    fi
fi
[ -n "$mmproj" ] && [ -f "$mmproj" ] || mmproj=''
[ -n "$mmproj" ] && printf 'projector=%s\n' "$(basename -- "$mmproj")"

control_start_entered=1
QWEN_BIND_HOST=$bind_host QWEN_SERVER_PORT=$server_port \
QWEN_MODEL_PATH=$model_path QWEN_MMPROJ=$mmproj \
    "$control" start "$profile"

attempt=0
while [ "$attempt" -lt "$ready_attempts" ]; do
    if grep -q 'state=failed' "$state_directory/session.status" 2>/dev/null; then
        printf 'session reported failure\n' >&2
        sed -n '1p' "$state_directory/session.status" >&2
        [ -r "$state_directory/server.log" ] && tail -n 40 "$state_directory/server.log" >&2
        "$script_directory/qwen-teardown.sh" >/dev/null 2>&1 || true
        exit 1
    fi
    if grep -q 'state=running ' "$state_directory/session.status" 2>/dev/null && \
       curl --silent --fail "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ "$attempt" -ge "$ready_attempts" ]; then
    printf 'server did not answer /health within %s seconds\n' \
        "$((ready_attempts / 10))" >&2
    "$script_directory/qwen-teardown.sh" >/dev/null 2>&1 || true
    exit 1
fi

# The running session now owns the unique snapshot and removes it through its
# EXIT trap. Until this acknowledgement, the launcher trap owns startup errors.
router_snapshot_owned=''
control_start_entered=0

sed -n '1p' "$state_directory/session.status"
if [ "$bind_host" = 127.0.0.1 ] || [ "$bind_host" = localhost ]; then
    printf 'reachable at http://127.0.0.1:%s (loopback only)\n' "$server_port"
else
    printf 'reachable at http://%s:%s\n' "$(hostname)" "$server_port"
    for address in $(hostname -I 2>/dev/null); do
        case $address in
            *:*) continue ;;
        esac
        printf 'reachable at http://%s:%s\n' "$address" "$server_port"
    done
fi
# The approval broker binds the loopback literal whatever the server's listener
# is, so a LAN launch reaches it through an SSH forward rather than through the
# addresses above. It is reported where the marker set it running.
if [ "${QWEN_WEB_BROKER:-0}" = 1 ]; then
    printf 'approval broker at http://127.0.0.1:%s (loopback only)\n' \
        "${QWEN_WEB_BROKER_PORT:-8571}"
fi
printf 'stop it with %s/qwen-teardown.sh\n' "$script_directory"
