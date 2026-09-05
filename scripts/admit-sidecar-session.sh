#!/bin/sh
set -eu
# gpu-ownership: delegated to the serving session qwen-sidecar-launch.sh
# starts through qwen-web-launch.sh; the session holds the owner lock on the
# far side of tmux and this harness waits on its status proof.
#
# Admit a device sidecar lane through the served session: one PhysX
# simulation or one OptiX ray query proposed by the model, approved on the
# page, granted by the broker, spent by the MCP child, revalidated by the
# service ahead of the compute lease, and run on the device. QWEN_ADMISSION_LANES
# names the armed lanes, `physics`, `geometry`, or `physics,geometry`. For each
# armed lane the ledger row is raised to validator-gated in a copy under this
# run's directory, the runtime is compiled here and its digest carried through
# the preset into the child and the grant, and the chain launches once through
# qwen-sidecar-launch.sh with every armed service beside the broker. Every
# request the page makes is replayed first with curl on the router port: the
# tool listing, the broker's health and session, one grant, one run with its
# GPU proof, and each refusal the design rests on -- the replayed grant, the
# ungranted call, a count over the approved one, the other lane's body at this
# lane's grant route, a held lease, and a run past the profile's deadline. The
# page then runs the same turn per lane through the appliance's headless
# Chromium, and the teardown proves no service, runtime, socket, or lease
# survives.
#
# With both lanes armed two arms belong to the pair alone: a grant signed for
# one service presented at the other's tool, refused by the child ahead of any
# service call, and a contention arm releasing one run per lane from one
# barrier against the one lease, which requires both to complete, the driver's
# client list to name at most one runtime per sample, and the second holder's
# status line to state the wait it paid.
#
# The driver's compute-client list is sampled at ten hertz through each run
# and reported as observed or not observed: a short run may finish between
# samples, and a /proc observation is never a proof of a launch.

usage() {
    printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
    printf '  QWEN_ADMISSION_LANES selects physics, geometry, or physics,geometry (default physics)\n' >&2
    exit 2
}
[ "$#" -eq 1 ] || usage
output_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
lanes=${QWEN_ADMISSION_LANES:-physics}
case $lanes in
    physics | geometry | physics,geometry) ;;
    *) printf 'QWEN_ADMISSION_LANES must be physics, geometry, or physics,geometry\n' >&2; exit 2 ;;
esac
lane_armed() { case ",$lanes," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
model_id=${QWEN_ADMISSION_MODEL_ID:-qwen38-4b-distill}
profile_id=${QWEN_ADMISSION_PROFILE:-web-sidecar-admission}
physics_profile_id=${QWEN_ADMISSION_PHYSICS_PROFILE:-physics-d6-chain-a}
physics_run_count=${QWEN_ADMISSION_PHYSICS_STEPS:-600}
physics_timeout_count=${QWEN_ADMISSION_PHYSICS_TIMEOUT_STEPS:-100000}
geometry_profile_id=${QWEN_ADMISSION_GEOMETRY_PROFILE:-geometry-cube-orbit-a}
geometry_run_count=${QWEN_ADMISSION_GEOMETRY_RAYS:-262144}
geometry_timeout_count=${QWEN_ADMISSION_GEOMETRY_TIMEOUT_RAYS:-1048576}
context=${QWEN_ADMISSION_CONTEXT:-4096}
server_port=${QWEN_SERVER_PORT:-8080}
broker_port=${QWEN_WEB_BROKER_PORT:-8571}
registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"$HOME/qwen-webui-state"}
source_physics_ledger=${QWEN_PHYSICS_PROFILES:-$script_directory/physics-profiles.tsv}
source_geometry_ledger=${QWEN_GEOMETRY_PROFILES:-$script_directory/geometry-profiles.tsv}
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
now() { date +%s.%N; }
elapsed() { printf '%s %s' "$1" "$2" | awk '{ printf "%.3f", $2 - $1 }'; }
mkdir -p "$output_directory/http" "$output_directory/keys"
chmod 700 "$output_directory/http" "$output_directory/keys"
api_key_curl_config=$output_directory/keys/api-key.curl
exchange=0
# call_into STEM METHOD URL [BODY] [CURL_ARGUMENT...]: one exchange retained
# as request, headers, and response under the stem, with call_status and
# call_out set for the caller. The stem is explicit so two exchanges in
# flight at once hold distinct files; call wraps it under the sequence number.
call_into() {
    call_stem=$1
    call_method=$2
    call_url=$3
    call_body=${4:-}
    call_headers_file=$call_stem.headers
    call_out=$call_stem.response
    if [ "$#" -ge 4 ]; then shift 4; else shift "$#"; fi
    if [ -s "$api_key_curl_config" ]; then set -- "$@" --config "$api_key_curl_config"; fi
    if [ -n "$call_body" ]; then
        printf '%s' "$call_body" >"$call_stem.request"
        curl -sS --max-time 700 -o "$call_out" -D "$call_headers_file" -X "$call_method" "$call_url" \
            -H 'Content-Type: application/json' --data-binary "@$call_stem.request" "$@" || true
    else
        curl -sS --max-time 120 -o "$call_out" -D "$call_headers_file" -X "$call_method" "$call_url" "$@" || true
    fi
    call_status=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' "$call_headers_file" 2>/dev/null | tail -1)
    call_status=${call_status:-000}
}
call() {
    exchange=$((exchange + 1))
    call_label=$1
    shift
    call_into "$output_directory/http/$exchange-$call_label" "$@"
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
printf 'admission_start utc=%s lanes=%s\n' "$(utc)" "$lanes" >"$output_directory/run.log"

# lane_facts LANE sets the lane_* variables the arms read: the builder and
# the binary it emits, the ledger and the columns the copy raises, the tool
# the child lists, the grant route, the count the run asks for and the count
# the deadline arm asks for, the proof the reply has to carry, and the prompt
# the page turn sends. The deadline arm is required to cross on physics,
# where 100000 steps take seconds; on geometry the protocol ceiling of
# 1048576 rays traces in about a second, so that arm records which side of
# the 1 s deadline the run landed on and requires the runtime reaped either
# way.
lane_facts() {
    lane=$1
    case $lane in
        physics)
            lane_builder=build-physics-runtime.sh
            lane_binary=physx-rigid-runtime
            lane_digest_key=physics_runtime_sha256
            lane_source_ledger=$source_physics_ledger
            lane_profile_id=$physics_profile_id
            lane_run_count=$physics_run_count
            lane_timeout_count=$physics_timeout_count
            lane_timeout_s=2
            lane_ceiling_column=4
            lane_timeout_column=8
            lane_policy_column=9
            lane_tool=physics_simulate_rigid
            lane_count_noun=steps
            lane_grant_route=/grant-physics
            lane_residue_check=physics-teardown-check.sh
            lane_proof_jq='.gpu.gpu_dynamics_active == true'
            lane_figures_jq='"simulate_ms=\(.simulate_ms) bodies=\(.bodies) joints=\(.joints)"'
            lane_deadline_required=yes
            lane_prompt="Run the physics simulation for $physics_run_count steps and tell me whether the chain stayed intact."
            lane_other=geometry
            lane_runtime_sha256=$physics_runtime_sha256
            lane_scene=$physics_scene
            ;;
        geometry)
            lane_builder=build-geometry-runtime.sh
            lane_binary=optix-ray-runtime
            lane_digest_key=geometry_runtime_sha256
            lane_source_ledger=$source_geometry_ledger
            lane_profile_id=$geometry_profile_id
            lane_run_count=$geometry_run_count
            lane_timeout_count=$geometry_timeout_count
            lane_timeout_s=1
            lane_ceiling_column=4
            lane_timeout_column=5
            lane_policy_column=6
            lane_tool=geometry_ray_query
            lane_count_noun=rays
            lane_grant_route=/grant-geometry
            lane_residue_check=geometry-teardown-check.sh
            lane_proof_jq='.gpu.launch_completed == true and .reference_disagreement == 0'
            lane_figures_jq='"launch_ms=\(.launch_ms) hits=\(.hits) misses=\(.misses) reference_agreement=\(.reference_agreement)"'
            lane_deadline_required=no
            lane_prompt="Trace $geometry_run_count rays through the geometry scene and tell me how many of them hit something."
            lane_other=physics
            lane_runtime_sha256=$geometry_runtime_sha256
            lane_scene=$geometry_scene
            ;;
        *) printf 'lane_facts: unknown lane %s\n' "$lane" >&2; exit 2 ;;
    esac
    lane_ledger=$output_directory/$lane-profiles.tsv
    lane_state_directory=$state_directory/$lane
}
physics_runtime_sha256=''
geometry_runtime_sha256=''
physics_scene=''
geometry_scene=''

# The runtime each armed lane spawns is compiled here, so its digest is this
# run's own and travels into the preset, the child, and every grant.
if lane_armed physics; then
    "$script_directory/verify-nvidia-sdk.sh" >"$output_directory/sdk-verify.txt" 2>&1 || {
        record sdk_verified refused "$(tail -1 "$output_directory/sdk-verify.txt")"
        exit 1
    }
    record sdk_verified accepted "$(tail -1 "$output_directory/sdk-verify.txt")"
fi
for lane in physics geometry; do
    lane_armed "$lane" || continue
    lane_facts "$lane"
    "$script_directory/$lane_builder" "$output_directory/$lane_binary" >"$output_directory/$lane-build.txt" 2>&1 || {
        record "$lane.runtime_built" refused "$(tail -1 "$output_directory/$lane-build.txt")"
        exit 1
    }
    built_sha256=$(sed -n "s/^$lane_digest_key=//p" "$output_directory/$lane-build.txt")
    [ -n "$built_sha256" ] || { record "$lane.runtime_built" refused "$lane_digest_key absent from the build record"; exit 1; }
    record "$lane.runtime_built" accepted "runtime_sha256=$built_sha256"
    # The ledger copy: the subject row raised to validator-gated with a
    # deadline the timeout arm can reach and a ceiling admitting its count.
    awk -F '\t' -v OFS='\t' -v id="$lane_profile_id" -v ceiling="$lane_timeout_count" -v timeout="$lane_timeout_s" \
        -v ceiling_column="$lane_ceiling_column" -v timeout_column="$lane_timeout_column" -v policy_column="$lane_policy_column" '
        /^#/ { print; next }
        $1 == id { $ceiling_column = ceiling; $timeout_column = timeout; $policy_column = "validator-gated" }
        { print }
    ' "$lane_source_ledger" >"$lane_ledger"
    scene=$(awk -F '\t' -v id="$lane_profile_id" -v policy_column="$lane_policy_column" \
        '!/^#/ && $1 == id && $policy_column == "validator-gated" { print $2 }' "$lane_ledger")
    [ -n "$scene" ] || { record "$lane.ledger_promoted" refused "$lane_profile_id is absent from $lane_source_ledger"; exit 1; }
    record "$lane.ledger_promoted" accepted "$lane_profile_id validator-gated ceiling=$lane_timeout_count timeout_s=$lane_timeout_s scene=$scene"
    case $lane in
        physics) physics_runtime_sha256=$built_sha256; physics_scene=$scene ;;
        geometry) geometry_runtime_sha256=$built_sha256; geometry_scene=$scene ;;
    esac
done

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

# The preset: an unarmed lane keeps the shipped ledger, whose every row reads
# refused, so the generator emits no server for it and the broker signs
# nothing at its route.
web_presets=$output_directory/web-presets.ini
physics_ledger_for_preset=$source_physics_ledger
geometry_ledger_for_preset=$source_geometry_ledger
lane_armed physics && physics_ledger_for_preset=$output_directory/physics-profiles.tsv
lane_armed geometry && geometry_ledger_for_preset=$output_directory/geometry-profiles.tsv
if QWEN_WEB_PROFILES=$web_ledger QWEN_WEB_MCP_SERVER=$script_directory/web-mcp/server.py \
    QWEN_WEB_PROVIDER=fake QWEN_WEB_TOKEN_KEY_FILE=$token_key_file QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_IMAGE_PROFILES=$image_ledger QWEN_IMAGE_TOKEN_KEY_FILE=$token_key_file \
    QWEN_PHYSICS_PROFILES=$physics_ledger_for_preset QWEN_PHYSICS_STATE_DIR=$state_directory/physics \
    QWEN_PHYSICS_RUNTIME_SHA256=$physics_runtime_sha256 \
    QWEN_GEOMETRY_PROFILES=$geometry_ledger_for_preset QWEN_GEOMETRY_STATE_DIR=$state_directory/geometry \
    QWEN_GEOMETRY_RUNTIME_SHA256=$geometry_runtime_sha256 \
    QWEN_SIDECAR_MCP_SERVER=$script_directory/sidecar-mcp/server.py QWEN_SIDECAR_TOKEN_KEY_FILE=$token_key_file \
    QWEN_WEB_AUTHORIZER_READY=1 QWEN_MODEL_REGISTRY=$registry QWEN_MODEL_ROOT=$model_root \
    "$script_directory/build-web-presets.sh" "$web_presets" >"$output_directory/build-web-presets.log" 2>&1; then
    preset_physics=$(sed -n 's/^# qwen_physics_profile=//p' "$web_presets")
    preset_geometry=$(sed -n 's/^# qwen_geometry_profile=//p' "$web_presets")
    expected_physics=-
    expected_geometry=-
    lane_armed physics && expected_physics=$physics_profile_id
    lane_armed geometry && expected_geometry=$geometry_profile_id
    if [ "$preset_physics" = "$expected_physics" ] && [ "$preset_geometry" = "$expected_geometry" ]; then
        record preset_generated accepted "physics_profile=$preset_physics geometry_profile=$preset_geometry sections=$(grep -c '^\[' "$web_presets")"
    else
        record preset_generated refused "the preset names physics=${preset_physics:-none} geometry=${preset_geometry:-none}"
        exit 1
    fi
else
    record preset_generated refused "$(tail -1 "$output_directory/build-web-presets.log")"
    exit 1
fi

launch_physics_runtime=''
launch_geometry_runtime=''
lane_armed physics && launch_physics_runtime=$output_directory/physx-rigid-runtime
lane_armed geometry && launch_geometry_runtime=$output_directory/optix-ray-runtime
if QWEN_WEB_PRESETS=$web_presets QWEN_WEB_PROFILES=$web_ledger QWEN_WEB_PROVIDER=fake \
    QWEN_WEB_TOKEN_KEY_FILE=$token_key_file QWEN_WEB_STATE_DIR=$output_directory/web-mcp \
    QWEN_WEB_BROKER_PORT=$broker_port QWEN_WEB_AUTHORIZER_READY=1 QWEN_IMAGE_TOKEN_KEY_FILE=$token_key_file \
    QWEN_PHYSICS_RUNTIME=$launch_physics_runtime QWEN_GEOMETRY_RUNTIME=$launch_geometry_runtime \
    QWEN_MODEL_REGISTRY=$registry QWEN_MODEL_ROOT=$model_root QWEN_MODEL_PATH=$control_model_path \
    "$script_directory/qwen-sidecar-launch.sh" default >"$output_directory/sidecar-launch.log" 2>&1; then
    record sidecar_launch accepted "$(grep -E '^(physics|geometry)_launch' "$output_directory/sidecar-launch.log" | tr '\n' ';')"
else
    record sidecar_launch refused "$(tail -3 "$output_directory/sidecar-launch.log" | tr '\n' ';')"
    cp "$state_directory/session.status" "$output_directory/failed-session.status" 2>/dev/null || :
    for lane in physics geometry; do
        cp "$state_directory/$lane-service.log" "$output_directory/failed-$lane-service.log" 2>/dev/null || :
    done
    cp "$state_directory/server.log" "$output_directory/failed-server.log" 2>/dev/null || :
    exit 1
fi
cp "$state_directory/session.status" "$output_directory/session.status"
secret_file=$(sed -n 's/^broker secret_file=//p' "$output_directory/session.status")
lease_path=''
for lane in physics geometry; do
    lane_armed "$lane" || continue
    lane_facts "$lane"
    service_pid=$(sed -n '1p' "$output_directory/session.status" | tr ' ' '\n' | sed -n "s/^${lane}_service_pid=//p")
    identity=$(sed -n "s/^${lane}_service_identity //p" "$output_directory/session.status" | sed -n '1p')
    if [ -n "$service_pid" ] && [ -n "$identity" ]; then
        record "$lane.service_recorded" accepted "pid=$service_pid $identity"
    else
        record "$lane.service_recorded" refused "pid=${service_pid:-none} identity=${identity:-none}"
    fi
    lane_lease=$(printf '%s' "$identity" | tr ' ' '\n' | sed -n 's/^lease=//p')
    if [ -z "$lease_path" ]; then
        lease_path=$lane_lease
    elif [ "$lane_lease" = "$lease_path" ]; then
        record "$lane.shares_the_session_lease" accepted "$lease_path"
    else
        record "$lane.shares_the_session_lease" refused "lease=$lane_lease against $lease_path"
    fi
    identity_runtime=$(printf '%s' "$identity" | tr ' ' '\n' | sed -n 's/^runtime_sha256=//p')
    if [ "$identity_runtime" = "$lane_runtime_sha256" ]; then
        record "$lane.service_announced_built_runtime" accepted "$lane_runtime_sha256"
    else
        record "$lane.service_announced_built_runtime" refused "announced=${identity_runtime:-none} built=$lane_runtime_sha256"
    fi
done
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
expected_tools=''
lane_armed geometry && expected_tools="geometry_ray_query,"
lane_armed physics && expected_tools="${expected_tools}physics_simulate_rigid,"
if [ "$tool_names" = "$expected_tools" ]; then
    record tool_enumeration accepted "$tool_names via $router_origin"
else
    record tool_enumeration refused "status=$call_status tools=${tool_names:-none} expected=$expected_tools"
fi
listing_field() {
    # listing_field TOOL JQ_PATH
    jq -r --arg t "$1" ".[] | select(.tool == \$t) | .definition.function.parameters.properties.$2 // empty" "$output_directory/tools.json" 2>/dev/null
}
call broker-health GET "$broker_origin/health" '' -H "Host: 127.0.0.1:$broker_port"
cp "$call_out" "$output_directory/broker-health.json"
for lane in physics geometry; do
    lane_facts "$lane"
    health_profile=$(jq -r ".${lane}_profile // empty" "$output_directory/broker-health.json" 2>/dev/null)
    if lane_armed "$lane"; then
        listed_runtime=$(listing_field "$lane_tool" profile_id.x_runtime_sha256)
        listed_scene=$(listing_field "$lane_tool" profile_id.x_scene)
        listed_ceiling=$(listing_field "$lane_tool" count.maximum)
        if [ "$listed_runtime" = "$lane_runtime_sha256" ] && [ "$listed_scene" = "$lane_scene" ] && [ "$listed_ceiling" = "$lane_timeout_count" ]; then
            record "$lane.listing_binds_runtime_scene_ceiling" accepted "scene=$listed_scene ceiling=$listed_ceiling"
        else
            record "$lane.listing_binds_runtime_scene_ceiling" refused "runtime=${listed_runtime:-none} scene=${listed_scene:-none} ceiling=${listed_ceiling:-none}"
        fi
        if [ "$health_profile" = "$lane_profile_id" ]; then
            record "$lane.broker_signs_profile" accepted "${lane}_profile=$health_profile"
        else
            record "$lane.broker_signs_profile" refused "${lane}_profile=${health_profile:-none}"
        fi
    elif [ -z "$health_profile" ]; then
        record "$lane.broker_signs_nothing_unarmed" accepted "${lane}_profile absent"
    else
        record "$lane.broker_signs_nothing_unarmed" refused "${lane}_profile=$health_profile"
    fi
done
call session GET "$broker_origin/session" '' -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port"
session_secret=$(jq -r '.session_secret // empty' "$call_out" 2>/dev/null)
if [ "$call_status" = 200 ] && [ -n "$session_secret" ]; then
    record session_secret_issued accepted "status=$call_status"
else
    record session_secret_issued refused "status=$call_status"
fi

grant_body() {
    # grant_body SERVICE PROFILE RUNTIME SCENE COUNT CEILING
    jq -cn --arg service "$1" --arg language "$profile_id" --arg sidecar "$2" --arg runtime "$3" \
        --arg scene "$4" --argjson count "$5" --argjson ceiling "$6" \
        '{context: "qwen-sidecar-run-v1", service: $service, language_profile: $language, sidecar_profile: $sidecar,
          runtime_sha256: $runtime, scene: $scene, count: $count, count_ceiling: $ceiling, conversation_generation: 0}'
}
lane_grant_body() {
    # lane_grant_body COUNT, over the lane_facts in force
    grant_body "$lane" "$lane_profile_id" "$lane_runtime_sha256" "$lane_scene" "$1" "$lane_timeout_count"
}
issue_grant() {
    # issue_grant LABEL ROUTE BODY
    call "$1" POST "$broker_origin$2" "$3" -H "Origin: $router_origin" -H "Host: 127.0.0.1:$broker_port" \
        -H "X-Qwen-Web-Session: $session_secret"
    issued_authorization=$(jq -r '.authorization // empty' "$call_out" 2>/dev/null)
}
tool_body() {
    # tool_body TOOL PARAMS
    jq -cn --arg m "$profile_id" --arg t "$1" --argjson p "$2" '{model: $m, tool: $t, params: $p, stream: false}'
}
run_params_for() {
    # run_params_for PROFILE COUNT AUTHORIZATION
    jq -cn --arg profile "$1" --argjson count "$2" --arg auth "$3" '{profile_id: $profile, count: $count, authorization: $auth}'
}
# sample_clients samples the driver's compute-client list, the lease's flock
# state, and every lane's lease status line at ten hertz.
sample_clients() {
    while :; do
        stamp=$(now)
        held=$(flock -n "$lease_path" true 2>/dev/null && printf free || printf held)
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null |
            sed "s|^|$stamp\t$held\tclient\t|" || :
        for status_lane in physics geometry; do
            status_file=$state_directory/$status_lane/vulkan-workload.status
            [ -f "$status_file" ] || continue
            printf '%s\t%s\tstatus\t%s\n' "$stamp" "$held" "$(sed -n '1p' "$status_file")"
        done
        printf '%s\t%s\ttick\n' "$stamp" "$held"
        sleep 0.1
    done
}
start_sampler() {
    sample_clients >"$1" 9>&- &
    sampler_pid=$!
}
stop_sampler() {
    # stop_sampler RAW TSV
    kill "$sampler_pid" 2>/dev/null || :; wait "$sampler_pid" 2>/dev/null || :; sampler_pid=''
    scrub_home <"$1" >"$2"
    rm -f "$1"
}
read_run() {
    # read_run RESPONSE: sets run_text, run_status, run_proof, result_runtime,
    # result_sha256 from the child's summary, under the lane_facts in force
    run_text=$(jq -r '.plain_text_response // empty' "$1" 2>/dev/null)
    run_status=$(printf '%s' "$run_text" | jq -r '.status // empty' 2>/dev/null)
    run_proof=$(printf '%s' "$run_text" | jq -r "$lane_proof_jq" 2>/dev/null)
    result_runtime=$(printf '%s' "$run_text" | jq -r '.runtime_sha256 // empty' 2>/dev/null)
    result_sha256=$(printf '%s' "$run_text" | jq -r '.result_sha256 // empty' 2>/dev/null)
}
# a well-formed digest for a lane this run never built, so a refusal of its
# body reads the route binding rather than the field's format
placeholder_sha256=$(printf '%064d' 0)
other_lane_body() {
    # other_lane_body LANE: a grant body for the named lane at a small count,
    # with placeholders where that lane was never built
    case $1 in
        physics) grant_body physics "$physics_profile_id" "${physics_runtime_sha256:-$placeholder_sha256}" "${physics_scene:-d6-chain-4}" 64 "$physics_timeout_count" ;;
        geometry) grant_body geometry "$geometry_profile_id" "${geometry_runtime_sha256:-$placeholder_sha256}" "${geometry_scene:-cube-and-plane}" 64 "$geometry_timeout_count" ;;
    esac
}

for lane in physics geometry; do
    lane_armed "$lane" || continue
    lane_facts "$lane"
    issue_grant "$lane-grant" "$lane_grant_route" "$(lane_grant_body "$lane_run_count")"
    authorization=$issued_authorization
    if [ "$call_status" = 200 ] && [ -n "$authorization" ]; then
        record "$lane.grant_issued" accepted "status=$call_status $lane_count_noun=$lane_run_count bytes=${#authorization}"
    else
        record "$lane.grant_issued" refused "status=$call_status $(head -c 160 "$call_out")"
    fi
    # the other lane's body at this lane's route: the broker binds each
    # route to one service, so this refuses whether or not the other lane
    # is armed
    other_lane=$lane_other
    other_body=$(other_lane_body "$other_lane")
    issue_grant "$lane-grant-other-body" "$lane_grant_route" "$other_body"
    if [ "$call_status" != 200 ]; then
        record "$lane.other_service_body_at_route_refused" accepted "status=$call_status $(jq -r '.error' "$call_out" 2>/dev/null | head -c 100)"
    else
        record "$lane.other_service_body_at_route_refused" refused "status=$call_status"
    fi
    if ! lane_armed "$other_lane"; then
        case $other_lane in physics) other_route=/grant-physics ;; *) other_route=/grant-geometry ;; esac
        issue_grant "$other_lane-grant-unarmed" "$other_route" "$other_body"
        if [ "$call_status" != 200 ]; then
            record "$other_lane.unarmed_route_refused" accepted "status=$call_status $(jq -r '.error' "$call_out" 2>/dev/null | head -c 100)"
        else
            record "$other_lane.unarmed_route_refused" refused "status=$call_status"
        fi
    fi

    run_params=$(run_params_for "$lane_profile_id" "$lane_run_count" "$authorization")
    start_sampler "$output_directory/$lane-clients.raw"
    run_started=$(now)
    call "$lane-run" POST "$router_origin/tools" "$(tool_body "$lane_tool" "$run_params")"
    run_ended=$(now)
    stop_sampler "$output_directory/$lane-clients.raw" "$output_directory/$lane-clients-during.tsv"
    read_run "$call_out"
    run_wall=$(elapsed "$run_started" "$run_ended")
    if [ "$call_status" = 200 ] && [ "$run_status" = completed ] && [ "$run_proof" = true ] && [ "$result_runtime" = "$lane_runtime_sha256" ]; then
        record "$lane.run_completed_with_gpu_proof" accepted "wall=${run_wall}s $lane_count_noun=$lane_run_count result_sha256=$result_sha256 $(printf '%s' "$run_text" | jq -r "$lane_figures_jq")"
    else
        record "$lane.run_completed_with_gpu_proof" refused "status=$call_status proof=${run_proof:-none} $(head -c 200 "$call_out")"
    fi
    if [ "$(printf '%s' "$run_text" | jq -r "has(\"$lane_count_noun\") and (.$lane_count_noun | type) == \"number\"" 2>/dev/null)" = true ] && \
       ! printf '%s' "$run_text" | jq -e '.result' >/dev/null 2>&1; then
        record "$lane.result_carries_summary_alone" accepted 'counts, proof, and digests; no per-body or per-ray state'
    else
        record "$lane.result_carries_summary_alone" refused "$(printf '%s' "$run_text" | head -c 160)"
    fi
    runtime_samples=$(grep -c "$lane_binary" "$output_directory/$lane-clients-during.tsv" || :)
    held_samples=$(awk -F '\t' '$2 == "held" && $3 == "tick"' "$output_directory/$lane-clients-during.tsv" | wc -l)
    if [ "$runtime_samples" -gt 0 ]; then
        record "$lane.nvml_compute_visibility" observed "runtime_samples=$runtime_samples lease_held_samples=$held_samples"
    else
        record "$lane.nvml_compute_visibility" observed "not_observed_during_sample lease_held_samples=$held_samples wall=${run_wall}s"
    fi

    call "$lane-run-replay" POST "$router_origin/tools" "$(tool_body "$lane_tool" "$run_params")"
    if [ "$(jq -r '.error // empty' "$call_out" 2>/dev/null | grep -c spent)" -ge 1 ]; then
        record "$lane.grant_replay_refused" accepted "$(jq -r '.error' "$call_out" | head -c 140)"
    else
        record "$lane.grant_replay_refused" refused "status=$call_status $(head -c 160 "$call_out")"
    fi
    ungranted=$(printf '%s' "$run_params" | jq -c 'del(.authorization)')
    call "$lane-run-no-grant" POST "$router_origin/tools" "$(tool_body "$lane_tool" "$ungranted")"
    if [ -n "$(jq -r '.error // empty' "$call_out" 2>/dev/null)" ]; then
        record "$lane.run_without_grant_refused" accepted "$(jq -r '.error' "$call_out" | head -c 140)"
    else
        record "$lane.run_without_grant_refused" refused "status=$call_status $(head -c 160 "$call_out")"
    fi
    issue_grant "$lane-grant-for-count" "$lane_grant_route" "$(lane_grant_body "$lane_run_count")"
    other_count=$(printf '%s' "$run_params" | jq -c --arg auth "$issued_authorization" '.authorization = $auth | .count = (.count + 1)')
    call "$lane-run-other-count" POST "$router_origin/tools" "$(tool_body "$lane_tool" "$other_count")"
    if [ "$(jq -r '.error // empty' "$call_out" 2>/dev/null | grep -c 'arguments differ')" -ge 1 ]; then
        record "$lane.count_outside_grant_refused" accepted "$(jq -r '.error' "$call_out" | head -c 140)"
    else
        record "$lane.count_outside_grant_refused" refused "status=$call_status $(head -c 160 "$call_out")"
    fi
    issue_grant "$lane-grant-for-lease" "$lane_grant_route" "$(lane_grant_body "$lane_run_count")"
    lease_params=$(printf '%s' "$run_params" | jq -c --arg auth "$issued_authorization" '.authorization = $auth')
    # the lease is held from outside for the whole call, so the service waits
    # its bounded deadline and refuses without starting a runtime. flock forks
    # the sleep it runs and the child inherits the locked descriptor, so the
    # release ends the child ahead of the leader and the next arm starts
    # against a lease proven free rather than one the sleep still holds.
    flock "$lease_path" sleep 75 9>&- &
    holder_pid=$!
    sleep 0.5
    call "$lane-run-lease-held" POST "$router_origin/tools" "$(tool_body "$lane_tool" "$lease_params")"
    pkill -TERM -P "$holder_pid" 2>/dev/null || :
    kill "$holder_pid" 2>/dev/null || :; wait "$holder_pid" 2>/dev/null || :
    if [ "$(jq -r '.error // empty' "$call_out" 2>/dev/null | grep -c 'lease')" -ge 1 ]; then
        record "$lane.held_lease_refuses_run" accepted "$(jq -r '.error' "$call_out" | head -c 140)"
    else
        record "$lane.held_lease_refuses_run" refused "status=$call_status $(head -c 160 "$call_out")"
    fi
    if flock -n "$lease_path" true 2>/dev/null; then
        record "$lane.lease_free_after_holder_released" accepted "$lease_path"
    else
        record "$lane.lease_free_after_holder_released" refused "$lease_path still held"
    fi
    issue_grant "$lane-grant-for-timeout" "$lane_grant_route" "$(lane_grant_body "$lane_timeout_count")"
    timeout_params=$(run_params_for "$lane_profile_id" "$lane_timeout_count" "$issued_authorization")
    timeout_started=$(now)
    call "$lane-run-timeout" POST "$router_origin/tools" "$(tool_body "$lane_tool" "$timeout_params")"
    timeout_wall=$(elapsed "$timeout_started" "$(now)")
    timeout_error=$(jq -r '.error // empty' "$call_out" 2>/dev/null)
    read_run "$call_out"
    if [ "$(printf '%s' "$timeout_error" | grep -c 'exceeded')" -ge 1 ]; then
        record "$lane.runtime_deadline_ends_the_run" accepted "wall=${timeout_wall}s $(printf '%s' "$timeout_error" | head -c 120)"
    elif [ "$lane_deadline_required" = no ] && [ "$run_status" = completed ] && [ "$run_proof" = true ]; then
        record "$lane.runtime_deadline_ends_the_run" observed "deadline_not_crossed $lane_count_noun=$lane_timeout_count wall=${timeout_wall}s under ${lane_timeout_s}s $(printf '%s' "$run_text" | jq -r "$lane_figures_jq")"
    else
        record "$lane.runtime_deadline_ends_the_run" refused "wall=${timeout_wall}s status=$call_status $(head -c 160 "$call_out")"
    fi
    sleep 1
    binary_comm=$(printf '%s' "$lane_binary" | cut -c1-15)
    if pgrep -x "$binary_comm" >/dev/null 2>&1; then
        record "$lane.timed_out_runtime_reaped" refused "$(pgrep -x "$binary_comm" | tr '\n' ' ')"
    else
        record "$lane.timed_out_runtime_reaped" accepted 'no runtime process survives the deadline'
    fi
done

if lane_armed physics && lane_armed geometry; then
    # A grant signed for one service presented at the other's tool: the child
    # verifies the service claim against its own lane ahead of any service
    # call, so the refusal lands with no runtime and no lease transition.
    lane_facts geometry
    issue_grant geometry-grant-for-cross /grant-geometry "$(lane_grant_body "$geometry_run_count")"
    cross_grant_status=$call_status
    cross_params=$(run_params_for "$physics_profile_id" "$physics_run_count" "$issued_authorization")
    start_sampler "$output_directory/cross-clients.raw"
    call cross-service-replay POST "$router_origin/tools" "$(tool_body physics_simulate_rigid "$cross_params")"
    stop_sampler "$output_directory/cross-clients.raw" "$output_directory/cross-clients-during.tsv"
    cross_error=$(jq -r '.error // empty' "$call_out" 2>/dev/null)
    cross_runtime_samples=$(grep -c 'physx-rigid-runtime\|optix-ray-runtime' "$output_directory/cross-clients-during.tsv" || :)
    cross_held=$(awk -F '\t' '$2 == "held" && $3 == "tick"' "$output_directory/cross-clients-during.tsv" | wc -l)
    # the refusal has to be the service binding by name: a malformed or
    # expired grant refuses too, and reads nothing about the binding
    if [ "$cross_grant_status" = 200 ] && [ "$(printf '%s' "$cross_error" | grep -c 'names another sidecar service')" -ge 1 ] && \
       [ "$cross_runtime_samples" = 0 ] && [ "$cross_held" = 0 ]; then
        record cross_service_grant_refused accepted "$(printf '%s' "$cross_error" | head -c 120) runtime_samples=0 lease_held_samples=0"
    else
        record cross_service_grant_refused refused "grant_status=$cross_grant_status status=$call_status error=${cross_error:-none} runtime_samples=$cross_runtime_samples lease_held_samples=$cross_held"
    fi

    # Contention: one run per lane released from one barrier against the
    # one lease. Both must complete with their proofs, no sample may name
    # both runtimes, and the holder that acquired second states a wait
    # above zero; a draw in which neither waited produced no contention and
    # measured nothing, so the pair is redrawn under fresh grants up to
    # QWEN_CONTENTION_REDRAWS times and the last draw is the record.
    contention_redraws=${QWEN_CONTENTION_REDRAWS:-3}
    draw=0
    while :; do
        draw=$((draw + 1))
        lane_facts physics
        issue_grant "physics-grant-for-contention-$draw" /grant-physics "$(lane_grant_body "$physics_run_count")"
        physics_contention=$(tool_body physics_simulate_rigid "$(run_params_for "$physics_profile_id" "$physics_run_count" "$issued_authorization")")
        lane_facts geometry
        issue_grant "geometry-grant-for-contention-$draw" /grant-geometry "$(lane_grant_body "$geometry_run_count")"
        geometry_contention=$(tool_body geometry_ray_query "$(run_params_for "$geometry_profile_id" "$geometry_run_count" "$issued_authorization")")
        exchange=$((exchange + 1))
        physics_stem=$output_directory/http/$exchange-contention-$draw-physics
        exchange=$((exchange + 1))
        geometry_stem=$output_directory/http/$exchange-contention-$draw-geometry
        contention_tsv=$output_directory/contention-$draw-clients-during.tsv
        # both callers block on the barrier file and leave together when it
        # appears, so the two requests reach the router within the poll
        # interval of each other rather than one curl start apart
        barrier=$output_directory/contention-$draw.barrier
        rm -f "$barrier"
        start_sampler "$output_directory/contention-$draw-clients.raw"
        ( while [ ! -e "$barrier" ]; do sleep 0.01; done
          call_into "$physics_stem" POST "$router_origin/tools" "$physics_contention" ) 9>&- &
        physics_call_pid=$!
        ( while [ ! -e "$barrier" ]; do sleep 0.01; done
          call_into "$geometry_stem" POST "$router_origin/tools" "$geometry_contention" ) 9>&- &
        geometry_call_pid=$!
        sleep 0.2
        contention_started=$(now)
        : >"$barrier"
        wait "$physics_call_pid" || :
        wait "$geometry_call_pid" || :
        contention_wall=$(elapsed "$contention_started" "$(now)")
        stop_sampler "$output_directory/contention-$draw-clients.raw" "$contention_tsv"
        rm -f "$barrier"
        holders=$(awk -F '\t' '$3 == "status" && $4 ~ /^state=held/ { print $4 }' "$contention_tsv" |
            sed -n 's/.*holder=\([a-z-]*\).*waited_ms=\([0-9]*\).*/\1 \2/p' | sort -u)
        holder_count=$(printf '%s\n' "$holders" | awk 'NF { print $1 }' | sort -u | grep -c . || :)
        waited=$(printf '%s\n' "$holders" | awk 'NF { print $1 "=" $2 "ms" }' | tr '\n' ' ')
        max_wait=$(printf '%s\n' "$holders" | awk 'NF && $2 > m { m = $2 } END { print m + 0 }')
        if [ "$holder_count" = 2 ] && [ "$max_wait" -gt 0 ]; then
            break
        fi
        record "contention_draw_$draw" observed "no wait recorded: holders=$holder_count $waited; redrawn"
        [ "$draw" -lt "$contention_redraws" ] || break
    done
    lane_facts physics
    read_run "$physics_stem.response"
    physics_ok=no
    [ "$run_status" = completed ] && [ "$run_proof" = true ] && [ "$result_runtime" = "$physics_runtime_sha256" ] && physics_ok=yes
    physics_figures=$(printf '%s' "$run_text" | jq -r "$lane_figures_jq" 2>/dev/null || :)
    lane_facts geometry
    read_run "$geometry_stem.response"
    geometry_ok=no
    [ "$run_status" = completed ] && [ "$run_proof" = true ] && [ "$result_runtime" = "$geometry_runtime_sha256" ] && geometry_ok=yes
    geometry_figures=$(printf '%s' "$run_text" | jq -r "$lane_figures_jq" 2>/dev/null || :)
    if [ "$physics_ok" = yes ] && [ "$geometry_ok" = yes ]; then
        record contention_both_complete accepted "draw=$draw wall=${contention_wall}s physics: $physics_figures; geometry: $geometry_figures"
    else
        record contention_both_complete refused "draw=$draw physics=$physics_ok geometry=$geometry_ok $(head -c 120 "$physics_stem.response") $(head -c 120 "$geometry_stem.response")"
    fi
    # a stamp naming both runtimes in the client list is the overlap the
    # lease exists to prevent
    overlap_stamps=$(awk -F '\t' '$3 == "client" && $4 ~ /physx-rigid-runtime/ { p[$1] = 1 }
        $3 == "client" && $4 ~ /optix-ray-runtime/ { g[$1] = 1 }
        END { n = 0; for (s in p) if (s in g) n++; print n }' "$contention_tsv")
    physics_seen=$(grep -c 'physx-rigid-runtime' "$contention_tsv" || :)
    geometry_seen=$(grep -c 'optix-ray-runtime' "$contention_tsv" || :)
    if [ "$overlap_stamps" = 0 ]; then
        record contention_runtimes_never_coresident accepted "physics_samples=$physics_seen geometry_samples=$geometry_seen overlapping_samples=0"
    else
        record contention_runtimes_never_coresident refused "overlapping_samples=$overlap_stamps"
    fi
    if [ "$holder_count" = 2 ] && [ "$max_wait" -gt 0 ]; then
        record contention_second_holder_waited accepted "draw=$draw $waited"
    else
        record contention_second_holder_waited refused "draw=$draw holders=$holder_count $waited; no draw produced a wait"
    fi
fi

# The page turns: the same proposal, dialog, grant, and run per lane through
# the appliance's headless Chromium, reading the driver's own request log.
for lane in physics geometry; do
    lane_armed "$lane" || continue
    lane_facts "$lane"
    browser_prompt=$lane_prompt
    record "$lane.browser_prompt_used" observed "$browser_prompt"
    browser_report=$output_directory/$lane-browser-turn.json
    if python3 "$script_directory/web-mcp/drive-fallback-page.py" --lane sidecar --origin "$router_origin" \
        --api-key-file "$api_key_file" --broker "$broker_origin" --model "$profile_id" \
        --prompt "$browser_prompt" >"$browser_report" 2>"$output_directory/$lane-browser-turn.err"; then
        grant_posts=$(jq --arg r "$lane_grant_route" '[.requests[]? | select(.url | endswith($r)) | select(.method == "POST")] | length' "$browser_report" 2>/dev/null || printf 0)
        tool_posts=$(jq '[.requests[]? | select(.url | test("/tools$")) | select(.method == "POST")] | length' "$browser_report" 2>/dev/null || printf 0)
        origins=$(jq -r '[.requests[]?.url | capture("^(?<o>https?://[^/]+)").o] | unique | join(",")' "$browser_report" 2>/dev/null)
        if [ "$grant_posts" = 1 ] && [ "$tool_posts" -ge 1 ]; then
            record "$lane.browser_turn_ran" accepted "grant_posts=$grant_posts tool_posts=$tool_posts origins=$origins"
        else
            record "$lane.browser_turn_ran" refused "grant_posts=$grant_posts tool_posts=$tool_posts origins=$origins"
        fi
        extra=$(printf '%s' "$origins" | tr ',' '\n' | grep -v "^$router_origin$" | grep -v "^$broker_origin$" || :)
        if [ -z "$extra" ] && [ -n "$origins" ]; then
            record "$lane.browser_origins_bounded" accepted "$origins"
        else
            record "$lane.browser_origins_bounded" refused "$origins"
        fi
        reply_excerpt=$(jq -r '[.history[]? | select(.role == "assistant") | .content // ""] | last // empty' "$browser_report" 2>/dev/null | tr '\n' ' ' | head -c 200)
        tool_message=$(jq -r '[.history[]? | select(.role == "tool") | .content // ""] | last // empty' "$browser_report" 2>/dev/null)
        record "$lane.browser_reply" observed "$reply_excerpt"
        # the tool message is the child's JSON summary; its status and its
        # proof are read by a JSON parse rather than by a substring
        browser_run_status=$(printf '%s' "$tool_message" | jq -r '.status // empty' 2>/dev/null || :)
        browser_run_proof=$(printf '%s' "$tool_message" | jq -r "$lane_proof_jq" 2>/dev/null || :)
        browser_count=$(printf '%s' "$tool_message" | jq -r ".$lane_count_noun // \"-\"" 2>/dev/null || :)
        if [ "$browser_run_status" = completed ] && [ "$browser_run_proof" = true ]; then
            record "$lane.browser_tool_message_completed" accepted "status=completed proof=true $lane_count_noun=$browser_count"
        else
            record "$lane.browser_tool_message_completed" refused "$(printf '%s' "$tool_message" | head -c 160)"
        fi
    else
        record "$lane.browser_turn_ran" refused "$(tail -3 "$output_directory/$lane-browser-turn.err" | tr '\n' ';')"
    fi
done

# Teardown: the session, every service, runtime, socket, and the lease all
# leave, proven by the teardown and each lane's own residue check.
if "$script_directory/qwen-teardown.sh" >"$output_directory/teardown.log" 2>&1; then
    torn_down=1
    record teardown_clean accepted "$(tail -1 "$output_directory/teardown.log")"
else
    torn_down=1
    record teardown_clean refused "$(tail -3 "$output_directory/teardown.log" | tr '\n' ';')"
fi
for lane in physics geometry; do
    lane_armed "$lane" || continue
    lane_facts "$lane"
    if "$script_directory/$lane_residue_check" "$lane_state_directory" >"$output_directory/$lane-teardown.log" 2>&1; then
        record "$lane.residue_clean" accepted "$(tail -1 "$output_directory/$lane-teardown.log")"
    else
        record "$lane.residue_clean" refused "$(tail -2 "$output_directory/$lane-teardown.log" | tr '\n' ';')"
    fi
done
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
