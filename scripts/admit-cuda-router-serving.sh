#!/bin/sh
set -eu

# gpu-ownership: delegated to the serving chain.
# This harness reaches the device only through qwen-launch.sh, and
# qwen-webui-control.sh puts a tmux boundary between itself and
# qwen-webui-session.sh. tmux starts a session from its own server process, so no
# descriptor this harness opens reaches the capacity server on the far side.
# run-qwen-capacity-server.sh takes the campaign lock there instead, and a claim
# held here would refuse the very session this harness launches.

# Drive the whole launch chain once and record what it served.
#
# The chain assembles policy link by link -- preflight, capacity policy, runtime
# environment wrapper, exec guard, router children -- and each link is tested
# alone elsewhere. This runs the assembled thing: it launches the appliance in
# router mode, asks two models for one reply each, and reads back from the
# server's own log which device the children allocated on and whether both were
# resident at once.
#
# The device check is the reason this exists. A binary carrying both backends
# offers CUDA0 and Vulkan0 for the same card, and a router child that named
# neither allocated on Vulkan0 here while every measurement that set the
# defaults ran on CUDA0. A serving path that silently changes backend is a
# different machine than the one the evidence describes.
#
# The launcher returns as soon as the session reports ready, and the tmux
# session it started is a child of the invoking process group, so this script
# stays in the foreground for the whole run and tears the appliance down before
# it exits.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [MODEL_ID MODEL_ID]\n' "$0" >&2
    printf '  QWEN_SERVER_PORT     listener, default 8080\n' >&2
    printf '  QWEN_ROUTER_MAX      resident children; the default is 1 where the\n                       registry carries an evict-first row, else 2\n' >&2
    printf '  QWEN_ROUTER_PRESETS  preset file, default the state directory copy\n' >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

output_directory=$1
first_model=${2:-qwen38-2b-distill}
second_model=${3:-qwen35-08b}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
server_port=${QWEN_SERVER_PORT:-8080}
# A roster holding an evict-first row serves one child at a time, which
# qwen-capacity-policy.sh enforces when it validates the preset tuples and
# README states as the router construction constraint. Hard-coding two made
# this admission refuse its own launch against a registry that carries such a
# row, so the default is derived from the registry rather than asserted here.
router_default=2
if grep -v '^#' "$script_directory/models.tsv" |
    awk -F'\t' '$26 == "evict-first" { found = 1 } END { exit !found }'; then
    router_default=1
fi
router_max=${QWEN_ROUTER_MAX:-$router_default}
endpoint=http://127.0.0.1:$server_port
readiness_seconds=${QWEN_ADMISSION_READINESS_SECONDS:-300}

command -v curl >/dev/null 2>&1 || {
    printf 'curl is absent from PATH\n' >&2
    exit 1
}

mkdir -p "$output_directory"
summary=$output_directory/serving-summary.tsv
printf 'check\tresult\tdetail\n' >"$summary"
record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$summary"
    printf '%s=%s %s\n' "$1" "$2" "$3"
}

appliance_started=0
# qwen-teardown.sh exits with the residue it found, and that status is the
# teardown evidence: a stop that reported incomplete once entered the summary
# as accepted because the status was dropped here.
teardown_status=untried
teardown_appliance() {
    [ "$appliance_started" -eq 1 ] || return 0
    appliance_started=0
    if QWEN_WEBUI_STATE_DIRECTORY=$state_directory QWEN_SERVER_PORT=$server_port \
        "$script_directory/qwen-teardown.sh" \
        >"$output_directory/teardown.log" 2>&1; then
        teardown_status=0
    else
        teardown_status=$?
    fi
}
trap 'teardown_appliance' EXIT
trap 'teardown_appliance; exit 130' INT
trap 'teardown_appliance; exit 143' TERM

server_log=$state_directory/server.log

QWEN_ROUTER=1 QWEN_ROUTER_MAX=$router_max \
    "$script_directory/qwen-launch.sh" >"$output_directory/launch.log" 2>&1 || {
    record launch failed "$(tail -1 "$output_directory/launch.log")"
    exit 1
}
appliance_started=1
record launch accepted "router_max=$router_max"

# The offset is taken after the launch because the session truncates this log
# as it starts, and a router child prints its memory breakdown while unwinding,
# long after both. Reading from here covers every line this run appends and
# none an earlier run left.
if [ -r "$server_log" ]; then
    server_log_offset=$(wc -c <"$server_log")
else
    server_log_offset=0
fi

waited=0
while ! curl --silent --fail --max-time 3 "$endpoint/health" >/dev/null 2>&1; do
    if [ "$waited" -ge "$readiness_seconds" ]; then
        record health timeout "waited=${waited}s"
        exit 1
    fi
    sleep 2
    waited=$((waited + 2))
done
record health accepted "waited=${waited}s"

curl --silent --fail --max-time 10 "$endpoint/v1/models" \
    >"$output_directory/models.json" || {
    record roster failed "GET /v1/models"
    exit 1
}
roster_count=$(python3 -c 'import json,sys
print(len(json.load(open(sys.argv[1]))["data"]))' "$output_directory/models.json")
record roster accepted "ids=$roster_count"

# Thinking is off because the reply budget here is one short answer and these
# distills spend a reasoning span before it otherwise, which reads as an empty
# completion rather than as the model failing.
ask_model() {
    ask_id=$1
    ask_output=$2
    printf '{"model":"%s","messages":[{"role":"user","content":"Reply with one word: the capital of Norway."}],"max_tokens":64,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' \
        "$ask_id" >"$output_directory/$ask_id.request.json"
    curl --silent --fail --max-time 600 "$endpoint/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        --data-binary "@$output_directory/$ask_id.request.json" >"$ask_output"
}

for model_id in "$first_model" "$second_model"; do
    reply_path=$output_directory/$model_id.reply.json
    if ! ask_model "$model_id" "$reply_path"; then
        record "reply_$model_id" failed 'POST /v1/chat/completions'
        exit 1
    fi
    reply_summary=$(python3 -c 'import json,sys
payload = json.load(open(sys.argv[1]))
message = payload["choices"][0]["message"]["content"].strip().replace("\t", " ")
print("served=%s tokens=%s reply=%s" % (
    payload.get("model", "unknown"),
    payload["usage"]["completion_tokens"],
    message[:40] or "<empty>"))' "$reply_path")
    record "reply_$model_id" accepted "$reply_summary"
done

curl --silent --fail --max-time 10 "$endpoint/v1/models" \
    >"$output_directory/models-after.json" || true
resident=$(python3 -c 'import json,sys
data = json.load(open(sys.argv[1]))["data"]
loaded = [r["id"] for r in data if r.get("status", {}).get("value") == "loaded"]
print("%d:%s" % (len(loaded), ",".join(loaded)))' \
    "$output_directory/models-after.json" 2>/dev/null || echo '0:')
record resident_children observed "$resident"

if command -v nvidia-smi >/dev/null 2>&1; then
    record device_memory observed \
        "used_mib=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)"
fi

teardown_appliance
teardown_last_line=$(tail -1 "$output_directory/teardown.log" 2>/dev/null || echo 'no output')
# Two claims, two rows. `teardown` is the machine's state, which
# qwen-teardown.sh proves by survivor checks. `teardown_exclusion` is whether
# the retiring process held the compute lease through its destroy, which a
# router parent never does: its children take the lease, so the parent's
# destroy reads held=no and the proof is the llama-router-orderly-retirement
# lane. Where that lane is off, the row is skipped by name rather than read
# as a failure of the teardown or passed as one of its successes.
case $teardown_status in
    0)
        record teardown accepted "$teardown_last_line"
        record teardown_exclusion accepted 'session retirement read teardown_exclusion=orderly'
        ;;
    4)
        record teardown accepted "$teardown_last_line"
        if [ "${QWEN_ROUTER_ORDERLY_RETIREMENT:-0}" = 1 ]; then
            record teardown_exclusion failed 'orderly router retirement was enabled and the exclusion stayed unproven'
        else
            record teardown_exclusion skipped 'router children hold the compute lease and the parent destroy reads held=no; the proof is the llama-router-orderly-retirement.patch lane, QWEN_ROUTER_ORDERLY_RETIREMENT=0 here'
        fi
        ;;
    *)
        record teardown failed "status=$teardown_status $teardown_last_line"
        record teardown_exclusion failed 'the teardown left residue'
        ;;
esac

# Each child prints its memory breakdown while unwinding rather than while
# loading, so the device the children allocated on is read after the teardown
# that made them print it.
# `common_param` prints every device the binary enumerates, so a Vulkan0 line
# there names an available backend rather than an allocation. The two lines that
# state where the weights went are the placement line each child prints while
# loading and the breakdown it prints while unwinding.
# Every line is kept rather than a tail, because the placement helper
# attributes a line to a child by its pid prefix and the second child's line
# is the one a tail drops first.
device_lines=$(tail -c "+$((server_log_offset + 1))" "$server_log" |
    grep -aE 'using device (CUDA|Vulkan)[0-9]|common_memory_breakdown_print:.*\((CUDA|Vulkan)[0-9]?' || true)
printf '%s\n' "$device_lines" >"$output_directory/device-lines.txt"
placement=$("$script_directory/router-serving-evidence.sh" placement \
    "$output_directory/device-lines.txt" 2)
record "$(printf '%s' "$placement" | cut -f1)" \
    "$(printf '%s' "$placement" | cut -f2)" \
    "$(printf '%s' "$placement" | cut -f3)"

# The verdict admits the accepting vocabulary alone, so a check that was not
# observed, not completed, or not attempted rejects the admission the same as
# one that failed: an admission is evidence of what it observed.
if verdict_line=$("$script_directory/router-serving-evidence.sh" verdict "$summary"); then
    verdict=accepted
else
    verdict=rejected
fi
printf 'cuda_router_serving=%s checks=%s %s summary=%s\n' \
    "$verdict" "$(($(wc -l <"$summary") - 1))" "$verdict_line" "$summary"
[ "$verdict" = accepted ]
