#!/bin/sh
set -eu

# Fill and decode a near-full cache with the projector loaded, so a vision row
# can claim a numeric validated_filled_depth.
#
# check-validated-tuples.sh maps a models.tsv row whose `projector` field reads
# `required` to expected_projector_state `loaded`, and llama-bench takes no
# --mmproj and allocates no projector
# buffers. Every arm a bench harness records therefore reads
# projector_state=none, and the vision rows qwen35-4b-base, qwen35-2b, and
# lfm25-vl-16b keep `-` in validated_filled_depth however many llama-bench arms
# they accumulate. This harness runs llama-server standalone with the
# projector attached, which is the tuple those rows need.
#
# The depth is reached through the server rather than through a bench flag. One
# chat completion carries a fixture image plus padding text, `/tokenize`
# measures the padding, and the server's own timings.prompt_n decides whether
# the arm met its depth. The image contributes a token lump `/tokenize` cannot
# see -- the route tokenizes text and the projector writes image tokens inside
# the chat pipeline -- so a probe request measures the template and image
# overhead first and the padding closes the remainder.
#
# The acceptance window is asymmetric because decode follows the fill inside
# one allocation. prompt_n at or above DEPTH leaves no room for the generated
# tokens and drives eviction rather than a filled decode, so an arm passes on
# `DEPTH - 2% <= prompt_n <= DEPTH - decode tokens`.
#
# Each arm ends with a control the fixture's own generator declares: bars.png
# holds four bars whose tallest is JUN at 150, so an answer naming JUN proves
# the projector still encodes into the language model's embedding space after
# the deep fill. A failed control establishes device or projector corruption
# and halts the chain rather than measuring a broken device.

if [ "$#" -ne 2 ]; then
    printf 'usage: %s MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'depths from QWEN_WEDGE_DEPTHS, default "8192 16384 32768"\n' >&2
    printf 'model root from QWEN_MODEL_ROOT, default $HOME/models\n' >&2
    printf 'QWEN_MMPROJ overrides the projector select-projector.sh resolves\n' >&2
    printf 'QWEN_PROJECTOR_ARM_TIMEOUT_S overrides the per-arm request limit,\n' >&2
    printf 'default 300 + depth/2 seconds; QWEN_PROJECTOR_KILL_AFTER_S\n' >&2
    printf 'overrides the SIGKILL grace period, default 30\n' >&2
    exit 2
fi

# The projector-summary.tsv and wedge-metadata.tsv schema version. A metadata
# file whose header carries no ledger_version field predates this field and is
# refused rather than read as if version 1 described an unmarked format.
ledger_version=1

model_id=$1
output_directory=$2
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_reader=${QWEN_MODEL_REGISTRY_READER:-$script_directory/model-registry.sh}
projector_selector=${QWEN_PROJECTOR_SELECTOR:-$script_directory/select-projector.sh}
clock_sampler=${QWEN_CLOCK_SAMPLER:-$script_directory/sample-nvidia-clocks.sh}
llama_server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-server"}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
image_directory=${QWEN_QUALITY_IMAGE_DIRECTORY:-$script_directory/quality-images}
depths=${QWEN_WEDGE_DEPTHS:-"8192 16384 32768"}
decode_tokens=${QWEN_PROJECTOR_DECODE_TOKENS:-32}
fill_margin_tokens=${QWEN_PROJECTOR_FILL_MARGIN:-128}
server_port=${QWEN_PROJECTOR_PROBE_PORT:-18087}
ready_timeout_s=${QWEN_PROJECTOR_READY_TIMEOUT_S:-300}
arm_kill_after_s=${QWEN_PROJECTOR_KILL_AFTER_S:-30}
control_fixture=${QWEN_PROJECTOR_CONTROL_FIXTURE:-bars}
control_answer=${QWEN_PROJECTOR_CONTROL_ANSWER:-jun}
control_prompt=${QWEN_PROJECTOR_CONTROL_PROMPT:-'Which bar is tallest in this chart? Reply with its label alone.'}
evidence_root=${QWEN_PROJECTOR_EVIDENCE_ROOT:-evidence/depth-validation-32k-projector}
# The kernel-log reader is named rather than hardcoded so a harness test drives
# the reset and fault accounting on a host whose own dmesg is restricted.
dmesg_command=${QWEN_DMESG_COMMAND:-dmesg}

for numeric_setting_name in decode_tokens fill_margin_tokens server_port \
    ready_timeout_s arm_kill_after_s; do
    numeric_setting_value=$(eval "printf '%s' \"\$$numeric_setting_name\"")
    case $numeric_setting_value in
        '' | *[!0-9]* | 0)
            printf '%s must be a positive integer: %s\n' \
                "$numeric_setting_name" "$numeric_setting_value" >&2
            exit 2
            ;;
    esac
done
case ${QWEN_PROJECTOR_ARM_TIMEOUT_S:-} in
    '') ;;
    *[!0-9]* | 0)
        printf 'QWEN_PROJECTOR_ARM_TIMEOUT_S must be a positive integer: %s\n' \
            "$QWEN_PROJECTOR_ARM_TIMEOUT_S" >&2
        exit 2
        ;;
esac
for requested_depth in $depths; do
    case $requested_depth in
        '' | *[!0-9]* | 0)
            printf 'QWEN_WEDGE_DEPTHS must hold positive integers: %s\n' \
                "$requested_depth" >&2
            exit 2
            ;;
    esac
    if [ "$requested_depth" -le "$((decode_tokens + fill_margin_tokens))" ]; then
        printf 'depth %s leaves no room for %s decode tokens beyond a %s-token margin\n' \
            "$requested_depth" "$decode_tokens" "$fill_margin_tokens" >&2
        exit 2
    fi
    # The margin has to fit inside the 2% shortfall the arm accepts, or every
    # arm reports a prompt too short for its own acceptance window. The
    # expression matches the floor the arm's own acceptance test computes.
    if [ "$fill_margin_tokens" -gt "$((requested_depth * 2 / 100))" ]; then
        printf 'fill margin %s exceeds the 2%% acceptance window at depth %s\n' \
            "$fill_margin_tokens" "$requested_depth" >&2
        exit 2
    fi
done

read_registry_field() {
    "$registry_reader" id "$model_id" "$1"
}

model_file=$(read_registry_field model_file)
projector_requirement=$(read_registry_field projector)
cache_type_k=$(read_registry_field cache_type_k)
cache_type_v=$(read_registry_field cache_type_v)
flash_attention=$(read_registry_field flash_attention)
batch_size=$(read_registry_field batch)
ubatch_size=$(read_registry_field ubatch)
model_path=$model_root/$model_file

if [ "$projector_requirement" != required ]; then
    printf 'registry row %s reads projector %s; this harness measures the loaded-projector tuple\n' \
        "$model_id" "$projector_requirement" >&2
    exit 2
fi
if [ ! -x "$llama_server" ]; then
    printf 'llama-server is not executable: %s\n' "$llama_server" >&2
    exit 2
fi
if [ ! -f "$model_path" ]; then
    printf 'model is not a regular file: %s\n' "$model_path" >&2
    exit 2
fi

# select-projector.sh exits 0 with empty output on an ambiguous directory, so
# the emptiness of its answer rather than its status decides. QWEN_MMPROJ is
# the same override qwen-capacity-policy.sh honours.
projector_path=${QWEN_MMPROJ:-}
if [ -z "$projector_path" ]; then
    projector_path=$("$projector_selector" "$model_path")
fi
if [ -z "$projector_path" ] || [ ! -f "$projector_path" ]; then
    printf 'projector for %s is unresolved; set QWEN_MMPROJ to choose one\n' \
        "$model_id" >&2
    exit 2
fi

control_image=''
for candidate_suffix in png jpg jpeg; do
    if [ -f "$image_directory/$control_fixture.$candidate_suffix" ]; then
        control_image=$image_directory/$control_fixture.$candidate_suffix
        break
    fi
done
if [ -z "$control_image" ]; then
    printf 'control fixture is absent: %s/%s\n' \
        "$image_directory" "$control_fixture" >&2
    exit 2
fi

if pgrep -x llama-server >/dev/null 2>&1 ||
   pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/projector-summary.tsv
emitted_rows=$output_directory/validated-tuples-rows.tsv
# status and control_status are the request-level outcomes; health carries the
# promotion signal a downstream consumer reads instead of recomputing them
# beside the kernel counts. `healthy` is a passing fill, a passing control, and
# a kernel delta confirming zero resets and zero faults; `unhealthy` is any
# failure or a confirmed reset or fault; `unverified` is a clean run whose
# dmesg was unreadable, where a recovery this probe never saw cannot be told
# apart from a clean device.
summary_header='arm	model_id	depth	batch	ubatch	cache_k	cache_v	flash_attn	projector_state	status	prompt_n	prefill_s	decode_tok_s	ring_resets	gpu_faults	vram_peak_mib	gtt_peak_mib	control_status	control_answer	health	hazard_class	server_log'
summary_field_count=22
summary_has_arms=0
if [ -s "$summary" ]; then
    if [ "$(sed -n '1p' "$summary")" != "$summary_header" ]; then
        printf 'projector summary header is incompatible with this harness: %s\n' \
            "$summary" >&2
        exit 2
    fi
    malformed_line=$(awk -F'\t' -v expected="$summary_field_count" '
        NR > 1 && (NF != expected ||
                   $1 != "d" $3 "-b" $4 "-ub" $5 "-proj") {
            print NR
            exit
        }' "$summary")
    if [ -n "$malformed_line" ]; then
        printf 'projector summary carries a malformed arm row at line %s: %s\n' \
            "$malformed_line" "$summary" >&2
        exit 2
    fi
    duplicate_arm=$(awk -F'\t' 'NR > 1 && seen[$1]++ { print $1; exit }' "$summary")
    if [ -n "$duplicate_arm" ]; then
        printf 'projector summary carries duplicate arm identity: %s\n' \
            "$duplicate_arm" >&2
        exit 2
    fi
    if awk 'NR > 1 { found = 1; exit } END { exit !found }' "$summary"; then
        summary_has_arms=1
    fi
else
    printf '%s\n' "$summary_header" >"$summary"
fi

# A matching arm label is not a matching measurement when the weights, the
# projector, the served tuple, or the control claim changes. The two digests
# bind every resumed row to immutable input bytes rather than to reusable
# paths. The decode length and the fill margin join them because the two set
# the acceptance window an arm passed under, so a resume at another pair would
# admit a row measured against a different window. The control fixture enters
# the gate by name and declared answer rather than by digest, because deflate
# re-encodes a fixture to different bytes with identical pixels across hosts
# and a byte digest would refuse a legitimate resume.
metadata=$output_directory/wedge-metadata.tsv
metadata_header='ledger_version	model_id	model_sha256	model_bytes	projector_sha256	projector_bytes	cache_k	cache_v	flash_attn	batch	ubatch	decode_tokens	fill_margin	control_fixture	control_answer'
model_sha256=$(nice -n 19 sha256sum "$model_path")
model_sha256=${model_sha256%% *}
model_bytes=$(stat -c %s -- "$model_path")
projector_sha256=$(nice -n 19 sha256sum "$projector_path")
projector_sha256=${projector_sha256%% *}
projector_bytes=$(stat -c %s -- "$projector_path")
metadata_row="$ledger_version	$model_id	$model_sha256	$model_bytes	$projector_sha256	$projector_bytes	$cache_type_k	$cache_type_v	$flash_attention	$batch_size	$ubatch_size	$decode_tokens	$fill_margin_tokens	$control_fixture	$control_answer"
if [ -s "$metadata" ]; then
    if [ "$(sed -n '1p' "$metadata")" != "$metadata_header" ] ||
       [ "$(sed -n '2p' "$metadata")" != "$metadata_row" ] ||
       [ -n "$(sed -n '3p' "$metadata")" ]; then
        printf 'projector metadata does not match this model, projector, tuple, or control: %s\n' \
            "$metadata" >&2
        exit 2
    fi
elif [ "$summary_has_arms" -eq 1 ]; then
    printf 'projector summary has arms but no model identity metadata: %s\n' \
        "$metadata" >&2
    exit 2
else
    printf '%s\n%s\n' "$metadata_header" "$metadata_row" >"$metadata"
fi

# projector-identity.tsv is provenance rather than a resume gate: one row per
# invocation naming the tool, fixture, and driver versions an arm ran under,
# appended rather than validated. Absent evidence reads `-`.
identity=$output_directory/projector-identity.tsv
identity_header='run_utc	llama_server_sha256	llama_cpp_commit	runner_sha256	sampler_sha256	control_image_sha256	kernel_release	vulkan_driver_version	gpu_kernel_module_version	vulkan_profile	argv'
if [ ! -s "$identity" ]; then
    printf '%s\n' "$identity_header" >"$identity"
fi
llama_server_sha256=$(nice -n 19 sha256sum "$llama_server")
llama_server_sha256=${llama_server_sha256%% *}
runner_sha256=$(nice -n 19 sha256sum "$0")
runner_sha256=${runner_sha256%% *}
sampler_sha256=-
if [ -r "$clock_sampler" ]; then
    sampler_sha256=$(nice -n 19 sha256sum "$clock_sampler")
    sampler_sha256=${sampler_sha256%% *}
fi
control_image_sha256=$(nice -n 19 sha256sum "$control_image")
control_image_sha256=${control_image_sha256%% *}
llama_cpp_commit=-
if server_version_output=$(timeout 5s "$llama_server" --version 2>&1); then
    parsed_commit=$(printf '%s\n' "$server_version_output" |
        grep -o 'build: [0-9a-f]\{4,\}' | tail -n1 | awk '{ print $2 }')
    [ -z "$parsed_commit" ] || llama_cpp_commit=$parsed_commit
fi
kernel_release=$(uname -r)
vulkan_driver_version=-
if command -v vulkaninfo >/dev/null 2>&1; then
    parsed_driver=$(timeout 5s vulkaninfo --summary 2>/dev/null |
        awk -F': *' '/driverInfo/ { print $2; exit }')
    [ -z "$parsed_driver" ] || vulkan_driver_version=$parsed_driver
fi
gpu_kernel_module_version=-
if command -v modinfo >/dev/null 2>&1; then
    parsed_module=$(modinfo nvidia 2>/dev/null |
        awk -F': *' '/^version:/ { print $2; exit }')
    [ -z "$parsed_module" ] || gpu_kernel_module_version=$parsed_module
fi
identity_argv=$(printf '%s ' "$0" "$@" | tr '\t\n' '  ')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$llama_server_sha256" "$llama_cpp_commit" \
    "$runner_sha256" "$sampler_sha256" "$control_image_sha256" \
    "$kernel_release" "$vulkan_driver_version" "$gpu_kernel_module_version" \
    "${QWEN_VULKAN_PROFILE:-unset}" "$identity_argv" >>"$identity"

# A killed run otherwise leaves the server holding the device, the sampler
# writing once a second into a file the next run recreates, and a dmesg reader
# attached to the ring buffer. Each owner is ended with the script that started
# it.
server_pid=''
sampler_pid=''
kernel_follow_pid=''
active_arm_label=''

stop_server() {
    [ -n "$server_pid" ] || return 0
    kill -TERM "$server_pid" 2>/dev/null || true
    stop_waited=0
    while [ "$stop_waited" -lt "$arm_kill_after_s" ]; do
        kill -0 "$server_pid" 2>/dev/null || break
        sleep 1
        stop_waited=$((stop_waited + 1))
    done
    kill -KILL "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''
}
stop_sampler() {
    [ -n "$sampler_pid" ] || return 0
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=''
}
stop_kernel_follow() {
    [ -n "$kernel_follow_pid" ] || return 0
    kill "$kernel_follow_pid" 2>/dev/null || true
    wait "$kernel_follow_pid" 2>/dev/null || true
    kernel_follow_pid=''
}
interrupt_run() {
    signal_status=$1
    stop_server
    stop_sampler
    stop_kernel_follow
    if [ -n "$active_arm_label" ]; then
        printf 'arm_abort_utc=%s label=%s status=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$active_arm_label" \
            "$signal_status" >&2
    fi
    printf 'depth_projector=interrupted status=%s output_directory=%s\n' \
        "$signal_status" "$output_directory" >&2
    exit "$signal_status"
}
trap 'stop_server; stop_sampler; stop_kernel_follow' EXIT
trap 'interrupt_run 129' HUP
trap 'interrupt_run 130' INT
trap 'interrupt_run 143' TERM

kernel_line_count() {
    if $dmesg_command >/dev/null 2>&1; then
        $dmesg_command | wc -l
    else
        printf 'unavailable\n'
    fi
}

kernel_delta_lines() {
    delta_before=$1
    delta_file=$2
    rm -f -- "$delta_file"
    [ "$delta_before" != unavailable ] || return 0
    $dmesg_command | tail -n "+$((delta_before + 1))" >"$delta_file" 2>/dev/null ||
        true
}

# `dmesg --follow-new` streams the delta to disk as it arrives, which survives a
# ring-buffer wrap the before-count-and-subtract method loses the earliest
# lines to. A short-lived probe distinguishes a following dmesg from one that
# replays the buffer once and exits; where none follows, the offset method
# stands in.
kernel_capture_method=offset
start_kernel_capture() {
    capture_file=$1
    kernel_capture_method=offset
    $dmesg_command --follow-new >"$capture_file" 2>/dev/null &
    kernel_follow_pid=$!
    sleep 0.2
    if kill -0 "$kernel_follow_pid" 2>/dev/null; then
        kernel_capture_method=follow
    else
        wait "$kernel_follow_pid" 2>/dev/null || true
        kernel_follow_pid=''
    fi
}

count_kernel_hazards() {
    hazard_file=$1
    hazard_pattern=$2
    if [ -f "$hazard_file" ]; then
        grep -c "$hazard_pattern" "$hazard_file" || true
    else
        printf 'unavailable\n'
    fi
}

# classify_hazard names what the kernel delta and the server log together say
# happened, beside the reset and fault counts. A clean arm reads `none` and
# several classes join with a comma.
classify_hazard() {
    hazard_kernel_file=$1
    hazard_server_log=$2
    hazard_resets=$3
    hazard_faults=$4
    hazard_control_status=$5
    hazard_classes=''
    hazard_has_page_fault=0
    if [ -f "$hazard_kernel_file" ]; then
        grep -qi 'page fault' "$hazard_kernel_file" 2>/dev/null &&
            hazard_has_page_fault=1
        if grep -qiE 'gfxhub.*page fault|page fault.*gfxhub' \
            "$hazard_kernel_file" 2>/dev/null; then
            hazard_classes=${hazard_classes:+$hazard_classes,}gfxhub-page-fault
        fi
        if grep -qE 'VM_L2_PROTECTION_FAULT|PROTECTION_FAULT' \
            "$hazard_kernel_file" 2>/dev/null; then
            hazard_classes=${hazard_classes:+$hazard_classes,}VM-protection-fault
        fi
        if [ "$hazard_has_page_fault" -eq 0 ] &&
           grep -qE 'ring reset|Ring .* reset|device wedged|GPU reset' \
               "$hazard_kernel_file" 2>/dev/null; then
            hazard_classes=${hazard_classes:+$hazard_classes,}ring-timeout-only
        fi
    fi
    if grep -qiE 'device lost|VK_ERROR_DEVICE_LOST' "$hazard_server_log" \
        2>/dev/null; then
        if { [ "$hazard_resets" = unavailable ] || [ "$hazard_resets" -eq 0 ]; } &&
           { [ "$hazard_faults" = unavailable ] || [ "$hazard_faults" -eq 0 ]; }; then
            hazard_classes=${hazard_classes:+$hazard_classes,}device-lost-without-kernel-record
        fi
    fi
    if [ "$hazard_resets" != unavailable ] && [ "$hazard_resets" -gt 0 ] &&
       [ "$hazard_control_status" != ok ]; then
        hazard_classes=${hazard_classes:+$hazard_classes,}post-reset-control-failure
    fi
    printf '%s' "${hazard_classes:-none}"
}

# The served tuple this harness measures is the one qwen-capacity-policy.sh
# builds for a single-model launch: strict Vulkan placement with the CPU
# fallback refused, the registry's cache triple and submission geometry, one
# slot, and the projector attached. --cache-ram 0, --ctx-checkpoints 0, and
# --no-context-shift keep the fill and the control from reusing a cached
# prefix, so prompt_n reports the tokens the arm actually prefilled.
start_server() {
    start_depth=$1
    start_log=$2
    env LLAMA_NO_CPU_FALLBACK=1 DISPLAY= WAYLAND_DISPLAY= \
        nice -n 19 ionice -c 3 "$llama_server" \
        --model "$model_path" \
        --mmproj "$projector_path" \
        --alias "$model_id" \
        --host 127.0.0.1 \
        --port "$server_port" \
        --no-ui \
        --log-verbosity 4 \
        --device Vulkan0 \
        --split-mode none \
        --n-gpu-layers all \
        --override-tensor '.*=Vulkan0' \
        --fit off \
        --parallel 1 \
        --threads 1 \
        --threads-batch 1 \
        --ctx-checkpoints 0 \
        --cache-ram 0 \
        --no-context-shift \
        --offline \
        --ctx-size "$start_depth" \
        --batch-size "$batch_size" \
        --ubatch-size "$ubatch_size" \
        --flash-attn "$flash_attention" \
        --cache-type-k "$cache_type_k" \
        --cache-type-v "$cache_type_v" \
        >"$start_log" 2>&1 &
    server_pid=$!
}

wait_for_server() {
    wait_elapsed=0
    while [ "$wait_elapsed" -lt "$ready_timeout_s" ]; do
        if curl --silent --fail --max-time 5 \
            "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            return 1
        fi
        sleep 1
        wait_elapsed=$((wait_elapsed + 1))
    done
    return 1
}

device_corrupt=0

run_arm() {
    arm_depth=$1
    arm_label=d$arm_depth-b$batch_size-ub$ubatch_size-proj
    arm_log=$output_directory/$arm_label.server.log
    arm_samples=$output_directory/$arm_label.clocks.tsv
    arm_kernel=$output_directory/$arm_label.dmesg.txt
    arm_requests=$output_directory/$arm_label.requests.txt
    arm_timeout_s=${QWEN_PROJECTOR_ARM_TIMEOUT_S:-$((300 + arm_depth / 2))}

    recorded_count=$(awk -F'\t' -v label="$arm_label" \
        'NR > 1 && $1 == label { count++ } END { print count + 0 }' "$summary")
    if [ "$recorded_count" -eq 1 ]; then
        for retained_artifact in "$arm_log" "$arm_samples" "$arm_requests"; do
            if [ ! -f "$retained_artifact" ]; then
                printf 'recorded arm %s is missing retained artifact: %s\n' \
                    "$arm_label" "$retained_artifact" >&2
                exit 2
            fi
        done
        recorded_status=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $10; exit }' "$summary")
        recorded_resets=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $14; exit }' "$summary")
        recorded_faults=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $15; exit }' "$summary")
        recorded_control_status=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $18; exit }' "$summary")
        recorded_health=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $20; exit }' "$summary")
        recorded_hazard_class=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $21; exit }' "$summary")
        recorded_projector_state=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $9; exit }' "$summary")
        if [ -z "$recorded_hazard_class" ] ||
           [ "$recorded_projector_state" != loaded ]; then
            printf 'recorded arm %s carries an incomplete hazard class or projector state\n' \
                "$arm_label" >&2
            exit 2
        fi
        case $recorded_resets in
            unavailable) ;;
            '' | *[!0-9]*)
                printf 'recorded arm %s carries invalid reset count: %s\n' \
                    "$arm_label" "$recorded_resets" >&2
                exit 2
                ;;
        esac
        case $recorded_faults in
            unavailable) ;;
            '' | *[!0-9]*)
                printf 'recorded arm %s carries invalid fault count: %s\n' \
                    "$arm_label" "$recorded_faults" >&2
                exit 2
                ;;
        esac
        if [ "$recorded_resets" = unavailable ] ||
           [ "$recorded_faults" = unavailable ]; then
            if [ "$recorded_resets" != "$recorded_faults" ] ||
               [ -e "$arm_kernel" ]; then
                printf 'recorded arm %s carries inconsistent kernel-delta evidence\n' \
                    "$arm_label" >&2
                exit 2
            fi
        elif [ ! -f "$arm_kernel" ]; then
            printf 'recorded arm %s is missing retained artifact: %s\n' \
                "$arm_label" "$arm_kernel" >&2
            exit 2
        fi
        expected_health=unhealthy
        if [ "$recorded_status" = ok ] && [ "$recorded_control_status" = ok ]; then
            if [ "$recorded_resets" = unavailable ]; then
                expected_health=unverified
            elif [ "$recorded_resets" -eq 0 ] && [ "$recorded_faults" -eq 0 ]; then
                expected_health=healthy
            fi
        fi
        if [ "$recorded_health" != "$expected_health" ]; then
            printf 'recorded arm %s carries health %s inconsistent with its status, control, resets, and faults (expected %s)\n' \
                "$arm_label" "$recorded_health" "$expected_health" \
                >&2
            exit 2
        fi
        # A resumed arm restores the halt state the live path derives, so a
        # recorded failure stops the chain on the second invocation exactly as
        # it stopped it on the first.
        if [ "$recorded_status" != ok ] || [ "$recorded_control_status" != ok ]; then
            device_corrupt=1
        fi
        printf 'arm_resume_skip label=%s status=%s resets=%s control=%s health=%s\n' \
            "$arm_label" "$recorded_status" "$recorded_resets" \
            "$recorded_control_status" "$recorded_health"
        return 0
    fi
    for incomplete_artifact in "$arm_log" "$arm_samples" "$arm_requests"; do
        if [ -e "$incomplete_artifact" ]; then
            printf 'unrecorded arm %s has incomplete artifact; use a new output directory: %s\n' \
                "$arm_label" "$incomplete_artifact" >&2
            exit 2
        fi
    done

    active_arm_label=$arm_label
    start_kernel_capture "$arm_kernel"
    kernel_before=unavailable
    [ "$kernel_capture_method" = follow ] || kernel_before=$(kernel_line_count)
    printf 'arm_start_utc=%s label=%s depth=%s cache=%s/%s fa=%s projector=loaded kernel_capture=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$arm_depth" \
        "$cache_type_k" "$cache_type_v" "$flash_attention" \
        "$kernel_capture_method"

    : >"$arm_samples"
    if [ -x "$clock_sampler" ]; then
        "$clock_sampler" "$arm_samples" &
        sampler_pid=$!
    fi

    arm_status=ok
    prompt_n=n/a
    prefill_s=n/a
    decode_rate=n/a
    control_status=n/a
    control_reply=-

    start_server "$arm_depth" "$arm_log"
    if wait_for_server; then
        set +e
        run_arm_requests "$arm_depth" "$arm_timeout_s" >"$arm_requests" 2>&1
        request_status=$?
        set -e
        prompt_n=$(read_request_field prompt_n "$arm_requests")
        prefill_s=$(read_request_field prefill_s "$arm_requests")
        decode_rate=$(read_request_field decode_tok_s "$arm_requests")
        control_status=$(read_request_field control_status "$arm_requests")
        control_reply=$(read_request_field control_answer "$arm_requests")
        # A failed control leaves the fill's own outcome standing: the arm
        # reached its depth and the device or the projector then failed the
        # recovery question, and the two columns say so separately.
        if [ "$request_status" -ne 0 ]; then
            arm_failure=$(read_request_field failure "$arm_requests")
            if [ "$arm_failure" != n/a ]; then
                arm_status=$arm_failure
            elif [ "$control_status" = ok ] || [ "$control_status" = n/a ]; then
                arm_status=request-failed
            fi
        fi
    else
        arm_status=server-unready
        printf 'server_unready label=%s log=%s\n' "$arm_label" "$arm_log" >&2
    fi
    stop_server
    stop_sampler
    if [ "$kernel_capture_method" = follow ]; then
        stop_kernel_follow
    else
        kernel_delta_lines "$kernel_before" "$arm_kernel"
    fi
    printf '%s\n' "$kernel_capture_method" \
        >"$output_directory/$arm_label.dmesg-method.txt"

    arm_resets=$(count_kernel_hazards "$arm_kernel" \
        'ring reset\|Ring .* reset\|device wedged\|GPU reset')
    arm_faults=$(count_kernel_hazards "$arm_kernel" \
        'page fault\|VM_L2_PROTECTION_FAULT\|PROTECTION_FAULT')

    # The device's VRAM and GTT occupancy during the arm, read from the clock
    # sampler's whole-device accounting: the peak sums every process's
    # allocation, so it names how full the device got rather than what this
    # arm privately holds.
    if [ -s "$arm_samples" ]; then
        memory_report=$(awk -F'\t' '
            $5 ~ /^[0-9]+$/ {
              if ($5 + 0 > vram_peak) { vram_peak = $5 + 0 }
              vram_samples++
            }
            $6 ~ /^[0-9]+$/ {
              if ($6 + 0 > gtt_peak) { gtt_peak = $6 + 0 }
              gtt_samples++
            }
            END {
                printf "%s\t%s",
                    (vram_samples ? sprintf("%.0f", vram_peak / 1048576) : "unavailable"),
                    (gtt_samples ? sprintf("%.0f", gtt_peak / 1048576) : "unavailable")
            }' "$arm_samples")
    else
        memory_report=$(printf 'unavailable\tunavailable')
    fi

    health=unhealthy
    if [ "$arm_status" = ok ] && [ "$control_status" = ok ]; then
        if [ "$arm_resets" = unavailable ] || [ "$arm_faults" = unavailable ]; then
            health=unverified
        elif [ "$arm_resets" -eq 0 ] && [ "$arm_faults" -eq 0 ]; then
            health=healthy
        fi
    fi
    hazard_class=$(classify_hazard "$arm_kernel" "$arm_log" "$arm_resets" \
        "$arm_faults" "$control_status")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tloaded\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_label" "$model_id" "$arm_depth" "$batch_size" "$ubatch_size" \
        "$cache_type_k" "$cache_type_v" "$flash_attention" "$arm_status" \
        "$prompt_n" "$prefill_s" "$decode_rate" "$arm_resets" "$arm_faults" \
        "$memory_report" "$control_status" "$control_reply" "$health" \
        "$hazard_class" "$arm_log" >>"$summary"
    printf 'arm_stop_utc=%s label=%s status=%s prompt_n=%s prefill_s=%s decode_tok_s=%s resets=%s faults=%s control=%s health=%s hazard_class=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$arm_status" \
        "$prompt_n" "$prefill_s" "$decode_rate" "$arm_resets" "$arm_faults" \
        "$control_status" "$health" "$hazard_class"
    active_arm_label=''

    if [ "$arm_status" != ok ] || [ "$control_status" != ok ]; then
        printf 'arm_failed label=%s status=%s control=%s: the chain stops rather than measuring past a failed depth\n' \
            "$arm_label" "$arm_status" "$control_status" >&2
        device_corrupt=1
    fi
}

read_request_field() {
    awk -F= -v key="$1" '$1 == key { value = $2 } END {
        print (value == "" ? "n/a" : value)
    }' "$2"
}

# The four requests one arm makes, in one place because each depends on the
# previous answer. The probe measures the template and image overhead the
# `/tokenize` route cannot see, `/tokenize` measures the padding unit, the fill
# closes the remainder to the arm's depth, and the control asks the question
# the fixture's own generator declares the answer to.
run_arm_requests() {
    request_depth=$1
    request_timeout_s=$2
    QWEN_PROJECTOR_REQUEST_DEPTH=$request_depth \
    QWEN_PROJECTOR_REQUEST_TIMEOUT_S=$request_timeout_s \
    QWEN_PROJECTOR_REQUEST_ENDPOINT="http://127.0.0.1:$server_port" \
    QWEN_PROJECTOR_REQUEST_IMAGE=$control_image \
    QWEN_PROJECTOR_REQUEST_PROMPT=$control_prompt \
    QWEN_PROJECTOR_REQUEST_ANSWER=$control_answer \
    QWEN_PROJECTOR_REQUEST_DECODE=$decode_tokens \
    QWEN_PROJECTOR_REQUEST_MARGIN=$fill_margin_tokens \
        python3 - <<'PY'
import base64
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request

endpoint = os.environ["QWEN_PROJECTOR_REQUEST_ENDPOINT"]
depth = int(os.environ["QWEN_PROJECTOR_REQUEST_DEPTH"])
timeout_s = int(os.environ["QWEN_PROJECTOR_REQUEST_TIMEOUT_S"])
image_path = os.environ["QWEN_PROJECTOR_REQUEST_IMAGE"]
control_prompt = os.environ["QWEN_PROJECTOR_REQUEST_PROMPT"]
control_answer = os.environ["QWEN_PROJECTOR_REQUEST_ANSWER"].lower()
decode_tokens = int(os.environ["QWEN_PROJECTOR_REQUEST_DECODE"])
margin_tokens = int(os.environ["QWEN_PROJECTOR_REQUEST_MARGIN"])

# One padding sentence, repeated. The unit is measured through /tokenize rather
# than assumed, because a token count per word belongs to the tokenizer the
# checkpoint ships.
PADDING_UNIT = ("The tide reaches the seawall at the equinox and withdraws "
                "again before the harbour lights come on. ")


def post(route, payload):
    request = urllib.request.Request(
        endpoint + route,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(request, timeout=timeout_s) as response:
        return json.loads(response.read().decode())


def emit(key, value):
    print(f"{key}={value}")


def fail(reason):
    emit("failure", reason)
    sys.exit(1)


media_type = mimetypes.guess_type(image_path)[0] or "image/png"
with open(image_path, "rb") as handle:
    image_part = {
        "type": "image_url",
        "image_url": {
            "url": f"data:{media_type};base64," + base64.b64encode(
                handle.read()).decode()}}


def chat(text, max_tokens, ignore_eos):
    return post("/v1/chat/completions", {
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": text}, image_part]}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "top_k": 1,
        "seed": 1,
        "ignore_eos": ignore_eos,
        "cache_prompt": False,
        "chat_template_kwargs": {"enable_thinking": False}})


def tokenize(text):
    return len(post("/tokenize", {"content": text, "add_special": False})
               ["tokens"])


try:
    probe = chat("Describe this chart.", 1, False)
except (urllib.error.URLError, OSError, ValueError) as error:
    fail(f"probe-request-failed:{type(error).__name__}")

overhead = (probe.get("timings") or {}).get("prompt_n")
if not isinstance(overhead, int):
    fail("probe-request-carried-no-prompt-n")
emit("probe_prompt_n", overhead)

try:
    unit_tokens = tokenize(PADDING_UNIT * 16) / 16
except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
    fail(f"tokenize-failed:{type(error).__name__}")
if unit_tokens <= 0:
    fail("padding-unit-tokenizes-to-nothing")

# The padding closes the gap between the fixed overhead and the arm's target,
# and the loop converges on the tokenizer rather than trusting one estimate:
# each pass re-measures the built string and corrects the repetition count.
target_text_tokens = depth - margin_tokens - overhead
if target_text_tokens <= 0:
    fail("image-and-template-overhead-exceeds-target-depth")
repetitions = max(1, int(target_text_tokens / unit_tokens))
padding = ""
for _ in range(8):
    padding = PADDING_UNIT * repetitions
    try:
        measured = tokenize(padding)
    except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
        fail(f"tokenize-failed:{type(error).__name__}")
    deficit = target_text_tokens - measured
    if abs(deficit) <= unit_tokens:
        break
    repetitions = max(1, repetitions + int(deficit / unit_tokens))
emit("padding_tokens", measured)
emit("padding_repetitions", repetitions)

try:
    fill = chat(padding, decode_tokens, True)
except (urllib.error.URLError, OSError, ValueError) as error:
    fail(f"fill-request-failed:{type(error).__name__}")

timings = fill.get("timings") or {}
prompt_n = timings.get("prompt_n")
predicted_n = timings.get("predicted_n")
prompt_ms = timings.get("prompt_ms")
decode_rate = timings.get("predicted_per_second")
if not isinstance(prompt_n, int):
    fail("fill-request-carried-no-prompt-n")
emit("prompt_n", prompt_n)
emit("prefill_s", "n/a" if prompt_ms is None else round(prompt_ms / 1000.0, 3))
emit("decode_tok_s", "n/a" if decode_rate is None else round(decode_rate, 3))
emit("decode_n", predicted_n)

# Decode follows the fill inside one allocation, so the window is asymmetric: a
# prompt within 2% below the depth proves the cache filled, and one leaving
# fewer than the generated tokens of headroom evicts instead of decoding.
floor_tokens = depth - depth * 2 // 100
ceiling_tokens = depth - decode_tokens
fill_failure = None
if prompt_n < floor_tokens or prompt_n > ceiling_tokens:
    fill_failure = (f"prompt-n-outside-window:{prompt_n}"
                    f":{floor_tokens}:{ceiling_tokens}")
elif predicted_n != decode_tokens:
    fill_failure = f"decode-length-mismatch:{predicted_n}"

# The control runs whatever the fill did, because a rejected graph and a
# corrupt device are what it separates: a fill that missed its window against a
# control that still answers is one refused depth, and a control that fails
# after it is a device the remaining depths would measure instead of the model.
# Its outcome reaches the summary through control_status alone, so the fill's
# own status stands beside it.
control_failed = False
try:
    control = chat(control_prompt, 32, False)
except (urllib.error.URLError, OSError, ValueError) as error:
    emit("control_status", f"request-failed:{type(error).__name__}")
    control_failed = True
else:
    reply = ""
    for choice in control.get("choices") or []:
        reply += (choice.get("message") or {}).get("content") or ""
    reply = " ".join(reply.split())
    emit("control_answer", reply[:120] if reply else "-")
    if control_answer in reply.lower():
        emit("control_status", "ok")
    else:
        emit("control_status", "answer-missing-declared-content")
        control_failed = True

if fill_failure is not None:
    fail(fill_failure)
if control_failed:
    sys.exit(1)
PY
}

for depth in $depths; do
    [ "$device_corrupt" -eq 0 ] || break
    run_arm "$depth"
done

# One appendable ledger row per healthy arm, written beside the evidence rather
# than into scripts/validated-tuples.tsv: a validated row requires its evidence
# path to exist in the tree, so the row joins the ledger with the evidence
# directory it names.
measured_at=$(date -u +%Y-%m-%d)
: >"$emitted_rows"
# The emitted row names the backend the arm ran on, because
# check-validated-tuples.sh counts only rows whose backend equals the one the
# host serves: a depth filled on one backend states nothing about another.
serving_backend=${QWEN_SERVING_BACKEND:-cuda}
awk -F'\t' -v OFS='\t' -v model_id="$model_id" \
    -v evidence="$evidence_root/$model_id/" -v commit="$llama_cpp_commit" \
    -v runner="$runner_sha256" -v kernel="$kernel_release" \
    -v mesa="$vulkan_driver_version" -v gpu_module="$gpu_kernel_module_version" \
    -v backend="$serving_backend" \
    -v measured_at="$measured_at" '
    NR > 1 && $10 == "ok" && $18 == "ok" && $20 == "healthy" {
        print model_id "-d" $3 "-b" $4 "-ub" $5 "-proj", model_id, "standalone",
            $3, $4, $5, $6, $7, $8, 1, 1, "loaded", backend, "validated",
            evidence, commit, runner, kernel, mesa, gpu_module, measured_at
    }' "$summary" >>"$emitted_rows"

if [ "$device_corrupt" -ne 0 ]; then
    printf 'depth_projector=halted model_id=%s output_directory=%s emitted_rows=%s\n' \
        "$model_id" "$output_directory" "$emitted_rows"
    cat "$summary"
    exit 1
fi

printf 'depth_projector=completed model_id=%s output_directory=%s emitted_rows=%s\n' \
    "$model_id" "$output_directory" "$emitted_rows"
cat "$summary"
