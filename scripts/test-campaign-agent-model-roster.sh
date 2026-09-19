#!/bin/sh
set -eu

# campaign-agent-model-roster.sh through its whole lifecycle against a fake
# tree: a registry stub, launch and teardown stubs that leave markers, a
# strict-load stub that passes, fails, or emits a kernel hazard by row name,
# a sudo stub that records every call and can refuse the ring read, the real
# admit-summarize-roster.sh, and an HTTP fixture that logs each request and
# can hold one open until released. The lifecycle claims under test: a
# preflight refusal and a cancellation while waiting touch no served
# process and call no sudo; a cancellation during a roster request stops
# the roster's whole process group, so no further request or launch
# follows; a failed strict load excludes its row; a hazard or an unreadable
# ring halts; a roster failure makes the exit status agree with the
# terminal status; and reconciliation reads the run's own directory.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/campaign-test.XXXXXX")
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    # CAMPAIGN_TEST_KEEP retains the fixture tree for inspection.
    [ -n "${CAMPAIGN_TEST_KEEP:-}" ] || rm -rf "$work"
}
trap cleanup EXIT INT TERM

checks_total=0
checks_failed=0
check() {
    checks_total=$((checks_total + 1))
    if [ "$2" = pass ]; then
        printf 'check=%s outcome=pass\n' "$1"
    else
        checks_failed=$((checks_failed + 1))
        printf 'check=%s outcome=FAIL detail=%s\n' "$1" "${3:-}" >&2
    fi
}

T=$work/tree
mkdir -p "$T/scripts" "$work/state" "$work/source" "$work/evidence"
cp "$script_directory/campaign-agent-model-roster.sh" "$script_directory/admit-summarize-roster.sh" "$T/scripts/"
teardowns=$work/teardown.marker
launches=$work/launch.marker
sudos=$work/sudo.marker
requests=$work/request.log
cat >"$T/scripts/qwen-teardown.sh" <<EOF
#!/bin/sh
printf 'teardown\n' >>'$teardowns'
EOF
cat >"$T/scripts/qwen-launch.sh" <<EOF
#!/bin/sh
printf '%s\n' "\${QWEN_MODEL_PATH:-}" >>'$launches'
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/scripts/graft-consumer-env.sh"
cat >"$T/scripts/model-registry.sh" <<'EOF'
#!/bin/sh
printf 'fetch_script=dl-%s.sh\nmodel_file=%s/%s.gguf\n' "$2" "$2" "$2"
EOF
cat >"$T/scripts/test-strict-cuda-placement.sh" <<'EOF'
#!/bin/sh
sleep 0.3
case $4 in
    *failrow*) exit 1 ;;
    *hazardrow*) printf 'NVRM: Xid (PCI:0000:01:00): 79, GPU has fallen off the bus\n'; exit 1 ;;
esac
exit 0
EOF
cat >"$work/fake-sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$sudos'
while [ "\$#" -gt 0 ]; do case \$1 in -*) shift ;; *) break ;; esac; done
[ "\$#" -gt 0 ] || exit 0
case \$1 in dmesg) [ -e '$work/ring.refuse' ] && exit 1; printf 'kernel: quiet\n'; exit 0 ;; esac
exec "\$@"
EOF
chmod 755 "$T"/scripts/*.sh "$work/fake-sudo"
printf 'test-key\n' >"$work/state/api.key"
row() { printf '%s\trole\t%s/%s.gguf\tdl-%s.sh\t16384\t32768\t32768\tq8_0\tq4_0\ton\tnone\t-\t-\t-\tuntested\tcandidate\t2048\t512\t-\t-\tunmeasured\trefused\t0\toff\t-\tlru\n' "$1" "$1" "$1" "$1"; }
{ printf '# header\n'; for id in ctl a b failrow hazardrow; do row "$id"; done; } >"$T/scripts/models.tsv"
printf 'int a;\n' >"$work/source/a.c"
printf 'int slow;\n' >"$work/source/slow.c"
printf ' ok dl-a.sh\n ok dl-b.sh\n ok dl-failrow.sh\n ok dl-hazardrow.sh\nfetch_done\n' >"$work/fetch.log"

port=$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cat >"$work/server.py" <<'EOF'
import http.server, json, os, re, sys, time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        return

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        name = re.match(r"File: (\S+)", request["messages"][1]["content"]).group(1)
        with open(sys.argv[2], "a") as log:
            log.write(name + "\n")
        if name == "slow.c":
            while not os.path.exists(sys.argv[3]):
                time.sleep(0.1)
        body = json.dumps({"usage": {"prompt_tokens": 100, "completion_tokens": 20},
                           "choices": [{"finish_reason": "stop",
                                        "message": {"role": "assistant", "content": "A summary."}}]}).encode()
        # A cancelled roster closes its socket mid-answer; that is the
        # tested path, so the broken pipe is expected.
        try:
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except BrokenPipeError:
            pass

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
PYTHONDONTWRITEBYTECODE=1 python3 "$work/server.py" "$port" "$requests" "$work/release" &
server_pid=$!
sleep 0.5

reset() { rm -f "$teardowns" "$launches" "$sudos" "$requests" "$work/release" "$work/build.flag" "$work/ring.refuse"; }
campaign_exports() {
    export CAMPAIGN_TREE="$T" CAMPAIGN_EVIDENCE="$work/evidence" CAMPAIGN_CONTROL=ctl CAMPAIGN_SOURCE="$work/source" \
        CAMPAIGN_LLAMA_SERVER=/bin/true CAMPAIGN_BUILD_ACTIVE="[ -e $work/build.flag ]" CAMPAIGN_SUDO="$work/fake-sudo" \
        CAMPAIGN_POLL=1 QWEN_SERVER_PORT="$port" QWEN_WEBUI_STATE_DIRECTORY="$work/state" QWEN_ROSTER_REQUEST_TIMEOUT=30
}
# Both forms exec the runner inside a subshell, so a background campaign's
# recorded pid is the runner's own and a signal reaches the runner rather
# than a wrapper that would leave it orphaned.
campaign() { ( campaign_exports; exec "$T/scripts/campaign-agent-model-roster.sh" "$@" ); }
campaign_bg() { ( campaign_exports; exec "$T/scripts/campaign-agent-model-roster.sh" "$@" ) & pid=$!; }
latest_run() { sed -n 's/^.* run directory //p' "$work/out" | head -1; }
verdict() { awk -F'\t' '$1=="campaign" {print $2}' "$(latest_run)/campaign-status.tsv" | tail -1; }

# A preflight refusal: one row's fetch never verified. No teardown, no sudo.
reset
status=0; CAMPAIGN_ROWS='a missing' campaign "$work/fetch.log" >"$work/out" 2>&1 || status=$?
if [ "$status" = 1 ] && [ ! -e "$teardowns" ] && [ ! -e "$sudos" ] && [ "$(verdict)" = refused ]; then
    check preflight_refusal_owns_nothing pass
else
    check preflight_refusal_owns_nothing fail "status=$status teardown=$([ -e "$teardowns" ] && echo yes || echo no) verdict=$(verdict)"
fi

# A cancellation while waiting for the build exits at once, owning nothing.
reset; touch "$work/build.flag"
CAMPAIGN_ROWS=a campaign_bg "$work/fetch.log" >"$work/out" 2>&1
sleep 1.5
kill -TERM "$pid" 2>/dev/null || true
status=0; wait "$pid" || status=$?
if [ "$status" = 143 ] && [ ! -e "$teardowns" ] && [ ! -e "$sudos" ] && [ "$(verdict)" = cancelled ]; then
    check cancel_while_waiting_is_terminal pass
else
    check cancel_while_waiting_is_terminal fail "status=$status teardown=$([ -e "$teardowns" ] && echo yes || echo no) sudo=$([ -e "$sudos" ] && echo yes || echo no)"
fi
sleep 1.5
# The poll loop stopped with the runner: no later poll reached sudo either.
if [ ! -e "$sudos" ]; then check no_poll_after_cancel pass; else check no_poll_after_cancel fail "sudo calls after cancel"; fi

# A cancellation during a roster request stops the roster's process group:
# the held request is the last one, no launch follows, teardown ran.
reset
CAMPAIGN_ROWS=a QWEN_ROSTER_FILES='slow.c a.c' campaign_bg "$work/fetch.log" >"$work/out" 2>&1
attempt=0
until [ -s "$requests" ]; do attempt=$((attempt + 1)); [ "$attempt" -lt 100 ] || break; sleep 0.1; done
ps -eo pid,pgid,ppid,args >"$work/ps-before-cancel" 2>/dev/null || true
kill -TERM "$pid" 2>/dev/null || true
status=0; wait "$pid" || status=$?
touch "$work/release"
sleep 2
if [ "$status" = 143 ] && [ "$(grep -c . "$requests")" = 1 ] && [ "$(grep -c . "$launches")" = 1 ] \
    && [ -e "$teardowns" ] && ! pgrep -f "$T/scripts/admit-summarize-roster.sh" >/dev/null; then
    check cancel_during_request_stops_roster pass
else
    check cancel_during_request_stops_roster fail "status=$status requests=$(grep -c . "$requests" 2>/dev/null) launches=$(grep -c . "$launches" 2>/dev/null) roster_alive=$(pgrep -f "$T/scripts/admit-summarize-roster.sh" | wc -l)"
fi

# Every arm completes: exit 0, complete, one outcome per expected entry.
reset
status=0; CAMPAIGN_ROWS='a b' QWEN_ROSTER_FILES='a.c' campaign "$work/fetch.log" >"$work/out" 2>&1 || status=$?
entries=$(awk -F'\t' 'NR>1 {print $1":"$2":"$4}' "$(latest_run)/expected.tsv" | tr '\n' ' ')
if [ "$status" = 0 ] && [ "$(verdict)" = complete ] \
    && [ "$entries" = "checkpoint:ctl:stop checkpoint:a:stop checkpoint:b:stop deployment:ctl:stop " ] \
    && [ "$(grep -c . "$launches")" = 4 ] && [ -s "$(latest_run)/strict/a/kernel-ring.log" ]; then
    check complete_run_reconciles pass
else
    check complete_run_reconciles fail "status=$status verdict=$(verdict) entries='$entries' launches=$(grep -c . "$launches")"
fi

# A failed strict load excludes its row and the campaign still completes.
reset
status=0; CAMPAIGN_ROWS='failrow a' QWEN_ROSTER_FILES='a.c' campaign "$work/fetch.log" >"$work/out" 2>&1 || status=$?
if [ "$status" = 0 ] && [ "$(verdict)" = complete ] && grep -q '^failrow	strict	fail_excluded$' "$(latest_run)/campaign-status.tsv" \
    && grep -q '^checkpoint	failrow	a.c	excluded$' "$(latest_run)/expected.tsv" && ! grep -q failrow "$launches"; then
    check strict_failure_excludes_row pass
else
    check strict_failure_excludes_row fail "status=$status verdict=$(verdict)"
fi

# A kernel hazard around a strict load halts before any roster launch.
reset
status=0; CAMPAIGN_ROWS='hazardrow a' QWEN_ROSTER_FILES='a.c' campaign "$work/fetch.log" >"$work/out" 2>&1 || status=$?
if [ "$status" = 3 ] && [ "$(verdict)" = halted ] && [ ! -e "$launches" ] && [ -e "$teardowns" ]; then
    check hazard_halts pass
else
    check hazard_halts fail "status=$status verdict=$(verdict) launches=$([ -e "$launches" ] && echo yes || echo no)"
fi

# An unreadable kernel ring leaves the load unverified and halts.
reset; touch "$work/ring.refuse"
status=0; CAMPAIGN_ROWS='a' QWEN_ROSTER_FILES='a.c' campaign "$work/fetch.log" >"$work/out" 2>&1 || status=$?
if [ "$status" = 3 ] && grep -q 'ring_unverified' "$(latest_run)/campaign-status.tsv" && [ ! -e "$launches" ]; then
    check unreadable_ring_halts pass
else
    check unreadable_ring_halts fail "status=$status"
fi

# A roster failure makes the exit status agree with the terminal status,
# and answers retained by an earlier run are not counted.
reset
mkdir -p "$work/evidence/run-stale"
for i in 1 2 3; do printf '{"usage":{}}' >"$work/evidence/run-stale/roster.tsv.ctl.$i.json"; done
status=0; CAMPAIGN_ROWS='a' QWEN_ROSTER_FILES='absent.c' campaign "$work/fetch.log" >"$work/out" 2>&1 || status=$?
if [ "$status" = 1 ] && [ "$(verdict)" = failed ] && grep -q '^roster	checkpoint	exit_2$' "$(latest_run)/campaign-status.tsv" \
    && grep -q 'not_run' "$(latest_run)/expected.tsv"; then
    check roster_failure_exit_agrees pass
else
    check roster_failure_exit_agrees fail "status=$status verdict=$(verdict)"
fi

printf 'checks_total=%s checks_failed=%s\n' "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
