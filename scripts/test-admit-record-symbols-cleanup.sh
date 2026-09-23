#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
work_directory=$(mktemp -d "$repository_root/.local-artifacts/admit-record-symbols-cleanup.XXXXXX")
fixture_socket=record-symbols-fixture-$$
cleanup() {
    tmux -L "$fixture_socket" kill-session -t qwen-webui 2>/dev/null || true
    rm -rf -- "$work_directory"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$work_directory/scripts" "$work_directory/source" "$work_directory/output"
sed "s/qwen-runtime/$fixture_socket/g" "$script_directory/admit-record-symbols.sh" \
    >"$work_directory/scripts/admit-record-symbols.sh"
chmod +x "$work_directory/scripts/admit-record-symbols.sh"
printf '%s\n' 'int fixture(void) { return 1; }' >"$work_directory/source/fixture.c"
printf '%s\n' '{}' >"$work_directory/graph.json"

cat >"$work_directory/scripts/model-registry.sh" <<'MODEL'
#!/bin/sh
printf '%s\n' 'model_file=fixture.gguf'
MODEL
cat >"$work_directory/scripts/record-symbols-contract.py" <<'CONTRACT'
import pathlib
import sys

operation = sys.argv[1]
if operation == "targets":
    pathlib.Path(sys.argv[4]).write_text("fixture\n")
    print("1")
elif operation == "request":
    pathlib.Path(sys.argv[5]).write_text("{}\n")
elif operation == "columns":
    print("model\tfile\toutcome")
CONTRACT
cat >"$work_directory/scripts/qwen-launch.sh" <<'LAUNCH'
#!/bin/sh
set -eu
if tmux -L "$TEST_TMUX_SOCKET" has-session -t qwen-webui 2>/dev/null; then
    exit 2
fi
tmux -L "$TEST_TMUX_SOCKET" new-session -d -s qwen-webui \
    -e "QWEN_LAUNCH_ATTEMPT_NONCE=$QWEN_LAUNCH_ATTEMPT_NONCE" 'sleep 120'
printf 'started attempt=%s\n' "$QWEN_LAUNCH_ATTEMPT_NONCE"
sleep 120
LAUNCH
cat >"$work_directory/scripts/qwen-teardown.sh" <<'TEARDOWN'
#!/bin/sh
set -eu
printf '%s\n' stopped >>"$TEST_TEARDOWN_LOG"
tmux -L "$TEST_TMUX_SOCKET" kill-session -t qwen-webui
TEARDOWN
chmod +x "$work_directory/scripts/model-registry.sh" \
    "$work_directory/scripts/qwen-launch.sh" "$work_directory/scripts/qwen-teardown.sh"

export PYTHON=${PYTHON:?Select the intended Python interpreter}
export TEST_TMUX_SOCKET=$fixture_socket
export TEST_TEARDOWN_LOG=$work_directory/teardown.log
export QWEN_SYMBOLS_SOURCE=$work_directory/source
export QWEN_SYMBOLS_GRAPH=$work_directory/graph.json
export QWEN_SYMBOLS_FILES=fixture.c
export QWEN_SYMBOLS_IDS=fixture

setsid "$work_directory/scripts/admit-record-symbols.sh" "$work_directory/output" \
    >"$work_directory/campaign.log" 2>&1 &
campaign_pid=$!
attempt=0
while ! tmux -L "$fixture_socket" has-session -t qwen-webui 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
        printf 'attempt session was not created\n' >&2
        exit 1
    fi
    sleep 0.1
done
kill -TERM "$campaign_pid"
wait "$campaign_pid" 2>/dev/null || true
if tmux -L "$fixture_socket" has-session -t qwen-webui 2>/dev/null \
    || [ "$(wc -l <"$TEST_TEARDOWN_LOG")" -ne 1 ]; then
    printf 'attempt-owned session survived campaign interruption\n' >&2
    exit 1
fi

tmux -L "$fixture_socket" new-session -d -s qwen-webui \
    -e QWEN_LAUNCH_ATTEMPT_NONCE=preexisting 'sleep 120'
if "$work_directory/scripts/admit-record-symbols.sh" "$work_directory/output" \
    >"$work_directory/preexisting.log" 2>&1; then
    printf 'campaign unexpectedly admitted a pre-existing session\n' >&2
    exit 1
fi
if ! tmux -L "$fixture_socket" has-session -t qwen-webui 2>/dev/null \
    || [ "$(wc -l <"$TEST_TEARDOWN_LOG")" -ne 1 ]; then
    printf 'campaign retired a pre-existing session\n' >&2
    exit 1
fi
printf 'attempt_owned_session_retired=pass preexisting_session_preserved=pass\n'
