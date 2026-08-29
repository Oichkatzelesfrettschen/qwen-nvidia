#!/bin/sh
set -eu

renice -n 19 -p $$ >/dev/null
taskset -pc 0 $$ >/dev/null
ionice -c 3 -p $$

# dash implements the core-size limit used by this POSIX-sh test even though
# ShellCheck classifies the option outside its portable ulimit subset.
# shellcheck disable=SC3045
ulimit -c 0

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
llama_server_binary=""
model_path=""

if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 4 ] || [ "$1" != "--llama-server" ] || \
       [ "$3" != "--model" ]; then
        printf 'usage: %s [--llama-server PATH --model PATH]\n' "$0" >&2
        exit 2
    fi
    llama_server_binary=$2
    model_path=$4
    if [ ! -x "$llama_server_binary" ]; then
        printf 'llama-server is not executable: %s\n' "$llama_server_binary" >&2
        exit 2
    fi
    if [ ! -f "$model_path" ]; then
        printf 'model is not a regular file: %s\n' "$model_path" >&2
        exit 2
    fi
fi

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
probe_binary=$temporary_directory/vulkan-low-priority-probe

cc -std=c11 -O2 -Wall -Wextra -Wpedantic -Werror \
    "$script_directory/vulkan-low-priority-probe.c" -lvulkan -o "$probe_binary"

radv_icd=${QWEN_RADV_ICD:-/usr/share/vulkan/icd.d/radeon_icd.x86_64.json}
if [ ! -r "$radv_icd" ]; then
    printf 'RADV ICD is not readable: %s\n' "$radv_icd" >&2
    exit 1
fi

probe_output=$(
    env DISPLAY= WAYLAND_DISPLAY= VK_ICD_FILENAMES="$radv_icd" \
        "$probe_binary"
)
printf '%s\n' "$probe_output"
printf '%s\n' "$probe_output" | grep -F 'global_priority=LOW result=VK_SUCCESS' >/dev/null

if [ -z "$llama_server_binary" ]; then
    printf 'llama_binary=not-tested reason=not-built\n'
    exit 0
fi

default_output=$(
    env -u GGML_VK_LOW_PRIORITY DISPLAY= WAYLAND_DISPLAY= \
        VK_ICD_FILENAMES="$radv_icd" "$llama_server_binary" --list-devices 2>&1
)
if printf '%s\n' "$default_output" | grep -F 'global queue priority = LOW' >/dev/null; then
    printf 'default device listing selected LOW unexpectedly\n' >&2
    exit 1
fi

default_log=$temporary_directory/default.log
low_priority_log=$temporary_directory/low.log
invalid_priority_log=$temporary_directory/invalid.log

run_model_server() {
    priority_mode=$1
    server_port=$2
    server_log=$3

    if [ "$priority_mode" = low ]; then
        env GGML_VK_LOW_PRIORITY=1 DISPLAY= WAYLAND_DISPLAY= \
            VK_DRIVER_FILES="$radv_icd" VK_ICD_FILENAMES="$radv_icd" \
            "$llama_server_binary" \
                --model "$model_path" --device Vulkan0 --split-mode none \
                --n-gpu-layers all --fit off --ctx-size 128 --parallel 1 \
                --threads 1 --threads-batch 1 --no-ui --host 127.0.0.1 \
                --port "$server_port" -lv 10 >"$server_log" 2>&1 &
    else
        env -u GGML_VK_LOW_PRIORITY DISPLAY= WAYLAND_DISPLAY= \
            VK_DRIVER_FILES="$radv_icd" VK_ICD_FILENAMES="$radv_icd" \
            "$llama_server_binary" \
                --model "$model_path" --device Vulkan0 --split-mode none \
                --n-gpu-layers all --fit off --ctx-size 128 --parallel 1 \
                --threads 1 --threads-batch 1 --no-ui --host 127.0.0.1 \
                --port "$server_port" -lv 10 >"$server_log" 2>&1 &
    fi
    server_pid=$!

    server_ready=0
    attempt=0
    while [ "$attempt" -lt 300 ]; do
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
        printf '%s-priority server did not become ready\n' "$priority_mode" >&2
        tail -n 80 "$server_log" >&2
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
        return 1
    fi

    kill -TERM "$server_pid"
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
}

run_model_server default 18082 "$default_log"
run_model_server low 18083 "$low_priority_log"

set +e
env GGML_VK_LOW_PRIORITY=0 DISPLAY= WAYLAND_DISPLAY= \
    VK_DRIVER_FILES="$radv_icd" VK_ICD_FILENAMES="$radv_icd" \
    timeout --signal=TERM 10 "$llama_server_binary" \
        --model "$model_path" --device Vulkan0 --split-mode none \
        --n-gpu-layers all --fit off --ctx-size 128 --parallel 1 \
        --threads 1 --threads-batch 1 --no-ui --host 127.0.0.1 \
        --port 18084 -lv 10 \
        >"$invalid_priority_log" 2>&1
invalid_priority_status=$?
set -e

if [ "$invalid_priority_status" -eq 0 ] || [ "$invalid_priority_status" -eq 124 ]; then
    printf 'llama-server accepted invalid LOW-priority opt-in value\n' >&2
    exit 1
fi
grep -F 'GGML_VK_LOW_PRIORITY accepts only the exact value 1' \
    "$invalid_priority_log" >/dev/null

if grep -F 'global queue priority = LOW' "$default_log" >/dev/null; then
    printf 'default model initialization selected LOW unexpectedly\n' >&2
    exit 1
fi

low_priority_output=$(cat "$low_priority_log")
printf '%s\n' "$low_priority_output" | grep -F 'global queue priority = LOW' >/dev/null
printf '%s\n' "$low_priority_output" | grep -F 'RADV RAVEN2' >/dev/null
printf '%s\n' "$low_priority_output" | grep -F 'model loaded' >/dev/null

printf 'llama_default_priority=unchanged llama_low_priority=accepted device=RADV_RAVEN2\n'
