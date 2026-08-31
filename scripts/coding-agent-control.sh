#!/bin/sh
set -eu

# Start, stop, and read the coding-agent service. start backgrounds the
# session, waits for the listening line, and records the pid with its
# /proc start time so stop signals exactly the process it started; a
# reused pid is left alone. status asks the socket for health.

usage() {
    printf 'usage: %s start|stop|status\n' "$0" >&2
    exit 2
}
[ "$#" -eq 1 ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
state_directory=${QWEN_CODING_STATE_DIRECTORY:-"${HOME:?}/qwen-coding-state"}
status_file=$state_directory/session.status
socket_path=$state_directory/agent.sock

proc_start_time() {
    awk '{ print $22 }' "/proc/$1/stat" 2>/dev/null || :
}

case $1 in
start)
    mkdir -p "$state_directory"
    chmod 700 "$state_directory"
    nohup sh "$script_directory/coding-agent-session.sh" \
        >"$state_directory/session.log" 2>&1 &
    session_pid=$!
    waited=0
    while ! grep -q 'coding_agent_service=listening' \
        "$state_directory/session.log" 2>/dev/null; do
        kill -0 "$session_pid" 2>/dev/null || {
            printf 'service exited during startup:\n' >&2
            tail -5 "$state_directory/session.log" >&2
            exit 1
        }
        [ "$waited" -lt 30 ] || {
            printf 'service produced no listening line in 30s\n' >&2
            exit 1
        }
        sleep 1
        waited=$((waited + 1))
    done
    printf 'state=running pid=%s start_time=%s socket=%s\n' \
        "$session_pid" "$(proc_start_time "$session_pid")" "$socket_path" \
        | tee "$status_file"
    ;;
stop)
    [ -r "$status_file" ] || {
        printf 'no session.status; nothing recorded to stop\n' >&2
        exit 0
    }
    recorded_pid=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' "$status_file")
    recorded_start=$(sed -n 's/.*start_time=\([0-9]*\).*/\1/p' "$status_file")
    if [ -n "$recorded_pid" ] &&
        [ "$(proc_start_time "$recorded_pid")" = "$recorded_start" ]; then
        kill "$recorded_pid" 2>/dev/null || :
        waited=0
        while kill -0 "$recorded_pid" 2>/dev/null; do
            [ "$waited" -lt 10 ] || {
                kill -9 "$recorded_pid" 2>/dev/null || :
                break
            }
            sleep 1
            waited=$((waited + 1))
        done
    fi
    rm -f "$socket_path"
    printf 'state=stopped\n' | tee "$status_file"
    ;;
status)
    python3 - "$socket_path" <<'EOF'
import json, socket, sys
try:
    connection = socket.socket(socket.AF_UNIX)
    connection.settimeout(3)
    connection.connect(sys.argv[1])
    connection.sendall(b'{"action":"health"}\n')
    print(connection.makefile().readline().strip())
except OSError as error:
    print("state=unreachable detail=%s" % error)
    raise SystemExit(1)
EOF
    ;;
*)
    usage
    ;;
esac
