#!/bin/sh
# The runner that produced strict/ and roster*.tsv, retained beside them.
# It reconciles the fetch chain by artifact name, waits for the detached
# graft deep build to exit, runs the strict CUDA0 placement load on each new
# row, and admits to the roster only the rows that passed: a strict failure
# whose logs carry a kernel hazard halts the campaign (exit 3), any other
# strict failure excludes that row and is recorded as such. The roster then
# runs over the admitted rows plus the qwen38-4b-distill control with every
# speculation variable unset (the checkpoint comparison), and the control
# alone under draft-mtp with one drafted token (the deployment comparison).
# campaign-status.tsv reconciles expected answers against retained ones and
# ends with campaign_status=complete, partial or failed; a signal makes the
# run terminal (exit 130 or 143) after the child in flight is stopped and
# the served process torn down. The log is the proof of order.
set -u
W=$HOME/worktrees/qwen-nvidia/campaign/agent-model-roster
S=${CAMPAIGN_SCRATCH:?CAMPAIGN_SCRATCH names the directory holding fetch-roster.log}
NEW="oxcoder-9b ornith15-9b qwen3-4b-instruct-2507 qwable-9b-fable5 klear-agentforge-8b hammer21-3b granite40-micro swe-dev-7b swe-agent-lm-7b"
CONTROL=qwen38-4b-distill
E=$W/evidence/ada/agent-model-roster
LS=$HOME/src/llama.cpp-qwen-nvidia/build-appliance-current/bin/llama-server
SOURCE=$HOME/Github/discobsd-2040-unofficial
hazard='NV_ERR_INVALID_STATE|dmaAllocMapping|mapping_reuse|mmuWalkMap|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed|GPU reset|ring[^[:cntrl:]]*timeout|VM fault|device los[ts]'
STATUS=$E/campaign-status.tsv
log() { printf '%s %s\n' "$(date +%FT%T)" "$*"; }
status() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$STATUS"; }

child=
keepalive=
cancelled=0
on_signal() {
    cancelled=$1
    log "signal $1 received, campaign cancelled"
    [ -n "$child" ] && kill "$child" 2>/dev/null
}
cleanup() {
    [ -n "$child" ] && kill "$child" 2>/dev/null
    [ -n "$keepalive" ] && kill "$keepalive" 2>/dev/null
    "$W/scripts/qwen-teardown.sh" >/dev/null 2>&1
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap cleanup EXIT
# run CMD... in the background and wait, so a signal interrupts the wait,
# the handler stops the child, and the caller sees the cancellation.
run() {
    "$@" &
    child=$!
    wait "$child"
    rc=$?
    child=
    [ "$cancelled" -eq 0 ] || exit "$cancelled"
    return "$rc"
}
device_ready() {
    [ "$cancelled" -eq 0 ] || exit "$cancelled"
    sudo -n true 2>/dev/null || { log "sudo timestamp lost, hazard watchdog unavailable; campaign halted"; status campaign halted sudo_unavailable; exit 3; }
}

cd "$W" || exit 1
mkdir -p "$E/strict"
printf 'subject\tstate\tdetail\n' >"$STATUS"

until grep -q '^fetch_done' "$S/fetch-roster.log" 2>/dev/null; do sleep 60; done
missing=''
for id in $NEW; do
    script=$(scripts/model-registry.sh id "$id" | sed -n 's/^fetch_script=//p')
    grep -q " ok $script\$" "$S/fetch-roster.log" || missing="$missing $id"
done
if [ -n "$missing" ]; then
    log "fetch chain did not verify:$missing; campaign refused"
    status campaign refused "fetch_unverified:$missing"
    exit 1
fi
log "fetch chain verified all nine by script name"

while pgrep -x node -a | grep -q 'graft build'; do sleep 300; done
log graft deep build exited

unset QWEN_SPEC_TYPE QWEN_SPEC_DRAFT_N_MAX QWEN_SPEC_DRAFT_P_MIN QWEN_SPEC_BACKEND_SAMPLING
export SUDO_ASKPASS=/usr/bin/unified-askpass
sudo -A -v || { log "sudo unavailable, hazard watchdog would abort; campaign refused"; status campaign refused sudo_unavailable; exit 1; }
( while :; do sleep 240; sudo -A -v >/dev/null 2>&1; done ) &
keepalive=$!
scripts/qwen-teardown.sh >/dev/null 2>&1

printf 'id\tstrict_cuda_placement\n' >"$E/strict/checks.tsv"
admitted=''
for id in $NEW; do
    device_ready
    file=$(scripts/model-registry.sh id "$id" | sed -n 's/^model_file=//p')
    log strict load "$id"
    if QWEN_TEST_EVIDENCE_DIRECTORY="$E/strict/$id" run scripts/test-strict-cuda-placement.sh --llama-server "$LS" --model "$HOME/models/$file" >"$E/strict/$id.out" 2>&1; then
        printf '%s\tpass\n' "$id" >>"$E/strict/checks.tsv"
        status "$id" strict pass
        admitted="$admitted $id"
        log strict pass "$id"
    else
        printf '%s\tfail\n' "$id" >>"$E/strict/checks.tsv"
        log strict fail "$id"
        tail -5 "$E/strict/$id.out"
        if grep -E -q "$hazard" "$E/strict/$id.out" "$E/strict/$id"/*.log 2>/dev/null; then
            log "kernel hazard in the strict logs of $id; campaign halted"
            status "$id" strict hazard
            status campaign halted "device_hazard:$id"
            exit 3
        fi
        status "$id" strict fail_excluded
    fi
done
[ -n "$admitted" ] || { log "no row passed the strict load; roster refused"; status campaign failed no_row_admitted; exit 1; }

device_ready
log "roster start, checkpoint comparison, speculation unset, rows:$CONTROL$admitted"
if QWEN_ROSTER_IDS="$CONTROL$admitted" QWEN_SUMMARIZE_SOURCE=$SOURCE run scripts/admit-summarize-roster.sh "$E/roster.tsv" >"$S/agent-roster-run.out" 2>&1; then
    status roster checkpoint complete
else
    status roster checkpoint "exit_$?"
fi

device_ready
log "roster start, deployment control, draft-mtp one token"
if QWEN_SPEC_TYPE=draft-mtp QWEN_SPEC_DRAFT_N_MAX=1 QWEN_ROSTER_IDS="$CONTROL" QWEN_SUMMARIZE_SOURCE=$SOURCE \
    run scripts/admit-summarize-roster.sh "$E/roster-4b-mtp.tsv" >"$S/agent-roster-mtp.out" 2>&1; then
    status roster deployment complete
else
    status roster deployment "exit_$?"
fi

nvidia-smi --query-gpu=name,driver_version,clocks.sm,clocks.max.sm,power.draw --format=csv >"$E/gpu-state-after.csv" 2>/dev/null

# Reconcile: three answers per admitted row and per control arm, each a
# retained JSON file with a usage object.
expected=0; for _ in $CONTROL $admitted $CONTROL; do expected=$((expected + 3)); done
retained=0
for f in "$E"/roster.tsv.*.json "$E"/roster-4b-mtp.tsv.*.json; do
    case $f in *.request.json) continue ;; esac
    [ -f "$f" ] && jq -e '.usage' "$f" >/dev/null 2>&1 && retained=$((retained + 1))
done
if grep -q 'roster.*exit_' "$STATUS"; then verdict=failed
elif [ "$retained" -eq "$expected" ]; then verdict=complete
else verdict=partial; fi
status campaign "$verdict" "expected=$expected retained=$retained excluded=$(grep -c 'fail_excluded' "$STATUS")"
log "campaign_status=$verdict expected=$expected retained=$retained"
