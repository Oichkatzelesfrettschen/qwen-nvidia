#!/bin/sh
set -eu

# Separate the compute-ring wedge at 16384 tokens into depth and submission
# geometry, and record what each arm did to the device.
#
# llama-bench prefills a depth rung with its own batch defaults. The guarded
# server runs `--batch-size 128 --ubatch-size 32`, which breaks the same prefill
# into submissions two orders of magnitude smaller, and that pacing is the
# reason those settings exist. Both wedges this tree has recorded were found
# under llama-bench at its defaults, so depth and submission size are confounded
# and neither has been separated from the other.
#
# Three geometries per depth resolve the direction. The harness default
# establishes that the wedge reproduces. The served geometry decides whether the
# shipped configuration is exposed. A geometry below the served one decides
# which way to move if it is: a pass there attributes the wedge to submission
# size and leaves depth viable, while a wedge there indicts the graph at that
# depth under every practical geometry and the admitted ceiling comes down.
#
# A configured context allocation is not a validated depth. A server that loads
# a 24576-token allocation has proven it can reserve the memory; it has not
# proven a near-full cache executes. What this probe measures is the filled and
# decoded depth, which is the capability the registry ceiling claims.
#
# Each arm ends with a shallow control at the served geometry. A ring reset that
# recovers leaves the control passing, and the wedge is one rejected graph; a
# control that fails establishes persistent device corruption instead, and the
# probe stops rather than measuring a broken device.

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s MODEL_PATH [OUTPUT_DIRECTORY]\n' "$0" >&2
    printf 'depths from QWEN_WEDGE_DEPTHS, default "8192 16384"\n' >&2
    printf 'geometries from QWEN_WEDGE_GEOMETRIES as batch:ubatch pairs,\n' >&2
    printf 'default "2048:512 128:32 32:8"\n' >&2
    printf 'QWEN_WEDGE_ARM_TIMEOUT_S overrides the per-invocation SIGTERM\n' >&2
    printf 'limit, default 120 + depth/4 seconds; QWEN_WEDGE_ARM_KILL_AFTER_S\n' >&2
    printf 'overrides the SIGKILL grace period after it, default 30\n' >&2
    exit 2
fi

# The wedge-metadata.tsv schema version. A metadata file whose header carries
# no ledger_version field predates this field and is refused rather than
# read as if version 1 were compatible with an unmarked format: nothing in
# an unmarked file states which reader wrote it.
ledger_version=3

model_path=$1
output_directory=${2:-"${HOME:?}/qwen-depth-wedge"}
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bench=${QWEN_LLAMA_BENCH:-"${HOME:?}/src/llama.cpp-qwen-apu/build-qwen-vulkan/bin/llama-bench"}
clock_sampler=${QWEN_CLOCK_SAMPLER:-"$script_directory/sample-gpu-clocks.sh"}
depths=${QWEN_WEDGE_DEPTHS:-"8192 16384"}
geometries=${QWEN_WEDGE_GEOMETRIES:-"2048:512 128:32 32:8"}
cache_type_k=${QWEN_CACHE_TYPE_K:-q8_0}
cache_type_v=${QWEN_CACHE_TYPE_V:-q4_0}
flash_attention=${QWEN_FLASH_ATTN:-on}
control_tokens=${QWEN_WEDGE_CONTROL_TOKENS:-16}
# A depth listed here stops after its geometries have all passed with healthy
# controls, leaving the remaining ones unrun. At 8192 the harness-default and
# served geometries bracket the deployed configuration, so a third arm below
# them validates a depth already validated and discriminates none of the 16384
# failure mechanisms. A depth absent from this list runs every geometry, which
# is what the 16384 matrix requires of its reduced-geometry arm.
conditional_depths=${QWEN_WEDGE_CONDITIONAL_DEPTHS:-8192}
# A wedge parks llama-bench in the driver rather than returning an error, so
# nothing but an external timeout ends it. QWEN_WEDGE_ARM_TIMEOUT_S overrides
# the per-invocation limit; its default scales with the prefill depth passed
# to that invocation, 120 seconds plus one second per four depth tokens, which
# covers this device's measured prefill and the fixed-length decode with
# margin while still bounding a hang. QWEN_WEDGE_ARM_KILL_AFTER_S is the grace
# period between the SIGTERM `timeout` sends at the limit and the SIGKILL it
# escalates to if the process ignores it; `timeout` reports its own exit
# status (124 on a plain timeout, 128+signal after a kill-after escalation),
# so a timed-out arm reads as a failure distinguishable from a bench failure
# by that status alone.
arm_timeout_kill_after_s=${QWEN_WEDGE_ARM_KILL_AFTER_S:-30}

case ${QWEN_WEDGE_ARM_TIMEOUT_S:-} in
    '') ;;
    *[!0-9]* | 0)
        printf 'QWEN_WEDGE_ARM_TIMEOUT_S must be a positive integer: %s\n' \
            "$QWEN_WEDGE_ARM_TIMEOUT_S" >&2
        exit 2
        ;;
esac
case $arm_timeout_kill_after_s in
    *[!0-9]* | 0)
        printf 'QWEN_WEDGE_ARM_KILL_AFTER_S must be a positive integer: %s\n' \
            "$arm_timeout_kill_after_s" >&2
        exit 2
        ;;
esac

if [ ! -x "$bench" ] || [ ! -f "$model_path" ]; then
    printf 'llama-bench and the model must both exist\n' >&2
    exit 2
fi
if pgrep -x llama-server >/dev/null 2>&1 ||
   pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/wedge-summary.tsv
# vram_peak_mib and gtt_peak_mib read amdgpu's whole-device VRAM and GTT
# accounting, sampled by sample-gpu-clocks.sh from the same sysfs and hwmon
# nodes every process on the device shares. They are the device's total
# allocation during the arm, not bytes this arm's own model or KV cache
# holds exclusively: a resident model, another process's allocation, and this
# arm's own buffers all sum into the one peak, and the peak is read as a
# device-occupancy ceiling rather than as this arm's private footprint.
# health carries the promotion signal a downstream consumer reads instead of
# recomputing arm_status, control_status, ring_resets, and gpu_faults itself.
# `healthy` is a clean arm with a passing control and a kernel delta that
# confirms zero resets and zero faults; `unhealthy` is a failed status, a
# failed control, or a confirmed reset or fault; `unverified` is every other
# case, where dmesg was unavailable or unreadable so the arm's reset and fault
# counts are `unavailable` and a clean run cannot be told apart from a
# recovery this probe did not see. A promotion rule that treats `unverified`
# as `healthy` promotes an arm this probe never confirmed clean.
# hazard_class names what the kernel and the bench logs together say happened,
# beside the ring_resets and gpu_faults line counts: `ring-timeout-only` is a
# reset or wedge line with no page-fault line in the same delta;
# `gfxhub-page-fault` is a GFXHUB-tagged page fault; `VM-protection-fault` is
# an L2 protection fault; `device-lost-without-kernel-record` is a Vulkan
# device-lost error from the bench or control process with a zero or
# unavailable reset and fault count, naming a hazard the kernel log never
# recorded; `post-reset-control-failure` is a confirmed reset (resets > 0)
# whose recovery control then failed. A clean arm reads `none`; several
# classes join with a comma when more than one line matches.
summary_header='arm	depth	batch	ubatch	cache_k	cache_v	flash_attn	status	ring_resets	gpu_faults	wall_s	decode_tok_s	vram_peak_mib	gtt_peak_mib	control_status	control_tok_s	mclk_modal	temp_c_max	health	hazard_class'
summary_has_arms=0
if [ -s "$summary" ]; then
    if [ "$(sed -n '1p' "$summary")" != "$summary_header" ]; then
        printf 'wedge summary header is incompatible with this harness: %s\n' \
            "$summary" >&2
        exit 2
    fi
    malformed_line=$(awk -F'\t' '
        NR > 1 && (NF != 20 || $1 != "d" $2 "-b" $3 "-ub" $4) {
            print NR
            exit
        }' "$summary")
    if [ -n "$malformed_line" ]; then
        printf 'wedge summary carries a malformed arm row at line %s: %s\n' \
            "$malformed_line" "$summary" >&2
        exit 2
    fi
    duplicate_arm=$(awk -F'\t' 'NR > 1 && seen[$1]++ { print $1; exit }' \
        "$summary")
    if [ -n "$duplicate_arm" ]; then
        printf 'wedge summary carries duplicate arm identity: %s\n' \
            "$duplicate_arm" >&2
        exit 2
    fi
    if ! awk -F'\t' -v cache_k="$cache_type_k" \
        -v cache_v="$cache_type_v" -v flash="$flash_attention" '
        NR > 1 && ($5 != cache_k || $6 != cache_v || $7 != flash) {
            printf "recorded arm %s belongs to cache policy %s/%s/%s, not %s/%s/%s; use a new output directory\n", \
                $1, $5, $6, $7, cache_k, cache_v, flash > "/dev/stderr"
            mismatch = 1
            exit
        }
        END { exit mismatch }
    ' "$summary"; then
        exit 2
    fi
    if awk 'NR > 1 { found = 1; exit } END { exit !found }' "$summary"; then
        summary_has_arms=1
    fi
else
    printf '%s\n' "$summary_header" >"$summary"
fi

# A matching arm label is not a matching measurement when the GGUF or recovery
# control changes. The digest is computed once per invocation, which is small
# beside a filled-depth arm and binds every resumed row to immutable input
# bytes rather than to a reusable path.
metadata=$output_directory/wedge-metadata.tsv
metadata_header='ledger_version	model_sha256	model_bytes	control_tokens'
legacy_metadata_header='model_sha256	model_bytes	control_tokens'
model_sha256=$(nice -n 19 sha256sum "$model_path")
model_sha256=${model_sha256%% *}
model_bytes=$(stat -c %s -- "$model_path")
metadata_row="$ledger_version	$model_sha256	$model_bytes	$control_tokens"
if [ -s "$metadata" ]; then
    if [ "$(sed -n '1p' "$metadata")" = "$legacy_metadata_header" ]; then
        printf 'wedge metadata predates ledger versioning (legacy ledger, no ledger_version field): %s\n' \
            "$metadata" >&2
        exit 2
    fi
    if [ "$(sed -n '1p' "$metadata")" != "$metadata_header" ] ||
       [ "$(sed -n '2p' "$metadata")" != "$metadata_row" ] ||
       [ -n "$(sed -n '3p' "$metadata")" ]; then
        printf 'wedge metadata does not match the model or recovery control: %s\n' \
            "$metadata" >&2
        exit 2
    fi
elif [ "$summary_has_arms" -eq 1 ]; then
    printf 'wedge summary has arms but no model identity metadata: %s\n' \
        "$metadata" >&2
    exit 2
else
    printf '%s\n%s\n' "$metadata_header" "$metadata_row" >"$metadata"
fi

# wedge-identity.tsv is provenance rather than a resume gate: one row per
# invocation, appended rather than validated, naming the tool and driver
# versions an arm ran under so a wedge or its absence can be traced back to
# what produced it. Absent evidence reads "-" rather than stopping the probe.
identity=$output_directory/wedge-identity.tsv
identity_header='run_utc	llama_bench_sha256	llama_cpp_commit	runner_sha256	sampler_sha256	kernel_release	mesa_radv_version	amdgpu_module_version	argv	environment'
if [ ! -s "$identity" ]; then
    printf '%s\n' "$identity_header" >"$identity"
fi
llama_bench_sha256=$(nice -n 19 sha256sum "$bench")
llama_bench_sha256=${llama_bench_sha256%% *}
runner_sha256=$(nice -n 19 sha256sum "$0")
runner_sha256=${runner_sha256%% *}
sampler_sha256=$(nice -n 19 sha256sum "$clock_sampler")
sampler_sha256=${sampler_sha256%% *}
llama_cpp_commit=-
# --version identifies the build without an arm-sized invocation and is
# bounded rather than left to the caller-configured arm timeout: an
# implementation that ignores --version and behaves like a full run would
# otherwise stall identity capture before the first arm starts.
if bench_version_output=$(timeout 5s "$bench" --version 2>&1); then
    parsed_commit=$(printf '%s\n' "$bench_version_output" |
        grep -o 'build: [0-9a-f]\{4,\}' | tail -n1 | awk '{ print $2 }')
    [ -z "$parsed_commit" ] || llama_cpp_commit=$parsed_commit
fi
if [ "$llama_cpp_commit" = - ]; then
    identity_search_dir=$(dirname -- "$bench")
    identity_search_depth=0
    while [ "$identity_search_depth" -lt 6 ] && [ "$identity_search_dir" != / ]; do
        if [ -d "$identity_search_dir/.git" ]; then
            llama_cpp_commit=$(git -C "$identity_search_dir" rev-parse HEAD \
                2>/dev/null || printf -)
            break
        fi
        identity_search_dir=$(dirname -- "$identity_search_dir")
        identity_search_depth=$((identity_search_depth + 1))
    done
fi
kernel_release=$(uname -r)
mesa_radv_version=-
if command -v vulkaninfo >/dev/null 2>&1; then
    parsed_driver=$(timeout 5s vulkaninfo --summary 2>/dev/null |
        awk -F': *' '/driverInfo/ { print $2; exit }')
    [ -z "$parsed_driver" ] || mesa_radv_version=$parsed_driver
fi
amdgpu_module_version=-
if command -v modinfo >/dev/null 2>&1; then
    parsed_module=$(modinfo amdgpu 2>/dev/null |
        awk -F': *' '/^version:/ { print $2; exit }')
    [ -z "$parsed_module" ] || amdgpu_module_version=$parsed_module
fi
identity_argv=$(printf '%s ' "$0" "$@" | tr '\t\n' '  ')
identity_environment=$(
    for identity_var in QWEN_CACHE_TYPE_K QWEN_CACHE_TYPE_V QWEN_FLASH_ATTN \
        QWEN_WEDGE_DEPTHS QWEN_WEDGE_GEOMETRIES QWEN_WEDGE_CONDITIONAL_DEPTHS \
        QWEN_WEDGE_CONTROL_TOKENS QWEN_WEDGE_ARM_TIMEOUT_S \
        QWEN_WEDGE_ARM_KILL_AFTER_S GGML_VK_MAX_NODES_PER_SUBMIT \
        GGML_VK_SERIALIZE_SUBMISSIONS QWEN_VULKAN_PROFILE; do
        identity_value=$(eval "printf '%s' \"\${$identity_var:-unset}\"")
        printf '%s=%s;' "$identity_var" "$identity_value"
    done | tr '\t\n' '  '
)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$llama_bench_sha256" "$llama_cpp_commit" \
    "$runner_sha256" "$sampler_sha256" "$kernel_release" "$mesa_radv_version" \
    "$amdgpu_module_version" "$identity_argv" "$identity_environment" >>"$identity"

# A killed run leaves its sampler writing once a second into a file the next run
# recreates, which contaminates that run and hides the orphan behind a plausible
# name. The trap ends the sampler with the script that started it.
sampler_pid=''
active_arm_label=''
stop_sampler() {
    [ -n "$sampler_pid" ] || return 0
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=''
}
# A killed run leaves its follow reader attached to the kernel ring buffer the
# same way an orphaned sampler leaves one attached to the clock sysfs files.
kernel_follow_pid=''
stop_kernel_follow() {
    [ -n "$kernel_follow_pid" ] || return 0
    kill "$kernel_follow_pid" 2>/dev/null || true
    wait "$kernel_follow_pid" 2>/dev/null || true
    kernel_follow_pid=''
}
interrupt_run() {
    signal_status=$1
    stop_sampler
    stop_kernel_follow
    if [ -n "$active_arm_label" ]; then
        printf 'arm_abort_utc=%s label=%s status=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$active_arm_label" \
            "$signal_status" >&2
    fi
    printf 'depth_wedge=interrupted status=%s output_directory=%s\n' \
        "$signal_status" "$output_directory" >&2
    exit "$signal_status"
}
trap 'stop_sampler; stop_kernel_follow' EXIT
trap 'interrupt_run 129' HUP
trap 'interrupt_run 130' INT
trap 'interrupt_run 143' TERM

kernel_line_count() {
    if dmesg >/dev/null 2>&1; then
        dmesg | wc -l
    else
        printf 'unavailable\n'
    fi
}

# The lines the kernel emitted during one arm, retained verbatim. The ring
# reset count and the fault count are grepped from these rather than from the
# whole buffer, so a reset that predates the probe stays out of the delta.
# This offset method breaks when the ring buffer wraps between the before
# count and the after read, which loses the earliest lines of a long arm's
# delta silently; start_kernel_capture's follow method reads the delta
# directly and does not depend on the buffer holding still.
kernel_delta_lines() {
    delta_before=$1
    delta_file=$2
    rm -f -- "$delta_file"
    [ "$delta_before" != unavailable ] || return 0
    dmesg | tail -n "+$((delta_before + 1))" >"$delta_file" 2>/dev/null || true
}

# `dmesg --follow-new` streams new kernel lines into the arm's kernel file as they
# arrive, which survives a ring-buffer wrap the offset method cannot: the
# offset method reads a before count and an after snapshot and subtracts, so a
# wrap between those two reads loses the earliest lines of the delta, where
# the follow reader has already written them to disk. A short-lived probe
# invocation distinguishes a following dmesg from one that only replays the
# buffer once and exits: this probe waits a beat and checks the process is
# still attached before trusting the read. When no dmesg on this host follows
# the buffer, kernel_capture_method stays `offset` and the caller falls back
# to kernel_line_count and kernel_delta_lines exactly as before this method
# existed.
kernel_capture_method=offset
start_kernel_capture() {
    capture_file=$1
    kernel_capture_method=offset
    dmesg --follow-new >"$capture_file" 2>/dev/null &
    kernel_follow_pid=$!
    sleep 0.2
    if kill -0 "$kernel_follow_pid" 2>/dev/null; then
        kernel_capture_method=follow
    else
        wait "$kernel_follow_pid" 2>/dev/null || true
        kernel_follow_pid=''
    fi
}

parse_decode_rate() {
    awk -F'|' '$0 ~ /\| *tg[0-9]+( @ d[0-9]+)? *\|/ {
                   split($(NF - 1), parts, /[^0-9.]+/)
                   for (i = 1; i <= 3; i++) {
                       if (parts[i] != "") { rate = parts[i]; break }
                   }
               }
               END { print (rate == "" ? "n/a" : rate) }' "$1"
}

# classify_hazard names what happened rather than how many lines matched.
# ring-timeout-only and the two fault classes read the kernel delta alone;
# device-lost-without-kernel-record reads the bench and control logs for a
# Vulkan device-lost error the kernel delta never recorded a matching reset or
# fault for; post-reset-control-failure reads the confirmed reset count
# against the control's own status. Classes join with a comma, and a clean
# arm reads `none`.
classify_hazard() {
    hazard_bench_log=$1
    hazard_arm_kernel_file=$2
    hazard_control_log=$3
    hazard_control_kernel_file=$4
    hazard_arm_resets=$5
    hazard_arm_faults=$6
    hazard_control_resets=$7
    hazard_control_faults=$8
    hazard_control_status=$9
    hazard_classes=''
    hazard_has_page_fault=0
    for hazard_kernel_file in "$hazard_arm_kernel_file" \
        "$hazard_control_kernel_file"; do
        [ -f "$hazard_kernel_file" ] || continue
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
    done
    if [ "$hazard_has_page_fault" -eq 0 ] &&
       grep -qE 'ring reset|Ring .* reset|device wedged|GPU reset' \
           "$hazard_arm_kernel_file" "$hazard_control_kernel_file" 2>/dev/null; then
        hazard_classes=${hazard_classes:+$hazard_classes,}ring-timeout-only
    fi
    if grep -qiE 'device lost|VK_ERROR_DEVICE_LOST' "$hazard_bench_log" \
        2>/dev/null; then
        if { [ "$hazard_arm_resets" = unavailable ] || [ "$hazard_arm_resets" -eq 0 ]; } &&
           { [ "$hazard_arm_faults" = unavailable ] || [ "$hazard_arm_faults" -eq 0 ]; }; then
            hazard_classes=${hazard_classes:+$hazard_classes,}device-lost-without-kernel-record
        fi
    fi
    if grep -qiE 'device lost|VK_ERROR_DEVICE_LOST' "$hazard_control_log" \
        2>/dev/null; then
        if { [ "$hazard_control_resets" = unavailable ] || [ "$hazard_control_resets" -eq 0 ]; } &&
           { [ "$hazard_control_faults" = unavailable ] || [ "$hazard_control_faults" -eq 0 ]; }; then
            case ,$hazard_classes, in
                *,device-lost-without-kernel-record,*) ;;
                *) hazard_classes=${hazard_classes:+$hazard_classes,}device-lost-without-kernel-record ;;
            esac
        fi
    fi
    combined_resets=unavailable
    if [ "$hazard_arm_resets" != unavailable ] && \
       [ "$hazard_control_resets" != unavailable ]; then
        combined_resets=$((hazard_arm_resets + hazard_control_resets))
    fi
    if [ "$combined_resets" != unavailable ] && [ "$combined_resets" -gt 0 ] &&
       [ "$hazard_control_status" -ne 0 ]; then
        hazard_classes=${hazard_classes:+$hazard_classes,}post-reset-control-failure
    fi
    printf '%s' "${hazard_classes:-none}"
}

run_bench() {
    bench_log=$1
    bench_depth=$2
    bench_batch=$3
    bench_ubatch=$4
    bench_tokens=$5
    bench_timeout_s=${QWEN_WEDGE_ARM_TIMEOUT_S:-$((120 + bench_depth / 4))}
    # errexit is the caller's to manage. Restoring it here re-arms it before the
    # return, and a non-zero return then kills the caller on the very failure
    # this probe exists to record: the wedge at 16384 aborted llama-bench, the
    # function returned 134, and the script died without writing the row.
    if [ "$bench_depth" -eq 0 ]; then
        nice -n 19 ionice -c 3 timeout \
            --kill-after="${arm_timeout_kill_after_s}s" "${bench_timeout_s}s" \
            "$bench" -m "$model_path" \
            -ngl 99 -t 2 -r 1 -p 0 -n "$bench_tokens" \
            -b "$bench_batch" -ub "$bench_ubatch" \
            -ctk "$cache_type_k" -ctv "$cache_type_v" -fa "$flash_attention" \
            -o md >"$bench_log" 2>&1
    else
        nice -n 19 ionice -c 3 timeout \
            --kill-after="${arm_timeout_kill_after_s}s" "${bench_timeout_s}s" \
            "$bench" -m "$model_path" \
            -ngl 99 -t 2 -r 1 -p 0 -n "$bench_tokens" -d "$bench_depth" \
            -b "$bench_batch" -ub "$bench_ubatch" \
            -ctk "$cache_type_k" -ctv "$cache_type_v" -fa "$flash_attention" \
            -o md >"$bench_log" 2>&1
    fi
}

device_corrupt=0

run_arm() {
    arm_depth=$1
    arm_batch=$2
    arm_ubatch=$3
    arm_label=d$arm_depth-b$arm_batch-ub$arm_ubatch
    arm_log=$output_directory/$arm_label.log
    arm_samples=$output_directory/$arm_label.clocks.tsv
    arm_kernel=$output_directory/$arm_label.dmesg.txt
    control_log=$output_directory/$arm_label.control.log
    control_kernel=$output_directory/$arm_label.control.dmesg.txt

    recorded_count=$(awk -F'\t' -v label="$arm_label" \
        'NR > 1 && $1 == label { count++ } END { print count + 0 }' "$summary")
    if [ "$recorded_count" -eq 1 ]; then
        for retained_artifact in "$arm_log" "$arm_samples" "$control_log"; do
            if [ ! -f "$retained_artifact" ]; then
                printf 'recorded arm %s is missing retained artifact: %s\n' \
                    "$arm_label" "$retained_artifact" >&2
                exit 2
            fi
        done
        recorded_status=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $8; exit }' "$summary")
        recorded_resets=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $9; exit }' "$summary")
        recorded_faults=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $10; exit }' "$summary")
        recorded_control_status=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $15; exit }' "$summary")
        recorded_health=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $19; exit }' "$summary")
        recorded_hazard_class=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $20; exit }' "$summary")
        if [ -z "$recorded_hazard_class" ]; then
            printf 'recorded arm %s carries an empty hazard class\n' \
                "$arm_label" >&2
            exit 2
        fi
        recorded_cache_type_k=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $5; exit }' "$summary")
        recorded_cache_type_v=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $6; exit }' "$summary")
        recorded_flash_attention=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $7; exit }' "$summary")
        if [ "$recorded_cache_type_k" != "$cache_type_k" ] ||
           [ "$recorded_cache_type_v" != "$cache_type_v" ] ||
           [ "$recorded_flash_attention" != "$flash_attention" ]; then
            printf 'recorded arm %s belongs to cache policy %s/%s/%s, not %s/%s/%s; use a new output directory\n' \
                "$arm_label" "$recorded_cache_type_k" "$recorded_cache_type_v" \
                "$recorded_flash_attention" "$cache_type_k" "$cache_type_v" \
                "$flash_attention" >&2
            exit 2
        fi
        case $recorded_status in '' | *[!0-9]*)
            printf 'recorded arm %s carries invalid status: %s\n' \
                "$arm_label" "$recorded_status" >&2
            exit 2
            ;;
        esac
        case $recorded_control_status in '' | *[!0-9]*)
            printf 'recorded arm %s carries invalid control status: %s\n' \
                "$arm_label" "$recorded_control_status" >&2
            exit 2
            ;;
        esac
        case $recorded_resets in unavailable | *[!0-9]* | '')
            [ "$recorded_resets" = unavailable ] || {
                printf 'recorded arm %s carries invalid reset count: %s\n' \
                    "$arm_label" "$recorded_resets" >&2
                exit 2
            }
            ;;
        esac
        case $recorded_faults in unavailable | *[!0-9]* | '')
            [ "$recorded_faults" = unavailable ] || {
                printf 'recorded arm %s carries invalid fault count: %s\n' \
                    "$arm_label" "$recorded_faults" >&2
                exit 2
            }
            ;;
        esac
        if [ "$recorded_resets" = unavailable ] ||
           [ "$recorded_faults" = unavailable ]; then
            if [ "$recorded_resets" != unavailable ] ||
               [ "$recorded_faults" != unavailable ] ||
               [ -e "$arm_kernel" ] || [ -e "$control_kernel" ]; then
                printf 'recorded arm %s carries inconsistent kernel-delta evidence\n' \
                    "$arm_label" >&2
                exit 2
            fi
        else
            for retained_kernel in "$arm_kernel" "$control_kernel"; do
                if [ ! -f "$retained_kernel" ]; then
                    printf 'recorded arm %s is missing retained artifact: %s\n' \
                        "$arm_label" "$retained_kernel" >&2
                    exit 2
                fi
            done
        fi
        case $recorded_health in
            healthy | unhealthy | unverified) ;;
            *)
                printf 'recorded arm %s carries invalid health: %s\n' \
                    "$arm_label" "$recorded_health" >&2
                exit 2
                ;;
        esac
        expected_health=unhealthy
        if [ "$recorded_status" -eq 0 ] && [ "$recorded_control_status" -eq 0 ]; then
            if [ "$recorded_resets" = unavailable ] ||
               [ "$recorded_faults" = unavailable ]; then
                expected_health=unverified
            elif [ "$recorded_resets" -eq 0 ] && [ "$recorded_faults" -eq 0 ]; then
                expected_health=healthy
            fi
        fi
        if [ "$recorded_health" != "$expected_health" ]; then
            printf 'recorded arm %s carries health %s inconsistent with its status, control, resets, and faults (expected %s)\n' \
                "$arm_label" "$recorded_health" "$expected_health" >&2
            exit 2
        fi
        arm_healthy=0
        [ "$recorded_health" != healthy ] || arm_healthy=1
        if [ "$recorded_control_status" -ne 0 ]; then
            device_corrupt=1
        fi
        printf 'arm_resume_skip label=%s status=%s resets=%s control=%s health=%s\n' \
            "$arm_label" "$recorded_status" "$recorded_resets" \
            "$recorded_control_status" "$recorded_health"
        return 0
    fi
    for incomplete_artifact in "$arm_log" "$arm_samples" "$control_log"; do
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
    arm_started=$(date +%s)

    printf 'arm_start_utc=%s label=%s cache=%s/%s fa=%s kernel_capture=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$cache_type_k" \
        "$cache_type_v" "$flash_attention" "$kernel_capture_method"
    # The sampler is killed the moment the arm ends, so an arm shorter than
    # its first sampling interval would leave no file and a later resume would
    # refuse the recorded arm for a missing artifact. The empty file is
    # created first; the summary reads it with -s, so an unwritten file still
    # reports unavailable clocks.
    : >"$arm_samples"
    "$clock_sampler" "$arm_samples" &
    sampler_pid=$!
    set +e
    run_bench "$arm_log" "$arm_depth" "$arm_batch" "$arm_ubatch" 32
    arm_status=$?
    set -e
    stop_sampler
    arm_wall=$(($(date +%s) - arm_started))
    if [ "$kernel_capture_method" = follow ]; then
        stop_kernel_follow
    else
        kernel_delta_lines "$kernel_before" "$arm_kernel"
    fi
    printf '%s\n' "$kernel_capture_method" >"$output_directory/$arm_label.dmesg-method.txt"

    arm_resets=unavailable
    arm_faults=unavailable
    if [ -f "$arm_kernel" ]; then
        arm_resets=$(grep -c 'ring reset\|Ring .* reset\|device wedged\|GPU reset' \
            "$arm_kernel" || true)
        arm_faults=$(grep -c 'page fault\|VM_L2_PROTECTION_FAULT\|PROTECTION_FAULT' \
            "$arm_kernel" || true)
    fi

    decode=n/a
    [ "$arm_status" -ne 0 ] || decode=$(parse_decode_rate "$arm_log")
    if [ "$arm_status" -eq 0 ] && [ "$decode" = n/a ]; then
        arm_status=65
    fi

    # The device's VRAM and GTT occupancy during the arm, read from amdgpu's
    # whole-device accounting rather than parsed from the log: llama-bench
    # prints no buffer sizes at default verbosity, and an arm that wedges
    # prints nothing at all. amdgpu's accounting is device-global -- it sums
    # every process's allocation, not this arm's model and KV cache alone --
    # so the peak names how full the device got, not what this arm privately
    # holds. The peak of each is reported because the KV cache grows through
    # the prefill.
    # The sampler is killed as soon as the arm ends, so an arm that completes
    # before the sampler writes its first row leaves no file at all and awk
    # exits fatal under set -e. This probe reports `unavailable` for every other
    # absent device reading, and an absent sampler file is the same fact: it
    # exists to find a wedge rather than to compare rates, so a missing covariate
    # names itself instead of ending the sweep.
    arm_samples_present=1
    [ -s "$arm_samples" ] || arm_samples_present=0

    if [ "$arm_samples_present" -eq 0 ]; then
        memory_report=$(printf 'unavailable\tunavailable')
    else
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
    fi

    # A ring reset needs the device quiet to finish recovering; the control
    # starting into a recovering device measures the recovery rather than the
    # device.
    if [ "$arm_resets" != unavailable ] && [ "$arm_resets" -gt 0 ]; then
        printf 'recovery_pause_utc=%s seconds=60 resets=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_resets"
        sleep 60
    fi

    start_kernel_capture "$control_kernel"
    control_kernel_before=unavailable
    [ "$kernel_capture_method" = follow ] || \
        control_kernel_before=$(kernel_line_count)
    control_kernel_capture_method=$kernel_capture_method
    set +e
    run_bench "$control_log" 0 128 32 "$control_tokens"
    control_status=$?
    set -e
    if [ "$control_kernel_capture_method" = follow ]; then
        stop_kernel_follow
    else
        kernel_delta_lines "$control_kernel_before" "$control_kernel"
    fi
    printf '%s\n' "$control_kernel_capture_method" \
        >"$output_directory/$arm_label.control.dmesg-method.txt"
    control_resets=unavailable
    control_faults=unavailable
    if [ -f "$control_kernel" ]; then
        control_resets=$(grep -c 'ring reset\|Ring .* reset\|device wedged\|GPU reset' \
            "$control_kernel" || true)
        control_faults=$(grep -c 'page fault\|VM_L2_PROTECTION_FAULT\|PROTECTION_FAULT' \
            "$control_kernel" || true)
    fi
    resets=unavailable
    faults=unavailable
    if [ "$arm_resets" != unavailable ] && [ "$control_resets" != unavailable ]; then
        resets=$((arm_resets + control_resets))
    fi
    if [ "$arm_faults" != unavailable ] && [ "$control_faults" != unavailable ]; then
        faults=$((arm_faults + control_faults))
    fi
    control_decode=n/a
    [ "$control_status" -ne 0 ] || control_decode=$(parse_decode_rate "$control_log")
    if [ "$control_status" -eq 0 ] && [ "$control_decode" = n/a ]; then
        control_status=65
    fi

    if [ "$arm_samples_present" -eq 0 ]; then
        clock_report=$(printf 'unavailable\tunavailable')
    else
        clock_report=$(awk -F'\t' '
            $1 ~ /^[0-9]+([.][0-9]+)?$/ { count[$1]++; clock_samples++ }
            $3 ~ /^[0-9]+([.][0-9]+)?$/ {
              if ($3 + 0 > temp_max) { temp_max = $3 + 0 }
              temperature_samples++
            }
            END {
                for (step in count) {
                    if (count[step] > best) { best = count[step]; modal = step }
                }
                printf "%s\t%s", (clock_samples ? modal : "unavailable"),
                    (temperature_samples ? sprintf("%.1f", temp_max / 1000) : "unavailable")
            }' "$arm_samples")
    fi

    # health carries the promotion signal. A fault or reset line without
    # recovery leaves the arm unhealthy regardless of dmesg availability. A
    # clean status and control with dmesg unavailable or unreadable cannot be
    # told apart from a hazard this probe did not see, so it reads
    # `unverified` rather than `healthy`: kernel telemetry unavailable keeps
    # the arm's decode and control results as an exploratory measurement
    # without certifying it clean, and a promotion rule that treats
    # `unverified` as `healthy` promotes an arm this probe never confirmed.
    health=unhealthy
    if [ "$arm_status" -eq 0 ] && [ "$control_status" -eq 0 ]; then
        if [ "$resets" = unavailable ] || [ "$faults" = unavailable ]; then
            health=unverified
        elif [ "$resets" -eq 0 ] && [ "$faults" -eq 0 ]; then
            health=healthy
        fi
    fi

    hazard_class=$(classify_hazard "$arm_log" "$arm_kernel" "$control_log" \
        "$control_kernel" "$arm_resets" "$arm_faults" "$control_resets" \
        "$control_faults" "$control_status")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_label" "$arm_depth" "$arm_batch" "$arm_ubatch" "$cache_type_k" \
        "$cache_type_v" "$flash_attention" "$arm_status" "$resets" "$faults" \
        "$arm_wall" "$decode" "$memory_report" "$control_status" \
        "$control_decode" "$clock_report" "$health" "$hazard_class" >>"$summary"
    printf 'arm_stop_utc=%s label=%s status=%s decode=%s resets=%s faults=%s wall_s=%s peak_vram_gtt_mib=%s control=%s control_tok_s=%s health=%s hazard_class=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$arm_status" "$decode" \
        "$resets" "$faults" "$arm_wall" \
        "$(printf '%s' "$memory_report" | tr '\t' '/')" "$control_status" \
        "$control_decode" "$health" "$hazard_class"
    active_arm_label=''

    if [ "$control_status" -ne 0 ]; then
        printf 'control_failed label=%s: the device did not recover, so the remaining arms would measure a corrupt device\n' \
            "$arm_label" >&2
        device_corrupt=1
    fi

    # arm_healthy gates the conditional-depth rescue skip below, and only
    # `healthy` promotes it: `unverified` runs every remaining geometry at
    # this depth exactly as `unhealthy` does, because a confirmed-clean depth
    # is what the rescue skip requires.
    arm_healthy=0
    [ "$health" != healthy ] || arm_healthy=1
}

for depth in $depths; do
    depth_conditional=0
    case " $conditional_depths " in
        *" $depth "*) depth_conditional=1 ;;
    esac
    depth_clean=1
    for geometry in $geometries; do
        [ "$device_corrupt" -eq 0 ] || break
        if [ "$depth_conditional" -eq 1 ] && [ "$depth_clean" -eq 1 ] &&
            [ "$geometry" != "${geometries%% *}" ] &&
            [ "$geometry" = "${geometries##* }" ]; then
            printf 'arm_skipped label=d%s-b%s-ub%s reason=preceding geometries at this depth passed with healthy controls\n' \
                "$depth" "${geometry%%:*}" "${geometry##*:}"
            continue
        fi
        run_arm "$depth" "${geometry%%:*}" "${geometry##*:}"
        [ "$arm_healthy" -eq 1 ] || depth_clean=0
    done
    [ "$device_corrupt" -eq 0 ] || break
done

if [ "$device_corrupt" -ne 0 ]; then
    printf 'depth_wedge=halted output_directory=%s\n' "$output_directory"
    cat "$summary"
    exit 1
fi

printf 'depth_wedge=completed output_directory=%s\n' "$output_directory"
cat "$summary"
