#!/bin/sh
set -eu

# --backend-sampling is a server default that three gates take away per request,
# so which requests it reaches is a separate claim from what it saves.
# `common/sampling.cpp:415` disables it whenever the request built a grammar and
# `:421` whenever it built a reasoning-budget sampler, each on a warning line;
# `tools/server/server-context.cpp:1697-1702` disables it per slot when
# `n_probs > 0 && !post_sampling_probs`, and that one writes nothing. The
# response echoes `task.params.sampling.backend_sampling`
# (`server-task.cpp:84`), which is the value the request asked for rather than
# the value the slot used, so neither the body nor the third gate leaves
# positive evidence and the server log is the only authority.
#
# This probe drives one server with the flag on and asks it one request per
# shape, reading the log between requests. Each arm states the gate it predicts
# and the run records what the log said, so a prediction that fails is the
# finding. The reasoning-budget arm is the one that matters for this appliance:
# `webui/index.html:2505` sends `reasoning_budget: 0` on every turn whose
# reasoning toggle is off, `sampling.cpp:311` creates the budget sampler at any
# `reasoning_budget_tokens >= 0`, and `server-common.cpp:1362` supplies the
# thinking tags from the chat template, so the appliance's own default chat turn
# is predicted to disable the flag it was launched with.
#
# gpu-ownership: acquires

usage() {
    printf 'usage: %s MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'environment: QWEN_REACH_SERVER  llama-server, default the promoted closure\n' >&2
    printf '             QWEN_REACH_PORT    default 18140\n' >&2
    printf '             QWEN_MODEL_ROOT    default $HOME/models\n' >&2
    exit 2
}
[ "$#" -eq 2 ] || usage
model_id=$1
output_directory=$2

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
build_directory=${QWEN_REACH_BUILD:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-appliance-current"}
server_binary=${QWEN_REACH_SERVER:-"$build_directory/bin/llama-server"}
port=${QWEN_REACH_PORT:-18140}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
wrapper=$script_directory/cuda-runtime-env.sh

[ -x "$server_binary" ] || { printf 'llama-server is unusable: %s\n' "$server_binary" >&2; exit 2; }
mkdir -p "$output_directory"

model_file=$("$script_directory/model-registry.sh" id "$model_id" model_file)
cache_type_k=$("$script_directory/model-registry.sh" id "$model_id" cache_type_k)
cache_type_v=$("$script_directory/model-registry.sh" id "$model_id" cache_type_v)
flash_attention=$("$script_directory/model-registry.sh" id "$model_id" flash_attention)
batch=$("$script_directory/model-registry.sh" id "$model_id" batch)
ubatch=$("$script_directory/model-registry.sh" id "$model_id" ubatch)
model_path=$model_root/$model_file
[ -f "$model_path" ] || { printf 'model file is absent: %s\n' "$model_path" >&2; exit 2; }

scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
scrub_home <"$output_directory/ownership.txt.raw" >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"

server_pid=''
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=''
    fi
    if [ -f "$output_directory/server.log.raw" ]; then
        scrub_home <"$output_directory/server.log.raw" >"$output_directory/server.log"
        rm -f "$output_directory/server.log.raw"
    fi
}
trap cleanup EXIT HUP INT TERM

log_raw=$output_directory/server.log.raw
QWEN_CUDA_PROFILE=default "$wrapper" "$server_binary" \
    --model "$model_path" --alias "$model_id" --host 127.0.0.1 --port "$port" --no-ui \
    --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
    --fit off --parallel 1 --threads 6 --threads-batch 6 --ctx-size 4096 \
    --batch-size "$batch" --ubatch-size "$ubatch" \
    --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
    --flash-attn "$flash_attention" --backend-sampling \
    --cache-ram 0 --ctx-checkpoints 0 --no-context-shift --no-warmup -lv 10 \
    >"$log_raw" 2>&1 9>&- &
server_pid=$!

attempt=0
while [ "$attempt" -lt 3000 ]; do
    if grep -q 'CUDA0 model buffer size' "$log_raw" && grep -q 'listening on' "$log_raw" &&
        curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        break
    fi
    kill -0 "$server_pid" 2>/dev/null || { printf 'server exited before readiness\n' >&2; exit 1; }
    attempt=$((attempt + 1))
    sleep 0.1
done
[ "$attempt" -lt 3000 ] || { printf 'server did not become ready\n' >&2; exit 1; }

summary=$output_directory/summary.tsv
: >"$summary"
printf 'model_id\t%s\n' "$model_id" >>"$summary"
printf 'server_flag\t--backend-sampling\n' >>"$summary"
printf 'closure\t%s\n' "$(basename "$(dirname "$(dirname "$server_binary")")")" >>"$summary"
printf 'context_armed\t%s\n' \
    "$(grep -c 'setting backend sampler' "$log_raw" || :)" >>"$summary"
printf '\narm\troute\tpredicted_gate\tobserved_gate\treasoning_budget_tokens\tagrees\n' >>"$summary"

# Each arm reads the log lines the request appended rather than the whole log,
# so an arm's verdict names what its own request caused.
ask() {
    # ask ARM ROUTE PREDICTED BODY
    arm=$1; route=$2; predicted=$3; body=$4
    before=$(wc -l <"$log_raw")
    curl --silent --show-error --max-time 300 \
        --header 'Content-Type: application/json' \
        --data "$body" "http://127.0.0.1:$port$route" \
        >"$output_directory/$arm.response.json" 2>"$output_directory/$arm.curl.stderr" || {
        printf '%s\t%s\t%s\trequest_failed\t-\tno\n' "$arm" "$route" "$predicted" >>"$summary"
        return 0
    }
    tail -n "+$((before + 1))" "$log_raw" | scrub_home >"$output_directory/$arm.server-lines.log"
    observed=none
    if grep -q 'not compatible with grammar' "$output_directory/$arm.server-lines.log"; then
        observed=grammar
    elif grep -q 'not compatible with reasoning budget' "$output_directory/$arm.server-lines.log"; then
        observed=reasoning_budget
    fi
    # llama_context emits `setting backend sampler` once at context creation
    # rather than per request, so no arm can read its own arming from the log.
    # The pre-sampling-logits gate at server-context.cpp:1697 writes nothing at
    # all, so an arm predicting it records what the log can establish -- that no
    # gate announced itself -- and the reachability question for that shape is
    # answered from the source rather than from this run.
    budget=$(sed -n 's/.*reasoning budget: tokens=\([-0-9]*\).*/\1/p' \
        "$output_directory/$arm.server-lines.log" | tail -1)
    [ -n "$budget" ] || budget=-
    if [ "$observed" = none ] && [ "$predicted" = pre_sample_logits ]; then
        observed=unobservable
    fi
    agrees=no
    [ "$observed" = "$predicted" ] && agrees=yes
    [ "$predicted" = pre_sample_logits ] && [ "$observed" = unobservable ] && agrees=n/a
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$arm" "$route" "$predicted" "$observed" "$budget" "$agrees" >>"$summary"
}

prompt='Name one color.'
chat_head="{\"model\":\"$model_id\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":8,\"temperature\":0"

ask completion-plain /completion none \
    "{\"prompt\":\"$prompt\",\"n_predict\":8,\"temperature\":0,\"cache_prompt\":false}"
ask completion-n-probs /completion pre_sample_logits \
    "{\"prompt\":\"$prompt\",\"n_predict\":8,\"temperature\":0,\"cache_prompt\":false,\"n_probs\":4}"
ask chat-thinking-on /v1/chat/completions none \
    "$chat_head,\"chat_template_kwargs\":{\"enable_thinking\":true}}"
# The body webui/index.html:2496-2505 composes for a turn with the reasoning
# toggle off: the template argument the checkpoint reads, and beside it the
# `reasoning_budget` key, which this server registers under the name
# `reasoning_budget_tokens` (server-schema.cpp:383) with no alias.
ask chat-thinking-off-webui /v1/chat/completions none \
    "$chat_head,\"chat_template_kwargs\":{\"enable_thinking\":false},\"reasoning_budget\":0}"
# The same intent under the name the server does register.
ask chat-budget-tokens /v1/chat/completions reasoning_budget \
    "$chat_head,\"chat_template_kwargs\":{\"enable_thinking\":true},\"reasoning_budget_tokens\":0}"
ask chat-json-schema /v1/chat/completions grammar \
    "$chat_head,\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"c\",\"schema\":{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\"}},\"required\":[\"color\"]}}}}"

disagreements=$(awk -F'\t' 'NF==6 && $1!="arm" && $6=="no"' "$summary" | wc -l)
printf '\nbackend_sampling_reach=%s arms=%s disagreements=%s\n' \
    "$([ "$disagreements" -eq 0 ] && echo accepted || echo deviated)" \
    "$(awk -F'\t' 'NF==6 && $1!="arm"' "$summary" | wc -l)" "$disagreements" >>"$summary"
tail -n 8 "$summary"
