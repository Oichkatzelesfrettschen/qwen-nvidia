#!/bin/sh
# gpu-ownership: delegated to the serving chain.
# The agent-model roster campaign: strict CUDA0 placement load per new row,
# then the summarize roster over the rows that passed plus the control with
# every speculation variable unset (the checkpoint comparison), then the
# control alone under draft-mtp with one drafted token (the deployment
# comparison). Each invocation owns one fresh run directory under the
# evidence directory and reconciles an explicit expected set of (arm, row,
# file) entries against the outcomes retained there, so a count from
# another run can never stand in for this one.
#
#   usage: campaign-agent-model-roster.sh FETCH_LOG
#   CAMPAIGN_TREE          the checkout whose scripts/ and registry run,
#                          default the tree this script lives in
#   CAMPAIGN_EVIDENCE      the evidence directory that receives run-<stamp>/,
#                          default evidence/ada/agent-model-roster
#   CAMPAIGN_ROWS          the new rows, default the nine agent-code rows
#   CAMPAIGN_CONTROL       the control row, default qwen38-4b-distill
#   CAMPAIGN_SOURCE        the tree the roster's probe files are read from
#   CAMPAIGN_LLAMA_SERVER  the strict load's server binary
#   CAMPAIGN_BUILD_ACTIVE  a command that succeeds while the device is held
#                          by the build the campaign waits for, default the
#                          graft deep build's node process
#   CAMPAIGN_SUDO          the sudo command, default sudo
#   CAMPAIGN_POLL          seconds between waiting polls, default 300
#
# Lifecycle. Cancellation is a signal (INT or TERM) at any point. While the
# campaign is waiting or validating it owns nothing, so a refusal or a
# cancellation there exits without touching the served appliance. It takes
# ownership at its first teardown, after the build has released the device,
# and from then on every child runs in its own process group: cancellation
# stops that whole group, waits for it, tears the served process down, and
# exits 130 or 143. The exit status agrees with the terminal status in
# run-<stamp>/campaign-status.tsv: 0 complete, 4 partial, 1 failed or
# refused, 3 halted on a device hazard or lost hazard monitoring.
#
# Device health. Each strict load is bracketed by a kernel-ring read through
# sudo; the lines added during the load are retained beside the load's own
# logs and scanned for the hazard pattern. A ring that cannot be read leaves
# the load's health unverified, which halts the campaign rather than
# admitting the row.
set -u
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
W=${CAMPAIGN_TREE:-$(CDPATH='' cd -- "$script_directory/.." && pwd)}
E=${CAMPAIGN_EVIDENCE:-$W/evidence/ada/agent-model-roster}
NEW=${CAMPAIGN_ROWS:-"oxcoder-9b ornith15-9b qwen3-4b-instruct-2507 qwable-9b-fable5 klear-agentforge-8b hammer21-3b granite40-micro swe-dev-7b swe-agent-lm-7b"}
CONTROL=${CAMPAIGN_CONTROL:-qwen38-4b-distill}
SOURCE=${CAMPAIGN_SOURCE:-"${HOME:?}/Github/discobsd-2040-unofficial"}
LS=${CAMPAIGN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-appliance-current/bin/llama-server"}
BUILD_ACTIVE=${CAMPAIGN_BUILD_ACTIVE:-"pgrep -x node -a | grep -q 'graft build'"}
SUDO=${CAMPAIGN_SUDO:-sudo}
POLL=${CAMPAIGN_POLL:-300}
FILES=${QWEN_ROSTER_FILES:-"sys/arch/rp2040/dev/flash_swap.c bin/cat/cat.c sys/arch/rp2040/dev/usb.c"}
hazard='NV_ERR_INVALID_STATE|dmaAllocMapping|mapping_reuse|mmuWalkMap|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed|GPU reset|ring[^[:cntrl:]]*timeout|VM fault|device los[ts]'

[ "$#" -eq 1 ] || { printf 'usage: %s FETCH_LOG\n' "$0" >&2; exit 2; }
FETCH_LOG=$1
[ -r "$FETCH_LOG" ] || { printf 'fetch log is unreadable: %s\n' "$FETCH_LOG" >&2; exit 2; }

log() { printf '%s %s\n' "$(date +%FT%T)" "$*"; }

# One exclusive run directory per invocation; mkdir refuses a second owner.
stamp=$(date +%Y%m%dT%H%M%S)
# The pid keeps two invocations inside one second apart.
RUN=$E/run-$stamp-$$
mkdir -p "$E"
mkdir "$RUN" 2>/dev/null || { printf 'run directory exists: %s\n' "$RUN" >&2; exit 2; }
STATUS=$RUN/campaign-status.tsv
EXPECTED=$RUN/expected.tsv
printf 'subject\tstate\tdetail\n' >"$STATUS"
printf 'arm\trow\tfile\toutcome\n' >"$EXPECTED"
status() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$STATUS"; }
log "run directory $RUN"

# Ownership and cancellation. Before ownership a signal exits at once with
# nothing to clean up; after it, the group in flight is stopped and reaped
# and the served process torn down.
owned=0
group=
keepalive=
cancelled=0
finish() {
    if [ -n "$group" ]; then
        kill -TERM -- "-$group" 2>/dev/null
        wait "$group" 2>/dev/null
        group=
    fi
    [ -n "$keepalive" ] && kill "$keepalive" 2>/dev/null
    if [ "$owned" -eq 1 ]; then
        "$W/scripts/qwen-teardown.sh" >/dev/null 2>&1
        owned=0
    fi
}
on_signal() {
    cancelled=$1
    log "signal $1 received, campaign cancelled"
    status campaign cancelled "signal_$1"
    finish
    exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap finish EXIT
# run CMD... in its own process group and wait for it; a signal during the
# wait reaches on_signal, which stops the group before exiting.
run() {
    setsid "$@" &
    group=$!
    wait "$group"
    rc=$?
    group=
    [ "$cancelled" -eq 0 ] || exit "$cancelled"
    return "$rc"
}
pause() { run sleep "$POLL"; }
check_sudo() {
    $SUDO -n true 2>/dev/null && return 0
    log "sudo timestamp lost, hazard watchdog unavailable; campaign halted"
    status campaign halted sudo_unavailable
    exit 3
}

cd "$W" || exit 1

# Preflight: every new row's fetch script verified its artifact, by name.
missing=''
for id in $NEW; do
    script=$(scripts/model-registry.sh id "$id" | sed -n 's/^fetch_script=//p')
    grep -q " ok $script\$" "$FETCH_LOG" || missing="$missing $id"
done
if [ -n "$missing" ]; then
    log "fetch chain did not verify:$missing; campaign refused"
    status campaign refused "fetch_unverified:$missing"
    exit 1
fi
log "fetch chain verified every new row by script name"

while sh -c "$BUILD_ACTIVE"; do pause; done
log "the build has released the device"

# Ownership begins here.
unset QWEN_SPEC_TYPE QWEN_SPEC_DRAFT_N_MAX QWEN_SPEC_DRAFT_P_MIN QWEN_SPEC_BACKEND_SAMPLING
export SUDO_ASKPASS=/usr/bin/unified-askpass
$SUDO -A -v || { log "sudo unavailable, hazard watchdog would abort; campaign refused"; status campaign refused sudo_unavailable; exit 1; }
( while :; do sleep 240; $SUDO -A -v >/dev/null 2>&1; done ) &
keepalive=$!
owned=1
scripts/qwen-teardown.sh >/dev/null 2>&1

# Strict CUDA0 load per row, bracketed by the kernel ring.
mkdir -p "$RUN/strict"
printf 'id\tstrict_cuda_placement\tkernel_ring\n' >"$RUN/strict/checks.tsv"
admitted=''
for id in $NEW; do
    check_sudo
    file=$(scripts/model-registry.sh id "$id" | sed -n 's/^model_file=//p')
    mkdir -p "$RUN/strict/$id"
    since=$(date '+%Y-%m-%dT%H:%M:%S')
    log strict load "$id"
    if QWEN_TEST_EVIDENCE_DIRECTORY="$RUN/strict/$id" run scripts/test-strict-cuda-placement.sh --llama-server "$LS" --model "$HOME/models/$file" >"$RUN/strict/$id/strict.out" 2>&1; then
        verdict=pass
    else
        verdict=fail
    fi
    if $SUDO -n dmesg --time-format=iso --since "$since" >"$RUN/strict/$id/kernel-ring.log" 2>/dev/null; then
        ring='read'
    else
        ring=unverified
    fi
    printf '%s\t%s\t%s\n' "$id" "$verdict" "$ring" >>"$RUN/strict/checks.tsv"
    if [ "$ring" = unverified ]; then
        log "kernel ring unreadable around the strict load of $id; campaign halted"
        status "$id" strict "${verdict}_ring_unverified"
        status campaign halted "ring_unverified:$id"
        exit 3
    fi
    if grep -E -q "$hazard" "$RUN/strict/$id/kernel-ring.log" "$RUN/strict/$id/strict.out" "$RUN/strict/$id"/*.log 2>/dev/null; then
        log "kernel hazard around the strict load of $id; campaign halted"
        status "$id" strict hazard
        status campaign halted "device_hazard:$id"
        exit 3
    fi
    if [ "$verdict" = pass ]; then
        status "$id" strict pass
        admitted="$admitted $id"
        log strict pass "$id"
    else
        status "$id" strict fail_excluded
        log strict fail "$id"
        tail -5 "$RUN/strict/$id/strict.out"
        for f in $FILES; do printf 'checkpoint\t%s\t%s\texcluded\n' "$id" "$f" >>"$EXPECTED"; done
    fi
done
[ -n "$admitted" ] || { log "no row passed the strict load; roster refused"; status campaign failed no_row_admitted; exit 1; }

# Roster arms. Each expected entry is (arm, row, file); the roster's outcome
# column fills it, and an entry the roster never wrote reads not_run.
roster_arm() {
    arm=$1; out=$2; ids=$3; shift 3
    check_sudo
    log "roster start, $arm, rows: $ids"
    if run env "$@" QWEN_ROSTER_IDS="$ids" QWEN_SUMMARIZE_SOURCE="$SOURCE" scripts/admit-summarize-roster.sh "$out" >"$out.log" 2>&1; then
        status roster "$arm" complete
    else
        status roster "$arm" "exit_$?"
    fi
    for id in $ids; do
        for f in $FILES; do
            outcome=$(awk -F'\t' -v id="$id" -v f="$f" 'NR>1 && $1==id && $2==f {print $12}' "$out" 2>/dev/null | head -1)
            if [ -z "$outcome" ]; then
                outcome=$(awk -F'\t' -v id="$id" 'NR>1 && $1==id && $12=="launch_failed" {print $12}' "$out" 2>/dev/null | head -1)
            fi
            printf '%s\t%s\t%s\t%s\n' "$arm" "$id" "$f" "${outcome:-not_run}" >>"$EXPECTED"
        done
    done
}
roster_arm checkpoint "$RUN/roster.tsv" "$CONTROL$admitted" QWEN_SPEC_TYPE=
roster_arm deployment "$RUN/roster-4b-mtp.tsv" "$CONTROL" QWEN_SPEC_TYPE=draft-mtp QWEN_SPEC_DRAFT_N_MAX=1

nvidia-smi --query-gpu=name,driver_version,clocks.sm,clocks.max.sm,power.draw --format=csv >"$RUN/gpu-state-after.csv" 2>/dev/null

# Reconcile the expected set: every entry ends in an outcome the roster
# wrote, an exclusion, or not_run.
expected=$(awk 'NR>1' "$EXPECTED" | wc -l)
answered=$(awk -F'\t' 'NR>1 && $4=="stop"' "$EXPECTED" | wc -l)
not_run=$(awk -F'\t' 'NR>1 && $4=="not_run"' "$EXPECTED" | wc -l)
excluded=$(awk -F'\t' 'NR>1 && $4=="excluded"' "$EXPECTED" | wc -l)
if grep -q '^roster	.*	exit_' "$STATUS"; then verdict=failed; code=1
elif [ "$not_run" -gt 0 ]; then verdict=partial; code=4
else verdict=complete; code=0; fi
status campaign "$verdict" "expected=$expected answered_stop=$answered not_run=$not_run excluded=$excluded"
log "campaign_status=$verdict expected=$expected answered_stop=$answered not_run=$not_run excluded=$excluded"
exit "$code"
