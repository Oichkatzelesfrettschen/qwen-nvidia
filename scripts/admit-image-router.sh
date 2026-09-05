#!/bin/sh
set -eu

# gpu-ownership: delegated to the serving chain.
# This harness reaches the device only through qwen-launch.sh and qwen-image-launch.sh, and
# qwen-webui-control.sh puts a tmux boundary between itself and
# qwen-webui-session.sh. tmux starts a session from its own server process, so no
# descriptor this harness opens reaches the capacity server on the far side.
# run-qwen-capacity-server.sh takes the campaign lock there instead, and a claim
# held here would refuse the very session this harness launches.

# Admit one approved image generation through the router: the router child, the
# approval broker, the image MCP child, image-service.py, and the pinned image
# runtime all execute, and every request the page would make runs with curl in
# its place on the router port and the artifact listener alone. The harness owns
# one outage: it records the ordinary router, tears it down, launches one
# validator-gated image profile from a ledger it writes itself, drives every
# boundary of the merged image path, tears the test session down, proves absence
# through image-teardown-check.sh, and restores the ordinary router. The
# checked-in scripts/image-profiles.tsv is read and never written; the test
# ledger lives under OUTPUT_DIR and names one profile at the evidence path this
# run produces.
#
# The run exercises what the browser page does, in the order the page does it.
# `GET /tools?model=` composes the tool list, the broker's /session and
# /grant-image sign one grant over the seed this script chose rather than one
# the runtime picks, `POST /tools` carrying the top-level model key spends it,
# and the completed reply names a digest and a provenance route rather than
# image bytes. Each refusal the design rests on is provoked once -- a replayed
# grant, a call carrying no grant, an argument outside the tool's schema, a
# grant naming another image profile, an artifact read without the credential --
# and the artifact is then read twice, as PNG bytes whose SHA-256 is compared
# with the reported digest and as the provenance record naming the seed and the
# profile that produced them. The page itself then runs the same turn in
# headless Chromium through scripts/web-mcp/drive-fallback-page.py.
#
# Every check lands in OUTPUT_DIR/summary.tsv as `check<TAB>result<TAB>detail`
# and prints as `name=accepted` or `name=refused` with its reason. The run exits
# non-zero when a required check fails, and the restoration of the ordinary
# router runs on every exit path once the teardown has begun.
#
# usage: admit-image-router.sh OUTPUT_DIR
#   QWEN_ADMISSION_MODEL_ID       registry row to serve, default qwen38-2b-distill
#   QWEN_ADMISSION_PROFILE        language profile id, default web-image-admission
#   QWEN_ADMISSION_IMAGE_PROFILE  image profile id, default image-sdxs-512-a
#   QWEN_ADMISSION_REVIEW_MODEL   vision model id the promoted row pairs; `-` skips the review arm
#   QWEN_ADMISSION_CONTEXT        depth the language profile requests, default 4096
#   QWEN_IMAGE_RUNTIME            image runtime binary the profile spawns
#   QWEN_IMAGE_RUNTIME_TEMPLATE   sd-cli or fixture; the argv template that binary reads
#   QWEN_IMAGE_MODEL_PATH         the bundle directory the runtime loads
#   QWEN_IMAGE_TAESD_PATH         the Tiny AutoEncoder the sd-cli template names
#   QWEN_SERVER_PORT              router port, default 8080
#   QWEN_WEB_BROKER_PORT          broker port, default 8571
#   QWEN_ADMISSION_RESTORE        0 leaves the appliance down after the run

if [ "$#" -ne 1 ]; then
    printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
    exit 2
fi

output_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
model_id=${QWEN_ADMISSION_MODEL_ID:-qwen38-2b-distill}
profile_id=${QWEN_ADMISSION_PROFILE:-web-image-admission}
image_profile_id=${QWEN_ADMISSION_IMAGE_PROFILE:-image-sdxs-512-a}
# build-web-presets.sh writes the image MCP server under the key `image`, and
# llama-server serves each wrapped tool as `<server>_<tool>`: server_mcp_tool
# sets name = server_name + "_" + tool_name (tools/server/server-tools.cpp:1814)
# and the listing composes the same string (:2046), so the child's own
# `generate_image` is served as `image_generate_image`. find_tool matches that
# composed name alone (:1935) and answers any other string at 404 (:2163),
# while the child receives the bare name back (:1838). The composition happens
# once here, so the listing expectation, the call body, and the browser-log
# check read one string.
image_mcp_server_name=${QWEN_ADMISSION_IMAGE_MCP_SERVER:-image}
image_mcp_tool_name=generate_image
image_tool_name=${image_mcp_server_name}_${image_mcp_tool_name}
context=${QWEN_ADMISSION_CONTEXT:-4096}
server_port=${QWEN_SERVER_PORT:-8080}
broker_port=${QWEN_WEB_BROKER_PORT:-8571}
restore=${QWEN_ADMISSION_RESTORE:-1}
registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"$HOME/qwen-webui-state"}
source_image_ledger=${QWEN_IMAGE_PROFILES:-$script_directory/image-profiles.tsv}

# One admission owns the appliance at a time, for the reason
# admit-web-router-fake.sh states: the run tears the ordinary router down and
# launches its own, and a second run started meanwhile would tear the first's
# session down as if it were its own. flock(1) holds the claim for as long as
# the run lives and the kernel releases it with the process, so no stale claim
# can exist. --close drops the locked descriptor before the run starts, so the
# servers the run launches inherit no lock.
admission_lock=$state_directory/image-admission.lock
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

router_origin=http://127.0.0.1:$server_port
broker_origin=http://127.0.0.1:$broker_port
generation_prompt=${QWEN_ADMISSION_PROMPT:-'a fox in a snowy field'}
generation_seed=${QWEN_ADMISSION_SEED:-20260829}

for tool in python3 curl jq sha256sum ss pgrep flock; do
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
        accepted | observed | skipped) ;;
        *) failures=$((failures + 1)) ;;
    esac
}
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Every request the page would make is retained as a numbered pair, request body
# beside response body, so a failed check names the exchange.
mkdir -p "$output_directory/http" "$output_directory/keys"
chmod 700 "$output_directory/http" "$output_directory/keys"
api_key_curl_config=$output_directory/keys/api-key.curl
api_key_bytes=''
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
    # The session mints a bearer API key the router, the broker's /session
    # route, and the artifact listener all demand, so every request carries it
    # the way the page's authHeaders() does. The key reaches curl through a
    # config file rather than argv.
    if [ -s "$api_key_curl_config" ] && [ "${call_without_key:-0}" != 1 ]; then
        set -- "$@" --config "$api_key_curl_config"
    fi
    if [ -n "$call_body" ]; then
        printf '%s' "$call_body" >"$output_directory/http/$exchange-$call_label.request"
        curl -sS --max-time 700 -o "$call_out" -D "$call_headers_file" \
            -X "$call_method" "$call_url" -H 'Content-Type: application/json' \
            --data-binary "@$output_directory/http/$exchange-$call_label.request" \
            "$@" || true
    else
        curl -sS --max-time 120 -o "$call_out" -D "$call_headers_file" \
            -X "$call_method" "$call_url" "$@" || true
    fi
    call_status=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$call_headers_file" 2>/dev/null | tail -1)
    call_status=${call_status:-000}
}
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
    ordinary_server=$(readlink -f "/proc/$(pgrep -x llama-server | head -1)/exe")
else
    ordinary_server=${QWEN_LLAMA_SERVER:-"$HOME/src/llama.cpp-qwen-nvidia/build-appliance-current/bin/llama-server"}
    [ -x "$ordinary_server" ] || \
        ordinary_server=$HOME/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-server
fi
record ordinary_router_recorded accepted "running=$ordinary_running server=$ordinary_server"

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
        record ordinary_restore accepted 'the ordinary router serves again'
    else
        record ordinary_restore refused "$(tail -1 "$output_directory/ordinary-restore.log")"
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
        record ordinary_teardown accepted 'no residue'
    else
        record ordinary_teardown refused "$(tail -1 "$output_directory/ordinary-teardown.log")"
        exit 1
    fi
fi

# 2. Test inputs: signing key, one-row image ledger, one-row web ledger, the
# validated profile parameters, and the generated preset.
token_key_file=$output_directory/keys/token.key
if [ ! -s "$token_key_file" ]; then
    python3 -c 'import secrets; print(secrets.token_hex(32))' >"$token_key_file"
fi
chmod 600 "$token_key_file"
# image-service.py names its own control socket, pid file, and artifact
# directory under `<state directory>/images`, so the emitted MCP configuration
# names that directory rather than one of the harness's choosing: a socket the
# generator invents reaches no listener.
image_state_directory=$state_directory/images
image_socket=$image_state_directory/image-service.sock
mkdir -p "$image_state_directory"
chmod 700 "$image_state_directory"

# The image ledger is the checked-in file with one row's execution_policy set
# to validator-gated and its validated_evidence set to this run's own record.
# Every other row and every other field is copied, so the run measures the
# shipped shape rather than a fabricated one, and the shipped file is read
# rather than written. image-registry.sh requires validated_evidence to name a
# path that exists in the tree, so the promoted row names one.
image_ledger=$output_directory/image-profiles.tsv
image_evidence=${QWEN_ADMISSION_IMAGE_EVIDENCE:-evidence/image-appliance/design.md}
if [ ! -e "$script_directory/../$image_evidence" ]; then
    printf 'the promoted row names %s, which is absent from the tree\n' \
        "$image_evidence" >&2
    restore_ordinary
    exit 2
fi
# review_model is set in the run's own copy rather than in the shipped ledger,
# because the pair it names has to fit the Vulkan budget of the machine the run
# happens on and the checked-in row states no such measurement. A `-` leaves
# the preset one section and the review arm reports itself skipped.
review_model=${QWEN_ADMISSION_REVIEW_MODEL:--}
awk -F'\t' -v OFS='\t' -v promoted="$image_profile_id" -v evidence="$image_evidence" \
    -v reviewer="$review_model" '
    /^#/ { print; next }
    $1 == promoted { $12 = "validator-gated"; $13 = evidence; $14 = reviewer }
    { print }
' "$source_image_ledger" >"$image_ledger"
if ! grep -q "^$image_profile_id	.*	validator-gated	$image_evidence	$review_model\$" "$image_ledger"; then
    record image_ledger_promoted refused "$image_profile_id is absent from $source_image_ledger"
    restore_ordinary
    exit 1
fi
record image_ledger_promoted accepted "$image_profile_id validator-gated review_model=$review_model in $image_ledger"

image_field() {
    awk -F'\t' -v id="$image_profile_id" -v column="$1" \
        '$1 == id { print $column }' "$image_ledger"
}
image_width=$(image_field 4)
image_height=$(image_field 5)
image_steps=$(image_field 6)
image_sampler=$(image_field 7)
image_cfg=$(image_field 8)
image_max_steps=$(image_field 9)
image_max_dimension=$(image_field 10)
image_timeout=$(image_field 11)
image_model_id=$(image_field 2)
image_placement=$(image_field 3)

# The language profile carries ui-mediated: the turn under test reaches the
# device rather than the network, so the section emits the image server alone
# and the run offers the model no network-reaching surface at all.
registry_row=$(grep -v '^#' "$registry" | awk -F'\t' -v id="$model_id" '$1 == id')
if [ -z "$registry_row" ]; then
    printf 'model %s is absent from %s\n' "$model_id" "$registry" >&2
    restore_ordinary
    exit 2
fi
validated_depth=$(printf '%s\n' "$registry_row" | cut -f19)
# The launcher's own model path is a control-path input that never reaches the
# router argv, and qwen-launch.sh still resolves and joins it to the registry
# before it starts anything, so the run names the row it serves rather than the
# tree's default checkpoint.
control_model_path=${QWEN_MODEL_PATH:-$model_root/$(printf '%s\n' "$registry_row" | cut -f3)}
projector=$(printf '%s\n' "$registry_row" | cut -f11)
tool_selection=$(printf '%s\n' "$registry_row" | cut -f21)
case $projector in
    none) vision_allowed=no ;;
    *) vision_allowed=yes ;;
esac
web_ledger=$output_directory/web-profiles.tsv
printf '# profile_id\tmodel_id\tweb_mode\tcontext\tvalidated_filled_depth\tmax_results\tmax_fetches\tmax_chars_per_fetch\tmulti_source\tvision_allowed\ttool_selection\texecution_policy\tprovider\tprimary_category\tfallback_category\tminimum_results\tsearxng_url\n' >"$web_ledger"
printf '%s\t%s\tui-mediated\t%s\t%s\t3\t1\t12000\tno\t%s\t%s\tui-mediated\tfake\t-\t-\t-\t-\n' \
    "$profile_id" "$model_id" "$context" "$validated_depth" "$vision_allowed" \
    "$tool_selection" >>"$web_ledger"

# The runtime and its argv template travel together. sd-cli reads -W, -H, -p,
# -o, --sampling-method, --cfg-scale, and --taesd; the fixture reads --width,
# --height, --prompt, --output, --sampler, and --cfg. A path swapped without
# its template reaches the runtime as an argument error, which reads as a
# service defect rather than as the configuration mistake it is.
image_runtime=${QWEN_IMAGE_RUNTIME:-"$HOME/src/stable-diffusion.cpp-qwen-nvidia/build-cuda-sm89/bin/sd-cli"}
# The device the runtime's --backend names. sd-cli resolves module placement
# through that flag and refuses a name that does not resolve, so the name is
# the CUDA device on this host and a Vulkan name reaches only a hand-run
# diagnostic build.
image_backend=${QWEN_IMAGE_BACKEND:-cuda0}
case $image_backend in
    cuda[0-9]* | vulkan[0-9]*) ;;
    *) printf 'QWEN_IMAGE_BACKEND names a cudaN or vulkanN device: %s\n' "$image_backend" >&2; restore_ordinary; exit 2 ;;
esac
case ${QWEN_IMAGE_RUNTIME_TEMPLATE:-} in
    sd-cli | fixture) runtime_template=$QWEN_IMAGE_RUNTIME_TEMPLATE ;;
    '')
        case $(basename -- "$image_runtime") in
            fake-image-runtime.sh) runtime_template=fixture ;;
            *) runtime_template=sd-cli ;;
        esac
        ;;
    *)
        printf 'QWEN_IMAGE_RUNTIME_TEMPLATE takes sd-cli or fixture: %s\n' \
            "$QWEN_IMAGE_RUNTIME_TEMPLATE" >&2
        restore_ordinary
        exit 2
        ;;
esac
image_model_path=${QWEN_IMAGE_MODEL_PATH:-"$HOME/models/image/sdxs-512"}
image_taesd_path=${QWEN_IMAGE_TAESD_PATH:-"$image_model_path/vae/diffusion_pytorch_model.safetensors"}
if [ ! -x "$image_runtime" ]; then
    record image_runtime_present refused "$image_runtime is absent or not executable"
    restore_ordinary
    exit 1
fi
record image_runtime_present accepted "$image_runtime template=$runtime_template backend=$image_backend"

image_parameters=$output_directory/image-parameters.json
QWEN_ADMISSION_TEMPLATE=$runtime_template \
QWEN_ADMISSION_PARAMETERS=$image_parameters \
QWEN_ADMISSION_IMAGE_PROFILE_ID=$image_profile_id \
QWEN_ADMISSION_IMAGE_MODEL_ID=$image_model_id \
QWEN_ADMISSION_IMAGE_PLACEMENT=$image_placement \
QWEN_ADMISSION_IMAGE_WIDTH=$image_width \
QWEN_ADMISSION_IMAGE_HEIGHT=$image_height \
QWEN_ADMISSION_IMAGE_STEPS=$image_steps \
QWEN_ADMISSION_IMAGE_SAMPLER=$image_sampler \
QWEN_ADMISSION_IMAGE_CFG=$image_cfg \
QWEN_ADMISSION_IMAGE_MAX_STEPS=$image_max_steps \
QWEN_ADMISSION_IMAGE_MAX_DIMENSION=$image_max_dimension \
QWEN_ADMISSION_IMAGE_TIMEOUT=$image_timeout \
QWEN_ADMISSION_RUNTIME_PATH=$image_runtime \
QWEN_ADMISSION_IMAGE_BACKEND=$image_backend \
QWEN_ADMISSION_MODEL_DIRECTORY=$image_model_path \
QWEN_ADMISSION_TAESD_PATH=$image_taesd_path \
python3 - <<'PY'
import json
import os

template = os.environ["QWEN_ADMISSION_TEMPLATE"]
model_directory = os.environ["QWEN_ADMISSION_MODEL_DIRECTORY"]
if template == "sd-cli":
    # The argv evidence/image-appliance records for the pinned binary, with the
    # service's own substitution tokens in place of the measured values.
    argv = [
        "--model", "{model_path}",
        "--taesd", os.environ["QWEN_ADMISSION_TAESD_PATH"],
        "--backend", os.environ["QWEN_ADMISSION_IMAGE_BACKEND"],
        "-W", "{width}", "-H", "{height}",
        "--steps", "{steps}",
        "--sampling-method", "{sampler}",
        "--cfg-scale", "{cfg}",
        "--seed", "{seed}",
        "-p", "{prompt}",
        # evidence/image-appliance/stable-diffusion-cpp-pin.md names -n at
        # lines 930-934 of the pinned source. The grant binds
        # negative_prompt_hash and the provenance record retains it, so a
        # template that dropped the text would authorize and record a
        # constraint the runtime never read.
        "-n", "{negative_prompt}",
        "-o", "{output}",
    ]
else:
    argv = [
        "--output", "{output}",
        "--width", "{width}", "--height", "{height}",
        "--seed", "{seed}", "--steps", "{steps}",
        "--sampler", "{sampler}", "--cfg", "{cfg}",
        "--prompt", "{prompt}", "--negative-prompt", "{negative_prompt}",
        "--model", "{model_path}",
        "--backend", os.environ["QWEN_ADMISSION_IMAGE_BACKEND"],
    ]
parameters = {
    os.environ["QWEN_ADMISSION_IMAGE_PROFILE_ID"]: {
        "profile_id": os.environ["QWEN_ADMISSION_IMAGE_PROFILE_ID"],
        "model_id": os.environ["QWEN_ADMISSION_IMAGE_MODEL_ID"],
        "placement": os.environ["QWEN_ADMISSION_IMAGE_PLACEMENT"],
        "width": int(os.environ["QWEN_ADMISSION_IMAGE_WIDTH"]),
        "height": int(os.environ["QWEN_ADMISSION_IMAGE_HEIGHT"]),
        "steps": int(os.environ["QWEN_ADMISSION_IMAGE_STEPS"]),
        "sampler": os.environ["QWEN_ADMISSION_IMAGE_SAMPLER"],
        "cfg": float(os.environ["QWEN_ADMISSION_IMAGE_CFG"]),
        "max_steps": int(os.environ["QWEN_ADMISSION_IMAGE_MAX_STEPS"]),
        "max_dimension": int(os.environ["QWEN_ADMISSION_IMAGE_MAX_DIMENSION"]),
        "timeout_s": int(os.environ["QWEN_ADMISSION_IMAGE_TIMEOUT"]),
        "execution_policy": "validator-gated",
        "runtime_path": os.environ["QWEN_ADMISSION_RUNTIME_PATH"],
        "runtime_argv": argv,
        "model_path": model_directory,
    }
}
with open(os.environ["QWEN_ADMISSION_PARAMETERS"], "w", encoding="utf-8") as handle:
    json.dump(parameters, handle, indent=1, sort_keys=True)
    handle.write("\n")
PY
record image_parameters_written accepted "template=$runtime_template runtime=$image_runtime"

web_presets=$output_directory/web-presets.ini
if QWEN_WEB_PROFILES=$web_ledger QWEN_WEB_MCP_SERVER=$script_directory/web-mcp/server.py \
    QWEN_WEB_PROVIDER=fake QWEN_WEB_TOKEN_KEY_FILE=$token_key_file \
    QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_IMAGE_PROFILES=$image_ledger \
    QWEN_IMAGE_MCP_SERVER=$script_directory/image-mcp/server.py \
    QWEN_IMAGE_TOKEN_KEY_FILE=$token_key_file \
    QWEN_IMAGE_STATE_DIR=$image_state_directory \
    QWEN_IMAGE_SERVICE_SOCKET=$image_socket \
    QWEN_IMAGE_PROFILES_JSON=$image_parameters \
    QWEN_WEB_AUTHORIZER_READY=1 QWEN_MODEL_REGISTRY=$registry QWEN_MODEL_ROOT=$model_root \
    "$script_directory/build-web-presets.sh" "$web_presets" \
    >"$output_directory/build-web-presets.log" 2>&1; then
    preset_image_profile=$(sed -n 's/^# qwen_image_profile=//p' "$web_presets")
    if [ "$preset_image_profile" = "$image_profile_id" ]; then
        record preset_generated accepted "image_profile=$preset_image_profile sections=$(grep -c '^\[' "$web_presets")"
    else
        record preset_generated refused "the preset names image profile ${preset_image_profile:-none}"
        restore_ordinary
        exit 1
    fi
else
    record preset_generated refused "$(tail -1 "$output_directory/build-web-presets.log")"
    restore_ordinary
    exit 1
fi

# 3. Launch the image router.
if QWEN_WEB_PRESETS=$web_presets QWEN_WEB_PROFILES=$web_ledger QWEN_WEB_PROVIDER=fake \
    QWEN_WEB_TOKEN_KEY_FILE=$token_key_file QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_WEB_BROKER_PORT=$broker_port QWEN_WEB_AUTHORIZER_READY=1 \
    QWEN_IMAGE_PROFILES_JSON=$image_parameters QWEN_MODEL_REGISTRY=$registry \
    QWEN_MODEL_ROOT=$model_root QWEN_MODEL_PATH=$control_model_path \
    "$script_directory/qwen-image-launch.sh" default \
    >"$output_directory/image-launch.log" 2>&1; then
    record image_launch accepted "$(grep '^image_launch timeouts' "$output_directory/image-launch.log" | tr '\n' ';')"
else
    record image_launch refused "$(tail -3 "$output_directory/image-launch.log" | tr '\n' ';')"
    cp "$state_directory/session.status" "$output_directory/failed-session.status" 2>/dev/null || true
    cp "$state_directory/image-service.log" "$output_directory/failed-image-service.log" 2>/dev/null || true
    cp "$state_directory/authorize-broker.log" "$output_directory/failed-broker.log" 2>/dev/null || true
    cp "$state_directory/server.log" "$output_directory/failed-server.log" 2>/dev/null || true
    restore_ordinary
    exit 1
fi
cp "$state_directory/session.status" "$output_directory/image-session.status"
broker_pid=$(sed -n '1p' "$output_directory/image-session.status" | tr ' ' '\n' | sed -n 's/^broker_pid=//p')
image_service_pid=$(sed -n '1p' "$output_directory/image-session.status" | tr ' ' '\n' | sed -n 's/^image_service_pid=//p')
secret_file=$(sed -n 's/^broker secret_file=//p' "$output_directory/image-session.status")
# The artifact listener binds an ephemeral port, so its address is read from the
# line the session recorded rather than assumed.
artifact_listener=$(sed -n 's/^image_service_identity .*listener=//p' "$output_directory/image-session.status" | sed -n '1p')
artifact_origin=http://$artifact_listener
case $artifact_listener in
    127.0.0.1:[0-9]*)
        record artifact_listener_loopback accepted "$artifact_listener"
        ;;
    *)
        record artifact_listener_loopback refused "listener=${artifact_listener:-absent}"
        ;;
esac
case $image_service_pid in
    '' | *[!0-9]*) record image_service_recorded refused "image_service_pid=${image_service_pid:-absent}" ;;
    *) record image_service_recorded accepted "image_service_pid=$image_service_pid" ;;
esac
router_listener=$(ss -ltnp 2>/dev/null | grep ":$server_port " | grep -o '[0-9.:*]*:'"$server_port" | sort -u | tr '\n' ',')
case $router_listener in
    "127.0.0.1:$server_port,") record router_listener_loopback accepted "$router_listener" ;;
    *) record router_listener_loopback refused "${router_listener:-absent}" ;;
esac

api_key_file=$state_directory/api.key
if [ -s "$api_key_file" ] && [ "$(stat -c %a "$api_key_file")" = 600 ]; then
    api_key_bytes=$(sed -n '1p' "$api_key_file")
    printf 'header = "Authorization: Bearer %s"\n' "$api_key_bytes" >"$api_key_curl_config"
    chmod 600 "$api_key_curl_config"
    record api_key_minted accepted "mode=600 path=$api_key_file"
else
    record api_key_minted refused "absent, empty, or not 0600: $api_key_file"
fi

# 4. The router roster and the one tool the section carries, read on the router
# port. The router resolves the model of GET /tools from the query string the
# way it resolves /props, and forwards to the child that read the section's own
# MCP configuration.
call models GET "$router_origin/v1/models"
model_ids=$(jq -r '.data[].id' "$call_out" 2>/dev/null | tr '\n' ',')
if [ "$review_model" = '-' ]; then
    expected_roster=$profile_id,
else
    expected_roster=$profile_id,$review_model,
fi
# The real router lists /v1/models sorted rather than in preset section order,
# so the roster is compared as a set -- every expected id present and no
# unexpected id, order ignored -- and the measured order is recorded rather
# than asserted, since it is a router property this check does not test.
expected_set=$(printf '%s\n' "$expected_roster" | tr ',' '\n' | awk 'NF' | LC_ALL=C sort -u)
measured_set=$(printf '%s\n' "$model_ids" | tr ',' '\n' | awk 'NF' | LC_ALL=C sort -u)
if [ "$expected_set" = "$measured_set" ]; then
    record router_roster accepted "measured_order=${model_ids:-none}"
else
    record router_roster refused "expected=$expected_roster measured=${model_ids:-none}"
fi
# The Review button appears where some roster row reports a vision modality, so
# the page's own discriminator is read here before the browser runs.
if [ "$review_model" != '-' ]; then
    call review-props GET "$router_origin/props?model=$review_model"
    if [ "$(jq -r '.modalities.vision // false' "$call_out" 2>/dev/null)" = true ]; then
        record review_row_reports_vision accepted "$review_model"
    else
        record review_row_reports_vision refused "status=$call_status $(head -c 200 "$call_out")"
    fi
    # A reviewer holds no execution grant, so the route that serves a tool set
    # answers the way the binary answers a model carrying none.
    call review-tools GET "$router_origin/tools?model=$review_model&autoload=true"
    if [ "$call_status" != 200 ]; then
        record review_row_offers_no_tools accepted "status=$call_status"
    else
        record review_row_offers_no_tools refused "status=$call_status $(head -c 200 "$call_out")"
    fi
else
    record review_row_reports_vision skipped 'the promoted row pairs no review_model'
fi
call tools GET "$router_origin/tools?model=$profile_id&autoload=true"
cp "$call_out" "$output_directory/tools.json"
tool_names=$(jq -r '.[].tool' "$call_out" 2>/dev/null | sort | tr '\n' ',')
if [ "$tool_names" = "$image_tool_name," ]; then
    record tool_enumeration accepted "$tool_names via $router_origin"
else
    record tool_enumeration refused "status=$call_status tools=${tool_names:-none}"
fi
# A ui-mediated language profile emits no web server, so the section offers the
# generation tool alone and this turn reaches no network surface.
if ! jq -e 'map(.tool) | index("web_search_exa")' "$output_directory/tools.json" >/dev/null 2>&1; then
    record web_tools_absent accepted 'the ui-mediated section emits the image server alone'
else
    record web_tools_absent refused 'the section carries a network-reaching tool'
fi
call tools-unknown-model GET "$router_origin/tools?model=no-such-model&autoload=true"
if [ "$call_status" != 200 ]; then
    record tools_unknown_model_refused accepted "status=$call_status"
else
    record tools_unknown_model_refused refused "status=$call_status"
fi

# 5. The broker session and one grant, signed over the seed this script chose.
# The seed is the field the protocol requires and the runtime never picks, so
# the grant binds a value decided before the approval rather than after it.
call broker-health GET "$broker_origin/health" '' -H "Host: 127.0.0.1:$broker_port"
health_image_profile=$(jq -r '.image_profile // empty' "$call_out" 2>/dev/null)
if [ "$health_image_profile" = "$image_profile_id" ]; then
    record broker_signs_image_profile accepted "image_profile=$health_image_profile"
else
    record broker_signs_image_profile refused "image_profile=${health_image_profile:-none}"
fi
call session GET "$broker_origin/session" '' -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port"
session_secret=$(jq -r '.session_secret // empty' "$call_out" 2>/dev/null)
if [ "$call_status" = 200 ] && [ -n "$session_secret" ]; then
    record session_secret_issued accepted "status=$call_status"
else
    record session_secret_issued refused "status=$call_status"
fi

prompt_hash=$(printf '%s' "$generation_prompt" | sha256sum | cut -c1-64)
empty_hash=$(printf '' | sha256sum | cut -c1-64)
grant_body=$(jq -cn --arg language "$profile_id" --arg image "$image_profile_id" \
    --arg prompt "$prompt_hash" --arg negative "$empty_hash" \
    --argjson seed "$generation_seed" --argjson dimension "$image_max_dimension" \
    --argjson steps "$image_steps" \
    '{context: "qwen-image-generate-v1", language_profile: $language,
      image_profile: $image, prompt_hash: $prompt, negative_prompt_hash: $negative,
      seed: $seed, aspect: "1:1", max_dimension: $dimension, max_steps: $steps,
      conversation_generation: 0}')
issue_grant() {
    call "$1" POST "$broker_origin/grant-image" "$grant_body" -H "Origin: $router_origin" \
        -H "Host: 127.0.0.1:$broker_port" -H "X-Qwen-Web-Session: $session_secret"
    issued_authorization=$(jq -r '.authorization // empty' "$call_out" 2>/dev/null)
}
issue_grant grant-image
authorization=$issued_authorization
if [ "$call_status" = 200 ] && [ -n "$authorization" ]; then
    record grant_issued accepted "status=$call_status seed=$generation_seed bytes=${#authorization}"
else
    record grant_issued refused "status=$call_status $(head -c 160 "$call_out")"
fi
foreign_grant_body=$(printf '%s' "$grant_body" | jq -c '.image_profile = "image-other"')
call grant-wrong-image-profile POST "$broker_origin/grant-image" "$foreign_grant_body" \
    -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port" \
    -H "X-Qwen-Web-Session: $session_secret"
if [ "$call_status" != 200 ]; then
    record grant_wrong_image_profile_refused accepted "status=$call_status"
else
    record grant_wrong_image_profile_refused refused "status=$call_status"
fi

# 6. One generation, through the router, the MCP child, the service, the lease,
# and the runtime. The body carries the model key the router reads and the
# grant inside params, which is where the page puts it.
tool_body() {
    jq -cn --arg m "$profile_id" --argjson p "$1" \
        --arg t "$image_tool_name" \
        '{model: $m, tool: $t, params: $p, stream: false}'
}
generation_params=$(jq -cn --arg prompt "$generation_prompt" --arg profile "$image_profile_id" \
    --arg grant "$authorization" --argjson seed "$generation_seed" \
    --argjson width "$image_width" --argjson height "$image_height" \
    --argjson steps "$image_steps" \
    '{prompt: $prompt, negative_prompt: "", seed: $seed, width: $width,
      height: $height, steps: $steps, profile_id: $profile, authorization: $grant}')
generation_started=$(date +%s)
call generate POST "$router_origin/tools" "$(tool_body "$generation_params")"
generation_elapsed=$(( $(date +%s) - generation_started ))
cp "$call_out" "$output_directory/generate-response.json"
generation_text=$(jq -r '.plain_text_response // empty' "$call_out" 2>/dev/null)
artifact_sha256=$(printf '%s' "$generation_text" | jq -r '.sha256 // empty' 2>/dev/null)
provenance_url=$(printf '%s' "$generation_text" | jq -r '.provenance_url // empty' 2>/dev/null)
generation_status=$(printf '%s' "$generation_text" | jq -r '.status // empty' 2>/dev/null)
if [ "$call_status" = 200 ] && [ "$generation_status" = completed ] && \
   [ "${#artifact_sha256}" -eq 64 ] && \
   [ "$provenance_url" = "/artifacts/$artifact_sha256.json" ]; then
    record generation_completed accepted "elapsed=${generation_elapsed}s sha256=$artifact_sha256 provenance=$provenance_url"
else
    record generation_completed refused "status=$call_status elapsed=${generation_elapsed}s $(head -c 200 "$call_out")"
fi
# The transcript keeps the identity and the route alone; the runtime's bytes
# reach no reply the model or the page reads.
if [ -n "$generation_text" ] && \
   [ "$(printf '%s' "$generation_text" | jq -r 'keys | join(",")' 2>/dev/null)" = 'provenance_url,sha256,status' ]; then
    record result_carries_identity_alone accepted 'status, sha256, and provenance_url'
else
    record result_carries_identity_alone refused "$(printf '%s' "$generation_text" | head -c 160)"
fi

call generate-replay POST "$router_origin/tools" "$(tool_body "$generation_params")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record grant_replay_refused accepted "$(jq -r '.error' "$call_out" | head -c 140)"
else
    record grant_replay_refused refused "status=$call_status $(head -c 160 "$call_out")"
fi
ungranted_params=$(printf '%s' "$generation_params" | jq -c 'del(.authorization)')
call generate-no-grant POST "$router_origin/tools" "$(tool_body "$ungranted_params")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1; then
    record generation_without_grant_refused accepted "$(jq -r '.error' "$call_out" | head -c 140)"
else
    record generation_without_grant_refused refused "status=$call_status $(head -c 160 "$call_out")"
fi
# The MCP server refuses an argument outside the tool's schema by name, so the
# generation above, which carried model at the top level, proves the router's
# routing key stayed out of the arguments; the control places the same key
# inside params and is refused naming it.
in_params_body=$(printf '%s' "$ungranted_params" | jq -c --arg m "$profile_id" '. + {model: $m}')
call generate-model-in-params POST "$router_origin/tools" "$(tool_body "$in_params_body")"
if [ "$call_status" = 200 ] && jq -e '.error' "$call_out" >/dev/null 2>&1 && \
   jq -r '.error' "$call_out" | grep -q 'model'; then
    record routing_key_outside_arguments accepted "params.model refused: $(jq -r '.error' "$call_out" | head -c 120)"
else
    record routing_key_outside_arguments refused "status=$call_status $(head -c 160 "$call_out")"
fi

# 7. The artifact, read from the listener that owns it. The bearer check runs
# ahead of the lookup, so the digest identifies an artifact and authenticates
# none, and the bytes are compared with the digest the reply named.
if [ "${#artifact_sha256}" -eq 64 ]; then
    call artifact-png GET "$artifact_origin/artifacts/$artifact_sha256.png"
    artifact_type=$(sed -n 's/^[Cc]ontent-[Tt]ype: *//p' "$call_headers_file" | tr -d '\r' | head -1)
    measured_sha256=$(sha256sum "$call_out" | cut -c1-64)
    cp "$call_out" "$output_directory/artifact.png"
    if [ "$call_status" = 200 ] && [ "$artifact_type" = image/png ] && \
       [ "$measured_sha256" = "$artifact_sha256" ]; then
        record artifact_png_matches_digest accepted "type=$artifact_type bytes=$(wc -c <"$output_directory/artifact.png")"
    else
        record artifact_png_matches_digest refused "status=$call_status type=${artifact_type:-none} measured=$measured_sha256"
    fi
    call_without_key=1 call artifact-no-credential GET "$artifact_origin/artifacts/$artifact_sha256.png"
    if [ "$call_status" = 401 ]; then
        record artifact_without_credential_refused accepted 'status=401'
    else
        record artifact_without_credential_refused refused "status=$call_status"
    fi
    call provenance GET "$artifact_origin$provenance_url"
    cp "$call_out" "$output_directory/provenance.json"
    provenance_seed=$(jq -r '.seed // empty' "$call_out" 2>/dev/null)
    provenance_profile=$(jq -r '.profile_id // empty' "$call_out" 2>/dev/null)
    provenance_png=$(jq -r '.png_sha256 // empty' "$call_out" 2>/dev/null)
    provenance_prompt=$(jq -r '.prompt_sha256 // empty' "$call_out" 2>/dev/null)
    if [ "$call_status" = 200 ] && [ "$provenance_seed" = "$generation_seed" ] && \
       [ "$provenance_profile" = "$image_profile_id" ] && \
       [ "$provenance_png" = "$artifact_sha256" ] && \
       [ "$provenance_prompt" = "$prompt_hash" ]; then
        record provenance_names_seed_and_profile accepted "seed=$provenance_seed profile=$provenance_profile"
    else
        record provenance_names_seed_and_profile refused "status=$call_status seed=${provenance_seed:-none} profile=${provenance_profile:-none}"
    fi
else
    record artifact_png_matches_digest refused 'the generation named no digest'
    record artifact_without_credential_refused refused 'the generation named no digest'
    record provenance_names_seed_and_profile refused 'the generation named no digest'
fi

# The lease spans the job alone, from its start to the artifact rename, so it is
# free again while the service still runs. WorkloadLease.acquire creates the
# lock file on the first job and release() closes the descriptor without
# unlinking it (image-service.py:556-596), so the file exists exactly when a job
# has taken the lease and this check reads that file only after a generation
# completed. Without that precondition an absent file reports the same refusal
# as a held one, which is what a run whose generation never reached the service
# records.
lease_file=$state_directory/vulkan-workload.lock
if [ "$generation_status" != completed ]; then
    record lease_released_after_generation skipped \
        "not run: no generation completed, so no job took the lease at $lease_file"
elif [ ! -e "$lease_file" ]; then
    record lease_released_after_generation refused \
        "the completed job left no lease file: $lease_file"
elif flock -n -E 75 "$lease_file" true; then
    record lease_released_after_generation accepted "$lease_file"
else
    record lease_released_after_generation refused "the lease is still held: $lease_file"
fi

# 8. The browser runs the served page through the same turn, up to
# QWEN_ADMISSION_BROWSER_ATTEMPTS attempts (default 2), because the 4B's
# proposal on an explicit prompt is observed to vary between launches --
# evidence/image-appliance/served-turn-admission/README.md records a
# schema-valid call, and a later appliance run of the same prompt recorded
# prose that named the tool and its arguments as text rather than proposing
# it. Each attempt runs the whole turn in a fresh page -- a new Chromium
# process reached through a new DevTools session, so no state from a failed
# attempt carries into the next -- and its complete report is retained at
# browser-turn-<n>.json whether or not the turn completed. The step accepts
# on the first attempt whose driver process exits 0, which happens only once
# the approval dialog opened, the grant was posted, and the turn ended, and
# refuses after the last attempt with every attempt's reply excerpt. The
# review arm, where armed, runs inside the accepted attempt alone, because a
# review needs a rendered artifact card and a failed attempt left none.
browser_report=$output_directory/browser-turn.json
# A graded comparison between prompts needs the prompt each run actually sent,
# so it is recorded once regardless of whether Chromium runs it.
browser_prompt=${QWEN_ADMISSION_BROWSER_PROMPT:-"Draw $generation_prompt."}
record browser_prompt_used observed "$browser_prompt"
browser_attempts=${QWEN_ADMISSION_BROWSER_ATTEMPTS:-2}
# The driver's own defaults, named explicitly so a caller whose fixture forces
# an early attempt to fail -- a prose reply that opens no dialog, for instance
# -- can shorten the wait rather than a refused attempt costing the full
# dialog timeout before the next one starts.
browser_load_timeout=${QWEN_ADMISSION_BROWSER_LOAD_TIMEOUT:-180}
browser_dialog_timeout=${QWEN_ADMISSION_BROWSER_DIALOG_TIMEOUT:-600}
browser_turn_timeout=${QWEN_ADMISSION_BROWSER_TURN_TIMEOUT:-900}
browser_accepted_attempt=0
browser_attempt_excerpts=''
if command -v chromium >/dev/null 2>&1; then
    browser_review_flag=
    if [ "$review_model" != '-' ]; then
        browser_review_flag=--review
    fi
    browser_attempt=1
    while [ "$browser_attempt" -le "$browser_attempts" ]; do
        attempt_report=$output_directory/browser-turn-$browser_attempt.json
        attempt_err=$output_directory/browser-turn-$browser_attempt.err
        if python3 "$script_directory/web-mcp/drive-fallback-page.py" --lane image \
                --origin "$router_origin" --api-key-file "$api_key_file" \
                --broker "$broker_origin" --artifacts "$artifact_origin" \
                --model "$profile_id" \
                --load-timeout "$browser_load_timeout" \
                --dialog-timeout "$browser_dialog_timeout" \
                --turn-timeout "$browser_turn_timeout" \
                ${browser_review_flag:+"$browser_review_flag"} \
                --prompt "$browser_prompt" >"$attempt_report" 2>"$attempt_err"; then
            attempt_tool_call_proposed=yes
            # A refused earlier attempt is expected behavior the retry budget
            # exists to absorb, not a harness failure, so every per-attempt
            # record reads `observed` and the overall gate is
            # browser_accepted_attempt -- whether any attempt reached a
            # completed turn -- checked below rather than each attempt's own
            # outcome.
            record "browser_attempt_${browser_attempt}_result" observed \
                "completed=yes tool_call_proposed=$attempt_tool_call_proposed"
            browser_accepted_attempt=$browser_attempt
            cp "$attempt_report" "$browser_report"
            break
        fi
        if jq -e . "$attempt_report" >/dev/null 2>&1; then
            attempt_last_assistant=$(jq -c '[.history[] | select(.role == "assistant")] | last // {}' "$attempt_report")
            attempt_last_assistant_text=$(printf '%s' "$attempt_last_assistant" | jq -r '.content // empty' | head -c 200)
            if printf '%s' "$attempt_last_assistant" | jq -e '(.tool_calls // []) | length > 0' >/dev/null 2>&1; then
                attempt_tool_call_proposed=yes
            else
                attempt_tool_call_proposed=no
            fi
            attempt_error_type=$(jq -r '.error.type // empty' "$attempt_report")
            attempt_error_message=$(jq -r '.error.message // empty' "$attempt_report" | head -c 160)
            record "browser_attempt_${browser_attempt}_result" observed \
                "completed=no tool_call_proposed=$attempt_tool_call_proposed error=${attempt_error_type:-none}(${attempt_error_message:-}) reply=$attempt_last_assistant_text"
            browser_attempt_excerpts="$browser_attempt_excerpts attempt=$browser_attempt tool_call_proposed=$attempt_tool_call_proposed reply=$attempt_last_assistant_text;"
        else
            record "browser_attempt_${browser_attempt}_result" observed \
                "completed=no tool_call_proposed=unknown(no report) $(tail -c 400 "$attempt_err" | tr '\n' ' ')"
            browser_attempt_excerpts="$browser_attempt_excerpts attempt=$browser_attempt tool_call_proposed=unknown(no report);"
        fi
        browser_attempt=$((browser_attempt + 1))
    done
    if [ "$browser_accepted_attempt" -gt 0 ]; then
        browser_origin_seen=$(jq -r '.origin // empty' "$browser_report")
        browser_model_seen=$(jq -r '.model // empty' "$browser_report")
        # The driver's own --model selection is what proves the page sent the
        # generation to the language section rather than to whichever roster
        # row a review-only sibling's sort position put first: a page whose
        # picker carried no option for $profile_id would have left the
        # driver's own --model step raising before this report was written.
        if [ "$browser_origin_seen" = "$router_origin" ] && [ "$browser_model_seen" = "$profile_id" ]; then
            record browser_page_origin accepted "origin=$browser_origin_seen model=$browser_model_seen"
        else
            record browser_page_origin refused "origin=${browser_origin_seen:-none} model=${browser_model_seen:-none} expected_model=$profile_id"
        fi
        # Randomness is fixed ahead of the grant rather than after: the dialog
        # names the seed the grant binds, whether the model proposed it or the
        # page generated the one the model omitted. The 4B on the appliance
        # proposes its own seed, so either source is admitted and recorded.
        dialog_seed=$(jq -r '.dialog.args.seed // empty' "$browser_report")
        grant_seed=$(jq -r --arg u "$broker_origin/grant-image" \
            '[.requests[] | select(.method == "POST" and .url == $u)][-1].body
             | if type == "string" then fromjson else . end | .seed // empty' \
            "$browser_report" 2>/dev/null)
        dialog_seed_value=$(printf '%s' "$dialog_seed" | grep -oE '^[0-9]+' || true)
        case $dialog_seed in
            *'generated by this page'*)
                record browser_dialog_names_bound_seed accepted "source=page $dialog_seed"
                ;;
            *)
                if [ -n "$dialog_seed_value" ] && [ "$dialog_seed_value" = "$grant_seed" ]; then
                    record browser_dialog_names_bound_seed accepted "source=model seed=$dialog_seed_value"
                else
                    record browser_dialog_names_bound_seed refused \
                        "dialog=${dialog_seed:-absent} grant=${grant_seed:-absent}"
                fi
                ;;
        esac
        grant_requests=$(jq -r --arg u "$broker_origin/grant-image" \
            '[.requests[] | select(.method == "POST" and .url == $u)] | length' "$browser_report")
        if [ "$grant_requests" -eq 1 ]; then
            record browser_grant_posted_once accepted "POST $broker_origin/grant-image count=1"
        else
            record browser_grant_posted_once refused "count=$grant_requests"
        fi
        generation_post=$(jq -c --arg u "$router_origin/tools" --arg t "$image_tool_name" \
            '[.requests[] | select(.method == "POST" and .url == $u) | (.body | fromjson? // {}) | select(.tool == $t)] | first // empty' \
            "$browser_report")
        if [ -n "$generation_post" ] && \
           [ "$(printf '%s' "$generation_post" | jq -r '.model')" = "$profile_id" ] && \
           [ "$(printf '%s' "$generation_post" | jq -r '.params.profile_id')" = "$image_profile_id" ] && \
           [ "$(printf '%s' "$generation_post" | jq -r '.params.authorization // empty | length')" -gt 0 ]; then
            record browser_generation_via_router accepted "POST /tools model=$profile_id profile_id=$image_profile_id grant=present"
        else
            record browser_generation_via_router refused "$(printf '%s' "$generation_post" | jq -c 'del(.params.authorization)' 2>/dev/null | head -c 300)"
        fi
        off_origin=$(jq -r --arg r "$router_origin/" --arg b "$broker_origin/" --arg a "$artifact_origin/" \
            '[.requests[] | select((.url | startswith($r) | not) and (.url | startswith($b) | not) and (.url | startswith($a) | not))] | length' \
            "$browser_report")
        if [ "$off_origin" -eq 0 ]; then
            record browser_requests_stay_on_known_origins accepted "every page request names $router_origin, $broker_origin, or $artifact_origin"
        else
            record browser_requests_stay_on_known_origins refused "$(jq -c --arg r "$router_origin/" --arg b "$broker_origin/" --arg a "$artifact_origin/" '[.requests[] | select((.url | startswith($r) | not) and (.url | startswith($b) | not) and (.url | startswith($a) | not)) | .url]' "$browser_report" | head -c 300)"
        fi
        browser_artifact_requests=$(jq -r --arg a "$artifact_origin/artifacts/" \
            '[.requests[] | select(.method == "GET" and (.url | startswith($a)))] | length' "$browser_report")
        browser_image_source=$(jq -r '[.imageCards[].src] | first // empty' "$browser_report")
        case $browser_image_source in
            blob:*)
                record browser_artifact_fetched accepted "requests=$browser_artifact_requests src=blob"
                ;;
            *)
                record browser_artifact_fetched refused "requests=$browser_artifact_requests src=${browser_image_source:-none} $(jq -r '[.imageCards[].caption] | first // empty' "$browser_report" | head -c 200)"
                ;;
        esac
        # The retained tool message names the digest and the provenance route
        # and carries neither the grant nor the image bytes.
        tool_message=$(jq -r '[.history[] | select(.role == "tool")] | first | .content // empty' "$browser_report")
        if printf '%s' "$tool_message" | grep -q "sha256 " && \
           printf '%s' "$tool_message" | grep -q 'provenance /artifacts/' && \
           ! printf '%s' "$tool_message" | grep -q 'authorization'; then
            record browser_transcript_carries_identity_alone accepted "$(printf '%s' "$tool_message" | head -c 160)"
        else
            record browser_transcript_carries_identity_alone refused "$(printf '%s' "$tool_message" | head -c 200)"
        fi
        # The review is a second transition through idle: the page reads the
        # artifact again, posts one completion to the vision row, and renders a
        # checklist on the card. The verdict is text a model wrote after reading
        # an image, so the check reads the rendered constraint names and their
        # pass state rather than treating the observation as a claim.
        if [ "$review_model" = '-' ]; then
            record browser_review_rendered skipped 'the promoted row pairs no review_model'
        else
            review_constraints=$(jq -r '[.review.constraints[]? | .verdict] | length' \
                "$browser_report" 2>/dev/null || echo 0)
            review_heading=$(jq -r '.review.heading // empty' "$browser_report")
            review_note=$(jq -r '.review.note // empty' "$browser_report")
            if [ "${review_constraints:-0}" -gt 0 ] && \
               [ "$review_heading" = "reviewed by $review_model" ]; then
                record browser_review_rendered accepted \
                    "$review_heading constraints=$review_constraints"
                record browser_review_verdict observed \
                    "$(jq -c '[.review.constraints[] | {verdict, text}]' "$browser_report" | head -c 300)"
            else
                record browser_review_rendered refused \
                    "heading=${review_heading:-none} constraints=${review_constraints:-0} note=${review_note:-none}"
            fi
            # The review's own request and reply stay out of `history`, so the
            # language model never reads what the vision model saw.
            review_in_history=$(jq -r '[.history[] | select((.content // "") | test("reviewed by|hard_constraints"))] | length' \
                "$browser_report" 2>/dev/null || echo 0)
            if [ "${review_in_history:-0}" -eq 0 ]; then
                record browser_review_stays_out_of_history accepted \
                    'the transcript carries no verdict text'
            else
                record browser_review_stays_out_of_history refused \
                    "entries=$review_in_history"
            fi
            # The review body carries a data URI of the whole PNG, so the
            # page log truncates it and only the recorded key names read
            # whole. `bodyKeys` is what the check reads: the review request
            # omits `tools` entirely rather than sending an empty list, so the
            # reviewer is offered no executable surface at all.
            review_posts=$(jq -r --arg u "$router_origin/v1/chat/completions" \
                --arg m "$review_model" \
                '[.requests[] | select(.method == "POST" and .url == $u and .bodyModel == $m)] | length' \
                "$browser_report" 2>/dev/null || echo 0)
            review_with_tools=$(jq -r --arg u "$router_origin/v1/chat/completions" \
                --arg m "$review_model" \
                '[.requests[] | select(.method == "POST" and .url == $u and .bodyModel == $m) | select((.bodyKeys // []) | index("tools"))] | length' \
                "$browser_report" 2>/dev/null || echo 0)
            if [ "${review_posts:-0}" -ge 1 ] && [ "${review_with_tools:-0}" -eq 0 ]; then
                record browser_review_offers_no_tools accepted \
                    "posts=$review_posts tools_key=0"
            else
                record browser_review_offers_no_tools refused \
                    "posts=${review_posts:-0} tools_key=${review_with_tools:-0}"
            fi
        fi
        # The grant is spent inside the request the browser sent, so the retained
        # page log keeps the fields and drops the token.
        jq '.requests |= map(.body |= (if . == null then null else (fromjson? // .) end) | .body |= (if type == "object" and .params? then .params |= del(.authorization) else . end))' \
            "$browser_report" >"$browser_report.tmp" && mv "$browser_report.tmp" "$browser_report"
    else
        # Every attempt ran and none completed, so the refusal names the
        # attempt count and every attempt's own excerpt rather than only the
        # last one -- the record above already retains each attempt's full
        # report at browser-turn-<n>.json for a reader who needs more than the
        # excerpt.
        record browser_turn_completed refused \
            "attempts=$browser_attempts$browser_attempt_excerpts"
        # Every image failure answers its call with a tool message, so the
        # transcript states what the page told the model where the turn ended
        # and states that it told it nothing where the turn hung. The last
        # attempt is what a reader checks first, since it is the one closest
        # to what a further attempt would have started from.
        last_attempt_report=$output_directory/browser-turn-$browser_attempts.json
        if jq -e . "$last_attempt_report" >/dev/null 2>&1; then
            refused_tool_message=$(jq -r \
                '[.history[] | select(.role == "tool")] | last | .content // empty' \
                "$last_attempt_report" | head -c 300)
        else
            refused_tool_message=''
        fi
        record browser_turn_tool_message observed "${refused_tool_message:-none}"
    fi
else
    record browser_turn_completed refused 'chromium is absent, so the served page was not run'
fi

# 9. Secret hygiene: the signing key, the API key, and the grant stay out of
# every process image and every retained file.
key_bytes=$(cat "$token_key_file")
hygiene_failures=''
for pid in $(pgrep -x llama-server 2>/dev/null || true) \
    $(pgrep -f 'image-mcp/server.py' 2>/dev/null || true) \
    $image_service_pid $broker_pid; do
    [ -r "/proc/$pid/environ" ] || continue
    for needle in "$key_bytes" "$api_key_bytes" "$authorization" "$session_secret"; do
        [ -n "$needle" ] || continue
        if tr '\0' '\n' <"/proc/$pid/environ" | grep -qF -- "$needle" || \
           tr '\0' '\n' <"/proc/$pid/cmdline" | grep -qF -- "$needle"; then
            hygiene_failures="$hygiene_failures pid=$pid"
        fi
    done
done
for retained in "$state_directory/server.log" "$state_directory/authorize-broker.log" \
    "$state_directory/image-service.log" "$state_directory/session.status" \
    "$output_directory/provenance.json"; do
    [ -r "$retained" ] || continue
    for needle in "$key_bytes" "$api_key_bytes" "$authorization" "$session_secret" \
        "$generation_prompt"; do
        [ -n "$needle" ] || continue
        if grep -qF -- "$needle" "$retained"; then
            hygiene_failures="$hygiene_failures file=$(basename "$retained")"
        fi
    done
done
if [ -z "$hygiene_failures" ]; then
    record secret_hygiene accepted 'key, grant, session secret, and prompt text absent from process images, logs, status, and provenance'
else
    record secret_hygiene refused "$hygiene_failures"
fi
cp "$state_directory/image-service.log" "$output_directory/image-service.log" 2>/dev/null || true
cp "$state_directory/server.log" "$output_directory/image-server.log" 2>/dev/null || true

# 10. Teardown and absence.
if "$script_directory/qwen-teardown.sh" >"$output_directory/image-teardown.log" 2>&1; then
    record image_teardown accepted "$(tail -1 "$output_directory/image-teardown.log")"
else
    record image_teardown refused "$(tail -1 "$output_directory/image-teardown.log")"
fi
if "$script_directory/image-teardown-check.sh" "$state_directory" \
    >"$output_directory/image-teardown-check.log" 2>&1; then
    record image_residue_absent accepted "$(tail -1 "$output_directory/image-teardown-check.log")"
else
    record image_residue_absent refused "$(tail -2 "$output_directory/image-teardown-check.log" | tr '\n' ';')"
fi
absence=''
pgrep -x llama-server >/dev/null 2>&1 && absence="$absence llama-server"
pgrep -f 'image-mcp/server.py' >/dev/null 2>&1 && absence="$absence image-mcp-child"
[ -n "$broker_pid" ] && kill -0 "$broker_pid" 2>/dev/null && absence="$absence broker"
[ -n "$secret_file" ] && [ -e "$secret_file" ] && absence="$absence secret"
ss -ltn 2>/dev/null | grep -q ":$server_port " && absence="$absence port-$server_port"
ss -ltn 2>/dev/null | grep -q ":$broker_port " && absence="$absence port-$broker_port"
if [ -z "$absence" ]; then
    record absence_proved accepted 'router, MCP child, broker, secret, and both ports'
else
    record absence_proved refused "$absence"
fi

# 11. Restore the ordinary router.
restore_ordinary
printf 'admission_end utc=%s failures=%s\n' "$(utc)" "$failures" >>"$output_directory/run.log"
if [ "$failures" -eq 0 ]; then
    printf 'admit_image_router=accepted\n'
    exit 0
fi
printf 'admit_image_router=refused checks=%s\n' "$failures" >&2
exit 1
