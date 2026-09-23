#!/bin/sh
# gpu-ownership: delegated to qwen-launch.sh and its serving chain.
set -eu
: "${PYTHON:?Select the intended Python interpreter}"
if [ "$#" -ne 1 ]; then
    printf 'usage: %s WORKFLOW_CONFIG\n' "$0" >&2
    exit 2
fi
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
native_ui=${QWEN_STATIC_PATH:-"$script_directory/../webui-llama-ui"}
if [ ! -f "$native_ui/index.html" ]; then
    printf 'Build the native UI with scripts/build-llama-ui.sh before launching Graft\n' >&2
    exit 2
fi
broker_port=${QWEN_WEB_BROKER_PORT:-8571}
if ! grep -Fq "name=\"qwen-graft-broker-origin\" content=\"http://127.0.0.1:$broker_port\"" \
    "$native_ui/index.html"; then
    printf 'native UI lacks matching Graft broker metadata; rebuild it with QWEN_WEB_BROKER_PORT=%s\n' \
        "$broker_port" >&2
    exit 2
fi
if [ "${QWEN_ROUTER:-0}" != 0 ]; then
    printf 'Graft launch requires a standalone model session\n' >&2
    exit 2
fi
if [ -n "${QWEN_GRAFT_BASE_MCP_CONFIG:-}" ]; then
    launch_environment=$("$PYTHON" "$script_directory/graft-launch-config.py" \
        "$1" --base-mcp "$QWEN_GRAFT_BASE_MCP_CONFIG")
else
    launch_environment=$("$PYTHON" "$script_directory/graft-launch-config.py" "$1")
fi
eval "$launch_environment"
export QWEN_STATIC_PATH=$native_ui
exec "$script_directory/qwen-launch.sh" default
