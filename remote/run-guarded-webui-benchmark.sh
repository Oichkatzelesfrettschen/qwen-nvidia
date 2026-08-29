#!/bin/sh
set -eu

if [ "$#" -ne 7 ]; then
    printf 'usage: %s PROFILE MODEL_PATH CONTEXT_SIZE REQUIRED_VULKAN_MIB REQUEST_JSON STATE_DIRECTORY TIMEOUT_SECONDS\n' \
        "$0" >&2
    exit 2
fi

initial_guard_nice=$(ps -o ni= -p $$ | tr -d ' ')
if ! renice -n 0 -p $$ >/dev/null 2>&1; then
    printf 'benchmark guard cannot normalize CPU priority from nice %s\n' \
        "$initial_guard_nice" >&2
    exit 2
fi
guard_nice=$(ps -o ni= -p $$ | tr -d ' ')
if [ "$guard_nice" != 0 ]; then
    printf 'benchmark guard requires normal CPU priority, found nice %s\n' \
        "$guard_nice" >&2
    exit 2
fi
taskset -pc 1 $$ >/dev/null
ionice -c 3 -p $$

profile=$1
model_path=$2
context_size=$3
required_vulkan_mib=$4
request_json=$5
state_directory=$6
timeout_seconds=$7
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
llama_server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-apu/build-qwen-vulkan/bin/llama-server"}
static_path=$repository_directory/webui
session_pid=""

cleanup() {
    if [ -n "$session_pid" ]; then
        kill "$session_pid" 2>/dev/null || true
        wait "$session_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

case $profile in
    paced-60 | low-serialized | low-async | custom) ;;
    *)
        printf 'unknown Vulkan profile: %s\n' "$profile" >&2
        exit 2
        ;;
esac
if [ ! -x "$llama_server" ] || [ ! -f "$model_path" ] || \
   [ ! -s "$request_json" ]; then
    printf 'server, model, and request must exist before a benchmark\n' >&2
    exit 2
fi
if pgrep -x llama-server >/dev/null 2>&1; then
    printf 'another llama-server process is already running\n' >&2
    exit 2
fi

umask 077
mkdir -p "$state_directory"
printf 'profile=%s\nmodel=%s\ncontext_size=%s\nrequired_vulkan_mib=%s\nrequest=%s\n' \
    "$profile" "$model_path" "$context_size" "$required_vulkan_mib" \
    "$request_json" >"$state_directory/benchmark-inputs.txt"

"$script_directory/qwen-webui-session.sh" \
    "$llama_server" "$model_path" "$static_path" "$context_size" \
    "$required_vulkan_mib" 8080 "$state_directory" "$profile" &
session_pid=$!

ready=0
attempt=0
while [ "$attempt" -lt 3000 ]; do
    if grep -F 'state=running ' "$state_directory/session.status" \
        >/dev/null 2>&1 && \
       curl --silent --fail http://127.0.0.1:8080/health >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$session_pid" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    printf 'guarded Web server did not become ready\n' >&2
    if [ -r "$state_directory/session.status" ]; then
        sed -n '1p' "$state_directory/session.status" >&2
    fi
    if [ -r "$state_directory/server.log" ]; then
        tail -n 80 "$state_directory/server.log" >&2
    fi
    exit 1
fi

set +e
"$script_directory/run-webui-request.sh" \
    "$request_json" "$state_directory" "$timeout_seconds"
request_status=$?
set -e

server_pid=$(sed -n '1p' "$state_directory/server.pid")
case $server_pid in
    '' | *[!0-9]*)
        printf 'benchmark server PID file is invalid\n' >&2
        exit 1
        ;;
esac
if kill -0 "$server_pid" 2>/dev/null && \
   [ "$(ps -o comm= -p "$server_pid" | tr -d ' ')" = llama-server ]; then
    kill -TERM "$server_pid"
fi
set +e
wait "$session_pid"
session_status=$?
set -e
session_pid=""

printf 'request_status=%s\nsession_status=%s\n' \
    "$request_status" "$session_status" >"$state_directory/benchmark-status.txt"

if [ "$request_status" -ne 0 ]; then
    exit "$request_status"
fi

jq -r '
    "prompt_tokens=" + (.timings.prompt_n | tostring),
    "prompt_tok_per_second=" + (.timings.prompt_per_second | tostring),
    "decode_tokens=" + (.timings.predicted_n | tostring),
    "decode_tok_per_second=" + (.timings.predicted_per_second | tostring)
' "$state_directory/real-response.json" \
    >"$state_directory/throughput-summary.txt"
cat "$state_directory/throughput-summary.txt"
printf 'guarded_webui_benchmark=completed profile=%s state_directory=%s\n' \
    "$profile" "$state_directory"
