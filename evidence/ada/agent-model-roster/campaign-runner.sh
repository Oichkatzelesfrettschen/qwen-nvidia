#!/bin/sh
# The runner that produced strict/ and roster*.tsv, retained beside them.
# It waits for the fetch chain to verify all nine artifacts and for the
# detached graft deep build to exit, then runs the strict CUDA0 placement
# load on each new row and the summarize roster over the nine rows plus the
# qwen38-4b-distill control. Speculation variables are unset for that run,
# because none of the nine artifacts carries an MTP head, so it is the
# checkpoint comparison; a second roster run serves the control alone under
# its registry speculation profile (draft-mtp, one drafted token), which is
# the deployment comparison. The log is the proof of order.
set -u
W=$HOME/worktrees/qwen-nvidia/campaign/agent-model-roster
S=${CAMPAIGN_SCRATCH:?CAMPAIGN_SCRATCH names the directory holding fetch-roster.log}
NEW="oxcoder-9b ornith15-9b qwen3-4b-instruct-2507 qwable-9b-fable5 klear-agentforge-8b hammer21-3b granite40-micro swe-dev-7b swe-agent-lm-7b"
E=$W/evidence/ada/agent-model-roster
LS=$HOME/src/llama.cpp-qwen-nvidia/build-appliance-current/bin/llama-server
log() { printf '%s %s\n' "$(date +%FT%T)" "$*"; }
cd "$W" || exit 1
until grep -q '^fetch_done' "$S/fetch-roster.log" 2>/dev/null; do sleep 60; done
verified=$(grep -c ' ok download-' "$S/fetch-roster.log")
log "fetch chain done, verified=$verified of 9"
[ "$verified" -eq 9 ] || { log "fetch chain incomplete, campaign refused"; grep ' FAIL ' "$S/fetch-roster.log"; exit 1; }
while pgrep -x node -a | grep -q 'graft build'; do sleep 300; done
log graft deep build exited
unset QWEN_SPEC_TYPE QWEN_SPEC_DRAFT_N_MAX QWEN_SPEC_DRAFT_P_MIN QWEN_SPEC_BACKEND_SAMPLING
export SUDO_ASKPASS=/usr/bin/unified-askpass
sudo -A -v || { log "sudo unavailable, hazard watchdog would abort; campaign refused"; exit 1; }
( while :; do sleep 240; sudo -A -v >/dev/null 2>&1; done ) &
keepalive=$!
trap 'kill "$keepalive" 2>/dev/null; scripts/qwen-teardown.sh >/dev/null 2>&1' EXIT INT TERM
scripts/qwen-teardown.sh >/dev/null 2>&1
mkdir -p "$E/strict"
printf 'id\tstrict_cuda_placement\n' >"$E/strict/checks.tsv"
for id in $NEW; do
    file=$(scripts/model-registry.sh id "$id" | sed -n 's/^model_file=//p')
    log strict load "$id"
    if QWEN_TEST_EVIDENCE_DIRECTORY="$E/strict/$id" scripts/test-strict-cuda-placement.sh --llama-server "$LS" --model "$HOME/models/$file" >"$E/strict/$id.out" 2>&1; then
        printf '%s\tpass\n' "$id" >>"$E/strict/checks.tsv"; log strict pass "$id"
    else
        printf '%s\tfail\n' "$id" >>"$E/strict/checks.tsv"; log strict fail "$id"; tail -5 "$E/strict/$id.out"
    fi
done
log roster start, checkpoint comparison, speculation unset
QWEN_ROSTER_IDS="qwen38-4b-distill $NEW" QWEN_SUMMARIZE_SOURCE=$HOME/Github/discobsd-2040-unofficial \
    scripts/admit-summarize-roster.sh "$E/roster.tsv" >"$S/agent-roster-run.out" 2>&1
log roster exit "$?"
log roster start, deployment control, draft-mtp one token
QWEN_SPEC_TYPE=draft-mtp QWEN_SPEC_DRAFT_N_MAX=1 QWEN_ROSTER_IDS="qwen38-4b-distill" \
    QWEN_SUMMARIZE_SOURCE=$HOME/Github/discobsd-2040-unofficial \
    scripts/admit-summarize-roster.sh "$E/roster-4b-mtp.tsv" >"$S/agent-roster-mtp.out" 2>&1
log roster-mtp exit "$?"
nvidia-smi --query-gpu=name,driver_version,clocks.sm,clocks.max.sm,power.draw --format=csv >"$E/gpu-state-after.csv" 2>/dev/null
log campaign_done
