#!/bin/sh
set -eu

# Admit scripts/graft-consumer-env.sh without the appliance: a fixture answers
# the tool-call probe the way llama-server does with and without --jinja, so
# the checks read the refusal a prose answer earns, the refusal a missing or
# world-readable key file earns, and the emitted environment on the passing
# arm, whose key line reads the file rather than carrying the secret.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
consumer=$script_directory/graft-consumer-env.sh
fixture=$script_directory/test-fixtures/fake-chat-tools-server.py
work_directory=$(mktemp -d "${TMPDIR:-/tmp}/graft-consumer-env.XXXXXX")
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    rm -rf "$work_directory"
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

state_directory=$work_directory/state
mkdir -p "$state_directory"
printf 'test-key-0123456789abcdef\n' >"$state_directory/api.key"
chmod 600 "$state_directory/api.key"
port=$(python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

start_fixture() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait 2>/dev/null || true; fi
    PYTHONDONTWRITEBYTECODE=1 python3 "$fixture" "$port" "$(cat "$state_directory/api.key")" "$1" &
    server_pid=$!
    attempt=0
    until curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 50 ] || { printf 'fixture never answered\n' >&2; exit 1; }
        sleep 0.1
    done
}

run_consumer() {
    QWEN_SERVER_PORT=$port QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
        "$consumer" >"$work_directory/stdout" 2>"$work_directory/stderr" \
        && printf 0 || printf '%s' "$?"
}

# A prose answer to the forced tool call is refused by name.
start_fixture prose
status=$(run_consumer)
if [ "$status" = 1 ] && grep -q 'QWEN_CHAT_TOOLS=on' "$work_directory/stderr"; then
    check prose_answer_refused pass
else
    check prose_answer_refused fail "status=$status stderr=$(cat "$work_directory/stderr")"
fi

# A tool_calls answer passes and the emitted environment is complete.
start_fixture jinja
status=$(run_consumer)
if [ "$status" = 0 ] \
    && grep -q '^export GRAFT_PROVIDER=openai$' "$work_directory/stdout" \
    && grep -q "^export GRAFT_BASE_URL=http://127.0.0.1:$port/v1\$" "$work_directory/stdout" \
    && grep -q '^export GRAFT_MODEL=qwen-nvidia$' "$work_directory/stdout"; then
    check environment_emitted pass
else
    check environment_emitted fail "status=$status stdout=$(cat "$work_directory/stdout")"
fi

# The key line reads the file; the secret itself appears nowhere in the output.
if grep -q "^export GRAFT_API_KEY=\$(cat '$state_directory/api.key')\$" "$work_directory/stdout" \
    && ! grep -q 'test-key-0123456789abcdef' "$work_directory/stdout"; then
    check key_read_at_eval pass
else
    check key_read_at_eval fail "stdout=$(cat "$work_directory/stdout")"
fi

# Evaluating the output places the key in the environment.
key_seen=$(sh -c "$(cat "$work_directory/stdout"); printf '%s' \"\$GRAFT_API_KEY\"")
if [ "$key_seen" = test-key-0123456789abcdef ]; then
    check key_in_environment pass
else
    check key_in_environment fail "seen=$key_seen"
fi

# A world-readable key file is refused before any request.
chmod 644 "$state_directory/api.key"
status=$(run_consumer)
if [ "$status" = 1 ] && grep -q 'required 0400 or 0600' "$work_directory/stderr"; then
    check key_mode_refused pass
else
    check key_mode_refused fail "status=$status"
fi
chmod 600 "$state_directory/api.key"

# An absent key file names the launch as the missing step.
rm "$state_directory/api.key"
status=$(run_consumer)
if [ "$status" = 1 ] && grep -q 'launch the appliance first' "$work_directory/stderr"; then
    check key_absent_refused pass
else
    check key_absent_refused fail "status=$status"
fi

printf 'checks_total=%s checks_failed=%s\n' "$checks_total" "$checks_failed"
[ "$checks_failed" -eq 0 ]
