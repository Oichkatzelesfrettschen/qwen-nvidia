#!/bin/sh
set -eu

if [ "$#" -ne 6 ]; then
    printf 'usage: %s LLAMA_SERVER MODEL_PATH CONTEXT_SIZE REQUIRED_VULKAN_MIB PORT LOG_PATH\n' \
        "$0" >&2
    exit 2
fi

llama_server=$1
model_path=$2
context_size=$3
required_vulkan_mib=$4
server_port=$5
server_log=$6

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
server_pid=""

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

if ! "$script_directory/model-memory-preflight.sh" \
    "$model_path" "$required_vulkan_mib" \
    >"$temporary_directory/preflight.log" 2>&1; then
    cat "$temporary_directory/preflight.log" >&2
    exit 1
fi

"$script_directory/qwen-capacity-policy.sh" \
    "$llama_server" "$model_path" "$context_size" "$server_port" \
    >"$server_log" 2>&1 &
server_pid=$!

server_ready=0
attempt=0
while [ "$attempt" -lt 900 ]; do
    if curl --silent --fail "http://127.0.0.1:$server_port/health" \
        >/dev/null 2>&1; then
        server_ready=1
        break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ "$server_ready" -ne 1 ]; then
    printf 'capacity allocation server did not become ready\n' >&2
    tail -n 80 "$server_log" >&2
    exit 1
fi

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

cat "$temporary_directory/preflight.log"
grep -F 'The UI is disabled' "$server_log" >/dev/null
grep -F 'Vulkan0 model buffer size' "$server_log" >/dev/null
grep -F 'Vulkan0 KV buffer size' "$server_log" >/dev/null
grep -F 'Vulkan0 compute buffer size' "$server_log" >/dev/null
if grep -F 'Vulkan_Host model buffer size' "$server_log" >/dev/null; then
    printf 'model tensors remained in a Vulkan host buffer\n' >&2
    exit 1
fi
if grep -F 'CPU fallback rejected' "$server_log" >/dev/null; then
    printf 'capacity allocation reached a CPU graph node\n' >&2
    exit 1
fi

grep -E 'Vulkan0 (model|KV|compute) buffer size|model loaded|listening on' \
    "$server_log"
printf 'capacity_allocation_smoke=accepted context_size=%s required_vulkan_mib=%s\n' \
    "$context_size" "$required_vulkan_mib"
