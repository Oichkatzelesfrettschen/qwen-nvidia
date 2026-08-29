#!/bin/sh
set -eu

# Load one checkpoint under the guarded launch path and record the properties a
# throughput number alone cannot show: whether the chat template still gates
# reasoning, whether a projector is bound to this checkpoint, what the load
# costs in Vulkan memory, and what the desktop latency probe saw meanwhile.
# Every candidate travels the same path, so a difference between two runs is a
# difference between two models.

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s LABEL MODEL_PATH [PROFILE]\n' "$0" >&2
    exit 2
fi

label=$1
model_path=$2
profile=${3:-low-async}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
result_directory=${QWEN_RESULT_DIRECTORY:-"${HOME:?}/qwen-model-comparison"}/$label
port=${QWEN_SERVER_PORT:-8080}
endpoint=http://127.0.0.1:$port

if [ ! -f "$model_path" ]; then
    printf 'model does not exist: %s\n' "$model_path" >&2
    exit 2
fi

umask 077
mkdir -p "$result_directory"

QWEN_MODEL_PATH=$model_path "$script_directory/qwen-launch.sh" "$profile" \
    >"$result_directory/launch.txt" 2>&1 || {
        cat "$result_directory/launch.txt" >&2
        exit 1
    }

curl --silent --fail "$endpoint/props" >"$result_directory/props.json" || true

request() {
    reasoning_flag=$1
    output_name=$2
    printf '{"model":"qwen-apu","messages":[{"role":"user","content":"Which is larger, 9.11 or 9.9? Answer in one sentence."}],"max_tokens":%s,"temperature":0,"chat_template_kwargs":{"enable_thinking":%s}%s}' \
        "$3" "$reasoning_flag" "$4" >"$result_directory/$output_name.request.json"
    curl --silent --show-error --max-time 900 \
        --header 'Content-Type: application/json' \
        --data @"$result_directory/$output_name.request.json" \
        "$endpoint/v1/chat/completions" >"$result_directory/$output_name.json" || true
}

request false reasoning-off 128 ',"reasoning_budget":0'
request true reasoning-on 1024 ''

"$script_directory/summarize-probe.sh" "$state_directory/graphics-latency.log" \
    >"$result_directory/probe-summary.txt" 2>/dev/null || true

"$script_directory/qwen-teardown.sh" >"$result_directory/teardown.txt" 2>&1 || true

# llama-server prints the per-device memory breakdown as it releases the
# context, so the figure exists only after teardown.
grep -F 'Vulkan0' "$state_directory/server.log" \
    >"$result_directory/vulkan-memory.txt" 2>/dev/null || true
cp "$state_directory/server.log" "$result_directory/server.log" 2>/dev/null || true

python3 - "$result_directory" "$label" "$model_path" <<'PY'
import json, os, sys

directory, label, model_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load(name):
    path = os.path.join(directory, name)
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return None

props = load('props.json') or {}
off = load('reasoning-off.json') or {}
on = load('reasoning-on.json') or {}

def message(document):
    try:
        return document['choices'][0]['message']
    except Exception:
        return {}

def timings(document):
    return document.get('timings') or {}

off_message, on_message = message(off), message(on)
off_timings, on_timings = timings(off), timings(on)

modalities = props.get('modalities') or {}
report = {
    'label': label,
    'model_path': model_path,
    'model_bytes': os.path.getsize(model_path),
    'context_size': props.get('default_generation_settings', {}).get('n_ctx'),
    'vision': bool(modalities.get('vision')),
    'prefill_tok_per_second': off_timings.get('prompt_per_second'),
    'decode_tok_per_second': off_timings.get('predicted_per_second'),
    'prompt_tokens': off_timings.get('prompt_n'),
    'decode_tokens': off_timings.get('predicted_n'),
    'reasoning_off_emitted_reasoning':
        bool(on_message and off_message.get('reasoning_content')),
    'reasoning_on_emitted_reasoning':
        bool(on_message.get('reasoning_content')),
    'reasoning_off_content': (off_message.get('content') or '')[:300],
    'reasoning_on_content': (on_message.get('content') or '')[:300],
    'reasoning_on_decode_tokens': on_timings.get('predicted_n'),
}
with open(os.path.join(directory, 'summary.json'), 'w') as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
for key in sorted(report):
    print('%s=%s' % (key, report[key]))
PY

printf 'candidate_comparison=completed label=%s result_directory=%s\n' \
    "$label" "$result_directory"
