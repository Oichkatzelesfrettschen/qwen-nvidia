#!/bin/sh
# gpu-ownership: measurement-campaign, acquires the owner lock for the run
#
# The CUDA graph lifecycle under one mixed-service transition. A llama-server
# built from the closure carrying patches/llama-cuda-graph-lifecycle.patch runs
# under GGML_CUDA_GRAPH_LIFECYCLE, so every graph compute appends one row naming
# its topology digest, what moved since the previous compute under the same
# graph key, the warmup state before and after the backend's decision, the
# action it took, the executable transition, and the host and device spans.
# graph-lifecycle-transition-client.py drives the T0 -> T1 -> T2 -> T3 state
# machine through that server several times with fixed prompts and fixed slot
# identities, then again with the slot identities swapped as the permutation
# control, and read-graph-lifecycle-trace.py joins the rows to the phases by
# wall clock and answers the five preregistered questions against the whole
# mixed-service interval as denominator.
#
# usage: run-graph-lifecycle-trace.sh SERVER_BINARY MODEL_ID OUTPUT_DIRECTORY
#   QWEN_LIFECYCLE_PORT          default 18200
#   QWEN_LIFECYCLE_SLOT_DEPTH    per-slot context, default 4096
#   QWEN_LIFECYCLE_PROMPT_A      tokens in A's prompt, default 256
#   QWEN_LIFECYCLE_PROMPT_B      tokens in B's prompt, default 256
#   QWEN_LIFECYCLE_PREDICT_A     default 128
#   QWEN_LIFECYCLE_PREDICT_B     default 32
#   QWEN_LIFECYCLE_TRIGGER       A tokens streamed before B enters, default 24
#   QWEN_LIFECYCLE_CYCLES        cycles per arm including the warm-up, default 6
#   QWEN_LIFECYCLE_CHECKPOINTS   --ctx-checkpoints, default 8
#   QWEN_LIFECYCLE_PASSAGE       text the prompts are cut from, default CLAUDE.md
#   QWEN_MODEL_ROOT              default $HOME/models
set -eu

usage() {
    printf 'usage: %s SERVER_BINARY MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    exit 2
}
[ "$#" -eq 3 ] || usage
server_binary=$1
model_id=$2
output_directory=$3
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
port=${QWEN_LIFECYCLE_PORT:-18200}
slot_depth=${QWEN_LIFECYCLE_SLOT_DEPTH:-4096}
prompt_a_tokens=${QWEN_LIFECYCLE_PROMPT_A:-256}
prompt_b_tokens=${QWEN_LIFECYCLE_PROMPT_B:-256}
predict_a=${QWEN_LIFECYCLE_PREDICT_A:-128}
predict_b=${QWEN_LIFECYCLE_PREDICT_B:-32}
trigger=${QWEN_LIFECYCLE_TRIGGER:-24}
cycles=${QWEN_LIFECYCLE_CYCLES:-6}
checkpoints=${QWEN_LIFECYCLE_CHECKPOINTS:-8}
passage=${QWEN_LIFECYCLE_PASSAGE:-"$script_directory/../CLAUDE.md"}
client=$script_directory/graph-lifecycle-transition-client.py
reader=$script_directory/read-graph-lifecycle-trace.py
wrapper=$script_directory/cuda-runtime-env.sh
telemetry_sampler=$script_directory/sample-nvidia-clocks.sh

refuse() { printf '%s\n' "$1" >&2; exit 2; }
[ -x "$server_binary" ] || refuse "server binary is not executable: $server_binary"
for helper in "$client" "$reader" "$wrapper" "$telemetry_sampler"; do
    [ -x "$helper" ] || refuse "helper is unusable: $helper"
done
for value in "$slot_depth" "$prompt_a_tokens" "$prompt_b_tokens" "$predict_a" "$predict_b" "$trigger" "$cycles" "$checkpoints" "$port"; do
    case $value in '' | *[!0-9]*) refuse "a numeric setting reads $value" ;; esac
done
[ "$cycles" -ge 3 ] || refuse "a trace needs the warm-up and two measured cycles at least"
[ "$trigger" -lt "$predict_a" ] || refuse "the trigger has to fall inside A's reply"
[ -r "$passage" ] || refuse "passage file is not readable: $passage"
closure_library=$(dirname "$server_binary")/libggml-cuda.so
if ! nm -D "$closure_library" 2>/dev/null | grep -q ggml_cuda_graph_lifecycle_begin; then
    refuse "closure carries no graph lifecycle hook: $closure_library"
fi
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    refuse "output directory exists and is not empty: $output_directory"
fi

row=$("$script_directory/model-registry.sh" id "$model_id")
field() { printf '%s\n' "$row" | sed -n "s/^$1=//p"; }
model_path=$model_root/$(field model_file)
cache_type_k=$(field cache_type_k)
cache_type_v=$(field cache_type_v)
flash_attention=$(field flash_attention)
batch=$(field batch)
ubatch=$(field ubatch)
context_ceiling=$(field context_ceiling)
[ -r "$model_path" ] || refuse "model file is not readable: $model_path"
[ $((2 * slot_depth)) -le "$context_ceiling" ] ||
    refuse "two slots at depth $slot_depth ask for $((2 * slot_depth)), above the $model_id ceiling $context_ceiling"
[ $((prompt_a_tokens + predict_a)) -le "$slot_depth" ] || refuse "A overflows its slot"
[ $((prompt_b_tokens + predict_b)) -le "$slot_depth" ] || refuse "B overflows its slot"

mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
scrub_ownership() {
    sed -E \
        -e 's|^(cuda_client) pid=[0-9]+ name=([^ ]+).* used=([0-9]+ MiB) .* verdict=(.*)$|\1 name=\2 used=\3 verdict=\4|' \
        -e 's|name=[^ ]*/([^ /]+)|name=\1|' \
        -e 's|^(named_llama_server_pids)=.*$|\1=redacted|' |
        scrub_home
}
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
scrub_ownership <"$output_directory/ownership.txt.raw" >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

server_pid=''
telemetry_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=''
    fi
    if [ -n "$telemetry_pid" ]; then
        kill "$telemetry_pid" 2>/dev/null || true
        wait "$telemetry_pid" 2>/dev/null || true
        telemetry_pid=''
    fi
    for raw in "$output_directory"/*.log.raw; do
        [ -f "$raw" ] || continue
        scrub_home <"$raw" >"${raw%.raw}"
        rm -f "$raw"
    done
}
trap 'cleanup' EXIT
trap 'cleanup; trap - EXIT; exit 129' HUP
trap 'cleanup; trap - EXIT; exit 130' INT
trap 'cleanup; trap - EXIT; exit 143' TERM

"$telemetry_sampler" "$output_directory/telemetry.tsv" 1 9>&- &
telemetry_pid=$!

summary=$output_directory/summary.tsv
: >"$summary"
printf 'model_id\t%s\n' "$model_id" >>"$summary"
printf 'closure_sha256\t%s\n' "$(sha256sum "$server_binary" | cut -d' ' -f1)" >>"$summary"
printf 'closure_path\t%s\n' "$(printf '%s' "$server_binary" | scrub_home)" >>"$summary"
printf 'slot_depth\t%s\nprompt_a_tokens\t%s\nprompt_b_tokens\t%s\npredict_a\t%s\npredict_b\t%s\ntrigger\t%s\ncycles\t%s\ncontext_checkpoints\t%s\nbatch\t%s\nubatch\t%s\n' \
    "$slot_depth" "$prompt_a_tokens" "$prompt_b_tokens" "$predict_a" "$predict_b" "$trigger" "$cycles" "$checkpoints" "$batch" "$ubatch" >>"$summary"

# One server serves both arms, so the permutation control runs against the
# same loaded weights, the same allocations, and the same graph key history
# the fixed-slot arm left; the reader separates the arms by wall clock.
trace=$output_directory/graph-lifecycle.tsv
GGML_CUDA_GRAPH_LIFECYCLE=$trace QWEN_CUDA_PROFILE=default "$wrapper" "$server_binary" \
    --model "$model_path" --alias "$model_id" --host 127.0.0.1 --port "$port" --no-ui \
    --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
    --fit off --parallel 2 --threads 6 --threads-batch 6 \
    --ctx-size $((2 * slot_depth)) --batch-size "$batch" --ubatch-size "$ubatch" \
    --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
    --flash-attn "$flash_attention" \
    --cache-ram 0 --ctx-checkpoints "$checkpoints" --no-context-shift --no-warmup -lv 10 \
    >"$output_directory/server.log.raw" 2>&1 9>&- &
server_pid=$!

attempt=0
while [ "$attempt" -lt 3000 ]; do
    if grep -q 'CUDA0 model buffer size' "$output_directory/server.log.raw" &&
        grep -q 'listening on' "$output_directory/server.log.raw" &&
        curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        break
    fi
    kill -0 "$server_pid" 2>/dev/null || break
    attempt=$((attempt + 1))
    sleep 0.1
done
grep -q 'CUDA0 model buffer size' "$output_directory/server.log.raw" ||
    { printf 'the server did not become ready with a CUDA0 model buffer\n' >&2; exit 1; }
observed_depth=$(sed -n 's/.*new slot, n_ctx = \([0-9][0-9]*\).*/\1/p' "$output_directory/server.log.raw" | head -1)
[ "$observed_depth" = "$slot_depth" ] ||
    { printf 'slot depth is %s where the arm asked for %s\n' "$observed_depth" "$slot_depth" >&2; exit 1; }

# Two prompts are cut from two ends of the passage through the server's own
# tokenizer, so A and B carry different token histories at fixed lengths.
python3 - "$passage" "$prompt_a_tokens" "$prompt_b_tokens" "$port" "$output_directory" <<'PY'
import http.client, json, pathlib, sys
passage, want_a, want_b, port, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
text = pathlib.Path(passage).read_text(encoding="utf-8", errors="replace")
connection = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
connection.request("POST", "/tokenize", body=json.dumps({"content": text}), headers={"Content-Type": "application/json"})
response = connection.getresponse()
payload = json.loads(response.read())
if response.status != 200:
    sys.exit("tokenize answered %s: %s" % (response.status, str(payload)[:200]))
ids = payload["tokens"]
if len(ids) < want_a + want_b:
    sys.exit("the passage tokenizes to %d tokens, short of the %d asked" % (len(ids), want_a + want_b))
pathlib.Path(out, "prompt-a-tokens.json").write_text(json.dumps(ids[:want_a]))
pathlib.Path(out, "prompt-b-tokens.json").write_text(json.dumps(ids[-want_b:]))
print("prompt_a_tokens=%d prompt_b_tokens=%d passage_tokens=%d" % (want_a, want_b, len(ids)))
PY

run_arm() {
    # run_arm NAME SLOT_A SLOT_B
    arm_started=$(date +%s%N)
    "$client" --port "$port" --prompt-a "$output_directory/prompt-a-tokens.json" \
        --prompt-b "$output_directory/prompt-b-tokens.json" --slot-a "$2" --slot-b "$3" \
        --predict-a "$predict_a" --predict-b "$predict_b" --trigger-tokens "$trigger" \
        --cycles "$cycles" --output "$output_directory/$1" >"$output_directory/$1.client.log" 2>&1 || {
        printf 'arm %s rejected:\n' "$1" >&2
        cat "$output_directory/$1.client.log" >&2
        exit 1
    }
    printf 'arm\t%s\tslot_a=%s\tslot_b=%s\tstarted_ns=%s\tended_ns=%s\n' "$1" "$2" "$3" "$arm_started" "$(date +%s%N)" >>"$summary"
    sleep 1
}
run_arm fixed 0 1
run_arm permuted 1 0

# The server leaves ahead of the read so the recorder's exit flush lands every
# row whose end event completed.
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=''
if grep -q 'CPU fallback rejected\|CPU_Mapped model buffer' "$output_directory/server.log.raw"; then
    printf 'the server left a tensor or a graph on the host\n' >&2
    exit 1
fi
[ -s "$trace" ] || { printf 'the closure wrote no lifecycle rows\n' >&2; exit 1; }

"$reader" "$output_directory" | tee "$output_directory/lifecycle-summary.txt"
printf 'graph_lifecycle_trace=complete arms=2 cycles=%s\n' "$cycles"
