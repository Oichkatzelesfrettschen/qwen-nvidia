#!/bin/sh
set -eu

# The CUDA0 admission load. test-strict-vulkan-placement.sh admits a row on the
# Vulkan fallback and names Vulkan0 in every argv and every log line it reads;
# this check runs the same three stages against the serving backend. The two
# refusals prove LLAMA_NO_CPU_FALLBACK is in force in the binary under test --
# a host-placed tensor and a host-placed graph node each end the process --
# and the positive load then requires every buffer class on CUDA0, a
# fixed-seed completion at temperature 0 answered twice with the same content,
# and no fallback line in the log. The wrapper is cuda-runtime-env.sh at the
# default profile, so the load runs under the environment the appliance serves.

if [ "$#" -ne 4 ] || [ "$1" != "--llama-server" ] || [ "$3" != "--model" ]; then
    printf 'usage: %s --llama-server PATH --model PATH\n' "$0" >&2
    printf 'environment: QWEN_TEST_EVIDENCE_DIRECTORY  retains every log and reply\n' >&2
    printf '             QWEN_STRICT_PORT_BASE           first of three ports, default 18094\n' >&2
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

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
wrapper=$script_directory/cuda-runtime-env.sh
temporary_directory=$(mktemp -d)
evidence_directory=${QWEN_TEST_EVIDENCE_DIRECTORY:-}
port_base=${QWEN_STRICT_PORT_BASE:-18094}
tensor_port=$port_base
graph_port=$((port_base + 1))
serving_port=$((port_base + 2))
server_pid=""

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [ -n "$evidence_directory" ]; then
        mkdir -p "$evidence_directory"
        cp -f "$temporary_directory"/* "$evidence_directory"/ 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

common_arguments='--fit off --ctx-size 128 --parallel 1 --threads 1 --threads-batch 1 --batch-size 128 --ubatch-size 128 --no-ui --host 127.0.0.1 -lv 10'

# Stage one: a load told to place every tensor on the host is refused at the
# buffer selection, which is the first point the strict build can see it.
set +e
# shellcheck disable=SC2086
env LLAMA_NO_CPU_FALLBACK=1 DISPLAY= WAYLAND_DISPLAY= \
    timeout --signal=TERM 20 "$llama_server_binary" \
        --model "$model_path" $common_arguments \
        --device none --n-gpu-layers 0 --port "$tensor_port" \
        >"$temporary_directory/cpu-tensor.log" 2>&1
tensor_status=$?
set -e
if [ "$tensor_status" -eq 0 ] || [ "$tensor_status" -eq 124 ]; then
    printf 'CPU tensor placement was not rejected: status=%s\n' "$tensor_status" >&2
    exit 1
fi
grep -F 'selected CPU buffer' "$temporary_directory/cpu-tensor.log" >/dev/null

# Stage two: with the device named and no override, the scheduler leaves the
# token embedding on the host. The CUDA backend refuses that at the buffer
# selection of token_embd.weight, ahead of any graph, where the Vulkan check
# reaches the graph and refuses the GET_ROWS node; either line proves the host
# placement was refused, and the one observed is reported.
set +e
# shellcheck disable=SC2086
QWEN_CUDA_PROFILE=default "$wrapper" \
    timeout --signal=TERM 20 "$llama_server_binary" \
    --model "$model_path" $common_arguments \
    --device CUDA0 --split-mode none --n-gpu-layers all \
    --port "$graph_port" >"$temporary_directory/cpu-graph.log" 2>&1
graph_status=$?
set -e
if [ "$graph_status" -eq 0 ] || [ "$graph_status" -eq 124 ]; then
    printf 'CPU graph placement was not rejected: status=%s\n' "$graph_status" >&2
    exit 1
fi
if grep -F 'token_embd.weight selected CPU buffer' \
    "$temporary_directory/cpu-graph.log" >/dev/null; then
    graph_refusal=buffer-selection
elif grep -E 'CPU fallback rejected for graph node [^ ]+ \(GET_ROWS\)' \
    "$temporary_directory/cpu-graph.log" >/dev/null; then
    graph_refusal=graph-node
else
    printf 'CPU graph placement ended without a fallback refusal line\n' >&2
    exit 1
fi

# Stage three: the served placement, every tensor overridden onto CUDA0.
positive_log=$temporary_directory/cuda-positive.log
first_response=$temporary_directory/response-1.json
second_response=$temporary_directory/response-2.json
# shellcheck disable=SC2086
QWEN_CUDA_PROFILE=default "$wrapper" "$llama_server_binary" \
    --model "$model_path" $common_arguments \
    --device CUDA0 --split-mode none --n-gpu-layers all \
    --override-tensor '.*=CUDA0' --port "$serving_port" >"$positive_log" 2>&1 &
server_pid=$!

server_ready=0
attempt=0
while [ "$attempt" -lt 600 ]; do
    if curl --silent --fail "http://127.0.0.1:$serving_port/health" >/dev/null 2>&1; then
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
    printf 'strict CUDA server did not become ready\n' >&2
    exit 1
fi

complete_once() {
    printf '%s\n' '{"prompt":"Hello","n_predict":8,"temperature":0,"seed":1,"cache_prompt":false}' |
        curl --silent --show-error --output "$1" \
            --write-out '%{http_code}' -H 'Content-Type: application/json' \
            --data-binary @- "http://127.0.0.1:$serving_port/completion"
}
first_status=$(complete_once "$first_response")
second_status=$(complete_once "$second_response")

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

if [ "$first_status" != 200 ] || [ "$second_status" != 200 ]; then
    printf 'strict CUDA completion returned HTTP %s then %s\n' \
        "$first_status" "$second_status" >&2
    exit 1
fi
read_reply() {
    python3 - "$1" <<'PYTHON'
import json
import sys

reply = json.load(open(sys.argv[1], encoding="utf-8"))
if reply.get("tokens_predicted") != 8:
    raise SystemExit(f"tokens_predicted is {reply.get('tokens_predicted')!r} rather than 8")
print(reply.get("content", ""))
PYTHON
}
first_content=$(read_reply "$first_response")
second_content=$(read_reply "$second_response")
if [ -z "$first_content" ] || [ "$first_content" != "$second_content" ]; then
    printf 'fixed-seed completion is not deterministic across two requests\n' >&2
    exit 1
fi
completion_sha256=$(printf '%s' "$first_content" | sha256sum | awk '{ print $1 }')
grep -F 'CUDA0 model buffer size' "$positive_log" >/dev/null
grep -F 'CUDA0 KV buffer size' "$positive_log" >/dev/null
grep -F 'CUDA0 compute buffer size' "$positive_log" >/dev/null
if grep -F 'CPU fallback rejected' "$positive_log" >/dev/null; then
    printf 'strict CUDA completion reached a CPU graph node\n' >&2
    exit 1
fi
if grep -F 'CPU_Mapped model buffer size' "$positive_log" >/dev/null; then
    printf 'strict CUDA load left a host-mapped model buffer\n' >&2
    exit 1
fi

printf 'cpu_tensor_rejection=accepted cpu_graph_rejection=accepted graph_refusal=%s strict_cuda_completion=accepted deterministic_completion=accepted completion_sha256=%s\n' \
    "$graph_refusal" "$completion_sha256"
