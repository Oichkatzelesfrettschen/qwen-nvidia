#!/bin/sh
set -eu

# Admit the web router on the appliance against the fake provider: the
# production llama-server, a real router child, the approval broker, and the
# MCP child all run, and nothing reaches a network. The harness owns one
# outage: it records the ordinary router, tears it down, launches one
# validator-gated test profile from a ledger it writes itself, drives every
# boundary of the merged web path over HTTP, tears the test router down,
# proves absence, and restores the ordinary router. The checked-in ledger
# stays at execution_policy=refused throughout; the test ledger lives under
# OUTPUT_DIR and names one profile.
#
# The run exercises what the browser page does, in the order the page does
# it, with curl in the page's place and every tool request on the router port:
# GET /tools?model= composes the tool list, the broker's /session and /grant
# sign one exact-argument grant, POST /tools with the top-level model key
# spends it, a Result ID from the search reply is redeemed by fetch, and the
# refusals the design relies on are each provoked once -- a replayed grant, a
# fetch past the profile's allowance, a fetch naming a URL rather than a Result
# ID, a grant request from a foreign Origin, a wrong session header, a wrong
# profile_id, a tool request naming no model or an unknown one, and a routing
# key placed inside the tool arguments. Two fixture queries hold the fake
# provider for 5 and 40 seconds, so the run observes that a slow call completes
# through the router and that the child's per-call MCP deadline answers a
# stalled one before the router's proxy read timeout. A chat completion then
# offers the model the composed tools and the search result, so the
# continuation the page performs is observed against the served model rather
# than assumed. The child's internal port is read once as a diagnostic control
# and no admission check runs against it.
#
# Every check lands in OUTPUT_DIR/summary.tsv as `check<TAB>result<TAB>detail`.
# The run exits non-zero when a required check fails, and the restoration of
# the ordinary router runs on every exit path once the teardown has begun.
#
# usage: admit-web-router-fake.sh OUTPUT_DIR
#   QWEN_ADMISSION_MODEL_ID   registry row to serve, default qwen38-4b-distill
#   QWEN_ADMISSION_CONTEXT    depth the test profile requests, default 8192
#   QWEN_ADMISSION_PROFILE    profile id, default web-balanced-admission
#   QWEN_SERVER_PORT          router port, default 8080
#   QWEN_WEB_BROKER_PORT      broker port, default 8571
#   QWEN_ADMISSION_RESTORE    0 leaves the appliance down after the run

if [ "$#" -ne 1 ]; then
    printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
    exit 2
fi

output_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
model_id=${QWEN_ADMISSION_MODEL_ID:-qwen38-4b-distill}
profile_id=${QWEN_ADMISSION_PROFILE:-web-balanced-admission}
context=${QWEN_ADMISSION_CONTEXT:-8192}
server_port=${QWEN_SERVER_PORT:-8080}
broker_port=${QWEN_WEB_BROKER_PORT:-8571}
restore=${QWEN_ADMISSION_RESTORE:-1}
registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"$HOME/qwen-webui-state"}

# One admission owns the appliance at a time: the run tears the ordinary
# router down, launches the web router, and restores the roster, and a second
# run started meanwhile tears down the first's web session as if it were its
# own. The script re-executes itself under flock(1), which holds an
# exclusive lock on a file in the state directory for as long as the run
# lives and releases it with the process on every exit path, so no stale
# claim can exist and the takeover needs no check of its own. --close drops
# the locked descriptor before the run starts, so the servers the run
# launches inherit no lock and cannot hold it past the run's end.
admission_lock=$state_directory/web-admission.lock
if [ "${QWEN_ADMISSION_LOCKED:-}" != "$admission_lock" ]; then
    mkdir -p "$state_directory"
    QWEN_ADMISSION_LOCKED=$admission_lock
    export QWEN_ADMISSION_LOCKED
    if flock -n --close -E 75 "$admission_lock" "$0" "$@"; then
        exit 0
    else
        lock_status=$?
        if [ "$lock_status" -eq 75 ]; then
            printf 'another admission run holds %s\n' "$admission_lock" >&2
        fi
        exit "$lock_status"
    fi
fi
fixture=${QWEN_WEB_FAKE_FIXTURES:-$script_directory/test-fixtures/web-fake-provider.json}
router_origin=http://127.0.0.1:$server_port
broker_origin=http://127.0.0.1:$broker_port
query='raven2 vulkan decode'

for tool in python3 curl jq sha256sum ss pgrep; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf '%s is required\n' "$tool" >&2
        exit 2
    fi
done

umask 077
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
summary=$output_directory/summary.tsv
: >"$summary"
failures=0
restoration_required=0
restoration_finished=0
record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$summary"
    printf '%s=%s %s\n' "$1" "$2" "$3"
    case $2 in
        pass | observed | skipped) ;;
        *) failures=$((failures + 1)) ;;
    esac
}
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Every request the page would make is retained as a numbered pair, request
# body beside response body, so a failed check names the exchange.
exchange=0
call() {
    exchange=$((exchange + 1))
    call_label=$1
    call_method=$2
    call_url=$3
    call_body=${4:-}
    call_headers_file=$output_directory/http/$exchange-$call_label.headers
    call_out=$output_directory/http/$exchange-$call_label.response
    # dash ends the shell on a shift past $#, so the count is checked first.
    if [ "$#" -ge 4 ]; then
        shift 4
    else
        shift "$#"
    fi
    # Web mode mints a bearer API key that the router and the broker's
    # /session route both demand, so every request to either carries it the
    # way the page's authHeaders() does. The key reaches curl through a
    # config file rather than argv, and the file lives beside the run's own
    # keys at 0600 and is removed with them.
    if [ -s "$api_key_curl_config" ] && [ "${call_without_key:-0}" != 1 ]; then
        set -- "$@" --config "$api_key_curl_config"
    fi
    if [ -n "$call_body" ]; then
        printf '%s' "$call_body" >"$output_directory/http/$exchange-$call_label.request"
        curl -sS --max-time 600 -o "$call_out" -D "$call_headers_file" \
            -X "$call_method" "$call_url" -H 'Content-Type: application/json' \
            --data-binary "@$output_directory/http/$exchange-$call_label.request" \
            "$@" || true
    else
        curl -sS --max-time 60 -o "$call_out" -D "$call_headers_file" \
            -X "$call_method" "$call_url" "$@" || true
    fi
    call_status=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$call_headers_file" 2>/dev/null | tail -1)
    call_status=${call_status:-000}
}
mkdir -p "$output_directory/http"
api_key_curl_config=$output_directory/keys/api-key.curl
api_key_bytes=''
# An early exit under set -e names itself in run.log rather than leaving an
# empty summary as the only trace.
note_exit() {
    exit_status=${1:-$?}
    if [ "$exit_status" -ne 0 ]; then
        printf 'admission_aborted status=%s utc=%s\n' "$exit_status" "$(utc)" >>"$output_directory/run.log"
    fi
}
trap note_exit EXIT

# 1. The ordinary router, as found.
printf 'admission_start utc=%s host=%s\n' "$(utc)" "$(uname -n)" >"$output_directory/run.log"
cp "$state_directory/session.status" "$output_directory/ordinary-session.status" 2>/dev/null || true
ordinary_running=0
if pgrep -x llama-server >/dev/null 2>&1; then
    ordinary_running=1
    call ordinary-models GET "$router_origin/v1/models"
    jq -r '.data[].id' "$call_out" 2>/dev/null | sort >"$output_directory/ordinary-model-ids.txt" || true
    ordinary_server=$(readlink -f "/proc/$(pgrep -x llama-server | head -1)/exe")
else
    ordinary_server=${QWEN_LLAMA_SERVER:-"$HOME/src/llama.cpp-qwen-nvidia/build-appliance-current/bin/llama-server"}
    [ -x "$ordinary_server" ] || \
        ordinary_server=$HOME/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-server
fi
sha256sum "$ordinary_server" >"$output_directory/ordinary-llama-server.sha256"
if [ -x "$script_directory/hash-load-closure.sh" ]; then
    "$script_directory/hash-load-closure.sh" "$ordinary_server" \
        "$output_directory/ordinary-load-closure.tsv" >/dev/null 2>&1 || true
fi
record ordinary_router_recorded pass "running=$ordinary_running server=$(cut -c1-16 "$output_directory/ordinary-llama-server.sha256")"

restore_ordinary() {
    if [ "$restoration_finished" = 1 ]; then
        return 0
    fi
    restoration_finished=1
    if [ "$restore" != 1 ]; then
        record ordinary_restore skipped 'QWEN_ADMISSION_RESTORE=0'
        return 0
    fi
    if pgrep -x llama-server >/dev/null 2>&1; then
        "$script_directory/qwen-teardown.sh" >"$output_directory/pre-restore-teardown.log" 2>&1 || true
    fi
    if QWEN_LLAMA_SERVER=$ordinary_server QWEN_ROUTER=1 QWEN_BIND_HOST=127.0.0.1 \
        "$script_directory/qwen-launch.sh" default \
        >"$output_directory/ordinary-restore.log" 2>&1; then
        restored_server=$(readlink -f "/proc/$(pgrep -x llama-server | head -1)/exe" 2>/dev/null || true)
        call restored-models GET "$router_origin/v1/models"
        jq -r '.data[].id' "$call_out" 2>/dev/null | sort >"$output_directory/restored-model-ids.txt" || true
        if [ "$restored_server" != "$ordinary_server" ]; then
            record ordinary_restore fail \
                "server differs expected=$ordinary_server actual=${restored_server:-absent}"
            return 1
        elif [ -s "$output_directory/ordinary-model-ids.txt" ] && \
           ! cmp -s "$output_directory/ordinary-model-ids.txt" "$output_directory/restored-model-ids.txt"; then
            record ordinary_restore fail 'model roster differs from the one found'
            return 1
        else
            record ordinary_restore pass "models=$(tr '\n' ',' <"$output_directory/restored-model-ids.txt")"
        fi
        # The ordinary preset carries no MCP configuration, so the proxied
        # route reaches a child that registered /tools as feature_disabled:
        # the binary carries the route and the ordinary roster exposes no tool.
        ordinary_id=$(head -1 "$output_directory/restored-model-ids.txt")
        if [ -n "$ordinary_id" ]; then
            call ordinary-tools GET "$router_origin/tools?model=$ordinary_id&autoload=true"
            if [ "$call_status" = 403 ] && jq -e '.error.type == "feature_disabled"' "$call_out" >/dev/null 2>&1; then
                record ordinary_tools_disabled pass "model=$ordinary_id status=403 feature_disabled"
            else
                record ordinary_tools_disabled fail "model=$ordinary_id status=$call_status $(head -c 120 "$call_out")"
            fi
        fi
        # models-max is 1 on every launch this tree performs, so loading a
        # second model evicts the first; the roster's status field is read
        # after each load rather than inferred from the setting.
        first_id=$(grep -x -m1 -e qwen35-08b -e qwen38-2b-distill "$output_directory/restored-model-ids.txt" || true)
        second_id=$(grep -x -e qwen35-08b -e qwen38-2b-distill "$output_directory/restored-model-ids.txt" | grep -v -x "$first_id" | head -1 || true)
        # POST /models/load returns before the child is resident, so the
        # roster is polled until the requested model reads loaded (or 120 s
        # pass) before the next step reads any status.
        model_status() {
            jq -r --arg m "$1" '.data[] | select(.id == $m) | .status.value // empty' "$call_out" 2>/dev/null
        }
        wait_loaded() {
            wait_deadline=$(( $(date +%s) + 120 ))
            while :; do
                call "models-poll-$1" GET "$router_origin/models"
                [ "$(model_status "$1")" = loaded ] && return 0
                [ "$(date +%s)" -lt "$wait_deadline" ] || return 1
                sleep 2
            done
        }
        if [ -n "$first_id" ] && [ -n "$second_id" ]; then
            # The check loads and evicts, so the roster's resident set before
            # it is captured and put back after it: each model the check
            # loaded is unloaded again and each model resident beforehand is
            # loaded again, and the statuses are compared whole.
            call models-before-eviction GET "$router_origin/models"
            jq -r '.data[] | .id + "\t" + (.status.value // "")' "$call_out" | sort >"$output_directory/resident-before-eviction.tsv"
            call load-first POST "$router_origin/models/load" "$(jq -cn --arg m "$first_id" '{model: $m}')"
            wait_loaded "$first_id" || true
            first_status=$(model_status "$first_id")
            call load-second POST "$router_origin/models/load" "$(jq -cn --arg m "$second_id" '{model: $m}')"
            wait_loaded "$second_id" || true
            first_after=$(model_status "$first_id")
            second_after=$(model_status "$second_id")
            if [ "$first_status" = loaded ] && [ "$second_after" = loaded ] && [ "$first_after" != loaded ]; then
                record models_max_evicts_previous pass "$first_id=$first_status then $first_id=$first_after $second_id=$second_after"
            else
                record models_max_evicts_previous fail "$first_id=$first_status then $first_id=$first_after $second_id=$second_after"
            fi
            for loaded_id in $first_id $second_id; do
                call "unload-$loaded_id" POST "$router_origin/models/unload" "$(jq -cn --arg m "$loaded_id" '{model: $m}')"
            done
            for resident_id in $(awk -F'\t' '$2 == "loaded" { print $1 }' "$output_directory/resident-before-eviction.tsv"); do
                call "reload-$resident_id" POST "$router_origin/models/load" "$(jq -cn --arg m "$resident_id" '{model: $m}')"
                wait_loaded "$resident_id" || true
            done
            call models-after-eviction GET "$router_origin/models"
            jq -r '.data[] | .id + "\t" + (.status.value // "")' "$call_out" | sort >"$output_directory/resident-after-eviction.tsv"
            if cmp -s "$output_directory/resident-before-eviction.tsv" "$output_directory/resident-after-eviction.tsv"; then
                record resident_state_restored pass "$(awk -F'\t' '{ printf "%s=%s ", $1, $2 }' "$output_directory/resident-after-eviction.tsv")"
            else
                record resident_state_restored fail "before: $(awk -F'\t' '{ printf "%s=%s ", $1, $2 }' "$output_directory/resident-before-eviction.tsv") after: $(awk -F'\t' '{ printf "%s=%s ", $1, $2 }' "$output_directory/resident-after-eviction.tsv")"
            fi
        else
            record models_max_evicts_previous skipped 'fewer than two of the small ordinary rows are served'
        fi
    else
        record ordinary_restore fail "$(tail -1 "$output_directory/ordinary-restore.log")"
        return 1
    fi
}


finish_run() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    if [ "$restoration_required" = 1 ] && [ "$restoration_finished" != 1 ]; then
        restore_ordinary || exit_status=1
    fi
    note_exit "$exit_status"
    exit "$exit_status"
}
trap finish_run EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

restoration_required=1
if [ "$ordinary_running" = 1 ]; then
    if "$script_directory/qwen-teardown.sh" >"$output_directory/ordinary-teardown.log" 2>&1; then
        record ordinary_teardown pass 'no residue'
    else
        record ordinary_teardown fail "$(tail -1 "$output_directory/ordinary-teardown.log")"
        exit 1
    fi
fi

# 2. Test inputs: signing key, state directory, one-row ledger, preset.
mkdir -p "$output_directory/keys" "$output_directory/web-mcp"
chmod 700 "$output_directory/keys" "$output_directory/web-mcp"
token_key_file=$output_directory/keys/token.key
if [ ! -s "$token_key_file" ]; then
    python3 -c 'import secrets; print(secrets.token_hex(32))' >"$token_key_file"
fi
chmod 600 "$token_key_file"

registry_row=$(grep -v '^#' "$registry" | awk -F'\t' -v id="$model_id" '$1 == id')
if [ -z "$registry_row" ]; then
    printf 'model %s is absent from %s\n' "$model_id" "$registry" >&2
    exit 2
fi
registry_field() { printf '%s\n' "$registry_row" | cut -f"$1"; }
validated_depth=$(registry_field 19)
projector=$(registry_field 11)
tool_selection=$(registry_field 21)
case $projector in
    none) vision_allowed=no ;;
    *) vision_allowed=yes ;;
esac
ledger=$output_directory/web-profiles.tsv
printf '# profile_id\tmodel_id\tweb_mode\tcontext\tvalidated_filled_depth\tmax_results\tmax_fetches\tmax_chars_per_fetch\tmulti_source\tvision_allowed\ttool_selection\texecution_policy\tprovider\tprimary_category\tfallback_category\tminimum_results\tsearxng_url\n' >"$ledger"
printf '%s\t%s\tvalidator-gated\t%s\t%s\t3\t1\t12000\tno\t%s\t%s\tvalidator-gated\tfake\t-\t-\t-\t-\n' \
    "$profile_id" "$model_id" "$context" "$validated_depth" "$vision_allowed" "$tool_selection" >>"$ledger"

web_presets=$output_directory/web-presets.ini
if QWEN_WEB_PROFILES=$ledger QWEN_WEB_MCP_SERVER=$script_directory/web-mcp/server.py \
    QWEN_WEB_PROVIDER=fake QWEN_WEB_FAKE_FIXTURES=$fixture \
    QWEN_WEB_TOKEN_KEY_FILE=$token_key_file QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_WEB_AUTHORIZER_READY=1 QWEN_MODEL_REGISTRY=$registry QWEN_MODEL_ROOT=$model_root \
    "$script_directory/build-web-presets.sh" "$web_presets" >"$output_directory/build-web-presets.log" 2>&1; then
    record preset_generated pass "$(grep -c '^\[' "$web_presets") section"
else
    record preset_generated fail "$(tail -1 "$output_directory/build-web-presets.log")"
    restore_ordinary
    exit 1
fi

# 3. Launch the test router.
if QWEN_WEB_PRESETS=$web_presets QWEN_WEB_PROFILES=$ledger QWEN_WEB_PROVIDER=fake \
    QWEN_WEB_TOKEN_KEY_FILE=$token_key_file QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_WEB_BROKER_PORT=$broker_port QWEN_WEB_AUTHORIZER_READY=1 \
    QWEN_MODEL_REGISTRY=$registry \
    "$script_directory/qwen-web-launch.sh" default >"$output_directory/web-launch.log" 2>&1; then
    record web_launch pass "$(grep '^web_launch' "$output_directory/web-launch.log" | tr '\n' ';')"
    # The session minted or reused the API key at 0600 in the state
    # directory; its first line is the bearer value the page's set-key field
    # takes, and only a curl config file and the driver's file argument
    # carry it from here.
    api_key_file=$state_directory/api.key
    if [ -s "$api_key_file" ] && [ "$(stat -c %a "$api_key_file")" = 600 ]; then
        api_key_bytes=$(sed -n '1p' "$api_key_file")
        printf 'header = "Authorization: Bearer %s"\n' "$api_key_bytes" >"$api_key_curl_config"
        chmod 600 "$api_key_curl_config"
        record api_key_minted pass "mode=600 path=$api_key_file"
    else
        record api_key_minted fail "absent, empty, or not 0600: $api_key_file"
    fi
else
    record web_launch fail "$(tail -2 "$output_directory/web-launch.log" | tr '\n' ';')"
    cp "$state_directory/session.status" "$output_directory/failed-session.status" 2>/dev/null || true
    cp "$state_directory/authorize-broker.log" "$output_directory/failed-broker.log" 2>/dev/null || true
    cp "$state_directory/server.log" "$output_directory/failed-server.log" 2>/dev/null || true
    restore_ordinary
    exit 1
fi
cp "$state_directory/session.status" "$output_directory/web-session.status"
cp "$state_directory/authorize-broker.log" "$output_directory/web-broker.log" 2>/dev/null || true
broker_pid=$(sed -n '1p' "$output_directory/web-session.status" | tr ' ' '\n' | sed -n 's/^broker_pid=//p')
secret_file=$(sed -n 's/^broker secret_file=//p' "$output_directory/web-session.status")
router_listener=$(ss -ltnp 2>/dev/null | grep ":$server_port " | grep -o '[0-9.:*]*:'"$server_port" | sort -u | tr '\n' ',')
broker_listener=$(ss -ltnp 2>/dev/null | grep ":$broker_port " | grep -o '[0-9.:*]*:'"$broker_port" | sort -u | tr '\n' ',')
case $router_listener in
    "127.0.0.1:$server_port,") record router_listener_loopback pass "$router_listener" ;;
    *) record router_listener_loopback fail "$router_listener" ;;
esac
case $broker_listener in
    "127.0.0.1:$broker_port,") record broker_listener_loopback pass "$broker_listener" ;;
    *) record broker_listener_loopback fail "$broker_listener" ;;
esac
case $broker_pid in
    '' | *[!0-9]*) record broker_pid_recorded fail "broker_pid=$broker_pid" ;;
    *) record broker_pid_recorded pass "broker_pid=$broker_pid" ;;
esac
if [ -f "$secret_file" ] && [ "$(stat -c %a "$secret_file")" = 600 ]; then
    record broker_secret_mode pass "$(stat -c %a "$secret_file")"
else
    record broker_secret_mode fail "secret_file=$secret_file"
fi

# 4. Router identity: one alias, the test tuple, the two web tools, all read
# on the router port. The router resolves the model of GET /tools from the
# query string and of POST /tools from the body's top-level model key, the
# way it resolves /props and /v1/chat/completions, and forwards the request to
# the child that read the section's MCP configuration.
call models GET "$router_origin/v1/models"
model_ids=$(jq -r '.data[].id' "$call_out" 2>/dev/null | tr '\n' ',')
if [ "$model_ids" = "$profile_id," ]; then
    record router_roster pass "$model_ids"
else
    record router_roster fail "$model_ids"
fi
call props GET "$router_origin/props?model=$profile_id"
served_context=$(jq -r '.default_generation_settings.n_ctx // empty' "$call_out" 2>/dev/null)
record served_context observed "n_ctx=$served_context requested=$context"
call tools-no-model GET "$router_origin/tools"
if [ "$call_status" != 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record tools_without_model_refused pass "status=$call_status $(jq -r '.error.message // .error' "$call_out" | head -c 80)"
else
    record tools_without_model_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
call tools-unknown-model GET "$router_origin/tools?model=no-such-model&autoload=true"
if [ "$call_status" != 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record tools_unknown_model_refused pass "status=$call_status $(jq -r '.error.message // .error' "$call_out" | head -c 80)"
else
    record tools_unknown_model_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
call tools GET "$router_origin/tools?model=$profile_id&autoload=true"
tool_names=$(jq -r '.[].tool' "$call_out" 2>/dev/null | sort | tr '\n' ',')
if [ "$tool_names" = "web_fetch_exa,web_search_exa," ]; then
    record tool_enumeration pass "$tool_names via $router_origin"
else
    record tool_enumeration fail "$tool_names status=$call_status"
fi
cp "$call_out" "$output_directory/tools.json"
# The child's own port is a diagnostic control: it separates a router proxy
# defect from a child tool defect when one appears, and no admission check
# reads it.
child_port=''
for candidate in $(ss -ltnp 2>/dev/null | grep '"llama-server"' | grep -o '127\.0\.0\.1:[0-9]*' | sed 's/.*://' | sort -u); do
    [ "$candidate" != "$server_port" ] || continue
    child_port=$candidate
done
if [ -n "$child_port" ]; then
    call child-tools-control GET "http://127.0.0.1:$child_port/tools"
    record child_port_control observed "port=$child_port status=$call_status tools=$(jq -r '.[].tool' "$call_out" 2>/dev/null | sort | tr '\n' ',')"
else
    record child_port_control observed 'no child listener beside the router'
fi
# The page the router serves is the executor the browser runs, so its own
# source is read for the route shape: GET /tools carrying ?model= and the
# POST body carrying the model key beside tool and params. The web launcher
# serves webui/index.html, and a router serving any other page fails here
# because the browser arm below would then run a page with no executor.
call page GET "$router_origin/"
if grep -q 'tools?model=' "$call_out" && grep -q 'model, tool: toolName, params' "$call_out"; then
    record ui_executor_targets_router pass 'served page composes ./tools?model= and posts {model, tool, params}'
else
    record ui_executor_targets_router fail "served page is not the fallback UI or lacks the model-scoped routes (status=$call_status)"
fi

# 5. Broker identity and the session secret's gates.
call broker-health GET "$broker_origin/health" '' -H "Host: 127.0.0.1:$broker_port"
health_profile=$(jq -r '.profile // empty' "$call_out" 2>/dev/null)
health_provider=$(jq -r '.provider // empty' "$call_out" 2>/dev/null)
health_pid=$(jq -r '.pid // empty' "$call_out" 2>/dev/null)
if [ "$health_profile" = "$profile_id" ] && [ "$health_provider" = fake ] && [ "$health_pid" = "$broker_pid" ]; then
    record broker_health_identity pass "profile=$health_profile provider=$health_provider pid=$health_pid"
else
    record broker_health_identity fail "profile=$health_profile provider=$health_provider pid=$health_pid"
fi
# Both listeners refuse a request without the key: the router at 401 and
# the broker's session route at 403, so an unauthenticated page reaches
# neither a model nor a grant.
call_without_key=1 call tools-no-api-key GET "$router_origin/tools?model=$profile_id&autoload=true"
if [ "$call_status" = 401 ]; then
    record router_without_api_key_refused pass "status=401"
else
    record router_without_api_key_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
call_without_key=1 call session-no-api-key GET "$broker_origin/session" '' -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port"
if [ "$call_status" = 403 ]; then
    record session_without_api_key_refused pass "status=403"
else
    record session_without_api_key_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
call session GET "$broker_origin/session" '' -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port"
session_secret=$(jq -r '.session_secret // empty' "$call_out" 2>/dev/null)
if [ "$call_status" = 200 ] && [ -n "$session_secret" ]; then
    record session_secret_issued pass "status=$call_status"
else
    record session_secret_issued fail "status=$call_status"
fi
call session-foreign-origin GET "$broker_origin/session" '' -H "Origin: http://localhost:$server_port" -H "Host: 127.0.0.1:$broker_port"
if [ "$call_status" != 200 ]; then
    record session_foreign_origin_refused pass "status=$call_status"
else
    record session_foreign_origin_refused fail "status=$call_status"
fi
call session-no-origin GET "$broker_origin/session" '' -H "Host: 127.0.0.1:$broker_port"
if [ "$call_status" != 200 ]; then
    record session_absent_origin_refused pass "status=$call_status"
else
    record session_absent_origin_refused fail "status=$call_status"
fi
call session-name-host GET "$broker_origin/session" '' -H "Origin: $router_origin" -H 'Host: broker.example'
if [ "$call_status" != 200 ]; then
    record session_name_host_refused pass "status=$call_status"
else
    record session_name_host_refused fail "status=$call_status"
fi

# 6. Grants, signed over the exact fields the page shows. One per search the
# run performs, since the broker signs single-use.
issue_grant() {
    grant_label=$1
    grant_query=$2
    grant_body=$(jq -cn --arg q "$grant_query" --arg p "$profile_id" \
        '{query: $q, profile_id: $p, max_results: 3, include_domains: [], exclude_domains: []}')
    call "$grant_label" POST "$broker_origin/grant" "$grant_body" -H "Origin: $router_origin" \
        -H "Host: 127.0.0.1:$broker_port" -H "X-Qwen-Web-Session: $session_secret"
    if [ "$call_status" = 429 ]; then
        # The broker charges its authorize-minute bucket (6 per 60 s) ahead of
        # every other check, and this run issues grants faster than an
        # operator clicks, so the seventh inside a minute is refused. That
        # refusal is the limit working and is recorded as such; the run then
        # waits out the window once and asks again.
        record broker_rate_limit_enforced observed "$grant_label: $(jq -r '.error // empty' "$call_out" | head -c 100)"
        sleep 61
        call "$grant_label-retry" POST "$broker_origin/grant" "$grant_body" -H "Origin: $router_origin" \
            -H "Host: 127.0.0.1:$broker_port" -H "X-Qwen-Web-Session: $session_secret"
    fi
    issued_authorization=$(jq -r '.authorization // empty' "$call_out" 2>/dev/null)
}
issue_grant grant "$query"
authorization=$issued_authorization
if [ "$call_status" = 200 ] && [ -n "$authorization" ]; then
    record grant_issued pass "status=$call_status bytes=${#authorization}"
else
    record grant_issued fail "status=$call_status"
fi
grant_body=$(jq -cn --arg q "$query" --arg p "$profile_id" \
    '{query: $q, profile_id: $p, max_results: 3, include_domains: [], exclude_domains: []}')
wrong_profile_body=$(jq -cn --arg q "$query" '{query: $q, profile_id: "web-other", max_results: 3, include_domains: [], exclude_domains: []}')
call grant-wrong-profile POST "$broker_origin/grant" "$wrong_profile_body" -H "Origin: $router_origin" \
    -H "Host: 127.0.0.1:$broker_port" -H "X-Qwen-Web-Session: $session_secret"
if [ "$call_status" != 200 ]; then
    record grant_wrong_profile_refused pass "status=$call_status"
else
    record grant_wrong_profile_refused fail "status=$call_status"
fi
call grant-wrong-session POST "$broker_origin/grant" "$grant_body" -H "Origin: $router_origin" \
    -H "Host: 127.0.0.1:$broker_port" -H 'X-Qwen-Web-Session: not-the-secret'
if [ "$call_status" != 200 ]; then
    record grant_wrong_session_refused pass "status=$call_status"
else
    record grant_wrong_session_refused fail "status=$call_status"
fi
call grant-foreign-origin POST "$broker_origin/grant" "$grant_body" -H "Origin: http://localhost:$server_port" \
    -H "Host: 127.0.0.1:$broker_port" -H "X-Qwen-Web-Session: $session_secret"
if [ "$call_status" != 200 ]; then
    record grant_foreign_origin_refused pass "status=$call_status"
else
    record grant_foreign_origin_refused fail "status=$call_status"
fi

# 7. The search runs through the router, the child, and its MCP process. The
# body carries the model key the router reads and stream=false, and the
# child's executor forwards params alone.
tool_body() {
    jq -cn --arg m "$profile_id" --arg t "$1" --argjson p "$2" \
        '{model: $m, tool: $t, params: $p, stream: false}'
}
search_params=$(jq -cn --arg q "$query" --arg a "$authorization" \
    '{query: $q, max_results: 3, include_domains: [], exclude_domains: [], authorization: $a}')
call search-no-model POST "$router_origin/tools" "$(jq -cn --argjson p "$search_params" '{tool: "web_search_exa", params: $p, stream: false}')"
if [ "$call_status" != 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record post_without_model_refused pass "status=$call_status $(jq -r '.error.message // .error' "$call_out" | head -c 80)"
else
    record post_without_model_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
call search-unknown-model POST "$router_origin/tools" "$(jq -cn --argjson p "$search_params" '{model: "no-such-model", tool: "web_search_exa", params: $p, stream: false}')"
if [ "$call_status" != 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record post_unknown_model_refused pass "status=$call_status $(jq -r '.error.message // .error' "$call_out" | head -c 80)"
else
    record post_unknown_model_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
call search POST "$router_origin/tools" "$(tool_body web_search_exa "$search_params")"
search_text=$(jq -r 'if type == "object" then (.error // .plain_text_response // tostring) else tostring end' "$call_out" 2>/dev/null)
cp "$call_out" "$output_directory/search-response.json"
result_id=$(printf '%s\n' "$search_text" | sed -n 's/^Result ID: //p' | head -1)
if [ "$call_status" = 200 ] && [ -n "$result_id" ] && ! jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record search_executed pass "results=$(printf '%s\n' "$search_text" | grep -c '^Result ID: ') via $router_origin"
else
    record search_executed fail "status=$call_status $(printf '%s' "$search_text" | head -c 160)"
fi
call search-replay POST "$router_origin/tools" "$(tool_body web_search_exa "$search_params")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record grant_replay_refused pass "$(jq -r '.error' "$call_out" | head -c 120)"
else
    record grant_replay_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
unauthorized_params=$(jq -cn --arg q "$query" \
    '{query: $q, max_results: 3, include_domains: [], exclude_domains: []}')
call search-no-grant POST "$router_origin/tools" "$(tool_body web_search_exa "$unauthorized_params")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record search_without_grant_refused pass "$(jq -r '.error' "$call_out" | head -c 120)"
else
    record search_without_grant_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi
# The MCP server refuses an argument outside a tool's schema by name, so the
# search above, which carried model at the top level, proves the router's
# routing key stayed out of the arguments; the control places the same key
# inside params and is refused naming it.
call search-model-in-params POST "$router_origin/tools" "$(tool_body web_search_exa "$(jq -cn --argjson p "$unauthorized_params" --arg m "$profile_id" '$p + {model: $m}')")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1 && jq -r '.error' "$call_out" | grep -q 'model'; then
    record routing_key_outside_arguments pass "top-level model executed the search; params.model refused: $(jq -r '.error' "$call_out" | head -c 100)"
else
    record routing_key_outside_arguments fail "status=$call_status $(head -c 120 "$call_out")"
fi

# 8. Fetch by Result ID, then the allowance and the URL refusal.
fetch_params=$(jq -cn --arg r "$result_id" '{result_id: $r}')
call fetch POST "$router_origin/tools" "$(tool_body web_fetch_exa "$fetch_params")"
fetch_text=$(jq -r 'if type == "object" then (.error // .plain_text_response // tostring) else tostring end' "$call_out" 2>/dev/null)
if [ "$call_status" = 200 ] && printf '%s' "$fetch_text" | grep -q 'FIXTURE-PAGE-' && ! jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record fetch_by_result_id pass "chars=${#fetch_text} via $router_origin"
else
    record fetch_by_result_id fail "status=$call_status $(printf '%s' "$fetch_text" | head -c 160)"
fi
cp "$call_out" "$output_directory/fetch-response.json"
second_result=$(printf '%s\n' "$search_text" | sed -n 's/^Result ID: //p' | sed -n '2p')
call fetch-past-allowance POST "$router_origin/tools" "$(tool_body web_fetch_exa "$(jq -cn --arg r "${second_result:-$result_id}" '{result_id: $r}')")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record fetch_allowance_enforced pass "$(jq -r '.error' "$call_out" | head -c 120)"
else
    record fetch_allowance_enforced fail "status=$call_status $(head -c 120 "$call_out")"
fi
call fetch-url POST "$router_origin/tools" "$(tool_body web_fetch_exa "$(jq -cn '{result_id: "https://example.org/raven2"}')")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record fetch_url_refused pass "$(jq -r '.error' "$call_out" | head -c 120)"
else
    record fetch_url_refused fail "status=$call_status $(head -c 120 "$call_out")"
fi

# 9. Deadlines. The fixture holds one query for 5 seconds and one for 40. The
# generated configuration names timeout_ms 30000 for the child's MCP call and
# the router proxies with llama-server's 3600 second read timeout, so the slow
# call completes through the router and the stalled one is answered by the
# child's own deadline, as an error body, before the router gives up on it.
timed_search() {
    timed_label=$1
    timed_query=$2
    issue_grant "$timed_label-grant" "$timed_query"
    timed_params=$(jq -cn --arg q "$timed_query" --arg a "$issued_authorization" \
        '{query: $q, max_results: 3, include_domains: [], exclude_domains: [], authorization: $a}')
    timed_start=$(date +%s)
    call "$timed_label" POST "$router_origin/tools" "$(tool_body web_search_exa "$timed_params")"
    timed_elapsed=$(( $(date +%s) - timed_start ))
}
timed_search search-slow 'raven2 vulkan decode slow'
if [ "$call_status" = 200 ] && ! jq -e '.error' "$call_out" >/dev/null 2>&1 && \
   jq -r '.plain_text_response' "$call_out" | grep -q '^Result ID: ' && [ "$timed_elapsed" -ge 5 ]; then
    record delayed_provider_completes pass "elapsed=${timed_elapsed}s status=$call_status"
else
    record delayed_provider_completes fail "elapsed=${timed_elapsed}s status=$call_status $(head -c 120 "$call_out")"
fi
timed_search search-stalled 'raven2 vulkan decode stalled'
# The child's deadline answers as HTTP 200 with its own message, the shape
# mcp_result_to_response gives a refusal; a router-side 5xx or a proxy
# failure inside the same window is a different mechanism and fails here.
stall_message=$(jq -r '.error | if type == "object" then .message else . end' "$call_out" 2>/dev/null)
if [ "$call_status" = 200 ] && [ "$stall_message" = 'request timed out' ] && \
   [ "$timed_elapsed" -ge 25 ] && [ "$timed_elapsed" -lt 40 ]; then
    record mcp_deadline_precedes_router pass "elapsed=${timed_elapsed}s status=$call_status $(jq -r '.error | if type == "object" then .message else . end' "$call_out" | head -c 100)"
else
    record mcp_deadline_precedes_router fail "elapsed=${timed_elapsed}s status=$call_status $(head -c 120 "$call_out")"
fi
# A call after the stalled one proves the child and its MCP process serve
# on. The listing alone comes from the child's cached tool definitions, so a
# granted search runs as well, after the provider's own 40 s sleep has ended
# and the stalled call has fully unwound inside the MCP process.
call tools-after-stall GET "$router_origin/tools?model=$profile_id&autoload=true"
listing_after_stall=$(jq -r '.[].tool' "$call_out" 2>/dev/null | sort | tr '\n' ',')
stall_remaining=$(( 40 - timed_elapsed + 2 ))
[ "$stall_remaining" -gt 0 ] && sleep "$stall_remaining"
timed_search search-after-stall 'raven2 vulkan decode'
if [ "$listing_after_stall" = "web_fetch_exa,web_search_exa," ] && [ "$call_status" = 200 ] && \
   ! jq -e '.error' "$call_out" >/dev/null 2>&1 && \
   jq -r '.plain_text_response' "$call_out" | grep -q '^Result ID: '; then
    record child_serves_after_stall pass "listing intact; granted search executed after the stall, elapsed=${timed_elapsed}s"
else
    record child_serves_after_stall fail "listing=$listing_after_stall status=$call_status $(head -c 120 "$call_out")"
fi

# The model meets the composed tools and the search result. The proposal is
# the model's own, so both halves are recorded as observations.
tools_for_chat=$(jq -c '[.[] | .definition | select(.type == "function") | .function.parameters.properties |= (del(.authorization) // {}) | .function.parameters.required |= ((. // []) | map(select(. != "authorization")))]' "$output_directory/tools.json" 2>/dev/null || printf '[]')
chat_body=$(jq -cn --arg m "$profile_id" --arg q "$query" --argjson tools "$tools_for_chat" \
    '{model: $m, messages: [{role: "user", content: ("Search the web with the query " + $q + " and report the decode rate the result states.")}], tools: $tools, tool_choice: "auto", max_tokens: 512, temperature: 0, chat_template_kwargs: {enable_thinking: false}}')
call chat-proposal POST "$router_origin/v1/chat/completions" "$chat_body"
cp "$call_out" "$output_directory/chat-proposal.json"
proposed_tool=$(jq -r '.choices[0].message.tool_calls[0].function.name // empty' "$call_out" 2>/dev/null)
proposed_arguments=$(jq -r '.choices[0].message.tool_calls[0].function.arguments // empty' "$call_out" 2>/dev/null)
served_model=$(jq -r '.model // empty' "$call_out" 2>/dev/null)
if [ "$proposed_tool" = web_search_exa ]; then
    record model_proposes_search observed "model=$served_model arguments=$(printf '%s' "$proposed_arguments" | head -c 200)"
else
    record model_proposes_search observed "model=$served_model tool=${proposed_tool:-none} finish=$(jq -r '.choices[0].finish_reason // empty' "$call_out" 2>/dev/null)"
fi
assistant_message=$(jq -c '.choices[0].message | {role, content, tool_calls}' "$call_out" 2>/dev/null || printf '{"role":"assistant","content":""}')
tool_call_id=$(jq -r '.choices[0].message.tool_calls[0].id // "call_admission"' "$call_out" 2>/dev/null)
continuation_body=$(jq -cn --arg m "$profile_id" --arg q "$query" --argjson assistant "$assistant_message" \
    --arg id "$tool_call_id" --arg text "$search_text" --argjson tools "$tools_for_chat" \
    '{model: $m, messages: [{role: "user", content: ("Search the web with the query " + $q + " and report the decode rate the result states.")}, $assistant, {role: "tool", tool_call_id: $id, content: $text}], tools: $tools, max_tokens: 512, temperature: 0, chat_template_kwargs: {enable_thinking: false}}')
call chat-continuation POST "$router_origin/v1/chat/completions" "$continuation_body"
cp "$call_out" "$output_directory/chat-continuation.json"
final_answer=$(jq -r '.choices[0].message.content // empty' "$call_out" 2>/dev/null)
if printf '%s' "$final_answer" | grep -q '3\.07'; then
    record model_reads_tool_result pass "$(printf '%s' "$final_answer" | tr '\n' ' ' | head -c 200)"
else
    record model_reads_tool_result observed "status=$call_status $(printf '%s' "$final_answer" | tr '\n' ' ' | head -c 200)"
fi

# 9b. The browser runs the served page through the same turn: a headless
# Chromium on the appliance loads the page at the router origin, sends the
# prompt, approves the one dialog, and reports every request the page's own
# fetch made. The checks read that log rather than the page source, so they
# fail when the page posts to the child port, omits the routing key, or runs
# the search without a grant, whatever its source says.
browser_report=$output_directory/browser-turn.json
if command -v chromium >/dev/null 2>&1; then
    browser_prompt="Search the web with the query $query and report the decode rate the result states."
    if python3 "$script_directory/web-mcp/drive-fallback-page.py" --origin "$router_origin" \
            --api-key-file "$api_key_file" --broker "$broker_origin" \
            --prompt "$browser_prompt" >"$browser_report" 2>"$output_directory/browser-turn.err"; then
        browser_origin=$(jq -r '.origin // empty' "$browser_report")
        if [ "$browser_origin" = "$router_origin" ]; then
            record browser_page_origin pass "origin=$browser_origin model=$(jq -r '.model' "$browser_report")"
        else
            record browser_page_origin fail "origin=$browser_origin"
        fi
        listing_request=$(jq -r --arg u "$router_origin/tools?model=$profile_id&autoload=true" \
            '[.requests[] | select(.method == "GET" and .url == $u)] | length' "$browser_report")
        if [ "$listing_request" -ge 1 ]; then
            record browser_lists_tools_via_router pass "GET /tools?model=$profile_id&autoload=true count=$listing_request"
        else
            record browser_lists_tools_via_router fail "requests=$(jq -c '[.requests[].url]' "$browser_report" | head -c 300)"
        fi
        grant_request=$(jq -r --arg u "$broker_origin/grant" \
            '[.requests[] | select(.method == "POST" and .url == $u)] | length' "$browser_report")
        if [ "$grant_request" -ge 1 ]; then
            record browser_grant_from_broker pass "POST $broker_origin/grant count=$grant_request"
        else
            record browser_grant_from_broker fail "no grant request in the page log"
        fi
        search_post=$(jq -c --arg u "$router_origin/tools" \
            '[.requests[] | select(.method == "POST" and .url == $u) | (.body | fromjson? // {}) | select(.tool == "web_search_exa")] | first // empty' "$browser_report")
        if [ -n "$search_post" ] && \
           [ "$(printf '%s' "$search_post" | jq -r '.model')" = "$profile_id" ] && \
           [ "$(printf '%s' "$search_post" | jq -r '.stream')" = false ] && \
           [ "$(printf '%s' "$search_post" | jq -r '.params.authorization // empty | length')" -gt 0 ] && \
           [ "$(printf '%s' "$search_post" | jq -r '.params.query')" = "$(jq -r '.dialog.args.query // empty' "$browser_report")" ]; then
            record browser_search_via_router pass "POST /tools model=$profile_id tool=web_search_exa stream=false grant=present query=$(printf '%s' "$search_post" | jq -r '.params.query')"
        else
            record browser_search_via_router fail "$(printf '%s' "$search_post" | jq -c 'del(.params.authorization)' 2>/dev/null | head -c 300)"
        fi
        off_router=$(jq -r --arg r "$router_origin/" --arg b "$broker_origin/" \
            '[.requests[] | select((.url | startswith($r) | not) and (.url | startswith($b) | not))] | length' "$browser_report")
        if [ "$off_router" -eq 0 ]; then
            record browser_requests_stay_on_router_and_broker pass "every page request names $router_origin or $broker_origin"
        else
            record browser_requests_stay_on_router_and_broker fail "$(jq -c --arg r "$router_origin/" --arg b "$broker_origin/" '[.requests[] | select((.url | startswith($r) | not) and (.url | startswith($b) | not)) | .url]' "$browser_report" | head -c 300)"
        fi
        tool_message=$(jq -r '[.history[] | select(.role == "tool")] | first | .content // empty' "$browser_report")
        if printf '%s' "$tool_message" | grep -q '^Result ID: '; then
            record browser_tool_result_in_transcript pass "$(printf '%s' "$tool_message" | head -c 120 | tr '\n' ' ')"
        else
            record browser_tool_result_in_transcript fail "$(printf '%s' "$tool_message" | head -c 200 | tr '\n' ' ')"
        fi
        fetch_post=$(jq -c --arg u "$router_origin/tools" \
            '[.requests[] | select(.method == "POST" and .url == $u) | (.body | fromjson? // {}) | select(.tool == "web_fetch_exa")] | first // empty' "$browser_report")
        if [ -n "$fetch_post" ]; then
            record browser_fetch_via_router observed "model=$(printf '%s' "$fetch_post" | jq -r '.model') result_id=$(printf '%s' "$fetch_post" | jq -r '.params.result_id // empty' | head -c 40)"
        else
            record browser_fetch_via_router observed 'the model proposed no fetch in this turn'
        fi
        browser_answer=$(jq -r '[.history[] | select(.role == "assistant")] | last | .content // empty' "$browser_report")
        if [ -n "$browser_answer" ]; then
            record browser_final_answer pass "$(printf '%s' "$browser_answer" | tr '\n' ' ' | head -c 200)"
        else
            record browser_final_answer fail 'the transcript ends without an assistant answer'
        fi
        # The grant is spent inside the request the browser sent, so the
        # retained page log keeps the fields and drops the token.
        jq '.requests |= map(.body |= (if . == null then null else (fromjson? // .) end) | .body |= (if type == "object" and .params? then .params |= del(.authorization) else . end))' \
            "$browser_report" >"$browser_report.tmp" && mv "$browser_report.tmp" "$browser_report"
    else
        record browser_turn_completed fail "$(tail -c 300 "$output_directory/browser-turn.err" | tr '\n' ' ')"
    fi
else
    record browser_turn_completed fail 'chromium is absent, so the served page was not run'
fi

# 10. Secret hygiene: key bytes, grant, session secret, and query text stay out
# of every process image and every retained file.
key_bytes=$(cat "$token_key_file")
hygiene_failures=''
for pid in $(pgrep -x llama-server) $(pgrep -f 'web-mcp/server.py') $broker_pid; do
    [ -r "/proc/$pid/environ" ] || continue
    for needle in "$key_bytes" "$api_key_bytes" "$authorization" "$session_secret"; do
        [ -n "$needle" ] || continue
        if tr '\0' '\n' <"/proc/$pid/environ" | grep -qF -- "$needle" || \
           tr '\0' '\n' <"/proc/$pid/cmdline" | grep -qF -- "$needle"; then
            hygiene_failures="$hygiene_failures pid=$pid"
        fi
    done
done
tr '\0' '\n' <"/proc/$broker_pid/cmdline" >"$output_directory/broker.cmdline" 2>/dev/null || true
for pid in $(pgrep -f 'web-mcp/server.py'); do
    tr '\0' '\n' <"/proc/$pid/cmdline" >"$output_directory/mcp-child-$pid.cmdline" 2>/dev/null || true
    tr '\0' '\n' <"/proc/$pid/environ" | sed 's/=.*/=<value>/' >"$output_directory/mcp-child-$pid.environ-keys" 2>/dev/null || true
done
python3 - "$output_directory/web-mcp" "$output_directory/audit-rows.tsv" <<'PY' || true
import glob, os, sqlite3, sys
directory, out = sys.argv[1], sys.argv[2]
with open(out, "w") as handle:
    for path in glob.glob(os.path.join(directory, "*.sqlite*")) + glob.glob(os.path.join(directory, "*.db")):
        try:
            connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            for (name,) in connection.execute("select name from sqlite_master where type='table'"):
                for row in connection.execute(f"select * from {name}"):
                    handle.write(name + "\t" + "\t".join(str(v) for v in row) + "\n")
            connection.close()
        except sqlite3.Error as error:
            handle.write(f"unreadable\t{path}\t{error}\n")
PY
for retained in "$state_directory/server.log" "$state_directory/authorize-broker.log" \
    "$state_directory/session.status" "$output_directory/audit-rows.tsv"; do
    [ -r "$retained" ] || continue
    for needle in "$key_bytes" "$api_key_bytes" "$authorization" "$session_secret"; do
        [ -n "$needle" ] || continue
        if grep -qF -- "$needle" "$retained"; then
            hygiene_failures="$hygiene_failures file=$(basename "$retained")"
        fi
    done
done
if grep -qF -- "$query" "$output_directory/audit-rows.tsv" 2>/dev/null; then
    hygiene_failures="$hygiene_failures audit=query-text"
fi
if [ -z "$hygiene_failures" ]; then
    record secret_hygiene pass 'key, grant, session secret, and query text absent from process images, logs, status, and audit'
else
    record secret_hygiene fail "$hygiene_failures"
fi
cp "$state_directory/server.log" "$output_directory/web-server.log" 2>/dev/null || true
cp "$state_directory/authorize-broker.log" "$output_directory/web-broker.log" 2>/dev/null || true

# 11. Teardown and absence.
if "$script_directory/qwen-teardown.sh" >"$output_directory/web-teardown.log" 2>&1; then
    record web_teardown pass "$(tail -1 "$output_directory/web-teardown.log")"
else
    record web_teardown fail "$(tail -1 "$output_directory/web-teardown.log")"
fi
absence=''
pgrep -x llama-server >/dev/null 2>&1 && absence="$absence llama-server"
pgrep -f 'web-mcp/server.py' >/dev/null 2>&1 && absence="$absence mcp-child"
kill -0 "$broker_pid" 2>/dev/null && absence="$absence broker"
[ -e "$secret_file" ] && absence="$absence secret"
ss -ltn 2>/dev/null | grep -q ":$server_port " && absence="$absence port-$server_port"
ss -ltn 2>/dev/null | grep -q ":$broker_port " && absence="$absence port-$broker_port"
if [ -z "$absence" ]; then
    record absence_proved pass 'router, child, broker, secret, and both ports'
else
    record absence_proved fail "$absence"
fi

# 12. Restore the ordinary router.
restore_ordinary
printf 'admission_end utc=%s failures=%s\n' "$(utc)" "$failures" >>"$output_directory/run.log"
if [ "$failures" -eq 0 ]; then
    printf 'web router admission against the fake provider: all required checks passed\n'
    exit 0
fi
printf 'web router admission against the fake provider: %s required checks failed\n' "$failures" >&2
exit 1
