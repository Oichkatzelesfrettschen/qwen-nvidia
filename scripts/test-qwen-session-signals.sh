#!/bin/sh
set -eu

# The tmux session process owns the server and router snapshot. Each terminating
# signal must stop both resources and return the conventional signal status
# instead of resuming the readiness loop after cleanup.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
fixture_scripts=$temporary_directory/remote
session_pid=''
server_pid=''

cleanup_fixture() {
    if [ -n "$session_pid" ]; then
        kill -TERM "$session_pid" 2>/dev/null || true
        wait "$session_pid" 2>/dev/null || true
    fi
    if [ -n "$server_pid" ]; then
        kill -TERM "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup_fixture EXIT HUP INT TERM

mkdir -p "$fixture_scripts"
cp "$script_directory/qwen-webui-session.sh" \
    "$fixture_scripts/qwen-webui-session.sh"
cat >"$fixture_scripts/run-qwen-capacity-server.sh" <<'SERVER'
#!/bin/sh
printf '%s\n' "$$" >"$QWEN_TEST_SERVER_PID_MARKER"
trap 'exit 0' HUP INT TERM
while :; do
    sleep 1
done
SERVER
cat >"$fixture_scripts/signal-reset-exec.py" <<'PYTHON'
import os
import signal
import sys

for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signal_number, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
PYTHON
chmod +x "$fixture_scripts"/*.sh

for signal_and_status in HUP:129 INT:130 TERM:143; do
    signal_name=${signal_and_status%%:*}
    expected_status=${signal_and_status#*:}
    state_directory=$temporary_directory/state-$signal_name
    server_pid_marker=$temporary_directory/server-$signal_name.pid
    router_snapshot=$state_directory/.router-presets.active.$signal_name
    mkdir -p "$state_directory"
    : >"$router_snapshot"
    QWEN_ROUTER=1 QWEN_ROUTER_PRESETS=$router_snapshot \
        QWEN_TEST_SERVER_PID_MARKER=$server_pid_marker \
        python3 "$fixture_scripts/signal-reset-exec.py" \
            "$fixture_scripts/qwen-webui-session.sh" \
                "$temporary_directory/fake-server" \
                "$temporary_directory/fake-model" \
                "$temporary_directory/fake-static" 4096 4096 18080 \
                "$state_directory" default \
      >"$temporary_directory/session-$signal_name.stdout" \
      2>"$temporary_directory/session-$signal_name.stderr" &
    session_pid=$!
    attempt=0
    while [ ! -s "$server_pid_marker" ] && [ "$attempt" -lt 100 ]; do
        attempt=$((attempt + 1))
        sleep 0.01
    done
    if [ ! -s "$server_pid_marker" ]; then
        printf '%s session did not start its server fixture\n' \
            "$signal_name" >&2
        exit 1
    fi
    server_pid=$(sed -n '1p' "$server_pid_marker")
    kill -"$signal_name" "$session_pid"
    set +e
    wait "$session_pid"
    session_status=$?
    set -e
    session_pid=''
    if [ "$session_status" -ne "$expected_status" ]; then
        printf '%s session returned %s instead of %s\n' \
            "$signal_name" "$session_status" "$expected_status" >&2
        exit 1
    fi
    if kill -0 "$server_pid" 2>/dev/null; then
        printf '%s session retained server pid %s\n' \
            "$signal_name" "$server_pid" >&2
        exit 1
    fi
    server_pid=''
    if [ -e "$router_snapshot" ] || [ -L "$router_snapshot" ]; then
        printf '%s session retained router snapshot %s\n' \
            "$signal_name" "$router_snapshot" >&2
        exit 1
    fi
done

# The approval broker is a guarded child of the same session, so the arms below
# drive a complete startup rather than the readiness loop the signal arms stop
# inside: session.status carries broker_pid only after state=running, and the
# secret file's fate is what the teardown proves. Every collaborator the
# startup reaches is a fixture, so the arm runs without a device.
cat >"$fixture_scripts/monitor-qwen-runtime.sh" <<'MONITOR'
#!/bin/sh
trap 'exit 0' HUP INT TERM
while :; do
    sleep 1
done
MONITOR
cat >"$fixture_scripts/watch-qwen-kernel-hazards.sh" <<'HAZARD'
#!/bin/sh
printf 'watch_ready_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$2"
trap 'exit 0' HUP INT TERM
while :; do
    sleep 1
done
HAZARD
# The session admits the server only once its affinity and nice value match
# what qwen-webui-session.sh expects for the backend in force, and the
# readiness marker reaches the log, so the fixture applies each to itself. The
# cuda default in this session compares against QWEN_SERVING_CPU_LIST (the
# online CPU set where unset) and QWEN_SERVING_NICE (0 where unset), the same
# pair cuda-runtime-env.sh applies; the fixture reads the two so an explicit
# override in the environment still reaches this readiness check.
cat >"$fixture_scripts/ready-capacity-server.sh" <<'READY'
#!/bin/sh
serving_cpu_list=${QWEN_SERVING_CPU_LIST:-$(cat /sys/devices/system/cpu/online 2>/dev/null || echo 0)}
renice -n "${QWEN_SERVING_NICE:-0}" -p $$ >/dev/null 2>&1
taskset -cp "$serving_cpu_list" $$ >/dev/null 2>&1
printf '%s\n' "$$" >"$QWEN_TEST_SERVER_PID_MARKER"
printf 'model loaded\n'
trap 'exit 0' HUP INT TERM
while :; do
    sleep 1
done
READY
cat >"$fixture_scripts/latency-probe.sh" <<'PROBE'
#!/bin/sh
probe_log=''
while [ "$#" -gt 0 ]; do
    case $1 in
        --log)
            probe_log=$2
            shift
            ;;
    esac
    shift
done
printf 'probe_start ok\n' >"$probe_log"
trap 'exit 0' HUP INT TERM
while :; do
    sleep 1
done
PROBE
# One fake broker honours SIGTERM and removes its session secret, and one
# retains the signal so the teardown meets a survivor and reports residue. It
# answers GET /health with the identity the session compares, so the arm
# exercises the handshake the real broker serves; QWEN_TEST_BROKER_HEALTH_PID
# substitutes a wrong pid to make the comparison fail.
cat >"$fixture_scripts/fake-broker.py" <<'BROKER'
#!/usr/bin/env python3
import hashlib
import http.server
import json
import os
import signal
import sys
import time

arguments = sys.argv[1:]
settings = {"--port": "8571", "--profile": "", "--provider": "exa",
            "--state-dir": os.environ.get("QWEN_WEB_STATE_DIR", ""),
            "--host": "127.0.0.1", "--api-key-file": ""}
while arguments:
    key = arguments.pop(0)
    if key in settings and arguments:
        settings[key] = arguments.pop(0)
state_dir = settings["--state-dir"]
argument_record = os.environ.get("QWEN_TEST_BROKER_API_KEY_RECORD", "")
if argument_record:
    with open(argument_record, "w") as handle:
        handle.write(settings["--api-key-file"] + "\n")
os.makedirs(state_dir, exist_ok=True)
secret_file = os.path.join(state_dir, "authorize-session.secret")
with open(secret_file, "w") as handle:
    handle.write("fixture-session-secret\n")
key_file = os.environ.get("QWEN_WEB_TOKEN_KEY_FILE", "")
key_digest = ""
if key_file:
    with open(key_file, "rb") as handle:
        key_digest = hashlib.sha256(handle.read()).hexdigest()
with open("/proc/self/stat") as handle:
    start_time = int(handle.read().rsplit(")", 1)[1].split()[19])
health = {
    "protocol": "qwen-web-broker/1",
    "profile": settings["--profile"],
    "provider": settings["--provider"],
    "pid": int(os.environ.get("QWEN_TEST_BROKER_HEALTH_PID", os.getpid())),
    "start_time": start_time,
    "signing_key_sha256": key_digest,
    "state_dir": "0:0",
    "origins": [],
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = json.dumps(health).encode()
        self.send_response(200 if self.path == "/health" else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def leave(number, frame):
    raise KeyboardInterrupt


if os.environ.get("QWEN_TEST_BROKER_IGNORES_TERM", "0") == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    signal.signal(signal.SIGTERM, leave)
service = http.server.HTTPServer((settings["--host"], int(settings["--port"])), Handler)
time.sleep(float(os.environ.get("QWEN_TEST_BROKER_LISTEN_DELAY", "0")))
sys.stdout.write("listening %s %s\n" % (settings["--host"], settings["--port"]))
sys.stdout.flush()
try:
    service.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    if os.path.exists(secret_file):
        os.unlink(secret_file)
BROKER
chmod +x "$fixture_scripts/fake-broker.py"
chmod +x "$fixture_scripts"/*.sh

printf 'fixture-signing-key\n' >"$temporary_directory/token.key"
chmod 600 "$temporary_directory/token.key"

start_session() {
    ready_state_directory=$1
    ready_marker=$2
    broker_listen_delay=${3:-0}
    mkdir -p "$ready_state_directory"
    cp "$fixture_scripts/ready-capacity-server.sh" \
        "$fixture_scripts/run-qwen-capacity-server.sh"
    QWEN_TEST_SERVER_PID_MARKER=$ready_state_directory/server.marker \
        QWEN_VULKAN_LATENCY_PROBE=$fixture_scripts/latency-probe.sh \
        QWEN_WEB_BROKER=$ready_marker \
        QWEN_WEB_BROKER_PROGRAM=$fixture_scripts/fake-broker.py \
        QWEN_WEB_BROKER_PORT=18571 \
        QWEN_REQUIRE_API_KEY=$ready_marker \
        QWEN_WEB_PROFILE=web-fixture \
        QWEN_WEB_TOKEN_KEY_FILE=$temporary_directory/token.key \
        QWEN_WEB_STATE_DIR=$ready_state_directory/web-mcp \
        QWEN_TEST_BROKER_API_KEY_RECORD=$ready_state_directory/broker-api-key.path \
        QWEN_TEST_BROKER_LISTEN_DELAY=$broker_listen_delay \
        "$fixture_scripts/qwen-webui-session.sh" \
            "$temporary_directory/fake-server" \
            "$temporary_directory/fake-model" \
            "$temporary_directory/fake-static" 4096 4096 18080 \
            "$ready_state_directory" default \
      >"$ready_state_directory/session.stdout" \
      2>"$ready_state_directory/session.stderr" &
    session_pid=$!
}

start_ready_session() {
    ready_state_directory=$1
    ready_marker=$2
    start_session "$ready_state_directory" "$ready_marker"
    attempt=0
    while [ "$attempt" -lt 600 ]; do
        if grep -q 'state=running ' \
            "$ready_state_directory/session.status" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    printf 'session did not reach state=running under marker %s\n' \
        "$ready_marker" >&2
    cat "$ready_state_directory/session.status" >&2 2>/dev/null || true
    cat "$ready_state_directory/server.log" >&2 2>/dev/null || true
    cat "$ready_state_directory/authorize-broker.log" >&2 2>/dev/null || true
    cat "$ready_state_directory/session.stderr" >&2
    exit 1
}

read_status_field() {
    sed -n '1p' "$1/session.status" | tr ' ' '\n' |
        sed -n "s/^$2=//p"
}

starting_state_directory=$temporary_directory/state-broker-starting
start_session "$starting_state_directory" 1 5
attempt=0
while [ "$attempt" -lt 300 ] && \
      ! grep -q '^state=starting broker_pid=[0-9]' \
        "$starting_state_directory/session.status" 2>/dev/null; do
    attempt=$((attempt + 1))
    sleep 0.01
done
starting_broker_pid=$(read_status_field "$starting_state_directory" broker_pid)
case $starting_broker_pid in
    '' | *[!0-9]*)
        printf 'starting session did not persist its broker pid\n' >&2
        exit 1
        ;;
esac
kill -TERM "$session_pid"
set +e
wait "$session_pid"
session_status=$?
set -e
session_pid=''
if [ "$session_status" -ne 143 ]; then
    printf 'interrupted broker startup returned %s instead of 143\n' \
        "$session_status" >&2
    exit 1
fi
if kill -0 "$starting_broker_pid" 2>/dev/null; then
    printf 'interrupted startup retained broker pid %s\n' \
        "$starting_broker_pid" >&2
    exit 1
fi

# The marker starts the broker, the status file records its PID, and the
# terminating-signal path stops it and takes the session secret with it.
broker_state_directory=$temporary_directory/state-broker
start_ready_session "$broker_state_directory" 1
recorded_broker_pid=$(read_status_field "$broker_state_directory" broker_pid)
case $recorded_broker_pid in
    '' | *[!0-9]*)
        printf 'session recorded no broker_pid under the marker\n' >&2
        exit 1
        ;;
esac
broker_secret_file=$broker_state_directory/web-mcp/authorize-session.secret
if [ ! -s "$broker_secret_file" ]; then
    printf 'broker wrote no session secret at %s\n' "$broker_secret_file" >&2
    exit 1
fi
if ! grep -Fqx "$broker_state_directory/api.key" \
    "$broker_state_directory/broker-api-key.path" ||
   [ ! -s "$broker_state_directory/api.key" ]; then
    printf 'session did not forward its API key path to the broker\n' >&2
    exit 1
fi
recorded_identity=$(sed -n 's/^broker_identity //p' "$broker_state_directory/session.status")
case $recorded_identity in
    "pid=$recorded_broker_pid start_time="[0-9]*" profile=web-fixture provider=exa signing_key_sha256="????????????????????????????????????????????????????????????????) ;;
    *)
        printf 'session recorded no broker identity line: %s\n' "$recorded_identity" >&2
        exit 1
        ;;
esac
kill -TERM "$session_pid"
set +e
wait "$session_pid"
session_status=$?
set -e
session_pid=''
if [ "$session_status" -ne 143 ]; then
    printf 'broker session returned %s instead of 143\n' "$session_status" >&2
    exit 1
fi
if kill -0 "$recorded_broker_pid" 2>/dev/null; then
    printf 'session retained broker pid %s\n' "$recorded_broker_pid" >&2
    kill -KILL "$recorded_broker_pid" 2>/dev/null || true
    exit 1
fi
if [ -e "$broker_secret_file" ]; then
    printf 'session secret survives the broker: %s\n' "$broker_secret_file" >&2
    exit 1
fi

supervision_state_directory=$temporary_directory/state-broker-supervision
start_ready_session "$supervision_state_directory" 1
supervised_broker_pid=$(read_status_field "$supervision_state_directory" broker_pid)
supervised_server_pid=$(read_status_field "$supervision_state_directory" server_pid)
kill -TERM "$supervised_broker_pid"
attempt=0
while [ "$attempt" -lt 300 ] && \
      ! grep -q 'stopped_component=authorization_broker' \
        "$supervision_state_directory/session.status" 2>/dev/null; do
    attempt=$((attempt + 1))
    sleep 0.1
done
set +e
wait "$session_pid"
session_status=$?
set -e
session_pid=''
if [ "$session_status" -eq 0 ] || \
   ! grep -q 'stopped_component=authorization_broker' \
        "$supervision_state_directory/session.status"; then
    printf 'session accepted an approval broker that exited while serving\n' >&2
    cat "$supervision_state_directory/session.status" >&2
    exit 1
fi
if kill -0 "$supervised_server_pid" 2>/dev/null; then
    printf 'broker exit left server pid %s running\n' \
        "$supervised_server_pid" >&2
    exit 1
fi
if [ -e "$supervision_state_directory/web-mcp/authorize-session.secret" ]; then
    printf 'broker exit left its session secret behind\n' >&2
    exit 1
fi

# The ordinary launch leaves the marker unset, so its session runs no broker and
# records no broker_pid for a teardown to act on.
plain_state_directory=$temporary_directory/state-plain
start_ready_session "$plain_state_directory" 0
if [ -n "$(read_status_field "$plain_state_directory" broker_pid)" ]; then
    printf 'session recorded broker_pid without the marker\n' >&2
    exit 1
fi
if [ -d "$plain_state_directory/web-mcp" ]; then
    printf 'session created a broker state directory without the marker\n' >&2
    exit 1
fi
kill -TERM "$session_pid"
wait "$session_pid" 2>/dev/null || true
session_pid=''

# A broker whose /health names another pid is a process this launch did not
# start on the port it expected, so the session fails rather than serving.
mismatch_state_directory=$temporary_directory/state-mismatch
mkdir -p "$mismatch_state_directory"
cp "$fixture_scripts/ready-capacity-server.sh" \
    "$fixture_scripts/run-qwen-capacity-server.sh"
set +e
QWEN_TEST_SERVER_PID_MARKER=$mismatch_state_directory/server.marker \
    QWEN_VULKAN_LATENCY_PROBE=$fixture_scripts/latency-probe.sh \
    QWEN_WEB_BROKER=1 \
    QWEN_WEB_BROKER_PROGRAM=$fixture_scripts/fake-broker.py \
    QWEN_WEB_BROKER_PORT=18571 \
    QWEN_WEB_PROFILE=web-fixture \
    QWEN_WEB_TOKEN_KEY_FILE=$temporary_directory/token.key \
    QWEN_WEB_STATE_DIR=$mismatch_state_directory/web-mcp \
    QWEN_TEST_BROKER_HEALTH_PID=1 \
    "$fixture_scripts/qwen-webui-session.sh" \
        "$temporary_directory/fake-server" \
        "$temporary_directory/fake-model" \
        "$temporary_directory/fake-static" 4096 4096 18080 \
        "$mismatch_state_directory" default \
    >"$mismatch_state_directory/session.stdout" \
    2>"$mismatch_state_directory/session.stderr"
mismatch_status=$?
set -e
if [ "$mismatch_status" -eq 0 ] || \
   ! grep -q 'reason=authorization_broker_identity_mismatch .*mismatch=pid=1' \
        "$mismatch_state_directory/session.status"; then
    printf 'session accepted a broker whose /health named another pid\n' >&2
    cat "$mismatch_state_directory/session.status" >&2
    exit 1
fi
if [ -e "$mismatch_state_directory/web-mcp/authorize-session.secret" ]; then
    printf 'identity mismatch left the session secret behind\n' >&2
    exit 1
fi

# The teardown reads broker_pid before `stop` rewrites the status file, signals
# the process with the other guards, and proves both the process and its secret
# gone. Its control script is a fixture, so the arm leaves any tmux session on
# this machine alone.
cp "$script_directory/qwen-teardown.sh" "$fixture_scripts/qwen-teardown.sh"
# The teardown reads its image residue proof from its own directory, so the
# fixture carries that script too and these arms measure a teardown whose
# proof ran rather than one reporting the proof absent.
cp "$script_directory/image-teardown-check.sh" \
    "$fixture_scripts/image-teardown-check.sh"
cat >"$fixture_scripts/qwen-webui-control.sh" <<'CONTROL'
#!/bin/sh
set -eu
printf 'stopped tmux_socket=fixture tmux_session=fixture\n'
CONTROL
chmod +x "$fixture_scripts/qwen-teardown.sh" "$fixture_scripts/qwen-webui-control.sh" \
    "$fixture_scripts/image-teardown-check.sh"

run_teardown_arm() {
    teardown_state_directory=$temporary_directory/state-teardown-$1
    teardown_ignores_term=$2
    teardown_start_time=${3:-live}
    mkdir -p "$teardown_state_directory/web-mcp"
    QWEN_WEB_STATE_DIR=$teardown_state_directory/web-mcp \
        QWEN_TEST_BROKER_IGNORES_TERM=$teardown_ignores_term \
        "$fixture_scripts/fake-broker.py" --port 18571 \
        >"$teardown_state_directory/broker.log" 2>&1 &
    teardown_broker_pid=$!
    if [ "$teardown_start_time" = live ]; then
        teardown_start_time=$(sed 's/^.*) //' "/proc/$teardown_broker_pid/stat" |
            awk '{ print $20 }')
    fi
    attempt=0
    while [ "$attempt" -lt 300 ] && \
          [ ! -s "$teardown_state_directory/web-mcp/authorize-session.secret" ]; do
        attempt=$((attempt + 1))
        sleep 0.01
    done
    {
        printf 'state=running server_pid=99999999 monitor_pid=99999999 latency_watchdog_pid=99999999 kernel_hazard_watchdog_pid=99999999 broker_pid=%s profile=default\n' \
            "$teardown_broker_pid"
        printf 'broker secret_file=%s\n' \
            "$teardown_state_directory/web-mcp/authorize-session.secret"
        printf 'broker_identity pid=%s start_time=%s profile=web-fixture provider=exa signing_key_sha256=0\n' \
            "$teardown_broker_pid" "$teardown_start_time"
    } >"$teardown_state_directory/session.status"
    set +e
    QWEN_WEBUI_STATE_DIRECTORY=$teardown_state_directory \
        QWEN_WEB_STATE_DIR=$teardown_state_directory/web-mcp \
        QWEN_SERVER_PORT=18571 \
        "$fixture_scripts/qwen-teardown.sh" \
        >"$teardown_state_directory/teardown.stdout" \
        2>"$teardown_state_directory/teardown.stderr"
    teardown_status=$?
    set -e
}

# The arm reads the broker's own residue lines rather than the exit status,
# because llama-server, the probe, and the tmux session the teardown also proves
# absent are named globally: an appliance serving while the gates run would fail
# an aggregate status for a reason the broker has no part in.
run_teardown_arm clean 0
if grep -q 'approval broker' \
    "$temporary_directory/state-teardown-clean/teardown.stderr"; then
    printf 'teardown reported broker residue against a broker that honours TERM\n' >&2
    cat "$temporary_directory/state-teardown-clean/teardown.stderr" >&2
    exit 1
fi
if kill -0 "$teardown_broker_pid" 2>/dev/null; then
    printf 'teardown left broker pid %s running\n' "$teardown_broker_pid" >&2
    kill -KILL "$teardown_broker_pid" 2>/dev/null || true
    exit 1
fi
if [ -e "$temporary_directory/state-teardown-clean/web-mcp/authorize-session.secret" ]; then
    printf 'teardown left the session secret in place\n' >&2
    exit 1
fi

run_teardown_arm survivor 1
survivor_pid=$teardown_broker_pid
kill -KILL "$survivor_pid" 2>/dev/null || true
wait "$survivor_pid" 2>/dev/null || true
if [ "$teardown_status" -eq 0 ]; then
    printf 'teardown accepted a broker that survived TERM\n' >&2
    exit 1
fi
if ! grep -q 'approval broker still running' \
    "$temporary_directory/state-teardown-survivor/teardown.stderr"; then
    printf 'teardown reported residue without naming the broker\n' >&2
    cat "$temporary_directory/state-teardown-survivor/teardown.stderr" >&2
    exit 1
fi

# A recorded start time that differs from the live one names a reused pid, so
# the teardown leaves that process alone and still proves the secret path.
run_teardown_arm reused 0 1
reused_pid=$teardown_broker_pid
if ! kill -0 "$reused_pid" 2>/dev/null; then
    printf 'teardown signalled a pid whose start time did not match\n' >&2
    exit 1
fi
kill -TERM "$reused_pid" 2>/dev/null || true
wait "$reused_pid" 2>/dev/null || true
if ! grep -q 'now belongs to another process' \
    "$temporary_directory/state-teardown-reused/teardown.stderr"; then
    printf 'teardown did not report the reused pid\n' >&2
    cat "$temporary_directory/state-teardown-reused/teardown.stderr" >&2
    exit 1
fi
if ! grep -q 'session secret survives' \
    "$temporary_directory/state-teardown-reused/teardown.stderr"; then
    printf 'teardown skipped the secret proof after the pid check\n' >&2
    cat "$temporary_directory/state-teardown-reused/teardown.stderr" >&2
    exit 1
fi

# A status file naming the secret path with no broker_pid still proves the
# path absent.
orphan_state_directory=$temporary_directory/state-teardown-orphan
mkdir -p "$orphan_state_directory/web-mcp"
printf 'stale\n' >"$orphan_state_directory/web-mcp/authorize-session.secret"
{
    printf 'state=running server_pid=99999999 monitor_pid=99999999 latency_watchdog_pid=99999999 kernel_hazard_watchdog_pid=99999999 profile=default\n'
    printf 'broker secret_file=%s\n' "$orphan_state_directory/web-mcp/authorize-session.secret"
} >"$orphan_state_directory/session.status"
set +e
QWEN_WEBUI_STATE_DIRECTORY=$orphan_state_directory QWEN_SERVER_PORT=18571 \
    "$fixture_scripts/qwen-teardown.sh" >/dev/null 2>"$orphan_state_directory/teardown.stderr"
orphan_status=$?
set -e
if [ "$orphan_status" -eq 0 ] || \
   ! grep -q 'session secret survives' "$orphan_state_directory/teardown.stderr"; then
    printf 'teardown ignored a surviving secret with no broker_pid recorded\n' >&2
    exit 1
fi

printf 'qwen_session_signals=accepted\n'
