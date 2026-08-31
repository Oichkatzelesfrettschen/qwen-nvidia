#!/bin/sh
set -eu

# Admit one full worktree-edit-test-diff-teardown chain through the router
# surface: the router (or its fixture), the approval broker, the coding MCP
# child, the coding-agent service, and the agent runtime (or its fixture)
# all execute, and every request the page makes runs with curl-equivalent
# HTTP in its place first, then the served page runs the same turn in
# headless Chromium through scripts/web-mcp/drive-fallback-page.py --lane
# code. The checked-in coding authorities are read and never written: the
# admission set lives under OUTPUT_DIR and moves exactly one profile and
# the qwen-code runtime row to validator-gated, leaving every other row
# refused, so the lane's production policy never changes inside the run.
#
# The deterministic fixture is one declared value and the one assertion
# that reads it: the agent edits declared-value.txt from 41 to 42 and
# updates check-value.sh, the run's test profile executes that assertion
# inside the worktree, and the exported patch is verified to reproduce the
# reported result tree against the base commit in a temporary index. The
# negatives each run once: a replayed plan grant, an apply without a
# grant, an apply grant over a foreign plan hash, a replayed apply grant,
# a foreign job id, and a late result after cancellation. The teardown
# proves absence: worktree, bundle, handoff, export ref, import ref,
# socket, and process, with the authoritative fixture repository
# byte-identical and its HEAD unchanged.
#
# usage: admit-coding-chain.sh OUTPUT_DIR
#   QWEN_CODING_ROUTER_COMMAND  router command; default the fake router
#   QWEN_CODING_AGENT_COMMAND   agent command; default the fake agent
#   QWEN_CODING_MODEL_ID        roster alias, default qwenseer-2b
#   QWEN_CODING_MODEL_PATH      LLAMA_ARG_MODEL value for the preset
#   QWEN_CODING_PRINCIPAL       service principal, default current
#   QWEN_CODING_PRINCIPAL_HOME  principal home, default OUTPUT_DIR-local
#   QWEN_CODING_WORKSPACE_REPO  authoritative repository; default a
#                               fixture repository the run builds
#   QWEN_CODING_TEST_PROFILE    allowed test profile, default
#                               fixture-declared-value
#   QWEN_CODING_VALIDATED_DEPTH registry validated depth, default 65536
#   QWEN_CODING_SERVER_PORT     router port, default 8098
#   QWEN_CODING_BROKER_PORT     broker port, default 8599
#   QWEN_CODING_PAGE_ARM        0 skips the headless-Chromium page arm

if [ "$#" -ne 1 ]; then
    printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
    exit 2
fi

output_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
model_id=${QWEN_CODING_MODEL_ID:-qwenseer-2b}
model_path=${QWEN_CODING_MODEL_PATH:-/nonexistent/coding-admission.gguf}
server_port=${QWEN_CODING_SERVER_PORT:-8098}
broker_port=${QWEN_CODING_BROKER_PORT:-8599}
principal=${QWEN_CODING_PRINCIPAL:-current}
test_profile=${QWEN_CODING_TEST_PROFILE:-fixture-declared-value}
validated_depth=${QWEN_CODING_VALIDATED_DEPTH:-65536}
page_arm=${QWEN_CODING_PAGE_ARM:-1}
router_command=${QWEN_CODING_ROUTER_COMMAND:-"python3 $script_directory/test-fixtures/fake-router-server.py"}
agent_command=${QWEN_CODING_AGENT_COMMAND:-"$script_directory/test-fixtures/fake-coding-agent.sh"}
router_origin=http://127.0.0.1:$server_port
broker_origin=http://127.0.0.1:$broker_port

for tool in python3 curl git sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf '%s is required\n' "$tool" >&2
        exit 2
    }
done

umask 077
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
principal_home=${QWEN_CODING_PRINCIPAL_HOME:-"$output_directory/principal-home"}
summary=$output_directory/summary.tsv
: >"$summary"
failures=0

record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$summary"
    if [ "$2" = accepted ] || [ "$2" = not-run ]; then
        printf '%s=%s\n' "$1" "$2"
    else
        failures=$((failures + 1))
        printf '%s=refused detail=%s\n' "$1" "${3:-}" >&2
    fi
}

service_pid=''
router_pid=''
broker_pid=''
cleanup() {
    for pid in $service_pid $router_pid $broker_pid; do
        kill "$pid" 2>/dev/null || :
    done
    for pid in $service_pid $router_pid $broker_pid; do
        wait "$pid" 2>/dev/null || :
    done
    [ -n "${socket_directory:-}" ] && rm -rf "$socket_directory" || :
}
trap cleanup EXIT INT TERM

# -- the authoritative fixture repository ---------------------------------
workspace_repo=${QWEN_CODING_WORKSPACE_REPO:-}
if [ -z "$workspace_repo" ]; then
    workspace_repo=$output_directory/authoritative
    mkdir -p "$workspace_repo"
    git -C "$workspace_repo" init -q
    git -C "$workspace_repo" config user.name admission
    git -C "$workspace_repo" config user.email admission@example.invalid
    printf 'VALUE=41\n' >"$workspace_repo/declared-value.txt"
    cat >"$workspace_repo/check-value.sh" <<'EOF'
#!/bin/sh
set -eu
expected=41
value=$(sed -n 's/^VALUE=//p' declared-value.txt)
[ "$value" = "$expected" ] || {
    printf 'declared value %s, expected %s\n' "$value" "$expected" >&2
    exit 1
}
printf 'declared-value-check=pass value=%s\n' "$value"
EOF
    printf 'declared-value\n' >"$workspace_repo/FIXTURE_BEHAVIOR"
    git -C "$workspace_repo" add -A
    git -C "$workspace_repo" commit -q -m 'declared-value admission base'
fi
head_before=$(git -C "$workspace_repo" rev-parse HEAD)
tree_digest() {
    (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort |
        xargs sha256sum | sha256sum | cut -d' ' -f1)
}
digest_before=$(tree_digest "$workspace_repo")

# -- the admission authority set ------------------------------------------
authorities=$output_directory/authorities
mkdir -p "$authorities"
{
    printf '# profile_id\tmodel_id\truntime_id\tworkspace_id\tmaximum_context\tmaximum_reply_tokens\tmaximum_files_changed\tmaximum_patch_bytes\tmaximum_job_seconds\tallowed_test_profile\tnetwork_policy\texecution_policy\n'
    printf 'code-fast-a\t%s\tqwen-code\tcoding-admission\t32768\t8192\t16\t262144\t600\t%s\tloopback-llama\tvalidator-gated\n' \
        "$model_id" "$test_profile"
    printf 'code-deep-a\tqwen25-coder-7b\tqwen-code\tcoding-admission\t8192\t4096\t8\t131072\t900\t%s\tloopback-llama\trefused\n' \
        "$test_profile"
} >"$authorities/coding-profiles.tsv"
printf '# workspace_id\trepository_path\tmirror\ttest_profile\trepository_identity\ncoding-admission\t%s\tcoding-admission.git\t%s\tcoding-admission\n' \
    "$workspace_repo" "$test_profile" >"$authorities/coding-workspaces.tsv"
printf '# model_id\trole\tminimum_validated_depth\tmax_reply_tokens\n%s\tfast-coder\t32768\t8192\nqwen25-coder-7b\tdeep-coder\t8192\t4096\n' \
    "$model_id" >"$authorities/coding-models.tsv"
printf '# id\tvalidated_filled_depth\n%s\t%s\n' \
    "$model_id" "$validated_depth" >"$authorities/models.tsv"
# The runtime row copies the pinned registry with execution_policy moved to
# validator-gated; every other column stays the checked-in pin.
awk -F'\t' 'BEGIN { OFS = "\t" }
    /^#/ { print; next }
    $1 == "qwen-code" { $10 = "validator-gated" }
    { print }' "$script_directory/coding-runtimes.tsv" \
    >"$authorities/coding-runtimes.tsv"
printf '# id\tscope\tsubject\tfailure_class\tfirst_evidence\treason_record\n' \
    >"$authorities/coding-quarantine.tsv"

grant_key=$output_directory/grant.key
python3 -c 'import secrets; print(secrets.token_hex(24))' >"$grant_key"
chmod 600 "$grant_key"
api_key_file=$output_directory/webui-api.key
printf 'coding-admission-%s\n' "$(python3 -c 'import secrets; print(secrets.token_hex(8))')" \
    >"$api_key_file"
chmod 600 "$api_key_file"

# -- the coding-agent service ---------------------------------------------
# AF_UNIX bounds a socket path at 108 bytes, so the socket lives in its own
# short temporary directory rather than under an arbitrarily deep
# OUTPUT_DIR.
socket_directory=$(mktemp -d /tmp/qwen-coding-admission.XXXXXX)
service_socket=$socket_directory/agent.sock
mkdir -p "$principal_home/repos" "$principal_home/worktrees" 2>/dev/null || :
python3 "$script_directory/coding-agent-service.py" \
    --state-dir "$output_directory/service-state" \
    --socket "$service_socket" \
    --profiles "$authorities/coding-profiles.tsv" \
    --workspaces "$authorities/coding-workspaces.tsv" \
    --models "$authorities/coding-models.tsv" \
    --quarantine "$authorities/coding-quarantine.tsv" \
    --registry "$authorities/models.tsv" \
    --runtimes "$authorities/coding-runtimes.tsv" \
    --grant-key-file "$grant_key" \
    --principal "$principal" \
    --principal-home "$principal_home" \
    --bundle-dir "$output_directory/bundles" \
    --runtime-root "${QWEN_CODING_RUNTIME_ROOT:-/var/lib/qwen-coder/runtime}" \
    --runtime-key-file "${QWEN_CODING_RUNTIME_KEY_FILE:-/run/qwen-coder/llama-api.key}" \
    --runtime-settings "${QWEN_CODING_RUNTIME_SETTINGS:-/run/qwen-coder/settings.json}" \
    --runtime-base-url "${QWEN_CODING_RUNTIME_BASE_URL:-http://127.0.0.1:$server_port/v1}" \
    --agent-command "$agent_command" \
    >"$output_directory/service.log" 2>&1 &
service_pid=$!
waited=0
while [ ! -S "$service_socket" ]; do
    kill -0 "$service_pid" 2>/dev/null || {
        record coding_service_started refused \
            "$(tail -2 "$output_directory/service.log" | tr '\n\t' '; ')"
        exit 1
    }
    [ "$waited" -lt 30 ] || { record coding_service_started refused timeout; exit 1; }
    sleep 1
    waited=$((waited + 1))
done
record coding_service_started accepted "pid=$service_pid"

# -- the MCP configuration and preset -------------------------------------
mcp_configuration=$output_directory/coding-mcp.json
python3 - "$mcp_configuration" "$script_directory" "$service_socket" \
    "$authorities/coding-profiles.tsv" <<'EOF'
import json, sys
path, scripts, socket_path, profiles = sys.argv[1:5]
json.dump({"mcpServers": {"code": {
    "command": "python3",
    "args": [scripts + "/coding-mcp/server.py"],
    "env": {
        "QWEN_CODING_SERVICE_SOCKET": socket_path,
        "QWEN_CODING_PROFILE": "code-fast-a",
        "QWEN_CODING_PROFILES_TSV": profiles,
    },
    "timeout_ms": 900000,
}}}, open(path, "w"), indent=1)
EOF
preset=$output_directory/coding-admission.ini
{
    printf '# qwen_web_presets=1\n'
    printf '[coding-admission]\n'
    printf 'LLAMA_ARG_ALIAS=%s\n' "$model_id"
    printf 'LLAMA_ARG_MODEL=%s\n' "$model_path"
    printf 'LLAMA_ARG_CTX_SIZE=32768\n'
    printf 'LLAMA_ARG_MCP_SERVERS_CONFIG=%s\n' "$mcp_configuration"
    printf 'LLAMA_ARG_TAGS=coding-admission\n'
} >"$preset"

# -- the router and the broker --------------------------------------------
# The router command is a command line by contract, so the split is wanted.
# shellcheck disable=SC2086
$router_command \
    --models-preset "$preset" \
    --host 127.0.0.1 --port "$server_port" \
    --path "$repository_root/webui" \
    --api-key-file "$api_key_file" \
    >"$output_directory/router.log" 2>&1 &
router_pid=$!
waited=0
until curl -sf "$router_origin/health" >/dev/null 2>&1; do
    kill -0 "$router_pid" 2>/dev/null || {
        record coding_router_started refused \
            "$(tail -2 "$output_directory/router.log" | tr '\n\t' '; ')"
        exit 1
    }
    [ "$waited" -lt 120 ] || { record coding_router_started refused timeout; exit 1; }
    sleep 1
    waited=$((waited + 1))
done
record coding_router_started accepted "pid=$router_pid"

QWEN_WEB_BROKER_ORIGIN=$router_origin \
python3 "$script_directory/web-mcp/authorize-broker.py" \
    --host 127.0.0.1 --port "$broker_port" \
    --token-key-file "$grant_key" \
    --api-key-file "$api_key_file" \
    --state-dir "$output_directory/broker-state" \
    --provider fake \
    --profile code-fast-a \
    --coding-profile code-fast-a \
    >"$output_directory/broker.log" 2>&1 &
broker_pid=$!
mkdir -p "$output_directory/broker-state"
waited=0
until curl -sf "$broker_origin/health" >/dev/null 2>&1; do
    kill -0 "$broker_pid" 2>/dev/null || {
        record coding_broker_started refused \
            "$(tail -2 "$output_directory/broker.log" | tr '\n\t' '; ')"
        exit 1
    }
    [ "$waited" -lt 30 ] || { record coding_broker_started refused timeout; exit 1; }
    sleep 1
    waited=$((waited + 1))
done
record coding_broker_started accepted "pid=$broker_pid"

# -- the replayed page requests, and every refusal once -------------------
if python3 "$script_directory/replay-coding-chain.py" \
    --router "$router_origin" --broker "$broker_origin" \
    --api-key-file "$api_key_file" --model "$model_id" \
    --workspace-repo "$workspace_repo" --out "$output_directory" \
    >>"$summary.replay" 2>"$output_directory/replay.err"; then
    replay_status=0
else
    replay_status=$?
fi
while IFS="$(printf '\t')" read -r name result detail; do
    record "$name" "$result" "$detail"
done <"$summary.replay"
[ "$replay_status" -eq 0 ] || record coding_replay_completed refused \
    "$(tail -3 "$output_directory/replay.err" | tr '\n\t' '; ')"

# -- the served page runs the same turn -----------------------------------
if [ "$page_arm" = 1 ] && command -v chromium >/dev/null 2>&1; then
    if python3 "$script_directory/web-mcp/drive-fallback-page.py" \
        --origin "$router_origin" --broker "$broker_origin" \
        --model "$model_id" --lane code \
        --api-key-file "$api_key_file" \
        --prompt 'Update the declared value fixture as planned.' \
        >"$output_directory/page-report.json" 2>"$output_directory/page.err"; then
        python3 - "$output_directory/page-report.json" "$router_origin" \
            "$broker_origin" <<'EOF' >>"$summary.page" || :
import json, sys
report = json.load(open(sys.argv[1]))
router, broker = sys.argv[2], sys.argv[3]
def check(name, ok, detail=""):
    print("%s\t%s\t%s" % (name, "accepted" if ok else "refused", detail))
dialog = report.get("dialog") or {}
apply_dialog = report.get("apply_dialog") or {}
card = report.get("code_card") or {}
check("page_plan_dialog_shown",
      "coding plan" in str(dialog.get("heading", "")),
      str(dialog.get("heading")))
check("page_apply_dialog_shows_plan_hash",
      "edit phase" in str(apply_dialog.get("heading", ""))
      and len(str((apply_dialog.get("args") or {}).get("plan sha256", ""))) == 64,
      json.dumps(apply_dialog.get("args")))
check("page_job_finished_with_export_identity",
      str(card.get("status", "")).startswith("finished: export"),
      str(card.get("status")))
origins = {request.get("url", "").split("/", 3)[2]
           for request in report.get("requests", [])
           if str(request.get("url", "")).startswith("http")}
allowed = {router.split("//", 1)[1], broker.split("//", 1)[1]}
check("page_requests_stay_on_admitted_origins",
      origins <= allowed, ",".join(sorted(origins - allowed)))
transcript = json.dumps(report.get("history", []))
check("page_transcript_carries_no_grant",
      '"signature"' not in transcript and '"nonce"' not in transcript)
EOF
        while IFS="$(printf '\t')" read -r name result detail; do
            record "$name" "$result" "$detail"
        done <"$summary.page"
    else
        record coding_page_arm refused \
            "$(tail -3 "$output_directory/page.err" | tr '\n\t' '; ')"
    fi
else
    record coding_page_arm not-run 'chromium absent or page arm disabled'
fi

# -- teardown proves absence ----------------------------------------------
kill "$service_pid" 2>/dev/null || :
wait "$service_pid" 2>/dev/null || :
service_pid=''
if [ -S "$service_socket" ]; then
    record coding_socket_removed_on_teardown refused "$service_socket"
else
    record coding_socket_removed_on_teardown accepted
fi
worktree_residue=$(find "$principal_home/worktrees" -mindepth 1 -maxdepth 1 \
    2>/dev/null | head -1 || :)
if [ -n "$worktree_residue" ]; then
    record coding_worktree_absent refused "$worktree_residue"
else
    record coding_worktree_absent accepted
fi
handoff_residue=$(find "$principal_home/handoff" "$output_directory/bundles" \
    -mindepth 1 -type f 2>/dev/null | head -1 || :)
if [ -n "$handoff_residue" ]; then
    record coding_transfer_residue_absent refused "$handoff_residue"
else
    record coding_transfer_residue_absent accepted
fi
if [ "$(git -C "$workspace_repo" for-each-ref refs/coding-export | wc -l)" -eq 0 ]; then
    record coding_export_ref_absent accepted
else
    record coding_export_ref_absent refused leftover
fi
mirror=$principal_home/repos/coding-admission.git
if [ -d "$mirror" ] &&
    [ "$(git -C "$mirror" for-each-ref refs/import 2>/dev/null | wc -l)" -ne 0 ]; then
    record coding_import_ref_absent refused leftover
else
    record coding_import_ref_absent accepted
fi
head_after=$(git -C "$workspace_repo" rev-parse HEAD)
if [ "$head_after" = "$head_before" ]; then
    record coding_authoritative_head_unchanged accepted "$head_after"
else
    record coding_authoritative_head_unchanged refused \
        "$head_before -> $head_after"
fi
digest_after=$(tree_digest "$workspace_repo")
if [ "$digest_after" = "$digest_before" ] &&
    [ -z "$(git -C "$workspace_repo" status --porcelain)" ]; then
    record coding_authoritative_tree_byte_identical accepted "$digest_after"
else
    record coding_authoritative_tree_byte_identical refused \
        "$digest_before -> $digest_after"
fi

if [ "$failures" -eq 0 ]; then
    printf 'coding_chain_admission=accepted checks=%s\n' \
        "$(wc -l <"$summary")"
    exit 0
fi
printf 'coding_chain_admission=rejected failures=%s\n' "$failures" >&2
exit 1
