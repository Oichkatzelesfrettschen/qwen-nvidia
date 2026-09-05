#!/bin/sh
set -eu
# gpu-ownership: delegated to the serving session qwen-sidecar-launch.sh
# starts through qwen-web-launch.sh; the session holds the owner lock on the
# far side of tmux and this harness waits on its status proof.
#
# Admit the physics lane through the served session: one PhysX simulation
# proposed by the model, approved on the page, granted by the broker, spent
# by the MCP child, revalidated by the service ahead of the compute lease,
# and run on the device. The ledger row is raised to validator-gated in a
# copy under this run's directory, the runtime is compiled here and its
# digest carried through the preset into the child and the grant, and the
# chain launches through qwen-sidecar-launch.sh. Every request the page
# makes is replayed first with curl on the router port: the tool listing,
# the broker's health and session, one grant, one run with its GPU proof,
# and each refusal the design rests on -- the replayed grant, the ungranted
# call, a count over the approved one, a geometry grant at the physics
# lane, a held lease, and a run past the profile's deadline, which proves
# the service ends its runtime and reports the timeout. The page then runs
# the same turn through the appliance's headless Chromium, and the teardown
# proves no service, runtime, socket, or lease survives.
#
# The driver's compute-client list is sampled at ten hertz through the curl
# run and reported as observed or not observed: a short run may finish
# between samples, and a /proc observation is never a proof of a launch.

usage() {
    printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
    exit 2
}
[ "$#" -eq 1 ] || usage
output_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
model_id=${QWEN_ADMISSION_MODEL_ID:-qwen38-4b-distill}
profile_id=${QWEN_ADMISSION_PROFILE:-web-sidecar-admission}
physics_profile_id=${QWEN_ADMISSION_PHYSICS_PROFILE:-physics-d6-chain-a}
run_steps=${QWEN_ADMISSION_PHYSICS_STEPS:-600}
timeout_steps=${QWEN_ADMISSION_PHYSICS_TIMEOUT_STEPS:-100000}
context=${QWEN_ADMISSION_CONTEXT:-4096}
server_port=${QWEN_SERVER_PORT:-8080}
broker_port=${QWEN_WEB_BROKER_PORT:-8571}
registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"$HOME/qwen-webui-state"}
source_physics_ledger=${QWEN_PHYSICS_PROFILES:-$script_directory/physics-profiles.tsv}
tool_name=physics_simulate_rigid
router_origin=http://127.0.0.1:$server_port
broker_origin=http://127.0.0.1:$broker_port
for tool in python3 curl jq sha256sum ss pgrep flock nvidia-smi; do
    command -v "$tool" >/dev/null 2>&1 || { printf '%s is required\n' "$tool" >&2; exit 2; }
done
umask 077
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
scrub_home() { sed -e "s|$output_directory|OUT|g" -e "s|${HOME:?}|\$HOME|g"; }
summary=$output_directory/summary.tsv
: >"$summary"
failures=0
record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "$3" | scrub_home)" >>"$summary"
    printf '%s=%s %s\n' "$1" "$2" "$(printf '%s' "$3" | scrub_home)"
    case $2 in
        accepted | observed | skipped) ;;
        *) failures=$((failures + 1)) ;;
    esac
}
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mkdir -p "$output_directory/http" "$output_directory/keys"
chmod 700 "$output_directory/http" "$output_directory/keys"
api_key_curl_config=$output_directory/keys/api-key.curl
exchange=0
call() {
    exchange=$((exchange + 1))
    call_label=$1
    call_method=$2
    call_url=$3
    call_body=${4:-}
    call_headers_file=$output_directory/http/$exchange-$call_label.headers
    call_out=$output_directory/http/$exchange-$call_label.response
    if [ "$#" -ge 4 ]; then shift 4; else shift "$#"; fi
    if [ -s "$api_key_curl_config" ]; then set -- "$@" --config "$api_key_curl_config"; fi
    if [ -n "$call_body" ]; then
        printf '%s' "$call_body" >"$output_directory/http/$exchange-$call_label.request"
        curl -sS --max-time 700 -o "$call_out" -D "$call_headers_file" -X "$call_method" "$call_url" \
            -H 'Content-Type: application/json' --data-binary "@$output_directory/http/$exchange-$call_label.request" "$@" || true
    else
        curl -sS --max-time 120 -o "$call_out" -D "$call_headers_file" -X "$call_method" "$call_url" "$@" || true
    fi
    call_status=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$call_headers_file" 2>/dev/null | tail -1)
    call_status=${call_status:-000}
}
sampler_pid=''
torn_down=0
finish_run() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$sampler_pid" ]; then kill "$sampler_pid" 2>/dev/null || :; fi
    if [ "$torn_down" != 1 ] && pgrep -x llama-server >/dev/null 2>&1; then
        "$script_directory/qwen-teardown.sh" >"$output_directory/abort-teardown.log" 2>&1 || :
    fi
    for text in "$output_directory"/*.log "$output_directory"/*.status "$output_directory"/http/*; do
        [ -f "$text" ] || continue
        scrub_home <"$text" >"$text.scrubbed" && mv "$text.scrubbed" "$text"
    done
    printf 'admission_finished status=%s failures=%s utc=%s\n' "$exit_status" "$failures" "$(utc)" >>"$output_directory/run.log"
    exit "$exit_status"
}
trap finish_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'admission_start utc=%s\n' "$(utc)" >"$output_directory/run.log"

# The runtime this run spawns is compiled here, so its digest is this run's
# own and travels into the preset, the child, and every grant.
"$script_directory/verify-nvidia-sdk.sh" >"$output_directory/sdk-verify.txt" 2>&1 || {
    record sdk_verified refused "$(tail -1 "$output_directory/sdk-verify.txt")"
    exit 1
}
record sdk_verified accepted "$(tail -1 "$output_directory/sdk-verify.txt")"
"$script_directory/build-physics-runtime.sh" "$output_directory/physx-rigid-runtime" >"$output_directory/build.txt" 2>&1 || {
    record physics_runtime_built refused "$(tail -1 "$output_directory/build.txt")"
    exit 1
}
runtime_sha256=$(sed -n 's/^physics_runtime_sha256=//p' "$output_directory/build.txt")
record physics_runtime_built accepted "runtime_sha256=$runtime_sha256"

# The ledger copy: the subject row raised to validator-gated with a deadline
# the timeout arm can cross and a ceiling that admits the timeout's count.
physics_ledger=$output_directory/physics-profiles.tsv
awk -F '\t' -v OFS='\t' -v id="$physics_profile_id" -v ceiling="$timeout_steps" '
    /^#/ { print; next }
    $1 == id { $4 = ceiling; $8 = 2; $9 = "validator-gated" }
    { print }
' "$source_physics_ledger" >"$physics_ledger"
grep -q "^$physics_profile_id	.*	validator-gated	" "$physics_ledger" || {
    record physics_ledger_promoted refused "$physics_profile_id is absent from $source_physics_ledger"
    exit 1
}
physics_scene=$(awk -F '\t' -v id="$physics_profile_id" '!/^#/ && $1 == id { print $2 }' "$physics_ledger")
record physics_ledger_promoted accepted "$physics_profile_id validator-gated max_steps=$timeout_steps timeout_s=2 scene=$physics_scene"

registry_row=$(grep -v '^#' "$registry" | awk -F'\t' -v id="$model_id" '$1 == id')
[ -n "$registry_row" ] || { record model_row refused "$model_id is absent from $registry"; exit 2; }
validated_depth=$(printf '%s\n' "$registry_row" | cut -f19)
control_model_path=${QWEN_MODEL_PATH:-$model_root/$(printf '%s\n' "$registry_row" | cut -f3)}
projector=$(printf '%s\n' "$registry_row" | cut -f11)
tool_selection=$(printf '%s\n' "$registry_row" | cut -f21)
case $projector in none) vision_allowed=no ;; *) vision_allowed=yes ;; esac
web_ledger=$output_directory/web-profiles.tsv
printf '# profile_id\tmodel_id\tweb_mode\tcontext\tvalidated_filled_depth\tmax_results\tmax_fetches\tmax_chars_per_fetch\tmulti_source\tvision_allowed\ttool_selection\texecution_policy\tprovider\tprimary_category\tfallback_category\tminimum_results\tsearxng_url\n' >"$web_ledger"
printf '%s\t%s\tui-mediated\t%s\t%s\t3\t1\t12000\tno\t%s\t%s\tui-mediated\tfake\t-\t-\t-\t-\n' \
    "$profile_id" "$model_id" "$context" "$validated_depth" "$vision_allowed" "$tool_selection" >>"$web_ledger"
image_ledger=$output_directory/image-profiles.tsv
grep -v '^#' "$script_directory/image-profiles.tsv" | awk -F '\t' -v OFS='\t' '{ $12 = "refused"; print }' >"$image_ledger"
token_key_file=$output_directory/keys/token.key
python3 -c 'import secrets; print(secrets.token_hex(32))' >"$token_key_file"
chmod 600 "$token_key_file"

web_presets=$output_directory/web-presets.ini
physics_state_directory=$state_directory/physics
if QWEN_WEB_PROFILES=$web_ledger QWEN_WEB_MCP_SERVER=$script_directory/web-mcp/server.py \
    QWEN_WEB_PROVIDER=fake QWEN_WEB_TOKEN_KEY_FILE=$token_key_file QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_IMAGE_PROFILES=$image_ledger QWEN_IMAGE_TOKEN_KEY_FILE=$token_key_file \
    QWEN_PHYSICS_PROFILES=$physics_ledger QWEN_PHYSICS_STATE_DIR=$physics_state_directory \
    QWEN_PHYSICS_RUNTIME_SHA256=$runtime_sha256 QWEN_SIDECAR_MCP_SERVER=$script_directory/sidecar-mcp/server.py \
    QWEN_SIDECAR_TOKEN_KEY_FILE=$token_key_file \
    QWEN_WEB_AUTHORIZER_READY=1 QWEN_MODEL_REGISTRY=$registry QWEN_MODEL_ROOT=$model_root \
    "$script_directory/build-web-presets.sh" "$web_presets" >"$output_directory/build-web-presets.log" 2>&1; then
    preset_physics_profile=$(sed -n 's/^# qwen_physics_profile=//p' "$web_presets")
    if [ "$preset_physics_profile" = "$physics_profile_id" ]; then
        record preset_generated accepted "physics_profile=$preset_physics_profile sections=$(grep -c '^\[' "$web_presets")"
    else
        record preset_generated refused "the preset names physics profile ${preset_physics_profile:-none}"
        exit 1
    fi
else
    record preset_generated refused "$(tail -1 "$output_directory/build-web-presets.log")"
    exit 1
fi

if QWEN_WEB_PRESETS=$web_presets QWEN_WEB_PROFILES=$web_ledger QWEN_WEB_PROVIDER=fake \
    QWEN_WEB_TOKEN_KEY_FILE=$token_key_file QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_WEB_BROKER_PORT=$broker_port QWEN_WEB_AUTHORIZER_READY=1 QWEN_IMAGE_TOKEN_KEY_FILE=$token_key_file \
    QWEN_PHYSICS_RUNTIME=$output_directory/physx-rigid-runtime QWEN_MODEL_REGISTRY=$registry \
    QWEN_MODEL_ROOT=$model_root QWEN_MODEL_PATH=$control_model_path \
    "$script_directory/qwen-sidecar-launch.sh" default >"$output_directory/sidecar-launch.log" 2>&1; then
    record sidecar_launch accepted "$(grep '^physics_launch' "$output_directory/sidecar-launch.log" | tr '\n' ';')"
else
    record sidecar_launch refused "$(tail -3 "$output_directory/sidecar-launch.log" | tr '\n' ';')"
    cp "$state_directory/session.status" "$output_directory/failed-session.status" 2>/dev/null || :
    cp "$state_directory/physics-service.log" "$output_directory/failed-physics-service.log" 2>/dev/null || :
    cp "$state_directory/server.log" "$output_directory/failed-server.log" 2>/dev/null || :
    exit 1
fi
cp "$state_directory/session.status" "$output_directory/session.status"
physics_service_pid=$(sed -n '1p' "$output_directory/session.status" | tr ' ' '\n' | sed -n 's/^physics_service_pid=//p')
physics_identity=$(sed -n 's/^physics_service_identity //p' "$output_directory/session.status" | sed -n '1p')
secret_file=$(sed -n 's/^broker secret_file=//p' "$output_directory/session.status")
if [ -n "$physics_service_pid" ] && [ -n "$physics_identity" ]; then
    record physics_service_recorded accepted "pid=$physics_service_pid $physics_identity"
else
    record physics_service_recorded refused "pid=${physics_service_pid:-none} identity=${physics_identity:-none}"
fi
lease_path=$(printf '%s' "$physics_identity" | tr ' ' '\n' | sed -n 's/^lease=//p')
identity_runtime=$(printf '%s' "$physics_identity" | tr ' ' '\n' | sed -n 's/^runtime_sha256=//p')
if [ "$identity_runtime" = "$runtime_sha256" ]; then
    record service_announced_built_runtime accepted "$runtime_sha256"
else
    record service_announced_built_runtime refused "announced=${identity_runtime:-none} built=$runtime_sha256"
fi
api_key_file=$state_directory/api.key
if [ -s "$api_key_file" ] && [ "$(stat -c %a "$api_key_file")" = 600 ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$(sed -n '1p' "$api_key_file")" >"$api_key_curl_config"
    chmod 600 "$api_key_curl_config"
    record api_key_read accepted "$api_key_file"
else
    record api_key_read refused "$api_key_file absent or not 0600"
fi

call tools GET "$router_origin/tools?model=$profile_id&autoload=true"
cp "$call_out" "$output_directory/tools.json"
tool_names=$(jq -r '.[].tool' "$call_out" 2>/dev/null | sort | tr '\n' ',')
if [ "$tool_names" = "$tool_name," ]; then
    record tool_enumeration accepted "$tool_names via $router_origin"
else
    record tool_enumeration refused "status=$call_status tools=${tool_names:-none}"
fi
listed_runtime=$(jq -r '.[] | select(.tool == "physics_simulate_rigid") | .definition.function.parameters.properties.profile_id.x_runtime_sha256 // empty' "$call_out" 2>/dev/null)
listed_scene=$(jq -r '.[] | select(.tool == "physics_simulate_rigid") | .definition.function.parameters.properties.profile_id.x_scene // empty' "$call_out" 2>/dev/null)
listed_ceiling=$(jq -r '.[] | select(.tool == "physics_simulate_rigid") | .definition.function.parameters.properties.count.maximum // empty' "$call_out" 2>/dev/null)
if [ "$listed_runtime" = "$runtime_sha256" ] && [ "$listed_scene" = "$physics_scene" ] && [ "$listed_ceiling" = "$timeout_steps" ]; then
    record listing_binds_runtime_scene_ceiling accepted "scene=$listed_scene ceiling=$listed_ceiling"
else
    record listing_binds_runtime_scene_ceiling refused "runtime=${listed_runtime:-none} scene=${listed_scene:-none} ceiling=${listed_ceiling:-none}"
fi
call broker-health GET "$broker_origin/health" '' -H "Host: 127.0.0.1:$broker_port"
health_physics=$(jq -r '.physics_profile // empty' "$call_out" 2>/dev/null)
if [ "$health_physics" = "$physics_profile_id" ]; then
    record broker_signs_physics_profile accepted "physics_profile=$health_physics"
else
    record broker_signs_physics_profile refused "physics_profile=${health_physics:-none}"
fi
call session GET "$broker_origin/session" '' -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port"
session_secret=$(jq -r '.session_secret // empty' "$call_out" 2>/dev/null)
if [ "$call_status" = 200 ] && [ -n "$session_secret" ]; then
    record session_secret_issued accepted "status=$call_status"
else
    record session_secret_issued refused "status=$call_status"
fi
grant_body() {
    # grant_body SERVICE PROFILE SCENE COUNT
    jq -cn --arg service "$1" --arg language "$profile_id" --arg sidecar "$2" --arg runtime "$runtime_sha256" \
        --arg scene "$3" --argjson count "$4" --argjson ceiling "$timeout_steps" \
        '{context: "qwen-sidecar-run-v1", service: $service, language_profile: $language, sidecar_profile: $sidecar,
          runtime_sha256: $runtime, scene: $scene, count: $count, count_ceiling: $ceiling, conversation_generation: 0}'
}
issue_grant() {
    # issue_grant LABEL PATH BODY
    call "$1" POST "$broker_origin$2" "$3" -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port" \
        -H "X-Qwen-Web-Session: $session_secret"
    issued_authorization=$(jq -r '.authorization // empty' "$call_out" 2>/dev/null)
}
issue_grant grant-physics /grant-physics "$(grant_body physics "$physics_profile_id" "$physics_scene" "$run_steps")"
authorization=$issued_authorization
if [ "$call_status" = 200 ] && [ -n "$authorization" ]; then
    record grant_issued accepted "status=$call_status steps=$run_steps bytes=${#authorization}"
else
    record grant_issued refused "status=$call_status $(head -c 160 "$call_out")"
fi
issue_grant grant-geometry-at-physics /grant-physics "$(grant_body geometry geometry-cube-orbit-a cube-and-plane 64)"
if [ "$call_status" != 200 ]; then
    record geometry_body_at_physics_endpoint_refused accepted "status=$call_status $(jq -r '.error' "$call_out" 2>/dev/null | head -c 100)"
else
    record geometry_body_at_physics_endpoint_refused refused "status=$call_status"
fi
issue_grant grant-geometry-endpoint /grant-geometry "$(grant_body geometry geometry-cube-orbit-a cube-and-plane 64)"
if [ "$call_status" != 200 ]; then
    record unarmed_geometry_endpoint_refused accepted "status=$call_status $(jq -r '.error' "$call_out" 2>/dev/null | head -c 100)"
else
    record unarmed_geometry_endpoint_refused refused "status=$call_status"
fi
tool_body() {
    jq -cn --arg m "$profile_id" --arg t "$tool_name" --argjson p "$1" '{model: $m, tool: $t, params: $p, stream: false}'
}
run_params=$(jq -cn --arg profile "$physics_profile_id" --argjson count "$run_steps" --arg auth "$authorization" \
    '{profile_id: $profile, count: $count, authorization: $auth}')
sample_clients() {
    while :; do
        stamp=$(date +%s.%N)
        held=$(flock -n "$lease_path" true 2>/dev/null && printf free || printf held)
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
            sed "s|^|$stamp\t$held\t|" || :
        printf '%s\t%s\ttick\n' "$stamp" "$held"
        sleep 0.1
    done
}
sample_clients >"$output_directory/clients-during.raw" 9>&- &
sampler_pid=$!
run_started=$(date +%s.%N)
call run POST "$router_origin/tools" "$(tool_body "$run_params")"
run_ended=$(date +%s.%N)
kill "$sampler_pid" 2>/dev/null || :; wait "$sampler_pid" 2>/dev/null || :; sampler_pid=''
run_text=$(jq -r '.plain_text_response // empty' "$call_out" 2>/dev/null)
run_status=$(printf '%s' "$run_text" | jq -r '.status // empty' 2>/dev/null)
gpu_active=$(printf '%s' "$run_text" | jq -r '.gpu.gpu_dynamics_active // empty' 2>/dev/null)
result_runtime=$(printf '%s' "$run_text" | jq -r '.runtime_sha256 // empty' 2>/dev/null)
result_sha256=$(printf '%s' "$run_text" | jq -r '.result_sha256 // empty' 2>/dev/null)
run_wall=$(printf '%s %s' "$run_started" "$run_ended" | awk '{ printf "%.3f", $2 - $1 }')
if [ "$call_status" = 200 ] && [ "$run_status" = completed ] && [ "$gpu_active" = true ] && [ "$result_runtime" = "$runtime_sha256" ]; then
    record run_completed_with_gpu_proof accepted "wall=${run_wall}s steps=$run_steps result_sha256=$result_sha256 simulate_ms=$(printf '%s' "$run_text" | jq -r '.simulate_ms // "-"')"
else
    record run_completed_with_gpu_proof refused "status=$call_status $(head -c 200 "$call_out")"
fi
if [ "$(printf '%s' "$run_text" | jq -r 'has("bodies") and (.bodies | type) == "number"' 2>/dev/null)" = true ] && \
   ! printf '%s' "$run_text" | jq -e '.result' >/dev/null 2>&1; then
    record result_carries_summary_alone accepted 'counts, proof, and digests; no body state'
else
    record result_carries_summary_alone refused "$(printf '%s' "$run_text" | head -c 160)"
fi
sed -E 's|^([0-9.]+)\t([a-z]+)\t(.*)$|\1\t\2\t\3|' "$output_directory/clients-during.raw" | scrub_home >"$output_directory/clients-during.tsv"
rm -f "$output_directory/clients-during.raw"
runtime_samples=$(grep -c 'physx-rigid-runtime' "$output_directory/clients-during.tsv" || :)
held_samples=$(awk -F '\t' '$2 == "held"' "$output_directory/clients-during.tsv" | wc -l)
if [ "$runtime_samples" -gt 0 ]; then
    record nvml_compute_visibility observed "runtime_samples=$runtime_samples lease_held_samples=$held_samples"
else
    record nvml_compute_visibility observed "not_observed_during_sample lease_held_samples=$held_samples wall=${run_wall}s"
fi

call run-replay POST "$router_origin/tools" "$(tool_body "$run_params")"
if [ "$(jq -r '.error // empty' "$call_out" 2>/dev/null | grep -c spent)" -ge 1 ]; then
    record grant_replay_refused accepted "$(jq -r '.error' "$call_out" | head -c 140)"
else
    record grant_replay_refused refused "status=$call_status $(head -c 160 "$call_out")"
fi
ungranted=$(printf '%s' "$run_params" | jq -c 'del(.authorization)')
call run-no-grant POST "$router_origin/tools" "$(tool_body "$ungranted")"
if [ -n "$(jq -r '.error // empty' "$call_out" 2>/dev/null)" ]; then
    record run_without_grant_refused accepted "$(jq -r '.error' "$call_out" | head -c 140)"
else
    record run_without_grant_refused refused "status=$call_status $(head -c 160 "$call_out")"
fi
issue_grant grant-for-count /grant-physics "$(grant_body physics "$physics_profile_id" "$physics_scene" "$run_steps")"
other_count=$(printf '%s' "$run_params" | jq -c --arg auth "$issued_authorization" '.authorization = $auth | .count = (.count + 1)')
call run-other-count POST "$router_origin/tools" "$(tool_body "$other_count")"
if [ "$(jq -r '.error // empty' "$call_out" 2>/dev/null | grep -c 'arguments differ')" -ge 1 ]; then
    record count_outside_grant_refused accepted "$(jq -r '.error' "$call_out" | head -c 140)"
else
    record count_outside_grant_refused refused "status=$call_status $(head -c 160 "$call_out")"
fi
issue_grant grant-for-lease /grant-physics "$(grant_body physics "$physics_profile_id" "$physics_scene" "$run_steps")"
lease_params=$(printf '%s' "$run_params" | jq -c --arg auth "$issued_authorization" '.authorization = $auth')
# the lease is held from outside for the whole call, so the service waits its
# bounded deadline and refuses without starting a runtime
flock "$lease_path" sh -c 'sleep 75' 9>&- &
holder_pid=$!
sleep 0.5
call run-lease-held POST "$router_origin/tools" "$(tool_body "$lease_params")"
kill "$holder_pid" 2>/dev/null || :; wait "$holder_pid" 2>/dev/null || :
if [ "$(jq -r '.error // empty' "$call_out" 2>/dev/null | grep -c 'lease')" -ge 1 ]; then
    record held_lease_refuses_run accepted "$(jq -r '.error' "$call_out" | head -c 140)"
else
    record held_lease_refuses_run refused "status=$call_status $(head -c 160 "$call_out")"
fi
issue_grant grant-for-timeout /grant-physics "$(grant_body physics "$physics_profile_id" "$physics_scene" "$timeout_steps")"
timeout_params=$(jq -cn --arg profile "$physics_profile_id" --argjson count "$timeout_steps" --arg auth "$issued_authorization" \
    '{profile_id: $profile, count: $count, authorization: $auth}')
timeout_started=$(date +%s.%N)
call run-timeout POST "$router_origin/tools" "$(tool_body "$timeout_params")"
timeout_wall=$(printf '%s %s' "$timeout_started" "$(date +%s.%N)" | awk '{ printf "%.3f", $2 - $1 }')
if [ "$(jq -r '.error // empty' "$call_out" 2>/dev/null | grep -c 'exceeded')" -ge 1 ]; then
    record runtime_deadline_ends_the_run accepted "wall=${timeout_wall}s $(jq -r '.error' "$call_out" | head -c 120)"
else
    record runtime_deadline_ends_the_run refused "wall=${timeout_wall}s status=$call_status $(head -c 160 "$call_out")"
fi
sleep 1
if pgrep -f '^([^ ]*/)?physx-rigid-runtime( |$)' >/dev/null 2>&1; then
    record timed_out_runtime_reaped refused "$(pgrep -f 'physx-rigid-runtime' | tr '\n' ' ')"
else
    record timed_out_runtime_reaped accepted 'no runtime process survives the deadline'
fi

# The page turn: the same proposal, dialog, grant, and run through the
# appliance's headless Chromium, reading the driver's own request log.
browser_prompt=${QWEN_ADMISSION_BROWSER_PROMPT:-"Run the physics simulation for $run_steps steps and tell me whether the chain stayed intact."}
record browser_prompt_used observed "$browser_prompt"
browser_report=$output_directory/browser-turn.json
if python3 "$script_directory/web-mcp/drive-fallback-page.py" --lane sidecar --origin "$router_origin" \
    --api-key-file "$api_key_file" --broker "$broker_origin" --model "$profile_id" \
    --prompt "$browser_prompt" >"$browser_report" 2>"$output_directory/browser-turn.err"; then
    grant_posts=$(jq '[.requests[]? | select(.url | test("/grant-physics$")) | select(.method == "POST")] | length' "$browser_report" 2>/dev/null || printf 0)
    tool_posts=$(jq '[.requests[]? | select(.url | test("/tools$")) | select(.method == "POST")] | length' "$browser_report" 2>/dev/null || printf 0)
    origins=$(jq -r '[.requests[]?.url | capture("^(?<o>https?://[^/]+)").o] | unique | join(",")' "$browser_report" 2>/dev/null)
    if [ "$grant_posts" = 1 ] && [ "$tool_posts" -ge 1 ]; then
        record browser_turn_ran accepted "grant_posts=$grant_posts tool_posts=$tool_posts origins=$origins"
    else
        record browser_turn_ran refused "grant_posts=$grant_posts tool_posts=$tool_posts origins=$origins"
    fi
    case ",$origins," in
        *,"$router_origin",*"$broker_origin",* | *,"$broker_origin",*"$router_origin",*)
            extra=$(printf '%s' "$origins" | tr ',' '\n' | grep -v "^$router_origin$" | grep -v "^$broker_origin$" || :)
            if [ -z "$extra" ]; then record browser_origins_bounded accepted "$origins"; else record browser_origins_bounded refused "$origins"; fi ;;
        *) record browser_origins_bounded refused "$origins" ;;
    esac
    reply_excerpt=$(jq -r '[.history[]? | select(.role == "assistant") | .content // ""] | last // empty' "$browser_report" 2>/dev/null | tr '\n' ' ' | head -c 200)
    tool_message=$(jq -r '[.history[]? | select(.role == "tool") | .content // ""] | last // empty' "$browser_report" 2>/dev/null)
    record browser_reply observed "$reply_excerpt"
    # the tool message is the child's JSON summary; its status key is read
    # by a JSON parse rather than by a substring at some offset
    browser_run_status=$(printf '%s' "$tool_message" | jq -r '.status // empty' 2>/dev/null || :)
    browser_run_proof=$(printf '%s' "$tool_message" | jq -r '.gpu.gpu_dynamics_active // empty' 2>/dev/null || :)
    if [ "$browser_run_status" = completed ] && [ "$browser_run_proof" = true ]; then
        record browser_tool_message_completed accepted "status=completed gpu_dynamics_active=true steps=$(printf '%s' "$tool_message" | jq -r '.steps // "-"')"
    else
        record browser_tool_message_completed refused "$(printf '%s' "$tool_message" | head -c 160)"
    fi
else
    record browser_turn_ran refused "$(tail -3 "$output_directory/browser-turn.err" | tr '\n' ';')"
fi

# Teardown: the session, the service, the runtime, the socket, and the lease
# all leave, proven by the teardown and the lane's own residue check.
if "$script_directory/qwen-teardown.sh" >"$output_directory/teardown.log" 2>&1; then
    torn_down=1
    record teardown_clean accepted "$(tail -1 "$output_directory/teardown.log")"
else
    torn_down=1
    record teardown_clean refused "$(tail -3 "$output_directory/teardown.log" | tr '\n' ';')"
fi
if "$script_directory/physics-teardown-check.sh" "$physics_state_directory" >"$output_directory/physics-teardown.log" 2>&1; then
    record physics_residue_clean accepted "$(tail -1 "$output_directory/physics-teardown.log")"
else
    record physics_residue_clean refused "$(tail -2 "$output_directory/physics-teardown.log" | tr '\n' ';')"
fi
if [ -n "$secret_file" ] && [ -e "$secret_file" ]; then
    record session_secret_removed refused "$secret_file"
else
    record session_secret_removed accepted "${secret_file:-unrecorded}"
fi
rm -f "$api_key_curl_config"
record checks_total observed "$(wc -l <"$summary")"
if [ "$failures" -eq 0 ]; then
    record admission accepted 'every check accepted'
    exit 0
fi
record admission refused "$failures refused"
exit 1
