#!/bin/sh
set -eu

# gpu-ownership: delegated to the serving chain.
# This harness reaches the device only through qwen-launch.sh, and
# qwen-webui-control.sh puts a tmux boundary between itself and
# qwen-webui-session.sh. tmux starts a session from its own server process, so no
# descriptor this harness opens reaches the capacity server on the far side.
# run-qwen-capacity-server.sh takes the campaign lock there instead, and a claim
# held here would refuse the very session this harness launches.

# Drive one evict-first transition through the assembled chain and record the
# device memory trajectory across it. The router at --models-max 1 already
# serializes evict-before-load on the victim child's process exit
# (server-models.cpp ensure_model_ready/unload_lru); this harness is the
# admission that the sequence holds on the device for a successor that fills
# the carve-out alone: the appliance serves a reply from the resident model,
# then asks the evict-first model, while a roster poll and the sub-second
# telemetry sampler watch the transition. Admission requires the victim to
# read unloaded before the successor reads loaded, the successor to answer
# from its own id, and the framebuffer peak to stay under the carve-out.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [RESIDENT_ID EVICT_FIRST_ID]\n' "$0" >&2
    printf '  QWEN_SERVER_PORT  listener, default 8080\n' >&2
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

output_directory=$1
resident_id=${2:-qwen38-2b-distill}
successor_id=${3:-qwen38-9b-distill}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
server_port=${QWEN_SERVER_PORT:-8080}
endpoint=http://127.0.0.1:$server_port
readiness_seconds=${QWEN_ADMISSION_READINESS_SECONDS:-300}
device_ceiling_mib=${QWEN_ADMISSION_DEVICE_CEILING_MIB:-11500}

command -v curl >/dev/null 2>&1 || {
    printf 'curl is absent from PATH\n' >&2
    exit 1
}

mkdir -p "$output_directory"
summary=$output_directory/transition-summary.tsv
printf 'check\tresult\tdetail\n' >"$summary"
record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$summary"
    printf '%s=%s %s\n' "$1" "$2" "$3"
}

appliance_started=0
roster_poll_pid=''
telemetry_pid=''
stop_watchers() {
    [ -n "$roster_poll_pid" ] && kill "$roster_poll_pid" 2>/dev/null || true
    [ -n "$telemetry_pid" ] && kill "$telemetry_pid" 2>/dev/null || true
    [ -n "$roster_poll_pid" ] && wait "$roster_poll_pid" 2>/dev/null || true
    [ -n "$telemetry_pid" ] && wait "$telemetry_pid" 2>/dev/null || true
    roster_poll_pid=''
    telemetry_pid=''
}
teardown_appliance() {
    stop_watchers
    [ "$appliance_started" -eq 1 ] || return 0
    QWEN_WEBUI_STATE_DIRECTORY=$state_directory QWEN_SERVER_PORT=$server_port \
        "$script_directory/qwen-teardown.sh" \
        >"$output_directory/teardown.log" 2>&1 || true
    appliance_started=0
}
trap 'teardown_appliance' EXIT
trap 'teardown_appliance; exit 130' INT
trap 'teardown_appliance; exit 143' TERM

QWEN_ROUTER=1 QWEN_ROUTER_MAX=1 \
    "$script_directory/qwen-launch.sh" >"$output_directory/launch.log" 2>&1 || {
    record launch failed "$(tail -1 "$output_directory/launch.log")"
    exit 1
}
appliance_started=1
record launch accepted "router_max=1"

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

ask_model() {
    printf '{"model":"%s","messages":[{"role":"user","content":"Reply with one word: the capital of Norway."}],"max_tokens":64,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' \
        "$1" >"$output_directory/$1.request.json"
    curl --silent --fail --max-time 600 "$endpoint/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        --data-binary "@$output_directory/$1.request.json" \
        >"$output_directory/$1.reply.json"
}

read_reply() {
    python3 -c 'import json, sys
payload = json.load(open(sys.argv[1]))
message = payload["choices"][0]["message"]["content"].strip().replace("\t", " ")
print("served=%s tokens=%s reply=%s" % (
    payload.get("model", "unknown"),
    payload["usage"]["completion_tokens"],
    message[:40] or "<empty>"))' "$output_directory/$1.reply.json"
}

if ! ask_model "$resident_id"; then
    record "reply_$resident_id" failed 'POST /v1/chat/completions'
    exit 1
fi
record "reply_$resident_id" accepted "$(read_reply "$resident_id")"

# The roster poll and the telemetry sampler cover the transition from before
# the successor request to after its reply, so the trough between the victim
# child's exit and the successor's allocation lands inside both windows.
roster_states=$output_directory/roster-states.tsv
printf 'epoch_ms\tresident_status\tsuccessor_status\n' >"$roster_states"
(
    while :; do
        stamp=$(date +%s%3N)
        pair=$(curl --silent --fail --max-time 2 "$endpoint/v1/models" 2>/dev/null |
            python3 -c 'import json, sys
data = json.load(sys.stdin)["data"]
status = {r["id"]: r.get("status", {}).get("value", "absent") for r in data}
print("%s\t%s" % (status.get(sys.argv[1], "absent"), status.get(sys.argv[2], "absent")))' \
                "$resident_id" "$successor_id" 2>/dev/null) || pair='poll-failed	poll-failed'
        printf '%s\t%s\n' "$stamp" "$pair" >>"$roster_states"
        sleep 0.25
    done
) &
roster_poll_pid=$!

"$script_directory/sample-transition-telemetry.sh" \
    "$output_directory/transition-telemetry.tsv" 240 100 \
    >"$output_directory/telemetry.log" 2>&1 &
telemetry_pid=$!

sleep 2
if ! ask_model "$successor_id"; then
    record "reply_$successor_id" failed 'POST /v1/chat/completions'
    exit 1
fi
record "reply_$successor_id" accepted "$(read_reply "$successor_id")"
sleep 3
stop_watchers

# The victim must leave before the successor arrives: some polled sample has
# the resident off loaded while the successor is not yet loaded, and the final
# sample has exactly the successor loaded.
transition_read=$(awk -F'\t' 'NR == 1 { next }
    $2 != "loaded" && $3 != "loaded" { gap = 1 }
    { last_resident = $2; last_successor = $3 }
    END {
        printf "gap_observed=%s final_resident=%s final_successor=%s",
            gap ? "yes" : "no", last_resident, last_successor
    }' "$roster_states")
case $transition_read in
    *gap_observed=yes*final_resident=unloaded*final_successor=loaded*)
        record evict_before_load accepted "$transition_read" ;;
    *)
        record evict_before_load failed "$transition_read" ;;
esac

memory_read=$(awk -F'\t' 'NR == 1 { next }
    NR == 2 { minimum = $2; maximum = $2 }
    { if ($2 < minimum) minimum = $2; if ($2 > maximum) maximum = $2 }
    END { printf "trough_mib=%s peak_mib=%s", minimum, maximum }' \
    "$output_directory/transition-telemetry.tsv")
peak_mib=${memory_read##*peak_mib=}
if [ "${peak_mib:-0}" -le "$device_ceiling_mib" ] 2>/dev/null; then
    record device_memory_bounded accepted "$memory_read ceiling=$device_ceiling_mib"
else
    record device_memory_bounded failed "$memory_read ceiling=$device_ceiling_mib"
fi

teardown_appliance
record teardown accepted \
    "$(tail -1 "$output_directory/teardown.log" 2>/dev/null || echo 'no output')"

rejected=$(awk -F'\t' '$2 == "failed" || $2 == "timeout"' "$summary" | grep -c '' || true)
if [ "$rejected" -eq 0 ]; then
    printf 'evict_first_transition=accepted summary=%s\n' "$summary"
    exit 0
fi
printf 'evict_first_transition=rejected rejected=%s summary=%s\n' \
    "$rejected" "$summary" >&2
exit 1
