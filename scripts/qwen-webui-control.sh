#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s start [default|no-graphs|no-fusion|pdl|unified]|status|stop|key\n' \
        "$0" >&2
    exit 2
fi

action=$1
# The profile vocabulary belongs to the wrapper the serving backend selects, so
# this check branches the same way qwen-capacity-policy.sh does. The submission
# profiles the Vulkan wrapper carried on the prior host are retired;
# evidence/legacy/raven2/comparative-findings.tsv retains what they measured.
profile=${2:-default}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tmux_socket=qwen-runtime
tmux_session=qwen-webui
# qwen-runtime was created from a fresh SSH login after render/video group
# repair. Reusing its separate tmux server preserves offscreen Vulkan access
# without inheriting the older qwen-admin server's supplementary group set.
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
# The served depth is the operational ceiling, admitted by the measured 24K
# allocation of 2,974 MiB against this gate. QWEN_BIND_HOST and
# QWEN_LATENCY_MODE reach the session script, so `start` reproduces the
# deployed listener instead of a loopback server the documentation would then
# contradict.
context_size=${QWEN_CONTEXT_SIZE:-24576}
required_vulkan_mib=${QWEN_REQUIRED_VULKAN_MIB:-4608}
bind_host=${QWEN_BIND_HOST:-127.0.0.1}
latency_mode=${QWEN_LATENCY_MODE:-observe}
server_port=${QWEN_SERVER_PORT:-8080}
# llama-ui is a SvelteKit build produced on a machine with Node and copied here
# as static files, so the laptop serves it without a build toolchain or a second
# process. QWEN_STATIC_PATH selects it against the hand-written diagnostic page.
# The distill and the base model share the Qwen3.5-4B architecture, so a model
# swap is an argument rather than an edit. The distill is the text default: it
# reasons in 43.3% of the base model's tokens and reaches an answer 2.71 times
# faster across the five-prompt suite. It ships text-only, so the vision profile
# names the base checkpoint, whose projector travels beside it.
model_path=${QWEN_MODEL_PATH:-"${HOME:?}/models/Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf"}
# scripts/promote-llama-build.sh gates a preset and points build-appliance-current
# at it in one rename, so switching build arms or rolling one back leaves this
# script untouched. The named directory is what the appliance was built with
# before presets existed, and it serves until a promotion happens.
llama_source_directory=${QWEN_LLAMA_SOURCE_DIRECTORY:-"${HOME:?}/src/llama.cpp-qwen-nvidia"}
llama_server=${QWEN_LLAMA_SERVER:-}
if [ -z "$llama_server" ]; then
    llama_server=$llama_source_directory/build-appliance-current/bin/llama-server
    if [ ! -x "$llama_server" ]; then
        llama_server=$llama_source_directory/build-qwen-cuda-sm89/bin/llama-server
    fi
fi
static_path=${QWEN_STATIC_PATH:-"$script_directory/../webui-llama-ui"}
if [ ! -f "$static_path/index.html" ]; then
    static_path=$script_directory/../webui
fi
pid_file=$state_directory/server.pid
status_file=$state_directory/session.status

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

case $action in
    start)
        # The profile vocabulary belongs to the backend that serves. CUDA's
        # profiles name what cuda-runtime-env.sh exports; the Vulkan names are
        # vulkan-runtime-env.sh's and stay reachable under
        # QWEN_SERVING_BACKEND=vulkan.
        case ${QWEN_SERVING_BACKEND:-cuda} in
            cuda)
                case $profile in
                    default | no-graphs | no-fusion | pdl | unified | custom) ;;
                    *)
                        printf 'unknown CUDA profile: %s\n' "$profile" >&2
                        exit 2
                        ;;
                esac
                ;;
            vulkan)
                case $profile in
                    default | custom) ;;
                    *)
                        printf 'unknown Vulkan profile: %s\n' "$profile" >&2
                        exit 2
                        ;;
                esac
                ;;
            *)
                printf 'QWEN_SERVING_BACKEND takes cuda or vulkan: %s\n' \
                    "${QWEN_SERVING_BACKEND:-cuda}" >&2
                exit 2
                ;;
        esac
        if tmux -L "$tmux_socket" has-session -t "$tmux_session" 2>/dev/null; then
            printf 'tmux session already exists: %s\n' "$tmux_session" >&2
            exit 2
        fi
        mkdir -p "$state_directory"
        # A launcher polls this file for the new session's verdict. The previous
        # run's last line would otherwise satisfy that poll before the new
        # session writes anything, reporting a stale failure as this one's.
        rm -f "$status_file"
        # tmux runs the new session from its server's environment, not this
        # shell's, so submission settings must travel in the command itself.
        forwarded_environment=''
        # The projector and its image budget must survive the tmux boundary too.
        # Backend sampling is a policy argument the capacity script reads from
        # the environment, so it crosses this boundary with the projector
        # settings rather than reaching the tmux server's own.
        # The approval broker's marker, port, program, state directory, signing
        # key path, profile, API-key requirement, and readiness decision cross
        # with them. qwen-web-launch.sh exports the values into the control
        # shell, and the session script starts the broker beyond the boundary.
        # The image service's marker, program, profile parameters, page origin,
        # and the three names its MCP child reads cross the same way, because
        # qwen-image-launch.sh exports them into this shell and the session
        # script starts that service beyond the boundary too. QWEN_VULKAN_ICD
        # crosses with them: image-service.py pins VK_DRIVER_FILES and
        # VK_ICD_FILENAMES for every runtime it spawns and derives both from
        # that name, and a value that stopped at this boundary would leave the
        # service deriving from the default path instead.
        #
        # The four QWEN_SPEC_* variables cross the boundary only for a
        # single-model launch. qwen-capacity-policy.sh refuses a router launch
        # that carries any of them, because server-models.cpp's
        # preset.merge(base_preset) overwrites every model section with a
        # router-parent speculation argument; forwarding them here would hand
        # the refusal something to refuse instead of leaving the registry's
        # per-checkpoint speculation_profile column in control.
        for forwarded_name in QWEN_SERVING_BACKEND QWEN_CUDA_DEVICES \
                              QWEN_SERVING_NICE QWEN_SERVING_CPU_LIST \
                              QWEN_SERVING_THREADS \
                              QWEN_MMPROJ QWEN_MMPROJ_OFFLOAD QWEN_IMAGE_MAX_TOKENS \
                              QWEN_INFERENCE_CPU \
                              QWEN_BACKEND_SAMPLING \
                              QWEN_CACHE_TYPE_K QWEN_CACHE_TYPE_V \
                              QWEN_FLASH_ATTN \
                              QWEN_CACHE_OVERRIDE_CONTEXT_CEILING \
                              QWEN_ROUTER QWEN_ROUTER_PRESETS \
                              QWEN_ROUTER_PRESET_SHA256 \
                              QWEN_ROUTER_INCLUDE_QUARANTINE \
                              QWEN_ROUTER_MAX \
                              QWEN_WEB_BROKER QWEN_WEB_BROKER_PORT \
                              QWEN_WEB_BROKER_PROGRAM QWEN_WEB_STATE_DIR \
                              QWEN_WEB_TOKEN_KEY_FILE QWEN_WEB_PROFILE \
                              QWEN_WEB_PROVIDER QWEN_WEB_PROFILES \
                              QWEN_WEB_BROKER_ORIGIN \
                              QWEN_REQUIRE_API_KEY \
                              QWEN_WEB_AUTHORIZER_READY \
                              QWEN_IMAGE_SERVICE QWEN_IMAGE_SERVICE_PROGRAM \
                              QWEN_IMAGE_PROFILES_JSON QWEN_IMAGE_PAGE_ORIGIN \
                              QWEN_IMAGE_PROFILE QWEN_IMAGE_TOKEN_KEY_FILE \
                              QWEN_IMAGE_STATE_DIR \
                              QWEN_IMAGE_SERVICE_SOCKET \
                              QWEN_VULKAN_ICD; do
            eval "forwarded_value=\${$forwarded_name:-}"
            if [ -n "$forwarded_value" ]; then
                forwarded_environment="$forwarded_environment $forwarded_name=$(shell_quote "$forwarded_value")"
            fi
        done
        if [ "${QWEN_ROUTER:-0}" != 1 ]; then
            for forwarded_name in QWEN_SPEC_TYPE QWEN_SPEC_DRAFT_N_MAX \
                                  QWEN_SPEC_DRAFT_P_MIN \
                                  QWEN_SPEC_BACKEND_SAMPLING; do
                eval "forwarded_value=\${$forwarded_name:-}"
                if [ -n "$forwarded_value" ]; then
                    forwarded_environment="$forwarded_environment $forwarded_name=$(shell_quote "$forwarded_value")"
                fi
            done
        fi
        for forwarded_name in GGML_VK_MAX_NODES_PER_SUBMIT \
                              GGML_VK_SERIALIZE_SUBMISSIONS \
                              GGML_VK_ALLOW_GRAPHICS_QUEUE \
                              GGML_VK_DUTY_CYCLE_PERCENT; do
            eval "forwarded_value=\${$forwarded_name:-}"
            if [ -n "$forwarded_value" ]; then
                forwarded_environment="$forwarded_environment $forwarded_name=$(shell_quote "$forwarded_value")"
            fi
        done
        session_command="env$forwarded_environment"
        session_command="$session_command QWEN_BIND_HOST=$(shell_quote "$bind_host")"
        session_command="$session_command QWEN_LATENCY_MODE=$(shell_quote "$latency_mode")"
        for session_argument in \
            "$script_directory/qwen-webui-session.sh" \
            "$llama_server" "$model_path" "$static_path" \
            "$context_size" "$required_vulkan_mib" "$server_port" \
            "$state_directory" "$profile"; do
            session_command="$session_command $(shell_quote "$session_argument")"
        done
        tmux -L "$tmux_socket" new-session -d -s "$tmux_session" \
            "$session_command"
        printf 'started tmux_socket=%s tmux_session=%s profile=%s host=%s port=%s context=%s latency_mode=%s model=%s server=%s\n' \
            "$tmux_socket" "$tmux_session" "$profile" "$bind_host" \
            "$server_port" "$context_size" "$latency_mode" "$model_path" \
            "$llama_server"
        printf 'speculation spec_type=%s draft_n_max=%s draft_p_min=%s draft_backend_sampling=%s backend_sampling=%s\n' \
            "${QWEN_SPEC_TYPE:-off}" "${QWEN_SPEC_DRAFT_N_MAX:-default}" \
            "${QWEN_SPEC_DRAFT_P_MIN:-default}" \
            "${QWEN_SPEC_BACKEND_SAMPLING:-0}" "${QWEN_BACKEND_SAMPLING:-0}"
        printf 'cache cache_type_k=%s cache_type_v=%s flash_attention=%s override_context_ceiling=%s\n' \
            "${QWEN_CACHE_TYPE_K:-registry}" "${QWEN_CACHE_TYPE_V:-registry}" \
            "${QWEN_FLASH_ATTN:-registry}" \
            "${QWEN_CACHE_OVERRIDE_CONTEXT_CEILING:-registry}"
        ;;
    status)
        if [ "$#" -ne 1 ]; then
            printf 'status does not accept a profile\n' >&2
            exit 2
        fi
        recorded_status=state=not-started
        if [ -r "$status_file" ]; then
            recorded_status=$(sed -n '1p' "$status_file")
        fi
        server_running=0
        if [ -r "$pid_file" ]; then
            status_pid=$(sed -n '1p' "$pid_file")
            case $status_pid in
                '' | *[!0-9]*) status_pid=0 ;;
            esac
            if [ "$status_pid" -gt 0 ] && kill -0 "$status_pid" 2>/dev/null && \
               [ "$(ps -o comm= -p "$status_pid" | tr -d ' ')" = llama-server ]; then
                server_running=1
            fi
        fi
        tmux_running=0
        if tmux -L "$tmux_socket" has-session -t "$tmux_session" 2>/dev/null; then
            tmux_running=1
        fi
        case $recorded_status:$server_running:$tmux_running in
            state=running*:0:0)
                printf 'state=stale recorded_status=%s\n' "$recorded_status"
                ;;
            *)
                printf '%s\n' "$recorded_status"
                ;;
        esac
        if [ "$tmux_running" -eq 1 ]; then
            printf 'tmux=running socket=%s session=%s\n' "$tmux_socket" "$tmux_session"
        else
            printf 'tmux=absent socket=%s session=%s\n' "$tmux_socket" "$tmux_session"
        fi
        if [ -r "$state_directory/server.log" ]; then
            printf 'server_log_tail\n'
            tail -n 10 "$state_directory/server.log"
        fi
        if [ -r "$state_directory/telemetry.log" ]; then
            printf 'telemetry_log_tail\n'
            tail -n 5 "$state_directory/telemetry.log"
        fi
        ;;
    key)
        if [ "$#" -ne 1 ]; then
            printf 'key does not accept a profile\n' >&2
            exit 2
        fi
        api_key_file=$state_directory/api.key
        if [ ! -s "$api_key_file" ]; then
            printf 'API key is unavailable; start the session first\n' >&2
            exit 1
        fi
        sed -n '1p' "$api_key_file"
        ;;
    stop)
        if [ "$#" -ne 1 ]; then
            printf 'stop does not accept a profile\n' >&2
            exit 2
        fi
        if [ -r "$pid_file" ]; then
            server_pid=$(sed -n '1p' "$pid_file")
            case $server_pid in
                '' | *[!0-9]*) server_pid=0 ;;
            esac
            if [ "$server_pid" -gt 0 ] && kill -0 "$server_pid" 2>/dev/null; then
                server_command=$(ps -o comm= -p "$server_pid" | tr -d ' ')
                if [ "$server_command" = llama-server ]; then
                    kill -TERM "$server_pid"
                else
                    printf 'stale PID file names non-llama process %s; leaving it running\n' \
                        "$server_pid" >&2
                fi
            fi
        fi
        wait_attempt=0
        while [ "$wait_attempt" -lt 100 ] && \
              tmux -L "$tmux_socket" has-session -t "$tmux_session" 2>/dev/null; do
            wait_attempt=$((wait_attempt + 1))
            sleep 0.1
        done
        if tmux -L "$tmux_socket" has-session -t "$tmux_session" 2>/dev/null; then
            tmux -L "$tmux_socket" kill-session -t "$tmux_session"
        fi
        printf 'stopped tmux_socket=%s tmux_session=%s\n' \
            "$tmux_socket" "$tmux_session"
        ;;
    *)
        printf 'usage: %s start [default|no-graphs|no-fusion|pdl|unified]|status|stop|key\n' \
            "$0" >&2
        exit 2
        ;;
esac
