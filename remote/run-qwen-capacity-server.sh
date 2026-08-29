#!/bin/sh
set -eu

if [ "$#" -lt 4 ] || [ "$#" -gt 7 ]; then
    printf 'usage: %s LLAMA_SERVER MODEL_PATH CONTEXT_SIZE REQUIRED_VULKAN_MIB [PORT [STATIC_PATH [API_KEY_FILE]]]\n' \
        "$0" >&2
    exit 2
fi

llama_server=$1
model_path=$2
context_size=$3
required_vulkan_mib=$4
server_port=${5:-8080}
static_path=${6:-}
api_key_file=${7:-}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

"$script_directory/model-memory-preflight.sh" \
    "$model_path" "$required_vulkan_mib"

exec "$script_directory/qwen-capacity-policy.sh" \
    "$llama_server" "$model_path" "$context_size" "$server_port" \
    "$static_path" "$api_key_file"
