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
: "${PYTHON:?Set PYTHON to the intended Python executable}"

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
port=$("$PYTHON" -c 'import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])')

start_fixture() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait 2>/dev/null || true; fi
    PYTHONDONTWRITEBYTECODE=1 "$PYTHON" "$fixture" "$port" "$state_directory/api.key" "$1" &
    server_pid=$!
    attempt=0
    until curl --user-agent 'Mozilla/5.0' --silent --fail --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
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

# The legacy server honors required while downgrading a named object to auto.
# Calibrate that fixture's passing string arm before its object refusal.
start_fixture string_only
printf 'Authorization: Bearer %s\n' "$(cat "$state_directory/api.key")" >"$work_directory/header"
chmod 600 "$work_directory/header"
curl --user-agent 'Mozilla/5.0' --silent --fail --max-time 5 \
    --header "@$work_directory/header" --header 'Content-Type: application/json' \
    --data '{"model":"qwen-nvidia","tools":[{"type":"function","function":{"name":"record_probe"}}],"tool_choice":"required"}' \
    "http://127.0.0.1:$port/v1/chat/completions" >"$work_directory/string-answer"
if jq -e '.choices[0].message.tool_calls[0].function.name == "record_probe"' \
    "$work_directory/string-answer" >/dev/null; then
    check string_only_required_control pass
else
    check string_only_required_control fail
fi
status=$(run_consumer)
if [ "$status" = 1 ] && grep -q 'without tool_calls' "$work_directory/stderr" \
    && [ ! -s "$work_directory/stdout" ]; then
    check named_choice_downgrade_refused pass
else
    check named_choice_downgrade_refused fail "status=$status"
fi

# Every answer that is not one completed record_probe(ok=true) is refused,
# and the refusal names the shape it had rather than the absence of the field.
for shape in wrong_function:function_record_graph empty_calls:tool_calls_0 \
    bad_arguments:arguments_unparsed ok_false:arguments_ok_false \
    truncated:raise\ QWEN_PROBE_MAX_TOKENS http_error:HTTP\ 500 \
    quoted_field:without\ tool_calls; do
    mode=${shape%%:*}
    expected=${shape#*:}
    start_fixture "$mode"
    status=$(run_consumer)
    if [ "$status" = 1 ] && grep -q "$expected" "$work_directory/stderr" \
        && [ ! -s "$work_directory/stdout" ]; then
        check "${mode}_refused" pass
    else
        check "${mode}_refused" fail "status=$status stderr=$(cat "$work_directory/stderr")"
    fi
done

# A tool_calls answer passes and the emitted environment is complete.
start_fixture jinja
status=$(run_consumer)
if [ "$status" = 0 ] \
    && grep -q '^export GRAFT_PROVIDER=openai$' "$work_directory/stdout" \
    && grep -q "^export GRAFT_BASE_URL='http://127.0.0.1:$port/v1'\$" "$work_directory/stdout" \
    && grep -q "^export GRAFT_MODEL='qwen-nvidia'\$" "$work_directory/stdout"; then
    check environment_emitted pass
else
    check environment_emitted fail "status=$status stdout=$(cat "$work_directory/stdout")"
fi
cp "$work_directory/stdout" "$work_directory/environment"

# JSON and shell exports preserve quotes and shell metacharacters literally.
ordinary_state_directory=$state_directory
state_directory="$work_directory/state 'quoted' \$(touch injected-state)"
mkdir -p "$state_directory"
cp "$ordinary_state_directory/api.key" "$state_directory/api.key"
# Shell metacharacters are literal alias bytes for the export round trip.
# shellcheck disable=SC2089
QWEN_GRAFT_MODEL="alias \"quoted\" 'single' \$(touch injected-model); \`touch injected-backtick\`"
FIXTURE_EXPECTED_MODEL=$QWEN_GRAFT_MODEL
# shellcheck disable=SC2090
export QWEN_GRAFT_MODEL FIXTURE_EXPECTED_MODEL
start_fixture jinja
status=$(run_consumer)
if [ "$status" = 0 ] && (
    cd "$work_directory"
    eval "$(cat "$work_directory/stdout")"
    [ "$GRAFT_MODEL" = "$QWEN_GRAFT_MODEL" ] \
        && [ "$GRAFT_API_KEY" = test-key-0123456789abcdef ] \
        && [ "$GRAFT_BASE_URL" = "http://127.0.0.1:$port/v1" ] \
        && [ ! -e injected-state ] && [ ! -e injected-model ] && [ ! -e injected-backtick ]
); then
    check quoted_environment_roundtrip pass
else
    check quoted_environment_roundtrip fail "status=$status"
fi
state_directory=$ordinary_state_directory
unset QWEN_GRAFT_MODEL FIXTURE_EXPECTED_MODEL

# Validate configuration before contacting the fixture or emitting exports.
for invalid_port in 0 00 08080 -1 invalid 65536 999999999999999999999; do
    status=$(QWEN_SERVER_PORT=$invalid_port QWEN_WEBUI_STATE_DIRECTORY=$state_directory \
        "$consumer" >"$work_directory/stdout" 2>"$work_directory/stderr" \
        && printf 0 || printf '%s' "$?")
    if [ "$status" = 2 ] && grep -q 'QWEN_SERVER_PORT' "$work_directory/stderr" \
        && [ ! -s "$work_directory/stdout" ]; then
        check "port_${invalid_port}_refused" pass
    else
        check "port_${invalid_port}_refused" fail "status=$status"
    fi
done
for invalid_tokens in 0 00 0128 -1 invalid 1.5; do
    status=$(QWEN_PROBE_MAX_TOKENS=$invalid_tokens run_consumer)
    if [ "$status" = 2 ] && grep -q 'QWEN_PROBE_MAX_TOKENS' "$work_directory/stderr" \
        && [ ! -s "$work_directory/stdout" ]; then
        check "tokens_${invalid_tokens}_refused" pass
    else
        check "tokens_${invalid_tokens}_refused" fail "status=$status"
    fi
done

# The key line reads the file; the secret itself appears nowhere in the output.
if grep -q "^export GRAFT_API_KEY=\$(cat '$state_directory/api.key')\$" "$work_directory/environment" \
    && ! grep -q 'test-key-0123456789abcdef' "$work_directory/environment"; then
    check key_read_at_eval pass
else
    check key_read_at_eval fail "stdout=$(cat "$work_directory/environment")"
fi

# Evaluating the output places the key in the environment.
key_seen=$(sh -c "$(cat "$work_directory/environment"); printf '%s' \"\$GRAFT_API_KEY\"")
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
