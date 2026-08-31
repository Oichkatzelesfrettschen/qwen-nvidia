#!/bin/sh
set -eu

# Router preflight consumes every model path from one unique preset snapshot.
# The fixture proves malformed sections fail closed and source replacement
# cannot change the snapshot handed to the session.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
detached_session_pid=''
cleanup_fixture() {
    if [ -n "$detached_session_pid" ]; then
        kill -TERM "$detached_session_pid" 2>/dev/null || true
        wait "$detached_session_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup_fixture EXIT INT TERM
fixture_scripts=$temporary_directory/remote
fixture_bin=$temporary_directory/bin
mkdir -p "$fixture_scripts" "$fixture_bin"
cp "$script_directory/qwen-launch.sh" "$fixture_scripts/qwen-launch.sh"
cp "$script_directory/qwen-teardown.sh" "$fixture_scripts/qwen-teardown.sh"
# qwen-launch.sh runs gpu-state-latch.sh require-clear from its own directory
# before anything else, so the fixture carries the latch beside it; a fresh
# state directory holds no recorded failure, so the check admits the launch.
cp "$script_directory/gpu-state-latch.sh" "$fixture_scripts/gpu-state-latch.sh"
# The teardown proves the image lane left no service, runtime, partial
# artifact, or held Vulkan workload lease, and it reads that proof from its own
# directory, so the fixture carries the prover beside it. A fixture without it
# measures a teardown that reports an absent proof rather than a clean stop.
cp "$script_directory/image-teardown-check.sh" \
    "$fixture_scripts/image-teardown-check.sh"

cat >"$fixture_bin/pgrep" <<'PGREP'
#!/bin/sh
exit 1
PGREP
cat >"$fixture_bin/signal-reset-exec.py" <<'PYTHON'
import os
import signal
import sys

for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signal_number, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])
PYTHON
cat >"$fixture_bin/detached-session-worker.py" <<'PYTHON'
import os
import signal
import sys

termination_marker = sys.argv[1]
ready_marker = sys.argv[2]


def terminate_session(_signal_number, _frame):
    with open(termination_marker, "w", encoding="utf-8") as marker:
        marker.write(f"pid={os.getpid()} state=terminated\n")
    raise SystemExit(0)


signal.signal(signal.SIGTERM, terminate_session)
with open(ready_marker, "w", encoding="utf-8"):
    pass
while True:
    signal.pause()
PYTHON

chmod +x "$fixture_scripts"/*.sh "$fixture_bin"/*
state_directory=$temporary_directory/custom-state
source_router_presets=$state_directory/router-presets.ini
mkdir -p "$state_directory"
printf '%s\n' '[broken]' 'LLAMA_ARG_CTX_SIZE = 4096' \
    >"$source_router_presets"
set +e
HOME=$temporary_directory QWEN_ROUTER=1 \
QWEN_MODEL_PATH=$temporary_directory/models/Normal/small.gguf \
QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
PATH="$fixture_bin:$PATH" \
    "$fixture_scripts/qwen-launch.sh" \
    >"$temporary_directory/launch.stdout" \
    2>"$temporary_directory/launch.stderr"
launch_status=$?
set -e

if [ "$launch_status" -eq 0 ]; then
    printf 'launcher accepted a preset section without a model path: %s\n' \
        "$launch_status" >&2
    exit 1
fi
grep -F 'router preflight section broken requires exactly one LLAMA_ARG_MODEL' \
    "$temporary_directory/launch.stderr" >/dev/null
for leftover_snapshot in "$state_directory"/.router-presets.active.*; do
    if [ -e "$leftover_snapshot" ]; then
        printf 'failed preflight retained a router snapshot: %s\n' \
            "$leftover_snapshot" >&2
        exit 1
    fi
done

missing_model=$temporary_directory/models/Missing/large.gguf
printf '%s\n' '[missing]' "LLAMA_ARG_MODEL = $missing_model" \
    >"$source_router_presets"
set +e
HOME=$temporary_directory QWEN_ROUTER=1 \
QWEN_WEBUI_STATE_DIRECTORY=$state_directory PATH="$fixture_bin:$PATH" \
    "$fixture_scripts/qwen-launch.sh" \
    >"$temporary_directory/missing-model.stdout" \
    2>"$temporary_directory/missing-model.stderr"
missing_model_status=$?
set -e
if [ "$missing_model_status" -eq 0 ]; then
    printf 'launcher omitted a missing preset model from preflight\n' >&2
    exit 1
fi
grep -F "router preflight model is not a regular file: $missing_model" \
    "$temporary_directory/missing-model.stderr" >/dev/null

# A durable research marker expands the preflight denominator before the
# launcher selects the largest installed model. The quarantined checkpoint is
# larger than the normal row and therefore becomes the weight-size subject.
cat >"$fixture_scripts/select-projector.sh" <<'PROJECTOR'
#!/bin/sh
exit 0
PROJECTOR
cat >"$fixture_scripts/qwen-webui-control.sh" <<'CONTROL'
#!/bin/sh
if [ "$1" = stop ]; then
    if [ -n "${QWEN_TEST_TMUX_PID_FILE:-}" ]; then
        tmux -L qwen-runtime kill-session -t qwen-webui 2>/dev/null || true
    fi
    exit 0
fi
mkdir -p "$QWEN_WEBUI_STATE_DIRECTORY"
measured_identity=$(sha256sum "$QWEN_ROUTER_PRESETS")
measured_sha256=${measured_identity%% *}
printf 'presets=%s\nexpected_sha256=%s\nmeasured_sha256=%s\n' \
    "$QWEN_ROUTER_PRESETS" "$QWEN_ROUTER_PRESET_SHA256" "$measured_sha256" \
    >"$FIXTURE_CONTROL_LOG"
sed -n '1p' "$QWEN_ROUTER_PRESETS" >>"$FIXTURE_CONTROL_LOG"
printf 'state=running fixture=1\n' >"$QWEN_WEBUI_STATE_DIRECTORY/session.status"
if [ -n "${QWEN_TEST_CONTROL_WAIT_MARKER:-}" ]; then
    tmux -L qwen-runtime new-session -d -s qwen-webui
    : >"$QWEN_TEST_CONTROL_WAIT_MARKER"
    while [ ! -e "$QWEN_TEST_CONTROL_RELEASE" ]; do
        sleep 0.01
    done
fi
exit 0
CONTROL
cat >"$fixture_bin/curl" <<'CURL'
#!/bin/sh
[ -z "${QWEN_TEST_CURL_MARKER:-}" ] || : >"$QWEN_TEST_CURL_MARKER"
exit 0
CURL
cat >"$fixture_bin/tmux" <<'TMUX'
#!/bin/sh
if [ -z "${QWEN_TEST_TMUX_PID_FILE:-}" ]; then
    exit 1
fi
case " $* " in
    *" new-session "*)
        [ -r "$QWEN_TEST_TMUX_CANDIDATE_PID_FILE" ] || exit 1
        candidate_pid=$(sed -n '1p' "$QWEN_TEST_TMUX_CANDIDATE_PID_FILE")
        kill -0 "$candidate_pid" 2>/dev/null || exit 1
        printf '%s\n' "$candidate_pid" >"$QWEN_TEST_TMUX_PID_FILE"
        ;;
    *" kill-session "*)
        if [ -r "$QWEN_TEST_TMUX_PID_FILE" ]; then
            session_pid=$(sed -n '1p' "$QWEN_TEST_TMUX_PID_FILE")
            kill -TERM "$session_pid" 2>/dev/null || true
            session_attempt=0
            while kill -0 "$session_pid" 2>/dev/null && \
                  [ "$session_attempt" -lt 200 ]; do
                session_attempt=$((session_attempt + 1))
                sleep 0.01
            done
            if kill -0 "$session_pid" 2>/dev/null; then
                kill -KILL "$session_pid" 2>/dev/null || true
            fi
            rm -f "$QWEN_TEST_TMUX_PID_FILE"
        fi
        ;;
    *" has-session "*)
        [ -r "$QWEN_TEST_TMUX_PID_FILE" ] || exit 1
        session_pid=$(sed -n '1p' "$QWEN_TEST_TMUX_PID_FILE")
        kill -0 "$session_pid" 2>/dev/null
        ;;
    *) exit 1 ;;
esac
TMUX
cat >"$fixture_bin/ss" <<'SS'
#!/bin/sh
exit 0
SS
cat >"$fixture_bin/stat" <<'STAT'
#!/bin/sh
case ${FIXTURE_STAT_MODE:-success}:$* in
    fail:*Quarantine/large.gguf)
        exit 9
        ;;
esac
if [ ! -e "$FIXTURE_MUTATION_MARKER" ]; then
    printf '%s\n' '# qwen_router_include_quarantine=0' \
        >"$FIXTURE_SOURCE_PRESET"
    : >"$FIXTURE_MUTATION_MARKER"
fi
exec "$FIXTURE_REAL_STAT" "$@"
STAT
chmod +x "$fixture_scripts"/*.sh "$fixture_bin"/*

mkdir -p "$temporary_directory/models/Normal" \
    "$temporary_directory/models/Quarantine"
printf 'x' >"$temporary_directory/models/Normal/small.gguf"
printf 'larger' >"$temporary_directory/models/Quarantine/large.gguf"
printf '%s\n' \
    '# qwen_router_include_quarantine=1' \
    '[normal]' \
    "LLAMA_ARG_MODEL = $temporary_directory/models/Normal/small.gguf" \
    '[quarantine]' \
    "LLAMA_ARG_MODEL = $temporary_directory/models/Quarantine/large.gguf" \
    >"$source_router_presets"
set +e
HOME=$temporary_directory QWEN_ROUTER=1 \
QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
FIXTURE_STAT_MODE=fail FIXTURE_SOURCE_PRESET=$source_router_presets \
FIXTURE_MUTATION_MARKER=$temporary_directory/stat-failure-no-mutation \
FIXTURE_REAL_STAT=$(command -v stat) PATH="$fixture_bin:$PATH" \
    "$fixture_scripts/qwen-launch.sh" \
    >"$temporary_directory/stat-failure.stdout" \
    2>"$temporary_directory/stat-failure.stderr"
stat_failure_status=$?
set -e
if [ "$stat_failure_status" -eq 0 ]; then
    printf 'launcher omitted an unstatable preset model from preflight\n' >&2
    exit 1
fi
grep -F 'router preflight cannot measure model bytes:' \
    "$temporary_directory/stat-failure.stderr" >/dev/null

# Restore the source preset after the stat fixture exercises its mutation hook.
printf '%s\n' \
    '# qwen_router_include_quarantine=1' \
    '[normal]' \
    "LLAMA_ARG_MODEL = $temporary_directory/models/Normal/small.gguf" \
    '[quarantine]' \
    "LLAMA_ARG_MODEL = $temporary_directory/models/Quarantine/large.gguf" \
    >"$source_router_presets"
HOME=$temporary_directory QWEN_ROUTER=1 \
QWEN_MODEL_PATH=$temporary_directory/models/Normal/small.gguf \
QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
FIXTURE_SOURCE_PRESET=$source_router_presets \
FIXTURE_MUTATION_MARKER=$temporary_directory/source-mutated \
FIXTURE_REAL_STAT=$(command -v stat) \
FIXTURE_CONTROL_LOG=$temporary_directory/control.log \
PATH="$fixture_bin:$PATH" \
    "$fixture_scripts/qwen-launch.sh" \
    >"$temporary_directory/override-launch.stdout" \
    2>"$temporary_directory/override-launch.stderr"
grep -Fx 'router_preflight_subject=large.gguf bytes=6' \
    "$temporary_directory/override-launch.stdout" >/dev/null
preset_snapshot=$(sed -n 's/^presets=//p' \
    "$temporary_directory/control.log")
case $preset_snapshot in
    "$state_directory"/.router-presets.active.*) ;;
    *)
        printf 'control received a non-unique preset snapshot: %s\n' \
            "$preset_snapshot" >&2
        exit 1
        ;;
esac
expected_sha256=$(sed -n 's/^expected_sha256=//p' \
    "$temporary_directory/control.log")
measured_sha256=$(sed -n 's/^measured_sha256=//p' \
    "$temporary_directory/control.log")
[ "$expected_sha256" = "$measured_sha256" ]
grep -Fx '# qwen_router_include_quarantine=1' \
    "$temporary_directory/control.log" >/dev/null
grep -Fx '[quarantine]' "$preset_snapshot" >/dev/null
grep -Fx '# qwen_router_include_quarantine=0' \
    "$source_router_presets" >/dev/null

# A terminating signal transfers control to a handler that removes the owned
# snapshot and exits with the signal status before readiness polling begins.
printf '%s\n' \
    '# qwen_router_include_quarantine=0' \
    '[normal]' \
    "LLAMA_ARG_MODEL = $temporary_directory/models/Normal/small.gguf" \
    >"$source_router_presets"
cancellation_mutation_marker=$temporary_directory/cancellation-no-mutation
: >"$cancellation_mutation_marker"
for cancellation_signal_and_status in HUP:129 INT:130 TERM:143; do
    cancellation_signal=${cancellation_signal_and_status%%:*}
    cancellation_expected_status=${cancellation_signal_and_status#*:}
    cancellation_control_log=$temporary_directory/cancellation-$cancellation_signal-control.log
    cancellation_wait_marker=$temporary_directory/cancellation-$cancellation_signal-waiting
    cancellation_release=$temporary_directory/cancellation-$cancellation_signal-release
    cancellation_curl_marker=$temporary_directory/cancellation-$cancellation_signal-curl-ran
    detached_session_pid_file=$temporary_directory/detached-session.pid
    detached_session_candidate_pid_file=$temporary_directory/detached-session-candidate.pid
    detached_session_ready_marker=$temporary_directory/detached-session-ready
    detached_session_termination_marker=$temporary_directory/detached-session-terminated
    rm -f "$detached_session_candidate_pid_file" \
        "$detached_session_ready_marker" "$detached_session_termination_marker"
    python3 "$fixture_bin/detached-session-worker.py" \
        "$detached_session_termination_marker" \
        "$detached_session_ready_marker" &
    detached_session_pid=$!
    printf '%s\n' "$detached_session_pid" \
        >"$detached_session_candidate_pid_file"
    detached_session_ready_attempt=0
    while [ ! -e "$detached_session_ready_marker" ] && \
          [ "$detached_session_ready_attempt" -lt 100 ]; do
        detached_session_ready_attempt=$((detached_session_ready_attempt + 1))
        sleep 0.01
    done
    if [ ! -e "$detached_session_ready_marker" ]; then
        printf 'detached session worker did not reach its ready boundary\n' >&2
        exit 1
    fi
    HOME=$temporary_directory QWEN_ROUTER=1 \
        QWEN_MODEL_PATH=$temporary_directory/models/Normal/small.gguf \
        QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
        QWEN_TEST_CONTROL_WAIT_MARKER=$cancellation_wait_marker \
        QWEN_TEST_CONTROL_RELEASE=$cancellation_release \
        QWEN_TEST_CURL_MARKER=$cancellation_curl_marker \
        QWEN_TEST_TMUX_PID_FILE=$detached_session_pid_file \
        QWEN_TEST_TMUX_CANDIDATE_PID_FILE=$detached_session_candidate_pid_file \
        FIXTURE_SOURCE_PRESET=$source_router_presets \
        FIXTURE_MUTATION_MARKER=$cancellation_mutation_marker \
        FIXTURE_REAL_STAT=$(command -v stat) \
        FIXTURE_CONTROL_LOG=$cancellation_control_log \
        PATH="$fixture_bin:$PATH" \
        python3 "$fixture_bin/signal-reset-exec.py" \
            "$fixture_scripts/qwen-launch.sh" \
      >"$temporary_directory/cancellation-$cancellation_signal.stdout" \
      2>"$temporary_directory/cancellation-$cancellation_signal.stderr" &
    cancellation_pid=$!
    cancellation_attempt=0
    while [ ! -e "$cancellation_wait_marker" ] && \
          [ "$cancellation_attempt" -lt 100 ]; do
        cancellation_attempt=$((cancellation_attempt + 1))
        sleep 0.01
    done
    if [ ! -e "$cancellation_wait_marker" ]; then
        : >"$cancellation_release"
        kill -TERM "$cancellation_pid" 2>/dev/null || true
        wait "$cancellation_pid" 2>/dev/null || true
        printf 'launcher did not reach the %s cancellation boundary\n' \
            "$cancellation_signal" >&2
        exit 1
    fi
    promoted_detached_session_pid=$(sed -n '1p' "$detached_session_pid_file")
    if [ "$promoted_detached_session_pid" -ne "$detached_session_pid" ]; then
        printf '%s cancellation promoted detached session pid %s instead of %s\n' \
            "$cancellation_signal" "$promoted_detached_session_pid" \
            "$detached_session_pid" >&2
        exit 1
    fi
    kill -"$cancellation_signal" "$cancellation_pid"
    : >"$cancellation_release"
    set +e
    wait "$cancellation_pid"
    cancellation_status=$?
    set -e
    if [ "$cancellation_status" -ne "$cancellation_expected_status" ]; then
        printf '%s launcher cancellation returned %s instead of %s\n' \
            "$cancellation_signal" "$cancellation_status" \
            "$cancellation_expected_status" >&2
        exit 1
    fi
    cancellation_snapshot=$(sed -n 's/^presets=//p' "$cancellation_control_log")
    if [ -e "$cancellation_snapshot" ] || [ -L "$cancellation_snapshot" ]; then
        printf '%s cancellation retained its router snapshot: %s\n' \
            "$cancellation_signal" "$cancellation_snapshot" >&2
        exit 1
    fi
    if [ -e "$detached_session_pid_file" ]; then
        printf '%s cancellation retained its detached session\n' \
            "$cancellation_signal" >&2
        exit 1
    fi
    detached_session_termination_attempt=0
    while [ ! -e "$detached_session_termination_marker" ] && \
          [ "$detached_session_termination_attempt" -lt 100 ]; do
        detached_session_termination_attempt=$((detached_session_termination_attempt + 1))
        sleep 0.01
    done
    if [ ! -e "$detached_session_termination_marker" ]; then
        printf '%s cancellation did not terminate detached session pid %s\n' \
            "$cancellation_signal" "$detached_session_pid" >&2
        exit 1
    fi
    set +e
    wait "$detached_session_pid"
    detached_session_status=$?
    reaped_detached_session_pid=$detached_session_pid
    detached_session_pid=''
    set -e
    if [ "$detached_session_status" -ne 0 ]; then
        printf '%s detached session returned status %s\n' \
            "$cancellation_signal" "$detached_session_status" >&2
        exit 1
    fi
    grep -Fx "pid=$reaped_detached_session_pid state=terminated" \
        "$detached_session_termination_marker" >/dev/null
    if [ -e "$cancellation_curl_marker" ]; then
        printf '%s cancellation entered readiness polling\n' \
            "$cancellation_signal" >&2
        exit 1
    fi
done

dangling_snapshot=$state_directory/.router-presets.active.dangling
ln -s "$state_directory/absent-snapshot-target" "$dangling_snapshot"
HOME=$temporary_directory QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
PATH="$fixture_bin:$PATH" \
    "$fixture_scripts/qwen-teardown.sh" \
    >"$temporary_directory/teardown.stdout" \
    2>"$temporary_directory/teardown.stderr"
if [ -e "$preset_snapshot" ]; then
    printf 'forced teardown retained router snapshot: %s\n' \
        "$preset_snapshot" >&2
    exit 1
fi
if [ -L "$dangling_snapshot" ]; then
    printf 'forced teardown retained dangling router snapshot: %s\n' \
        "$dangling_snapshot" >&2
    exit 1
fi
printf 'qwen_launch_router_preflight=accepted\n'
