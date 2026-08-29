#!/bin/sh
set -eu

# Measure decode through the guarded launch path under the same terms
# llama-bench measures it: a fixed generation length, end of sequence ignored,
# greedy sampling, one request against a freshly loaded server. The served
# figures already recorded came from a 13-token reply, where per-request
# transitions occupy a large share of the window, so they are not comparable to
# a 64-token steady-state rate. This makes them comparable, which leaves the
# harness itself as the only difference between the two numbers.
#
# QWEN_CACHE_TYPE_K, QWEN_CACHE_TYPE_V, and QWEN_FLASH_ATTN reach the server
# through qwen-webui-control.sh, so one cache cell of the factorial runs here
# exactly as it runs under llama-bench.

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s LABEL MODEL_PATH [PROFILE]\n' "$0" >&2
    exit 2
fi

label=$1
model_path=$2
profile=${3:-low-async}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
launch_script=${QWEN_LAUNCH_SCRIPT:-"$script_directory/qwen-launch.sh"}
teardown_script=${QWEN_TEARDOWN_SCRIPT:-"$script_directory/qwen-teardown.sh"}
state_directory=${QWEN_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
result_directory=${QWEN_RESULT_DIRECTORY:-"${HOME:?}/qwen-served-decode/$label"}
endpoint=http://127.0.0.1:${QWEN_SERVER_PORT:-8080}
generate_tokens=${QWEN_BENCH_GENERATE:-64}
export QWEN_WEBUI_STATE_DIRECTORY=$state_directory

case $generate_tokens in
    '' | *[!0-9]* | 0)
        printf 'generation length must be a positive integer: %s\n' \
            "$generate_tokens" >&2
        exit 2
        ;;
esac

if [ ! -f "$model_path" ]; then
    printf 'model file is absent: %s\n' "$model_path" >&2
    exit 2
fi

umask 077
mkdir -p "$result_directory"
printf 'label=%s\nmodel=%s\nprofile=%s\ncache_type_k=%s\ncache_type_v=%s\nflash_attention=%s\ngenerate_tokens=%s\n' \
    "$label" "$model_path" "$profile" \
    "${QWEN_CACHE_TYPE_K:-registry}" "${QWEN_CACHE_TYPE_V:-registry}" \
    "${QWEN_FLASH_ATTN:-registry}" "$generate_tokens" \
    >"$result_directory/inputs.txt"

server_started=0
teardown_status=not_run
teardown_server() {
    [ "$server_started" -eq 1 ] || return 0
    if "$teardown_script" >"$result_directory/teardown.txt" 2>&1; then
        teardown_status=0
    else
        teardown_status=$?
    fi
    server_started=0
}
trap 'teardown_server' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

QWEN_MODEL_PATH=$model_path "$launch_script" "$profile" \
    >"$result_directory/launch.txt" 2>&1 || {
        cat "$result_directory/launch.txt" >&2
        exit 1
    }
server_started=1

api_key=''
if [ -s "$state_directory/api.key" ]; then
    api_key=$(sed -n '1p' "$state_directory/api.key")
fi

# ignore_eos fixes the generation length, so the rate covers the same number of
# decode steps as `llama-bench -n 64` rather than however many the model chose.
printf '{"model":"qwen-apu","messages":[{"role":"user","content":"Write one paragraph about tides."}],"max_tokens":%s,"temperature":0,"top_k":1,"seed":1,"ignore_eos":true,"chat_template_kwargs":{"enable_thinking":false}}' \
    "$generate_tokens" >"$result_directory/request.json"

set +e
if [ -n "$api_key" ]; then
    curl --silent --show-error --fail-with-body --max-time 900 \
        --header 'Content-Type: application/json' \
        --header "Authorization: Bearer $api_key" \
        --data @"$result_directory/request.json" \
        "$endpoint/v1/chat/completions" >"$result_directory/response.json"
else
    curl --silent --show-error --fail-with-body --max-time 900 \
        --header 'Content-Type: application/json' \
        --data @"$result_directory/request.json" \
        "$endpoint/v1/chat/completions" >"$result_directory/response.json"
fi
request_status=$?
set -e

sed -n '1,3p' "$state_directory/session.status" >"$result_directory/session.status" \
    2>/dev/null || true
teardown_server

set +e
python3 - "$result_directory" "$label" "$request_status" \
    "$teardown_status" "$generate_tokens" <<'PY'
import json, os, sys

directory = sys.argv[1]
label = sys.argv[2]
request_status = int(sys.argv[3])
teardown_status = int(sys.argv[4])
expected_tokens = int(sys.argv[5])
try:
    with open(os.path.join(directory, 'response.json')) as handle:
        document = json.load(handle)
except Exception as error:
    document = {}
    print(f'served_decode=unreadable label={label} error={error}',
          file=sys.stderr)

timings = document.get('timings') or {}
report = {
    'label': label,
    'request_status': request_status,
    'teardown_status': teardown_status,
    'prefill_tok_per_second': timings.get('prompt_per_second'),
    'decode_tok_per_second': timings.get('predicted_per_second'),
    'prompt_tokens': timings.get('prompt_n'),
    'decode_tokens': timings.get('predicted_n'),
}
valid = (
    request_status == 0
    and teardown_status == 0
    and isinstance(report['prefill_tok_per_second'], (int, float))
    and isinstance(report['decode_tok_per_second'], (int, float))
    and report['prompt_tokens'] is not None
    and report['decode_tokens'] == expected_tokens
)
report['valid'] = valid
with open(os.path.join(directory, 'summary.json'), 'w') as handle:
    json.dump(report, handle, indent=2)
for key in sorted(report):
    print(f'{key}={report[key]}')
sys.exit(0 if valid else 1)
PY
summary_status=$?
set -e

if [ "$summary_status" -ne 0 ]; then
    printf 'served_decode=failed label=%s result_directory=%s\n' \
        "$label" "$result_directory" >&2
    exit 1
fi

printf 'served_decode=completed label=%s result_directory=%s\n' \
    "$label" "$result_directory"
