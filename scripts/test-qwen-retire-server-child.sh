#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
retire_child=$script_directory/qwen-retire-server-child.sh
temporary_directory=$(mktemp -d)
fixture_pid=
cleanup() {
    [ -z "$fixture_pid" ] || kill -KILL "$fixture_pid" 2>/dev/null || true
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

start_fixture() {
    fixture_mode=$1
    fixture_log=$temporary_directory/$fixture_mode.log
    QWEN_TEST_RETIRE_MODE=$fixture_mode \
        setsid sh -c '
            on_term() {
                case $QWEN_TEST_RETIRE_MODE in
                    held) printf "workload lease teardown: held=yes\n" ;;
                    contradictory) printf "workload lease teardown: held=yes\nworkload lease teardown: held=no\n" ;;
                esac
                exit 0
            }
            trap on_term TERM
            wait_pipe=$1.wait
            mkfifo "$wait_pipe"
            while :; do read -r wait_value <"$wait_pipe" || true; done
        ' sh "$fixture_log" >"$fixture_log" 2>&1 &
    fixture_pid=$!
    fixture_start=$(sed 's/^.*) //' "/proc/$fixture_pid/stat" | awk '{ print $20 }')
}

start_fixture held
held_output=$(QWEN_DRAIN_ESCALATION_MS=1000 \
    "$retire_child" "$fixture_pid" "$fixture_start" "$fixture_log")
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=
printf '%s\n' "$held_output" | grep -qx 'teardown: held=yes'

start_fixture missing
missing_output=$(QWEN_DRAIN_ESCALATION_MS=1000 \
    "$retire_child" "$fixture_pid" "$fixture_start" "$fixture_log")
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=
if printf '%s\n' "$missing_output" | grep -q '^teardown:'; then
    printf 'missing teardown proof was accepted\n' >&2
    exit 1
fi

start_fixture contradictory
contradictory_output=$(QWEN_DRAIN_ESCALATION_MS=1000 \
    "$retire_child" "$fixture_pid" "$fixture_start" "$fixture_log")
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=
if printf '%s\n' "$contradictory_output" | grep -q '^teardown: held=yes$'; then
    printf 'contradictory teardown proof was accepted\n' >&2
    exit 1
fi

# The helper refuses a process inside the caller's session because a session
# scan at that boundary could include unrelated processes.
sh -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
fixture_pid=$!
fixture_start=$(sed 's/^.*) //' "/proc/$fixture_pid/stat" | awk '{ print $20 }')
set +e
boundary_output=$(QWEN_DRAIN_ESCALATION_MS=1000 \
    "$retire_child" "$fixture_pid" "$fixture_start" "$fixture_log" 2>&1)
boundary_status=$?
set -e
if [ "$boundary_status" -eq 0 ] ||
   ! printf '%s\n' "$boundary_output" |
        grep -q 'reason=session_boundary_mismatch'; then
    printf 'retirement accepted an unbounded serving session\n' >&2
    exit 1
fi
kill -TERM "$fixture_pid" 2>/dev/null || true
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=

# Real SRV_INF output prefixes the structured payload with logger fields. The
# parser binds the exact generation tuple across those prefixes.
router_log=$temporary_directory/router-prefix.log
router_marker=$temporary_directory/router-prefix.ready
QWEN_TEST_ROUTER_LOG=$router_log QWEN_TEST_ROUTER_MARKER=$router_marker \
    setsid sh -c '
        sleep 300 & child=$!
        start=$(sed "s/^.*) //" "/proc/$child/stat" | awk "{ print \$20 }")
        printf "srv  update_slots: router_child_generation model=old generation_port=19001 pid=%s start_time=%s state=running\n" "$child" "$start" >>"$QWEN_TEST_ROUTER_LOG"
        printf "srv  update_slots: router_child_inventory complete=yes active=1\n" >>"$QWEN_TEST_ROUTER_LOG"
        touch "$QWEN_TEST_ROUTER_MARKER"
        retire() {
            kill -TERM "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
            printf "srv  update_slots: router_child_retirement model=old generation_port=19001 pid=%s start_time=%s exited=yes exit_status=0 teardown_exclusion=orderly\n" "$child" "$start" >>"$QWEN_TEST_ROUTER_LOG"
            exit 0
        }
        trap retire TERM
        while :; do sleep 1; done
    ' >"$temporary_directory/router-prefix.stdout" 2>&1 &
fixture_pid=$!
fixture_start=$(sed 's/^.*) //' "/proc/$fixture_pid/stat" | awk '{ print $20 }')
attempt=0
while [ ! -e "$router_marker" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1)); sleep 0.01
done
router_output=$(QWEN_ROUTER=1 QWEN_DRAIN_ESCALATION_MS=1000 \
    "$retire_child" "$fixture_pid" "$fixture_start" "$router_log")
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=
printf '%s\n' "$router_output" | grep -qx 'teardown: held=yes'

orphan_log=$temporary_directory/orphan.log
orphan_marker=$temporary_directory/orphan.pid
QWEN_TEST_ORPHAN_MARKER=$orphan_marker setsid python3 -c '
import os
import signal
import subprocess
import time

child = subprocess.Popen(
    ["python3", "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(300)"]
)
with open(os.environ["QWEN_TEST_ORPHAN_MARKER"], "w", encoding="ascii") as marker:
    marker.write(str(child.pid) + "\n")
def leave(*_):
    raise SystemExit(0)
signal.signal(signal.SIGTERM, leave)
def_wait = time.sleep
while True:
    def_wait(1)
' >"$orphan_log" 2>&1 &
fixture_pid=$!
fixture_start=$(sed 's/^.*) //' "/proc/$fixture_pid/stat" | awk '{ print $20 }')
attempt=0
while [ ! -s "$orphan_marker" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.01
done
orphan_pid=$(sed -n '1p' "$orphan_marker")
set +e
QWEN_DRAIN_ESCALATION_MS=500 \
    "$retire_child" "$fixture_pid" "$fixture_start" "$orphan_log" >/dev/null 2>&1
orphan_status=$?
set -e
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=
if [ "$orphan_status" -eq 0 ]; then
    printf 'surviving runtime child was accepted\n' >&2
    exit 1
fi
if kill -0 "$orphan_pid" 2>/dev/null; then
    orphan_state=$(sed 's/^.*) //' "/proc/$orphan_pid/stat" 2>/dev/null | awk '{ print $1 }')
    if [ "$orphan_state" != Z ] && [ "$orphan_state" != X ]; then
        printf 'bounded escalation left runtime child %s alive\n' "$orphan_pid" >&2
        exit 1
    fi
fi

printf 'qwen_server_child_retirement=accepted\n'
