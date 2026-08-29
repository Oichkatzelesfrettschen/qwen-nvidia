#!/bin/sh
set -eu

# Drive the request shape the fallback Web UI sends through the whole approval
# path: `authorize-broker.py` signs a grant over the approved fields, the exact
# `{tool, params}` body the page builds reaches the tool routes, and `server.py`
# under the fake provider verifies the grant and spends it in its ledger. The
# executor stands in for llama-server through
# `remote/test-fixtures/fake-llama-tools-server.py`, which speaks the same two
# routes over one MCP child, so the run needs the appliance for nothing.
#
# The decisive pair is one search and its replay. The first spends the grant
# under its `grant_id` primary key and returns the rendered results; the second
# presents the same token and comes back as an HTTP 200 carrying an `error`
# key, which is the shape `mcp_result_to_response` gives an MCP `isError`
# result and the shape the page reads before it reads a status.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

for required_command in python3 curl; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        printf 'required command is absent: %s\n' "$required_command" >&2
        exit 2
    fi
done

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
broker_script=$script_directory/web-mcp/authorize-broker.py
mcp_server=$script_directory/web-mcp/server.py
tools_fixture=$script_directory/test-fixtures/fake-llama-tools-server.py
workspace=$(mktemp -d)
broker_pid=
tools_pid=

cleanup() {
    if [ -n "$broker_pid" ]; then kill "$broker_pid" 2>/dev/null || true; fi
    if [ -n "$tools_pid" ]; then kill "$tools_pid" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    rm -rf "$workspace"
}
trap cleanup EXIT INT TERM

state_directory=$workspace/state
mkdir -p "$state_directory"
chmod 700 "$state_directory"
token_key_file=$workspace/token.key
printf 'roundtrip-token-secret-8XQ2ZK\n' > "$token_key_file"
chmod 600 "$token_key_file"
api_key_file=$workspace/api.key
printf 'roundtrip-web-ui-key-4V8Q2N\n' >"$api_key_file"
chmod 600 "$api_key_file"
fixture_file=$workspace/fixtures.json
cat > "$fixture_file" <<'FIXTURES'
{
  "search": {
    "raven2 vulkan decode": [
      {
        "title": "Vulkan decode on Raven2",
        "url": "https://example.org/raven2",
        "publishedDate": "2026-01-05",
        "author": "A. Measurer",
        "highlights": ["decode reaches 3.07 tok/s"]
      }
    ]
  },
  "contents": {
    "https://example.org/raven2": {"text": "measured decode", "status": "ok"}
  }
}
FIXTURES

# The broker and the wrapper agree on provider, profile, signing key, and state
# directory. `enforce_search_authorization` refuses a claim naming another
# provider or profile, and the one SQLite ledger under the shared state
# directory is what spends the grant_id, so a divergence here would refuse the
# replay for a reason the test is not measuring.
browser_origin=http://127.0.0.1:8080
PYTHONDONTWRITEBYTECODE=1 python3 "$broker_script" \
    --host 127.0.0.1 --port 0 \
    --state-dir "$state_directory" \
    --token-key-file "$token_key_file" \
    --api-key-file "$api_key_file" \
    --provider fake --profile default \
    --origin "$browser_origin" > "$workspace/broker.out" 2>"$workspace/broker.err" &
broker_pid=$!

QWEN_WEB_PROVIDER=fake \
QWEN_WEB_FAKE_FIXTURES="$fixture_file" \
QWEN_WEB_TOKEN_KEY_FILE="$token_key_file" \
QWEN_WEB_STATE_DIR="$state_directory" \
QWEN_WEB_SEARCH_AUTH=required \
QWEN_WEB_PROFILE=default \
PYTHONDONTWRITEBYTECODE=1 python3 "$tools_fixture" 0 "$mcp_server" \
    > "$workspace/tools.out" 2>"$workspace/tools.err" &
tools_pid=$!

read_listening_port() {
    listening_file=$1
    attempt=0
    # The complete line rather than the first byte ends the wait: a partially
    # flushed file would otherwise yield an empty port and send the next
    # request to a hostless URL.
    while [ "$attempt" -lt 100 ]; do
        listening_port=$(awk '/^listening / { print $3; exit }' "$listening_file" \
            2>/dev/null || true)
        if [ -n "$listening_port" ]; then
            printf '%s\n' "$listening_port"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    printf 'no listening line reached %s\n' "$listening_file" >&2
    return 1
}

broker_port=$(read_listening_port "$workspace/broker.out")
tools_port=$(read_listening_port "$workspace/tools.out")

# The page reads the per-launch secret through the broker's own endpoint. The
# existing Web UI API key is the bearer capability for the /session read. An
# Origin alone receives nothing; llama-server and the broker validate the same
# key bytes.
session_secret_file=$state_directory/authorize-session.secret
attempt=0
while [ ! -s "$session_secret_file" ] && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ ! -s "$session_secret_file" ]; then
    printf 'the broker wrote no session secret file\n' >&2
    exit 1
fi
unauthorized_session_status=$(curl -sS -o "$workspace/session-unauthorized.json" \
    -w '%{http_code}' "http://127.0.0.1:$broker_port/session" \
    -H "Origin: $browser_origin")
if [ "$unauthorized_session_status" != 403 ]; then
    printf 'the session endpoint admitted a request without the Web UI API key: %s\n' \
        "$(cat "$workspace/session-unauthorized.json")" >&2
    exit 1
fi
curl -sS "http://127.0.0.1:$broker_port/session" \
    -H "Origin: $browser_origin" \
    -H "Authorization: Bearer $(sed -n '1p' "$api_key_file")" \
    >"$workspace/session.json"
session_secret=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["session_secret"])' \
    "$workspace/session.json")
if [ "$session_secret" != "$(cat "$session_secret_file")" ]; then
    printf 'the authenticated session endpoint returned another launch authority\n' >&2
    exit 1
fi

# The listing composes the tool names the page filters on.
curl -sS "http://127.0.0.1:$tools_port/tools" > "$workspace/listing.json"
grep -F '"tool": "web_search_exa"' "$workspace/listing.json" >/dev/null
grep -F '"tool": "web_fetch_exa"' "$workspace/listing.json" >/dev/null

# The approval dialog posts the parsed proposal; the broker signs the grant.
# `profile_id` is `requestModel`, the alias `GET /v1/models` reports for the
# selected router child, and `remote/build-web-presets.sh` sets that alias
# from the profile's own row (`LLAMA_ARG_ALIAS`), so the browser sends the
# same name the broker and the MCP child were both launched with.
cat > "$workspace/grant-request.json" <<'GRANT'
{"query": "raven2 vulkan decode", "max_results": 1,
 "include_domains": [], "exclude_domains": [], "profile_id": "default"}
GRANT

# A request naming another profile is refused before a token is signed: the
# broker's `--profile` is the name `enforce_search_authorization` on the MCP
# child compares a spent grant against, and a page that sent the wrong
# selected model's alias must fail here rather than mint a grant the child
# would refuse anyway.
cat > "$workspace/grant-request-wrong-profile.json" <<'GRANT'
{"query": "raven2 vulkan decode", "max_results": 1,
 "include_domains": [], "exclude_domains": [], "profile_id": "vision"}
GRANT
wrong_profile_status=$(curl -sS -o "$workspace/grant-wrong-profile.json" \
    -w '%{http_code}' -X POST "http://127.0.0.1:$broker_port/grant" \
    -H 'Content-Type: application/json' \
    -H "Origin: $browser_origin" \
    -H "X-Qwen-Web-Session: $session_secret" \
    --data-binary "@$workspace/grant-request-wrong-profile.json")
if [ "$wrong_profile_status" != "400" ]; then
    printf 'a grant request naming another profile returned HTTP %s rather than 400: %s\n' \
        "$wrong_profile_status" "$(cat "$workspace/grant-wrong-profile.json")" >&2
    exit 1
fi
if grep -F 'authorization' "$workspace/grant-wrong-profile.json" >/dev/null; then
    printf 'a grant request naming another profile issued a token: %s\n' \
        "$(cat "$workspace/grant-wrong-profile.json")" >&2
    exit 1
fi

# A request naming no profile at all is refused the same way, before the
# rest of the body is even validated for shape.
cat > "$workspace/grant-request-no-profile.json" <<'GRANT'
{"query": "raven2 vulkan decode", "max_results": 1,
 "include_domains": [], "exclude_domains": []}
GRANT
no_profile_status=$(curl -sS -o "$workspace/grant-no-profile.json" \
    -w '%{http_code}' -X POST "http://127.0.0.1:$broker_port/grant" \
    -H 'Content-Type: application/json' \
    -H "Origin: $browser_origin" \
    -H "X-Qwen-Web-Session: $session_secret" \
    --data-binary "@$workspace/grant-request-no-profile.json")
if [ "$no_profile_status" != "400" ]; then
    printf 'a grant request naming no profile returned HTTP %s rather than 400: %s\n' \
        "$no_profile_status" "$(cat "$workspace/grant-no-profile.json")" >&2
    exit 1
fi
curl -sS -X POST "http://127.0.0.1:$broker_port/grant" \
    -H 'Content-Type: application/json' \
    -H "Origin: $browser_origin" \
    -H "X-Qwen-Web-Session: $session_secret" \
    --data-binary "@$workspace/grant-request.json" > "$workspace/grant.json"
authorization=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["authorization"])' \
    "$workspace/grant.json")
if [ -z "$authorization" ]; then
    printf 'the broker issued no grant: %s\n' "$(cat "$workspace/grant.json")" >&2
    exit 1
fi

# This is the body `searchRequestParams` builds: the approved fields with both
# domain lists present, the explicit result count, the grant inside `params`,
# and the empty publication dates and absent max_age_hours omitted so the
# wrapper reads the same defaults the claim was signed over.
python3 -c 'import json,sys
authorization = sys.argv[1]
body = {"tool": "web_search_exa",
        "params": {"query": "raven2 vulkan decode", "max_results": 1,
                   "include_domains": [], "exclude_domains": [],
                   "authorization": authorization}}
open(sys.argv[2], "w").write(json.dumps(body))' \
    "$authorization" "$workspace/call.json"

post_tool_call() {
    # One argument: the file the response body lands in.
    curl -sS -o "$1" -w '%{http_code}' \
        -X POST "http://127.0.0.1:$tools_port/tools" \
        -H 'Content-Type: application/json' \
        --data-binary "@$workspace/call.json"
}

first_status=$(post_tool_call "$workspace/first.json")
if [ "$first_status" != "200" ]; then
    printf 'the first search returned HTTP %s: %s\n' \
        "$first_status" "$(cat "$workspace/first.json")" >&2
    exit 1
fi
if ! grep -F 'plain_text_response' "$workspace/first.json" >/dev/null; then
    printf 'the first search carried no result text: %s\n' \
        "$(cat "$workspace/first.json")" >&2
    exit 1
fi
grep -F 'https://example.org/raven2' "$workspace/first.json" >/dev/null

# The replay presents the spent grant. The ledger refuses it under its
# grant_id primary key, and the refusal reaches the page as an `error` key at
# HTTP 200 rather than as a failing status.
replay_status=$(post_tool_call "$workspace/replay.json")
if [ "$replay_status" != "200" ]; then
    printf 'the replay returned HTTP %s rather than a 200 refusal body\n' \
        "$replay_status" >&2
    exit 1
fi
if grep -F 'plain_text_response' "$workspace/replay.json" >/dev/null; then
    printf 'the replay ran a second search on one grant: %s\n' \
        "$(cat "$workspace/replay.json")" >&2
    exit 1
fi
python3 -c 'import json,sys
payload = json.load(open(sys.argv[1]))
message = payload.get("error", "")
if "spent" not in message:
    raise SystemExit("the replay refusal names another reason: " + repr(payload))' \
    "$workspace/replay.json"

printf 'web_tools_roundtrip=accepted\n'
