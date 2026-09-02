#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

usage() {
    printf 'usage: %s LLAMA_SERVER MODEL_PATH STATIC_PATH CONTEXT_SIZE REQUIRED_DEVICE_MIB [PORT [STATE_DIRECTORY [PROFILE]]]\n' \
        "$0" >&2
    exit 2
}

# Depth and the memory the load requires are registry claims rather than session
# defaults. qwen-capacity-policy.sh reads context_default, context_ceiling, and
# validated_filled_depth from scripts/models.tsv and model-memory-preflight.sh
# reads the artifact, so a session that supplied its own numbers would serve a
# depth no row admits and gate a load against a figure no closure measured. Both
# are required arguments for that reason, and every caller in the tree passes all
# eight.
[ "$#" -ge 5 ] || usage
llama_server=$1
model_path=$2
static_path=$3
context_size=$4
required_device_mib=$5
server_port=${6:-8080}
state_directory=${7:-"${HOME:?}/qwen-webui-state"}
runtime_profile=${8:-default}
for session_required in "$context_size" "$required_device_mib"; do
    case $session_required in
        '' | *[!0-9]*) usage ;;
    esac
    [ "$session_required" -gt 0 ] || usage
done

umask 077
mkdir -p "$state_directory"

# This session is the top-level GPU owner and it takes the owner authority from
# scripts/gpu-workload-ownership.sh before it starts anything. It owns the
# serving lifetime: it outlives llama-server, tears down the broker, the image
# service, the probe, the watcher, and the monitor, and only then exits, which
# releases the lock. Taking it here rather than deeper in the chain is what makes
# the claim last exactly as long as the session does; tmux starts this script
# from its own server process, so no descriptor from the launcher reaches here
# and the lock has to be opened on this side of that boundary.
#
# Every child closes the descriptor with `9>&-`, including the broker and the
# telemetry sampler that open no CUDA context of their own. An inherited
# descriptor keeps the owner claim alive after this session exits, so a child
# that outlives the teardown would lock out the next serving session and every
# campaign against a device nothing is using. Closing it costs a child nothing:
# none of them is the owner.
#
# The inspection this call performs runs before the broker and the control
# services start, so what the driver reports is the state the session found
# rather than the state it created.
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require || exit $?
# gpu_ownership_require exports QWEN_GPU_OWNERSHIP_FD, and every child closes
# descriptor 9. A child inheriting the variable without the descriptor is the
# forgery gpu_ownership_verify_inherited refuses, so the variable is dropped here
# and the children carry neither half.
unset QWEN_GPU_OWNERSHIP_FD

server_log=$state_directory/server.log
telemetry_log=$state_directory/telemetry.log
graphics_latency_log=$state_directory/graphics-latency.log
kernel_hazard_log=$state_directory/kernel-hazards.log
pid_file=$state_directory/server.pid
status_file=$state_directory/session.status
api_key_file=$state_directory/api.key
monitor_pid=""
latency_watchdog_pid=""
kernel_hazard_watchdog_pid=""
server_pid=""
broker_pid=""
router_preset_snapshot=''
# The approval broker signs one search grant per human approval and holds no
# device, so it is a guarded child of this session the way the probe, the
# monitor, and the kernel-hazard watcher are. qwen-web-launch.sh sets
# QWEN_WEB_BROKER=1; the ordinary launch leaves it unset and starts no broker.
broker_enabled=${QWEN_WEB_BROKER:-0}
broker_program=${QWEN_WEB_BROKER_PROGRAM:-"$script_directory/web-mcp/authorize-broker.py"}
broker_port=${QWEN_WEB_BROKER_PORT:-8571}
broker_state_directory=${QWEN_WEB_STATE_DIR:-"$state_directory/web-mcp"}
broker_log=$state_directory/authorize-broker.log
broker_origin=${QWEN_WEB_BROKER_ORIGIN:-"http://${QWEN_BIND_HOST:-127.0.0.1}:$server_port"}
# The image service owns the Vulkan workload lease and the pinned image
# runtime, and it allocates nothing on the device until a job arrives, so it is
# a guarded child of this session beside the broker. qwen-image-launch.sh sets
# QWEN_IMAGE_SERVICE=1; every other launch leaves it unset and starts none.
image_service_pid=""
image_service_enabled=${QWEN_IMAGE_SERVICE:-0}
image_service_program=${QWEN_IMAGE_SERVICE_PROGRAM:-"$script_directory/image-service.py"}
image_service_profiles_json=${QWEN_IMAGE_PROFILES_JSON:-}
image_service_origin=${QWEN_IMAGE_PAGE_ORIGIN:-"http://${QWEN_BIND_HOST:-127.0.0.1}:$server_port"}
image_service_log=$state_directory/image-service.log
case ${QWEN_ROUTER_PRESETS:-} in
    "$state_directory"/.router-presets.active.*)
        router_preset_snapshot=$QWEN_ROUTER_PRESETS
        ;;
esac

cleanup() {
    if [ -n "$monitor_pid" ]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
    fi
    if [ -n "$latency_watchdog_pid" ]; then
        kill "$latency_watchdog_pid" 2>/dev/null || true
        wait "$latency_watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$kernel_hazard_watchdog_pid" ]; then
        kill "$kernel_hazard_watchdog_pid" 2>/dev/null || true
        wait "$kernel_hazard_watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    # The broker removes its per-launch session secret while unwinding from
    # SIGTERM, so it is signalled and waited for rather than left to the
    # process group: a killed broker leaves that file for the next launch.
    if [ -n "$broker_pid" ]; then
        kill "$broker_pid" 2>/dev/null || true
        wait "$broker_pid" 2>/dev/null || true
    fi
    # The image service unlinks its socket and releases the workload lease
    # while unwinding from SIGTERM, and a killed one leaves both for the next
    # launch to meet, so it is signalled and waited for the same way.
    if [ -n "$image_service_pid" ]; then
        kill "$image_service_pid" 2>/dev/null || true
        wait "$image_service_pid" 2>/dev/null || true
    fi
    if [ -n "$router_preset_snapshot" ]; then
        rm -f -- "$router_preset_snapshot"
        router_preset_snapshot=''
    fi
}
terminate_session() {
    signal_status=$1
    cleanup
    trap - EXIT HUP INT TERM
    exit "$signal_status"
}
trap cleanup EXIT
trap 'terminate_session 129' HUP
trap 'terminate_session 130' INT
trap 'terminate_session 143' TERM

process_running() {
    process_pid=$1
    [ -n "$process_pid" ] || return 1
    kill -0 "$process_pid" 2>/dev/null || return 1
    [ -r "/proc/$process_pid/stat" ] || return 1
    process_state=$(sed 's/^.*) //' "/proc/$process_pid/stat" | awk '{ print $1 }')
    [ "$process_state" != Z ] && [ "$process_state" != X ]
}

require_broker_running() {
    if [ "$broker_enabled" = 1 ] && ! process_running "$broker_pid"; then
        printf 'state=failed reason=authorization_broker_exited broker_pid=%s utc=%s\n' \
            "$broker_pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    if [ "$image_service_enabled" = 1 ] && \
        ! process_running "$image_service_pid"; then
        printf 'state=failed reason=image_service_exited image_service_pid=%s utc=%s\n' \
            "$image_service_pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
}

if [ -s "$pid_file" ]; then
    prior_pid=$(sed -n '1p' "$pid_file")
    case $prior_pid in
        '' | *[!0-9]*) prior_pid=0 ;;
    esac
    if [ "$prior_pid" -gt 0 ] && kill -0 "$prior_pid" 2>/dev/null; then
        printf 'qwen Web UI server is already running with PID %s\n' "$prior_pid" >&2
        exit 2
    fi
fi

# QWEN_REQUIRE_API_KEY=1 mints a key and makes llama-server demand it. The
# default serves without one, because this deployment is a local model on a
# trusted network and a key there only stands between a reader and the page.
if [ "${QWEN_REQUIRE_API_KEY:-0}" = 1 ]; then
    if [ ! -s "$api_key_file" ]; then
        if ! command -v openssl >/dev/null 2>&1; then
            printf 'openssl is required to create the Web UI API key\n' >&2
            exit 1
        fi
        openssl rand -hex 32 >"$api_key_file"
    fi
    chmod 600 "$api_key_file"
else
    api_key_file=''
fi

printf 'state=starting utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"

# The broker starts ahead of the capacity server because model loading occupies
# the readiness loop for up to 120 seconds and the broker allocates nothing on
# the device: starting it first bounds the window in which the page is reachable
# while the endpoint that signs its approvals is absent. Every failure path
# below leaves through the EXIT trap, which stops it.
#
# The listener is the loopback literal the broker itself admits, and the page
# that reads the session secret is named by Origin rather than by another
# setting: the served page is the one this session binds, so its origin comes
# from QWEN_BIND_HOST and the served port. The signing key travels as a path in
# the environment and its contents stay in the broker's own address space.
broker_start_time=''
broker_signing_key_sha256=''
if [ "$broker_enabled" = 1 ]; then
    if [ ! -x "$broker_program" ]; then
        printf 'state=failed reason=authorization_broker_unavailable path=%s utc=%s\n' \
            "$broker_program" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    # One broker signs for one profile, and a grant it signs names that
    # profile, so the session refuses to start a broker for no profile rather
    # than for `default`, a name no preset section carries. The signing key is
    # read here as a digest alone: the broker reports the digest of the key it
    # loaded on /health, and the comparison below proves the child signs with
    # the file this launch named.
    if [ -z "${QWEN_WEB_PROFILE:-}" ]; then
        printf 'state=failed reason=authorization_broker_profile_unset utc=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    if [ ! -f "${QWEN_WEB_TOKEN_KEY_FILE:-}" ] || [ ! -r "$QWEN_WEB_TOKEN_KEY_FILE" ]; then
        printf 'state=failed reason=authorization_broker_signing_key_unreadable utc=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    broker_signing_key_sha256=$(sha256sum "$QWEN_WEB_TOKEN_KEY_FILE" | cut -c1-64)
    mkdir -p "$broker_state_directory"
    chmod 700 "$broker_state_directory"
    : >"$broker_log"
    chmod 600 "$broker_log"
    QWEN_WEB_STATE_DIR=$broker_state_directory \
    QWEN_WEB_BROKER_ORIGIN=$broker_origin \
        "$broker_program" --host 127.0.0.1 --port "$broker_port" \
        --state-dir "$broker_state_directory" \
        --profile "$QWEN_WEB_PROFILE" \
        --image-profile "${QWEN_IMAGE_PROFILE:-}" \
        --provider "${QWEN_WEB_PROVIDER:-exa}" \
        --api-key-file "$api_key_file" \
        >"$broker_log" 2>&1 9>&- &
    broker_pid=$!
    if ! process_running "$broker_pid"; then
        printf 'state=failed reason=authorization_broker_exited broker_pid=%s utc=%s\n' \
            "$broker_pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    broker_start_time=$(sed 's/^.*) //' "/proc/$broker_pid/stat" | awk '{ print $20 }')
    {
        printf 'state=starting broker_pid=%s utc=%s\n' \
            "$broker_pid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'broker secret_file=%s\n' \
            "$broker_state_directory/authorize-session.secret"
        printf 'broker_identity pid=%s start_time=%s profile=%s image_profile=%s provider=%s signing_key_sha256=%s\n' \
            "$broker_pid" "$broker_start_time" "$QWEN_WEB_PROFILE" \
            "${QWEN_IMAGE_PROFILE:--}" \
            "${QWEN_WEB_PROVIDER:-exa}" "$broker_signing_key_sha256"
    } >"$status_file"

    broker_ready=0
    attempt=0
    while [ "$attempt" -lt 300 ]; do
        if grep -F "listening 127.0.0.1 $broker_port" "$broker_log" \
            >/dev/null 2>&1; then
            broker_ready=1
            break
        fi
        if ! kill -0 "$broker_pid" 2>/dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    if [ "$broker_ready" -ne 1 ]; then
        printf 'state=failed reason=authorization_broker_not_listening port=%s utc=%s\n' \
            "$broker_port" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    # The `listening` line proves a socket; `GET /health` proves the process
    # behind it is this launch's broker, serving this profile and provider and
    # signing with this key. A stale broker on the same port from an earlier
    # launch answers the line's grep and fails the pid comparison here.
    broker_health=$(curl -sS --max-time 5 -H 'Host: 127.0.0.1' \
        "http://127.0.0.1:$broker_port/health" 2>>"$broker_log" || true)
    health_field() {
        printf '%s' "$broker_health" | tr -d '\n' |
            sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p"
    }
    health_pid=$(health_field pid)
    health_profile=$(health_field profile)
    health_image_profile=$(health_field image_profile)
    health_provider=$(health_field provider)
    health_key=$(health_field signing_key_sha256)
    health_start_time=$(health_field start_time)
    health_mismatch=''
    [ "$health_pid" = "$broker_pid" ] || health_mismatch="pid=$health_pid"
    [ "$health_profile" = "$QWEN_WEB_PROFILE" ] || \
        health_mismatch="$health_mismatch profile=$health_profile"
    # The image lane the launch armed is the lane the broker signs for. A
    # broker that loaded another image profile, or none, would refuse every
    # approved generation at the first grant rather than at startup.
    [ "$health_image_profile" = "${QWEN_IMAGE_PROFILE:-}" ] || \
        health_mismatch="$health_mismatch image_profile=$health_image_profile"
    [ "$health_provider" = "${QWEN_WEB_PROVIDER:-exa}" ] || \
        health_mismatch="$health_mismatch provider=$health_provider"
    [ "$health_key" = "$broker_signing_key_sha256" ] || \
        health_mismatch="$health_mismatch signing_key=mismatch"
    case $health_start_time in
        '' | *[!0-9]*) health_mismatch="$health_mismatch start_time=absent" ;;
        "$broker_start_time") ;;
        *) health_mismatch="$health_mismatch start_time=$health_start_time" ;;
    esac
    if [ -n "$health_mismatch" ]; then
        printf 'state=failed reason=authorization_broker_identity_mismatch port=%s mismatch=%s utc=%s\n' \
            "$broker_port" "$(printf '%s' "$health_mismatch" | sed 's/^ //; s/ /,/g')" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
fi

# The image service starts here for the reason the broker does: it allocates
# nothing on the device until a job arrives, where model loading holds the
# readiness loop for up to 120 seconds, so starting it first bounds the window
# in which the page is reachable and the executor its approvals name is absent.
# The `socket` line the service prints proves it bound the control socket; the
# start time recorded beside its pid is what binds the number to this process,
# since a pid is reused once its process exits.
image_service_start_time=''
image_service_socket=''
image_service_listener=''
if [ "$image_service_enabled" = 1 ]; then
    if [ ! -r "$image_service_program" ]; then
        printf 'state=failed reason=image_service_unavailable path=%s utc=%s\n' \
            "$image_service_program" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >"$status_file"
        exit 1
    fi
    if [ ! -r "${image_service_profiles_json:-}" ]; then
        printf 'state=failed reason=image_service_profiles_unreadable path=%s utc=%s\n' \
            "${image_service_profiles_json:-<unset>}" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    : >"$image_service_log"
    chmod 600 "$image_service_log"
    python3 "$image_service_program" \
        --state-dir "$state_directory" \
        --profiles-json "$image_service_profiles_json" \
        --api-key-file "$api_key_file" \
        --origin "$image_service_origin" \
        --http-host 127.0.0.1 \
        >"$image_service_log" 2>&1 9>&- &
    image_service_pid=$!
    image_service_ready=0
    attempt=0
    while [ "$attempt" -lt 300 ]; do
        if grep -F 'socket ' "$image_service_log" >/dev/null 2>&1; then
            image_service_ready=1
            break
        fi
        if ! kill -0 "$image_service_pid" 2>/dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    if [ "$image_service_ready" -ne 1 ]; then
        printf 'state=failed reason=image_service_not_listening log=%s utc=%s\n' \
            "$image_service_log" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
        exit 1
    fi
    image_service_start_time=$(sed 's/^.*) //' "/proc/$image_service_pid/stat" |
        awk '{ print $20 }')
    image_service_socket=$(sed -n 's/^socket //p' "$image_service_log" |
        sed -n '1p')
    # The artifact listener binds an ephemeral port by default, so its host and
    # port are read from the line the service printed rather than assumed.
    image_service_listener=$(sed -n 's/^listening //p' "$image_service_log" |
        sed -n '1p' | tr ' ' ':')
fi

# The session owns the state directory, so it names the one the Vulkan workload
# lease lives in; qwen-capacity-policy.sh derives the lock path from it and
# image-service.py opens the same file under its own --state-dir.
# One positional profile reaches the wrapper the serving backend selects, so
# the name is exported under that wrapper's own variable and the other stays
# absent rather than carrying a value from the wrong vocabulary.
case ${QWEN_SERVING_BACKEND:-cuda} in
    vulkan) runtime_profile_variable=QWEN_VULKAN_PROFILE ;;
    *)      runtime_profile_variable=QWEN_CUDA_PROFILE ;;
esac

env "$runtime_profile_variable=$runtime_profile" \
QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
"$script_directory/run-qwen-capacity-server.sh" \
    "$llama_server" "$model_path" "$context_size" "$required_device_mib" \
    "$server_port" "$static_path" "$api_key_file" >"$server_log" 2>&1 9>&- &
server_pid=$!
printf '%s\n' "$server_pid" >"$pid_file"

ready_for_monitor=0
attempt=0
inference_cpu=${QWEN_INFERENCE_CPU:-0}
# The runtime policy the session requires is the one its wrapper applies, and
# the two wrappers apply different ones. vulkan-runtime-env.sh pins one core
# at nice 19 because the APU's second core is the desktop's; cuda-runtime-env.sh
# runs across every core at the desktop's own priority and exports both values,
# so the check reads back what was asked for rather than a constant.
case ${QWEN_SERVING_BACKEND:-cuda} in
    vulkan)
        expected_affinity=$inference_cpu
        expected_nice=19
        ;;
    *)
        expected_affinity=${QWEN_SERVING_CPU_LIST:-$(cat /sys/devices/system/cpu/online 2>/dev/null || echo 0)}
        expected_nice=${QWEN_SERVING_NICE:-0}
        ;;
esac
# Model loading performs one-time Vulkan allocation and transfer work before the
# HTTP service can accept inference. Arm the service-latency watchdog only after
# llama-server reports itself ready, while still requiring the runtime CPU
# policy before admitting the session.
#
# A router reports readiness differently because it loads nothing at startup: it
# binds the port and waits for a request to name a model. Waiting for the
# single-model marker there times out against a server that is already serving,
# and the session tears down a healthy listener.
readiness_marker='model loaded'
if [ "${QWEN_ROUTER:-0}" = 1 ]; then
    readiness_marker='starting server in router mode'
fi
while [ "$attempt" -lt 1200 ]; do
    require_broker_running
    if ! kill -0 "$server_pid" 2>/dev/null; then
        break
    fi
    affinity=$(awk '$1 == "Cpus_allowed_list:" { print $2 }' "/proc/$server_pid/status")
    nice_value=$(ps -o ni= -p "$server_pid" | tr -d ' ')
    if [ "$affinity" = "$expected_affinity" ] && \
       [ "$nice_value" = "$expected_nice" ] && \
       grep -F "$readiness_marker" "$server_log" >/dev/null 2>&1; then
        ready_for_monitor=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ "$ready_for_monitor" -ne 1 ]; then
    # run-qwen-capacity-server.sh takes the campaign lock ahead of the memory
    # preflight and exits 75 when a measurement campaign already holds the
    # device, which is a different operator action from a policy that failed to
    # come up, so the refusal reaches the status file under its own reason.
    server_failure_reason=server_policy_not_active
    if grep -q 'another qwen CUDA campaign owns GPU 0\|a foreign CUDA client holds GPU 0\|lock order inversion' \
        "$server_log" 2>/dev/null; then
        server_failure_reason=gpu_ownership_refused
    fi
    printf 'state=failed reason=%s utc=%s\n' \
        "$server_failure_reason" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
    exit 1
fi

latency_probe=${QWEN_VULKAN_LATENCY_PROBE:-"$script_directory/../build/vulkan-graphics-service-probe"}
# The probe watches the compositor's own frame-completion fences against a
# 20,000 us deadline sampled every 16 ms; it measures whatever yielding the
# scheduling policy actually produces rather than enforcing one itself.
# `terminate` ends any sustained session that breaches the deadline and is
# retained only for deliberately strict runs; `observe` counts the same
# breaches, leaves them in the log, and lets the session serve.
latency_probe_mode=${QWEN_LATENCY_MODE:-observe}
case $latency_probe_mode in
    terminate) latency_probe_mode_argument='' ;;
    observe) latency_probe_mode_argument='--observe' ;;
    *)
        printf 'QWEN_LATENCY_MODE must be terminate or observe: %s\n' \
            "$latency_probe_mode" >&2
        exit 2
        ;;
esac
if [ ! -x "$latency_probe" ]; then
    printf 'state=failed reason=graphics_latency_probe_unavailable path=%s utc=%s\n' \
        "$latency_probe" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
    exit 1
fi

: >"$graphics_latency_log"
(
    unset AMD_PRIORITY DISPLAY WAYLAND_DISPLAY
    # The probe measures the compositor's own device, so it names an ICD rather
    # than accepting whichever the loader enumerates first. QWEN_GRAPHICS_ICD
    # wins where the caller sets it, the installed NVIDIA and AMD files follow
    # in that order, and a host carrying neither leaves the loader to enumerate.
    graphics_icd=${QWEN_GRAPHICS_ICD:-}
    if [ -z "$graphics_icd" ]; then
        for icd_candidate in /usr/share/vulkan/icd.d/nvidia_icd.json \
                             /usr/share/vulkan/icd.d/radeon_icd.x86_64.json; do
            if [ -r "$icd_candidate" ]; then
                graphics_icd=$icd_candidate
                break
            fi
        done
    fi
    if [ -n "$graphics_icd" ]; then
        export VK_DRIVER_FILES=$graphics_icd
        export VK_ICD_FILENAMES=$graphics_icd
    fi
    exec ionice -c 3 "$latency_probe" \
        --log "$graphics_latency_log" --watch-pid "$server_pid" \
        --interval-ms 16 --deadline-us 20000 $latency_probe_mode_argument
) 9>&- &
latency_watchdog_pid=$!

latency_ready=0
attempt=0
while [ "$attempt" -lt 100 ]; do
    require_broker_running
    if grep -F 'probe_start ' "$graphics_latency_log" >/dev/null 2>&1; then
        latency_ready=1
        break
    fi
    if ! kill -0 "$latency_watchdog_pid" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$latency_ready" -ne 1 ]; then
    printf 'state=failed reason=graphics_latency_probe_not_ready utc=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
    exit 1
fi

"$script_directory/watch-qwen-kernel-hazards.sh" \
    "$server_pid" "$kernel_hazard_log" 9>&- &
kernel_hazard_watchdog_pid=$!

kernel_watch_ready=0
attempt=0
while [ "$attempt" -lt 100 ]; do
    require_broker_running
    if grep -F 'watch_ready_utc=' "$kernel_hazard_log" >/dev/null 2>&1; then
        kernel_watch_ready=1
        break
    fi
    if ! kill -0 "$kernel_hazard_watchdog_pid" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$kernel_watch_ready" -ne 1 ]; then
    printf 'state=failed reason=kernel_hazard_watchdog_not_ready utc=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
    exit 1
fi

"$script_directory/monitor-qwen-runtime.sh" "$server_pid" "$telemetry_log" \
    "$runtime_profile" "$latency_watchdog_pid" \
    "$kernel_hazard_watchdog_pid" 9>&- &
monitor_pid=$!
require_broker_running
# The paced profile uses the aggregate busy ceiling. The serialized LOW
# profile uses the MEDIUM graphics-family deadline as its responsiveness gate.
#
# broker_pid appears on this line only where a broker runs, so its absence is
# what the ordinary launch records: qwen-teardown.sh reads the field to signal
# the process and to decide whether the session secret is its own to prove gone.
broker_status_field=''
if [ -n "$broker_pid" ]; then
    broker_status_field=" broker_pid=$broker_pid"
fi
# image_service_pid appears on the same line for the same reason: the teardown
# reads the first line to signal the process and to decide whether the socket,
# the lease, and the partial artifacts are its own to prove gone.
if [ -n "$image_service_pid" ]; then
    broker_status_field="$broker_status_field image_service_pid=$image_service_pid"
fi
printf 'state=running server_pid=%s monitor_pid=%s latency_watchdog_pid=%s kernel_hazard_watchdog_pid=%s%s profile=%s host=%s port=%s context=%s latency_mode=%s utc=%s\n' \
    "$server_pid" "$monitor_pid" "$latency_watchdog_pid" \
    "$kernel_hazard_watchdog_pid" "$broker_status_field" "$runtime_profile" \
    "${QWEN_BIND_HOST:-127.0.0.1}" "$server_port" "$context_size" \
    "$latency_probe_mode" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
# The owner claim is recorded on its own line so an admission harness has status
# proof to wait on: it launches the session, waits for this line, and drives its
# test through the session that holds the lock rather than holding one itself.
# The line follows the `state=running` write because that write truncates the
# file.
printf 'gpu_owner lock=%s pid=%s fd=%s\n' \
    "$(gpu_ownership_lock_path)" "$$" "${QWEN_GPU_OWNERSHIP_FD:-9}" \
    >>"$status_file"
# The speculation settings occupy a second line because the control script and
# the teardown script both read the first line alone, the teardown to recover
# the guard PIDs before `stop` rewrites the file.
printf 'speculation spec_type=%s draft_n_max=%s draft_p_min=%s draft_backend_sampling=%s backend_sampling=%s\n' \
    "${QWEN_SPEC_TYPE:-off}" "${QWEN_SPEC_DRAFT_N_MAX:-default}" \
    "${QWEN_SPEC_DRAFT_P_MIN:-default}" \
    "${QWEN_SPEC_BACKEND_SAMPLING:-0}" "${QWEN_BACKEND_SAMPLING:-0}" >>"$status_file"
# The cache triple lands on a third line for the same reason, and it records
# `registry` where the row supplied the value, so a retained status file
# distinguishes an experiment arm from the served default.
printf 'cache cache_type_k=%s cache_type_v=%s flash_attention=%s override_context_ceiling=%s\n' \
    "${QWEN_CACHE_TYPE_K:-registry}" "${QWEN_CACHE_TYPE_V:-registry}" \
    "${QWEN_FLASH_ATTN:-registry}" \
    "${QWEN_CACHE_OVERRIDE_CONTEXT_CEILING:-registry}" >>"$status_file"
# Router state lands on a fourth line. A router listener serves several
# checkpoints behind one port and spawns a child process per loaded model, so a
# retained status file that named only the default model would describe one of
# the processes running rather than the service.
printf 'router enabled=%s presets=%s preset_sha256=%s models_max=%s\n' \
    "${QWEN_ROUTER:-0}" \
    "${QWEN_ROUTER_PRESETS:-default}" \
    "${QWEN_ROUTER_PRESET_SHA256:-unbound}" \
    "${QWEN_ROUTER_MAX:-1}" >>"$status_file"
# The broker's session secret lands on a fifth line, whole, because
# QWEN_WEB_STATE_DIR reaches this session alone and a teardown run as a bare
# command would otherwise re-derive the default path and prove the absence of a
# file the broker never wrote there. A line of its own carries a directory
# holding a space, which the space-delimited first line splits.
if [ -n "$broker_pid" ]; then
    printf 'broker secret_file=%s\n' \
        "$broker_state_directory/authorize-session.secret" >>"$status_file"
    # The broker's process start time lands on a sixth line, so a teardown
    # signals the process that /health identified rather than whatever
    # process later holds the same number: a PID is reused after the broker
    # exits, and its start time in /proc/PID/stat is what tells the two apart.
    printf 'broker_identity pid=%s start_time=%s profile=%s provider=%s signing_key_sha256=%s\n' \
        "$broker_pid" "$broker_start_time" "$QWEN_WEB_PROFILE" \
        "${QWEN_WEB_PROVIDER:-exa}" "$broker_signing_key_sha256" >>"$status_file"
fi
# The image service's identity lands after the same truncating write the
# broker's does, because `state=running` rewrites this file rather than
# appending to it. The start time is what binds the pid to the process a
# teardown signals, and the socket and listener are what a later reader reaches
# the control channel and the artifact routes through.
if [ -n "$image_service_pid" ]; then
    printf 'image_service_identity pid=%s start_time=%s socket=%s listener=%s\n' \
        "$image_service_pid" "$image_service_start_time" \
        "${image_service_socket:-unrecorded}" \
        "${image_service_listener:-unrecorded}" >>"$status_file"
fi

supervised_component=server
while process_running "$server_pid"; do
    if ! process_running "$monitor_pid"; then
        supervised_component=monitor
        break
    fi
    if ! process_running "$latency_watchdog_pid"; then
        supervised_component=latency_watchdog
        break
    fi
    if ! process_running "$kernel_hazard_watchdog_pid"; then
        supervised_component=kernel_hazard_watchdog
        break
    fi
    if [ -n "$broker_pid" ] && ! process_running "$broker_pid"; then
        supervised_component=authorization_broker
        break
    fi
    sleep 0.1
done
if [ "$supervised_component" != server ]; then
    printf 'state=failed reason=%s_exited utc=%s\n' \
        "$supervised_component" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_file"
fi
for supervised_pid in "$server_pid" "$monitor_pid" "$latency_watchdog_pid" \
        "$kernel_hazard_watchdog_pid" "$broker_pid"; do
    [ -n "$supervised_pid" ] || continue
    kill "$supervised_pid" 2>/dev/null || true
done
set +e
wait "$server_pid"
server_status=$?
wait "$monitor_pid"
monitor_status=$?
wait "$latency_watchdog_pid"
latency_status=$?
wait "$kernel_hazard_watchdog_pid"
kernel_hazard_status=$?
broker_status=0
if [ -n "$broker_pid" ]; then
    wait "$broker_pid"
    broker_status=$?
fi
set -e
server_pid=""
monitor_pid=""
latency_watchdog_pid=""
kernel_hazard_watchdog_pid=""
broker_pid=""
session_status=$server_status
if [ "$supervised_component" != server ]; then
    session_status=1
fi
printf 'state=stopped server_status=%s monitor_status=%s latency_status=%s kernel_hazard_status=%s broker_status=%s stopped_component=%s profile=%s utc=%s\n' \
    "$server_status" "$monitor_status" "$latency_status" \
    "$kernel_hazard_status" "$broker_status" "$supervised_component" \
    "$runtime_profile" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >"$status_file"
exit "$session_status"
