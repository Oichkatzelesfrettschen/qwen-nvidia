#!/bin/sh
set -eu

# Run the Vulkan submission-trace campaign as one detached, resumable chain and
# leave the production closure in place whatever the device does.
#
# `evidence/vulkan-submit-trace-design.md` registers what the trace answers: a
# lost queue reports only that the queue is gone, and
# `patches/llama-vulkan-submit-trace.patch` retains the host-side identity of
# the dispatch that failed to retire. Three arms turn that instrumentation into
# a measurement. P0 repeats the served geometry on the trace-capable build with
# the trace disabled, which establishes that the build itself decodes at depth.
# P1 enables the trace at the same geometry, so P0 and P1 differ in one
# variable and a P1 failure indicts the instrumentation rather than the graph.
# T1 raises the batch to the geometry the quarantine record wedged at, which is
# the decisive arm and the first one that must run traced.
#
# The submission tuple deviates from `low-async` and the deviation is recorded
# per arm rather than implied. `radv-low-priority-env.sh` unsets
# GGML_VK_SUBMIT_TRACE in its scrub and re-exports it from the `custom` branch
# alone, so a traced arm under a named profile would run with the trace
# silently off; the patch's device-creation guard also throws
# "GGML_VK_SUBMIT_TRACE requires GGML_VK_SERIALIZE_SUBMISSIONS", and
# `mark_completed` is reached on the serialized path alone, so an unserialized
# trace leaves last_completed_serial at zero and every record reads unretired.
# Every arm therefore runs `custom` with GGML_VK_MAX_NODES_PER_SUBMIT=16, which
# is the node count `low-async` exports, together with
# GGML_VK_SERIALIZE_SUBMISSIONS=1. That pairing is the `low-serialized` node
# count's neighbour rather than `low-async`, and those two profiles carry a
# measured 1.348 to 2.718 decode difference, so the summary row states the
# resolved triple and a rate read from it belongs to that triple.
#
# The arm runs through `radv-low-priority-env.sh` rather than invoking the
# bench directly the way `probe-depth-wedge.sh` does, because trace-on depends
# on three GGML_VK_* variables agreeing and the scrub is what makes the
# recorded triple the one the device saw.
#
# The chain stops at the first reset, fault, timeout, failed arm, or failed
# post-arm control. A wedge at P0 therefore ends the campaign before any trace
# exists, which the terminal summary states rather than leaving to inference.
#
# The trace prints through GGML_LOG_ERROR to the process's stderr, so the arm
# log is the trace artifact. `trace_dump` reads that log for the dump's own
# header line and reads `present`, `not-triggered` on a traced arm that
# completed, `absent` on a traced arm that failed and named no dispatch, or
# `off`, because a T1 failure carrying a trace and a T1 failure carrying none
# are the same row without it.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
    printf '\nenvironment:\n' >&2
    printf '  QWEN_TRACE_BUILD_DIR        trace-capable build, required;\n' >&2
    printf '                              remote/build-llama-trace.sh composes\n' >&2
    printf '                              and builds the tree it names\n' >&2
    printf '  QWEN_TRACE_SOURCE_DIR       source tree the trace build came from\n' >&2
    printf '  QWEN_TRACE_MODEL_PATH       checkpoint, defaults to the 4B distill\n' >&2
    printf '  QWEN_TRACE_APPLIANCE_SOURCE llama.cpp tree holding the promotion link\n' >&2
    printf '  QWEN_TRACE_PATCH_SOURCE     tree the patch series replays against\n' >&2
    printf '  QWEN_TRACE_ARM_TIMEOUT_S    per-invocation SIGTERM limit\n' >&2
    printf '  QWEN_TRACE_ARM_KILL_AFTER_S SIGKILL grace period, default 30\n' >&2
    printf '  QWEN_TRACE_CONTROL_TOKENS   post-arm control length, default 16\n' >&2
    printf '  QWEN_TRACE_FOREGROUND=1     run in this process rather than detaching\n' >&2
    printf '  QWEN_TRACE_SKIP_TRACE_SOURCE_GATE=1       admit an unverified\n' >&2
    printf '                              trace build; the run records the bypass\n' >&2
    printf '  QWEN_TRACE_SKIP_PRODUCTION_SOURCE_GATE=1  admit an unverified\n' >&2
    printf '                              serving tree; the run records the bypass\n' >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
case $1 in
    -h | --help) usage ;;
esac

output_directory=$1
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script_path=$script_directory/$(basename -- "$0")

model_path=${QWEN_TRACE_MODEL_PATH:-"${HOME:?}/models/Qwen3.8-4B-Distill-GGUF/Qwen3.8-4B-Q4_K_M.gguf"}
trace_build_directory=${QWEN_TRACE_BUILD_DIR:-}
appliance_source=${QWEN_TRACE_APPLIANCE_SOURCE:-"${HOME:?}/src/llama.cpp-qwen-apu"}
patch_source=${QWEN_TRACE_PATCH_SOURCE:-}
environment_wrapper=${QWEN_TRACE_ENV_WRAPPER:-"$script_directory/radv-low-priority-env.sh"}
clock_sampler=${QWEN_TRACE_CLOCK_SAMPLER:-"$script_directory/sample-gpu-clocks.sh"}
patch_verifier=${QWEN_TRACE_PATCH_VERIFIER:-"$script_directory/verify-llama-patch-series.sh"}
closure_hasher=${QWEN_TRACE_CLOSURE_HASHER:-"$script_directory/hash-load-closure.sh"}
kernel_reader=${QWEN_TRACE_KERNEL_READER:-dmesg}
control_tokens=${QWEN_TRACE_CONTROL_TOKENS:-16}
arm_timeout_kill_after_s=${QWEN_TRACE_ARM_KILL_AFTER_S:-30}
generate_tokens=${QWEN_TRACE_GENERATE_TOKENS:-32}

# The production cache triple of the `qwen38-4b-distill` row in models.tsv. The
# campaign measures the served tuple, so the triple is the row's rather than the
# caller's; an override would make the arms describe another allocation.
cache_type_k=q8_0
cache_type_v=q4_0
flash_attention=on

# The submission tuple every arm resolves to, stated once because P0, P1, and
# T1 differ in the trace flag and the batch alone.
max_nodes_per_submit=16
serialize_submissions=1

case $arm_timeout_kill_after_s in
    '' | *[!0-9]* | 0)
        printf 'QWEN_TRACE_ARM_KILL_AFTER_S must be a positive integer: %s\n' \
            "$arm_timeout_kill_after_s" >&2
        exit 2
        ;;
esac
case ${QWEN_TRACE_ARM_TIMEOUT_S:-} in
    '') ;;
    *[!0-9]* | 0)
        printf 'QWEN_TRACE_ARM_TIMEOUT_S must be a positive integer: %s\n' \
            "$QWEN_TRACE_ARM_TIMEOUT_S" >&2
        exit 2
        ;;
esac
case $control_tokens in
    '' | *[!0-9]* | 0)
        printf 'QWEN_TRACE_CONTROL_TOKENS must be a positive integer: %s\n' \
            "$control_tokens" >&2
        exit 2
        ;;
esac
case $generate_tokens in
    '' | *[!0-9]* | 0)
        printf 'QWEN_TRACE_GENERATE_TOKENS must be a positive integer: %s\n' \
            "$generate_tokens" >&2
        exit 2
        ;;
esac

if [ -z "$trace_build_directory" ]; then
    printf 'QWEN_TRACE_BUILD_DIR names the trace-capable build and is required\n' >&2
    exit 2
fi
bench=$trace_build_directory/bin/llama-bench
if [ ! -x "$bench" ]; then
    printf 'trace build has no executable llama-bench: %s\n' "$bench" >&2
    exit 2
fi
trace_source_directory=${QWEN_TRACE_SOURCE_DIR:-$(dirname -- "$trace_build_directory")}
if [ ! -f "$model_path" ]; then
    printf 'campaign model is absent: %s\n' "$model_path" >&2
    exit 2
fi
for required_helper in "$environment_wrapper" "$clock_sampler" \
    "$patch_verifier" "$closure_hasher"; do
    if [ ! -x "$required_helper" ]; then
        printf 'required helper is missing or not executable: %s\n' \
            "$required_helper" >&2
        exit 2
    fi
done

# The trace build is the production five-patch series plus
# `patches/llama-vulkan-submit-trace.patch`, which is the six-patch replay
# `verify-llama-patch-series.sh` records. Three checks establish that the binary
# about to run came from that tree. The verifier replays the series from the
# tree's own git objects at the pinned commit, which fixes the patch inputs; the
# working-tree digests fix the files the compiler read, and
# `tools/server/server.cpp` among them refuses a tree from before the router
# tools proxy patch by name; the preset manifest fixes the commit the build
# recorded. A diagnostic binary retained from an earlier revision fails the
# second check, so it never reaches an arm.
trace_ggml_vulkan_sha256=d81e9093b4a3d98bf5cde8dc710ec187ddbaffca84540369cec72ecd132e575c
trace_submit_trace_sha256=ac957254c09afda811983801e7dd59d7e4829d40e572804ea7e23dadba521867
trace_server_sha256=d2d5cb43a83c6b2b459b85f2df181a3d976efcaef351e5cbc6b418ba839390e3
pre_router_server_sha256=2833d9d237e77a70a75736426f11432b964bc66f8e85c5751451f77444338703
pinned_commit=f280b26983ad0fdb705a0d9ebf0503e76f2899b0

source_digest() {
    [ -r "$trace_source_directory/$1" ] || return 1
    sha256sum "$trace_source_directory/$1" | awk '{ print $1 }'
}
require_source_digest() {
    expected_digest=$1
    relative_path=$2
    if ! actual_digest=$(source_digest "$relative_path"); then
        printf 'trace source is missing %s: %s\n' "$relative_path" \
            "$trace_source_directory" >&2
        exit 2
    fi
    if [ "$actual_digest" != "$expected_digest" ]; then
        if [ "$relative_path" = tools/server/server.cpp ] &&
           [ "$actual_digest" = "$pre_router_server_sha256" ]; then
            printf 'trace source predates llama-router-tools-proxy.patch; rebuild it with build-llama-trace.sh\n' >&2
        else
            printf 'trace source %s hashes %s, not the six-patch replay %s\n' \
                "$relative_path" "$actual_digest" "$expected_digest" >&2
        fi
        exit 2
    fi
}

# A bypassed gate is announced rather than left to the reader, the way a
# research quarantine override is recorded in the preset it generates: a run
# whose binary identity went unproven says so on its own output.
if [ "${QWEN_TRACE_SKIP_TRACE_SOURCE_GATE:-0}" = 1 ]; then
    printf 'trace_source_gate=bypassed source=%s\n' "$trace_source_directory" >&2
fi
if [ "${QWEN_TRACE_SKIP_PRODUCTION_SOURCE_GATE:-0}" = 1 ]; then
    printf 'production_source_gate=bypassed source=%s\n' "$appliance_source" >&2
fi
if [ "${QWEN_TRACE_SKIP_TRACE_SOURCE_GATE:-0}" != 1 ]; then
    if [ ! -d "$trace_source_directory/.git" ]; then
        printf 'trace build names no source repository: %s\n' \
            "$trace_source_directory" >&2
        exit 2
    fi
    require_source_digest "$trace_server_sha256" tools/server/server.cpp
    require_source_digest "$trace_submit_trace_sha256" \
        ggml/src/ggml-vulkan/ggml-vulkan-submit-trace.h
    require_source_digest "$trace_ggml_vulkan_sha256" \
        ggml/src/ggml-vulkan/ggml-vulkan.cpp
    if ! "$patch_verifier" "$trace_source_directory" >/dev/null 2>&1; then
        printf 'trace source refuses the patch series replay: %s\n' \
            "$trace_source_directory" >&2
        exit 2
    fi
    trace_manifest=$trace_build_directory/artifact-manifest.tsv
    if [ ! -r "$trace_manifest" ]; then
        printf 'trace build has no artifact manifest: %s\n' "$trace_manifest" >&2
        exit 2
    fi
    trace_manifest_commit=$(awk -F'\t' '$1 == "commit" { print $2; exit }' \
        "$trace_manifest")
    if [ "$trace_manifest_commit" != "$pinned_commit" ]; then
        printf 'trace build manifest names commit %s, not the pinned %s\n' \
            "$trace_manifest_commit" "$pinned_commit" >&2
        exit 2
    fi
fi

# The campaign owns the device for its whole run. The ordinary router holds the
# device across every arm and every control, so a campaign started beside it
# measures contention rather than the graph, and its wedge would take the
# serving process with it. QWEN_TRACE_DEVICE_PROBE names the check so a test can
# state the answer without holding the device.
device_probe=${QWEN_TRACE_DEVICE_PROBE:-}
device_holder=''
if [ -n "$device_probe" ]; then
    device_holder=$($device_probe 2>/dev/null || true)
else
    if pgrep -x llama-server >/dev/null 2>&1; then
        device_holder=llama-server
    elif pgrep -x llama-bench >/dev/null 2>&1; then
        device_holder=llama-bench
    fi
fi
if [ -n "$device_holder" ]; then
    printf 'the device is held by %s; stop the appliance before the campaign\n' \
        "$device_holder" >&2
    exit 2
fi

mkdir -p "$output_directory"
campaign_log=$output_directory/campaign.log

# The diagnostic binary's own load closure, recorded fresh rather than copied
# from the build manifest, so the campaign output identifies every object the
# arms executed independently of what the build wrote.
if ! "$closure_hasher" "$bench" \
    "$output_directory/trace-build-closure.tsv" >/dev/null; then
    printf 'trace build load-closure enumeration failed: %s\n' "$bench" >&2
    exit 2
fi

# Detachment happens after every deterministic refusal, so a caller sees an
# argument or device error on its own terminal rather than in a log it has to
# find. The EXIT trap that restores the closure is installed in the process that
# runs the arms alone: a parent that backgrounds a child and exits would fire
# its own trap and print a restore line over a running campaign.
if [ "${QWEN_TRACE_FOREGROUND:-0}" != 1 ]; then
    QWEN_TRACE_FOREGROUND=1
    export QWEN_TRACE_FOREGROUND
    setsid nohup "$script_path" "$output_directory" \
        >>"$campaign_log" 2>&1 </dev/null &
    printf 'trace_campaign=detached pid=%s log=%s\n' "$!" "$campaign_log"
    exit 0
fi

printf 'trace_campaign=started utc=%s output_directory=%s build=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$output_directory" "$trace_build_directory"

# The promotion link this campaign leaves behind. The target is read before any
# arm runs, because the restore reinstates the recorded target rather than
# whatever the link happens to point at when the campaign ends.
current_link=$appliance_source/build-appliance-current
recorded_link_target=''
if [ -L "$current_link" ]; then
    recorded_link_target=$(readlink "$current_link")
fi

summary=$output_directory/trace-campaign-summary.tsv
summary_header='arm	depth	batch	ubatch	submit_trace	max_nodes_per_submit	serialize_submissions	cache_k	cache_v	flash_attn	status	ring_resets	gpu_faults	wall_s	decode_tok_s	control_status	control_tok_s	mclk_modal	temp_c_max	health	hazard_class	trace_dump	trace_log'
summary_field_count=23
summary_has_arms=0
if [ -s "$summary" ]; then
    if [ "$(sed -n '1p' "$summary")" != "$summary_header" ]; then
        printf 'campaign summary header is incompatible with this harness: %s\n' \
            "$summary" >&2
        exit 2
    fi
    malformed_line=$(awk -F'\t' -v fields="$summary_field_count" '
        NR > 1 && NF != fields { print NR; exit }' "$summary")
    if [ -n "$malformed_line" ]; then
        printf 'campaign summary carries a malformed arm row at line %s: %s\n' \
            "$malformed_line" "$summary" >&2
        exit 2
    fi
    duplicate_arm=$(awk -F'\t' 'NR > 1 && seen[$1]++ { print $1; exit }' "$summary")
    if [ -n "$duplicate_arm" ]; then
        printf 'campaign summary carries duplicate arm identity: %s\n' \
            "$duplicate_arm" >&2
        exit 2
    fi
    if ! awk -F'\t' -v cache_k="$cache_type_k" -v cache_v="$cache_type_v" \
        -v flash="$flash_attention" '
        NR > 1 && ($8 != cache_k || $9 != cache_v || $10 != flash) {
            printf "recorded arm %s belongs to cache policy %s/%s/%s, not %s/%s/%s; use a new output directory\n", \
                $1, $8, $9, $10, cache_k, cache_v, flash > "/dev/stderr"
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

# A matching arm label is a matching measurement only while the model bytes, the
# bench binary, and the recovery control stay the same. The metadata row binds
# the ledger to all three, so a rebuilt trace binary requires a new directory
# rather than resuming into rows another binary produced.
ledger_version=1
metadata=$output_directory/trace-campaign-metadata.tsv
metadata_header='ledger_version	model_sha256	model_bytes	bench_sha256	control_tokens'
model_sha256=$(nice -n 19 sha256sum "$model_path")
model_sha256=${model_sha256%% *}
model_bytes=$(stat -c %s -- "$model_path")
bench_sha256=$(nice -n 19 sha256sum "$bench")
bench_sha256=${bench_sha256%% *}
metadata_row="$ledger_version	$model_sha256	$model_bytes	$bench_sha256	$control_tokens"
if [ -s "$metadata" ]; then
    if [ "$(sed -n '1p' "$metadata")" != "$metadata_header" ] ||
       [ "$(sed -n '2p' "$metadata")" != "$metadata_row" ] ||
       [ -n "$(sed -n '3p' "$metadata")" ]; then
        printf 'campaign metadata does not match the model, the bench, or the control: %s\n' \
            "$metadata" >&2
        exit 2
    fi
elif [ "$summary_has_arms" -eq 1 ]; then
    printf 'campaign summary has arms but no identity metadata: %s\n' \
        "$metadata" >&2
    exit 2
else
    printf '%s\n%s\n' "$metadata_header" "$metadata_row" >"$metadata"
fi

sampler_pid=''
stop_sampler() {
    [ -n "$sampler_pid" ] || return 0
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=''
}
kernel_follow_pid=''
stop_kernel_follow() {
    [ -n "$kernel_follow_pid" ] || return 0
    kill "$kernel_follow_pid" 2>/dev/null || true
    wait "$kernel_follow_pid" 2>/dev/null || true
    kernel_follow_pid=''
}

# The restore runs from the EXIT trap, so it runs after a halt, after a signal,
# and after a shell error alike. It reinstates the link target recorded before
# the first arm and then proves the closure twice: the patch series replays
# against a pristine checkout, which fixes the source the production binary was
# built from, and the promoted build's own load closure is rehashed against its
# artifact manifest, which fixes the binary that serves. The two answer
# different questions, so the failure reason names which one refused.
#
# The re-promotion is the atomic relink alone. `promote-llama-build.sh` runs
# llama-cli and llama-mtmd-cli against the device before it moves the link, and
# the campaign exists to wedge that device, so the full gate would refuse for a
# reason the closure has nothing to do with. Relinking the recorded target and
# then proving the target's own identity establishes the same claim without
# spending the device.
restore_state=unattempted
restore_reason=''
restore_action=unchanged
restore_production_closure() {
    restore_reason=''
    restore_action=unchanged

    if [ -z "$recorded_link_target" ]; then
        restore_state=UNRESTORED
        restore_reason=current-link-absent
        return 0
    fi

    live_link_target=''
    [ ! -L "$current_link" ] || live_link_target=$(readlink "$current_link")
    if [ "$live_link_target" != "$recorded_link_target" ]; then
        restore_action=relinked
        ln -sfn "$recorded_link_target" "$current_link.new" 2>/dev/null || true
        mv -T "$current_link.new" "$current_link" 2>/dev/null || true
        live_link_target=''
        [ ! -L "$current_link" ] || live_link_target=$(readlink "$current_link")
        if [ "$live_link_target" != "$recorded_link_target" ]; then
            restore_state=UNRESTORED
            restore_reason=relink-failed
            return 0
        fi
    fi

    # The production closure is the five-patch series:
    # `prepare-llama-vulkan-source.sh` reports `patch_count=5` and leaves
    # `ggml-vulkan-submit-trace.h` off the serving tree, so a serving tree
    # carrying that header is the diagnostic tree in the production tree's
    # place. `verify-llama-patch-series.sh` replays six patches and therefore
    # states that the patch inputs are intact rather than which series the
    # promoted binary came from; the serving tree's own digests state that.
    production_ggml_vulkan_sha256=db34fbfc5ee5368ccc5999dc5a37c90dd3198ae0aff8138440cd7f5f0532eca4
    production_server_sha256=d2d5cb43a83c6b2b459b85f2df181a3d976efcaef351e5cbc6b418ba839390e3
    if [ "${QWEN_TRACE_SKIP_PRODUCTION_SOURCE_GATE:-0}" != 1 ]; then
        if [ -e "$appliance_source/ggml/src/ggml-vulkan/ggml-vulkan-submit-trace.h" ]; then
            restore_state=UNRESTORED
            restore_reason=production-source-carries-trace-header
            return 0
        fi
        for production_check in \
            "$production_ggml_vulkan_sha256 ggml/src/ggml-vulkan/ggml-vulkan.cpp" \
            "$production_server_sha256 tools/server/server.cpp"; do
            production_expected=${production_check%% *}
            production_path=${production_check#* }
            if [ ! -r "$appliance_source/$production_path" ]; then
                restore_state=UNRESTORED
                restore_reason=production-source-incomplete
                return 0
            fi
            production_actual=$(sha256sum "$appliance_source/$production_path" |
                awk '{ print $1 }')
            if [ "$production_actual" != "$production_expected" ]; then
                restore_state=UNRESTORED
                restore_reason=production-source-mismatch
                return 0
            fi
        done
    fi

    if [ -n "$patch_source" ]; then
        patch_series_ok=0
        "$patch_verifier" "$patch_source" \
            >>"$output_directory/restore.log" 2>&1 && patch_series_ok=1
    else
        patch_series_ok=0
        "$patch_verifier" >>"$output_directory/restore.log" 2>&1 &&
            patch_series_ok=1
    fi
    if [ "$patch_series_ok" -ne 1 ]; then
        restore_state=UNRESTORED
        restore_reason=patch-series-refused
        return 0
    fi

    promoted_directory=$live_link_target
    case $promoted_directory in
        /*) ;;
        *) promoted_directory=$appliance_source/$promoted_directory ;;
    esac
    promoted_manifest=$promoted_directory/artifact-manifest.tsv
    promoted_server=$promoted_directory/bin/llama-server
    if [ ! -r "$promoted_manifest" ] || [ ! -x "$promoted_server" ]; then
        restore_state=UNRESTORED
        restore_reason=promoted-build-incomplete
        return 0
    fi
    if ! promoted_closure=$("$closure_hasher" "$promoted_server" 2>>"$output_directory/restore.log"); then
        restore_state=UNRESTORED
        restore_reason=closure-enumeration-failed
        return 0
    fi
    closure_drift=''
    printf '%s\n' "$promoted_closure" | sed 1d >"$output_directory/restore-closure.tsv"
    while IFS= read -r closure_row; do
        [ -n "$closure_row" ] || continue
        grep -F -x -- "$closure_row" "$promoted_manifest" >/dev/null ||
            closure_drift=$closure_row
    done <"$output_directory/restore-closure.tsv"
    if [ -n "$closure_drift" ]; then
        restore_state=UNRESTORED
        restore_reason=closure-drift
        return 0
    fi

    restore_state=restored
    return 0
}

campaign_exit() {
    campaign_status=$?
    trap - EXIT
    stop_sampler
    stop_kernel_follow
    restore_production_closure
    if [ "$restore_state" = restored ]; then
        printf 'production_closure=restored action=%s target=%s\n' \
            "$restore_action" "$recorded_link_target"
    else
        printf 'production_closure=UNRESTORED reason=%s target=%s\n' \
            "${restore_reason:-unknown}" "${recorded_link_target:-none}" >&2
        # An unrestored closure outranks the campaign's own result, because a
        # laptop left serving an instrumented binary is the more dangerous
        # state than a campaign that halted on the arm it was run to find.
        campaign_status=70
    fi
    exit "$campaign_status"
}
interrupt_campaign() {
    printf 'trace_campaign=interrupted status=%s output_directory=%s\n' \
        "$1" "$output_directory" >&2
    exit "$1"
}
trap campaign_exit EXIT
trap 'interrupt_campaign 129' HUP
trap 'interrupt_campaign 130' INT
trap 'interrupt_campaign 143' TERM

kernel_line_count() {
    if "$kernel_reader" >/dev/null 2>&1; then
        "$kernel_reader" | wc -l
    else
        printf 'unavailable\n'
    fi
}

kernel_delta_lines() {
    delta_before=$1
    delta_file=$2
    rm -f -- "$delta_file"
    [ "$delta_before" != unavailable ] || return 0
    "$kernel_reader" | tail -n "+$((delta_before + 1))" >"$delta_file" 2>/dev/null || true
}

# `dmesg --follow-new` writes the delta as it arrives, which survives a ring
# buffer wrap that the before-count-and-subtract method loses silently. A dmesg
# that replays the buffer once and exits leaves the method at `offset`.
kernel_capture_method=offset
start_kernel_capture() {
    capture_file=$1
    kernel_capture_method=offset
    "$kernel_reader" --follow-new >"$capture_file" 2>/dev/null &
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

# The five classes of evidence/vulkan-submit-trace-design.md, recognised from
# the kernel delta, the bench log, and the control's own status together.
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
    if [ "$hazard_arm_resets" != unavailable ] &&
       [ "$hazard_control_resets" != unavailable ]; then
        combined_resets=$((hazard_arm_resets + hazard_control_resets))
    fi
    if [ "$combined_resets" != unavailable ] && [ "$combined_resets" -gt 0 ] &&
       [ "$hazard_control_status" -ne 0 ]; then
        hazard_classes=${hazard_classes:+$hazard_classes,}post-reset-control-failure
    fi
    printf '%s' "${hazard_classes:-none}"
}

# One invocation of the trace-capable bench under the resolved submission
# triple. The wrapper's `custom` branch restores exactly the variables named
# here, so the environment the device saw is the environment the summary row
# states. `timeout` reports 124 on a plain expiry and 128+signal after the
# kill-after escalation, which is what makes a parked driver distinguishable
# from a bench that returned an error.
# The wrapper exports LLAMA_NO_CPU_FALLBACK=1, and llama-bench without a
# placement leaves model.input_embed on the host, which the guard rejects
# during the fused Gated DeltaNet reserve check. -dev Vulkan0 with the
# override pattern is the placement qwen-capacity-policy.sh gives the server,
# so every arm measures the served placement under the served guard.
run_bench() {
    bench_log=$1
    bench_depth=$2
    bench_batch=$3
    bench_ubatch=$4
    bench_tokens=$5
    bench_submit_trace=$6
    bench_timeout_s=${QWEN_TRACE_ARM_TIMEOUT_S:-$((120 + bench_depth / 4))}
    bench_trace_value=
    [ "$bench_submit_trace" != on ] || bench_trace_value=1
    if [ "$bench_depth" -eq 0 ]; then
        QWEN_VULKAN_PROFILE=custom \
        GGML_VK_MAX_NODES_PER_SUBMIT=$max_nodes_per_submit \
        GGML_VK_SERIALIZE_SUBMISSIONS=$serialize_submissions \
        GGML_VK_SUBMIT_TRACE=$bench_trace_value \
            nice -n 19 ionice -c 3 timeout \
            --kill-after="${arm_timeout_kill_after_s}s" "${bench_timeout_s}s" \
            "$environment_wrapper" "$bench" -m "$model_path" \
            -ngl 99 -dev Vulkan0 -ot '.*=Vulkan0' \
            -t 2 -r 1 -p 0 -n "$bench_tokens" \
            -b "$bench_batch" -ub "$bench_ubatch" \
            -ctk "$cache_type_k" -ctv "$cache_type_v" -fa "$flash_attention" \
            -o md >"$bench_log" 2>&1
    else
        QWEN_VULKAN_PROFILE=custom \
        GGML_VK_MAX_NODES_PER_SUBMIT=$max_nodes_per_submit \
        GGML_VK_SERIALIZE_SUBMISSIONS=$serialize_submissions \
        GGML_VK_SUBMIT_TRACE=$bench_trace_value \
            nice -n 19 ionice -c 3 timeout \
            --kill-after="${arm_timeout_kill_after_s}s" "${bench_timeout_s}s" \
            "$environment_wrapper" "$bench" -m "$model_path" \
            -ngl 99 -dev Vulkan0 -ot '.*=Vulkan0' \
            -t 2 -r 1 -p 0 -n "$bench_tokens" -d "$bench_depth" \
            -b "$bench_batch" -ub "$bench_ubatch" \
            -ctk "$cache_type_k" -ctv "$cache_type_v" -fa "$flash_attention" \
            -o md >"$bench_log" 2>&1
    fi
}

campaign_halted=0
halt_reason=''
halt_arm=''
halt_trace_log=''
halt_trace_dump=''

run_arm() {
    arm_label=$1
    arm_depth=$2
    arm_batch=$3
    arm_ubatch=$4
    arm_submit_trace=$5
    arm_log=$output_directory/$arm_label.log
    arm_samples=$output_directory/$arm_label.clocks.tsv
    arm_kernel=$output_directory/$arm_label.dmesg.txt
    arm_signature=$output_directory/$arm_label.kernel-signature.txt
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
            '$1 == label { print $11; exit }' "$summary")
        recorded_control_status=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $16; exit }' "$summary")
        recorded_resets=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $12; exit }' "$summary")
        recorded_faults=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $13; exit }' "$summary")
        recorded_trace=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $5; exit }' "$summary")
        recorded_batch=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $3; exit }' "$summary")
        recorded_ubatch=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $4; exit }' "$summary")
        recorded_depth=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $2; exit }' "$summary")
        recorded_trace_dump=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $22; exit }' "$summary")
        recorded_trace_log=$(awk -F'\t' -v label="$arm_label" \
            '$1 == label { print $23; exit }' "$summary")
        if [ "$recorded_depth" != "$arm_depth" ] ||
           [ "$recorded_batch" != "$arm_batch" ] ||
           [ "$recorded_ubatch" != "$arm_ubatch" ] ||
           [ "$recorded_trace" != "$arm_submit_trace" ]; then
            printf 'recorded arm %s carries geometry %s/%s/%s trace=%s, not %s/%s/%s trace=%s; use a new output directory\n' \
                "$arm_label" "$recorded_depth" "$recorded_batch" \
                "$recorded_ubatch" "$recorded_trace" "$arm_depth" "$arm_batch" \
                "$arm_ubatch" "$arm_submit_trace" >&2
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
        printf 'arm_resume_skip label=%s status=%s control=%s resets=%s faults=%s trace_dump=%s\n' \
            "$arm_label" "$recorded_status" "$recorded_control_status" \
            "$recorded_resets" "$recorded_faults" "$recorded_trace_dump"
        if [ "$recorded_status" -ne 0 ] || [ "$recorded_control_status" -ne 0 ] ||
           { [ "$recorded_resets" != unavailable ] && [ "$recorded_resets" -gt 0 ]; } ||
           { [ "$recorded_faults" != unavailable ] && [ "$recorded_faults" -gt 0 ]; }; then
            campaign_halted=1
            halt_arm=$arm_label
            halt_reason=recorded-failure
            halt_trace_dump=$recorded_trace_dump
            halt_trace_log=$recorded_trace_log
        fi
        return 0
    fi
    for incomplete_artifact in "$arm_log" "$arm_samples" "$control_log"; do
        if [ -e "$incomplete_artifact" ]; then
            printf 'unrecorded arm %s has an incomplete artifact; use a new output directory: %s\n' \
                "$arm_label" "$incomplete_artifact" >&2
            exit 2
        fi
    done

    start_kernel_capture "$arm_kernel"
    kernel_before=unavailable
    [ "$kernel_capture_method" = follow ] || kernel_before=$(kernel_line_count)
    arm_started=$(date +%s)
    printf 'arm_start_utc=%s label=%s depth=%s geometry=%s/%s trace=%s nodes=%s serialize=%s kernel_capture=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$arm_depth" \
        "$arm_batch" "$arm_ubatch" "$arm_submit_trace" "$max_nodes_per_submit" \
        "$serialize_submissions" "$kernel_capture_method"

    : >"$arm_samples"
    "$clock_sampler" "$arm_samples" &
    sampler_pid=$!
    set +e
    run_bench "$arm_log" "$arm_depth" "$arm_batch" "$arm_ubatch" \
        "$generate_tokens" "$arm_submit_trace"
    arm_status=$?
    set -e
    stop_sampler
    arm_wall=$(($(date +%s) - arm_started))
    if [ "$kernel_capture_method" = follow ]; then
        stop_kernel_follow
    else
        kernel_delta_lines "$kernel_before" "$arm_kernel"
    fi

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

    # The trace prints to the bench process's stderr, which this log holds, so
    # the dump's own header line is what states the trace produced a record.
    # The dump runs from the device-lost path alone, so a traced arm that
    # completed reads `not-triggered` and `absent` belongs to a traced arm that
    # failed and named no dispatch, which is the instrumentation failure the
    # field exists to separate from a graph that never lost the device. An
    # untraced arm reads `off`. The match names the dump's two header forms
    # from ggml_vk_print_submit_trace, since the startup banner also carries
    # `submission trace = on` and would otherwise read a completed arm as a dump.
    trace_dump=off
    if [ "$arm_submit_trace" = on ]; then
        if grep -qE 'submission trace, [0-9]+ unretired of [0-9]+ dispatches|submission trace holds no unretired dispatch' \
            "$arm_log" 2>/dev/null; then
            trace_dump=present
        elif [ "$arm_status" -eq 0 ]; then
            trace_dump=not-triggered
        else
            trace_dump=absent
        fi
    fi
    trace_log=-
    [ "$arm_submit_trace" != on ] || trace_log=$arm_log

    # The kernel signature of a failed arm is extracted beside the whole delta,
    # because the delta of a wedging arm runs to hundreds of lines and the
    # signature is what a quarantine record quotes.
    if [ "$arm_status" -ne 0 ] && [ -f "$arm_kernel" ]; then
        grep -iE 'ring reset|Ring .* reset|device wedged|GPU reset|page fault|PROTECTION_FAULT|amdgpu' \
            "$arm_kernel" >"$arm_signature" 2>/dev/null || true
    fi

    arm_samples_present=1
    [ -s "$arm_samples" ] || arm_samples_present=0

    # A ring reset finishes recovering on a quiet device, so a control started
    # into a recovering device measures the recovery.
    if [ "$arm_resets" != unavailable ] && [ "$arm_resets" -gt 0 ]; then
        printf 'recovery_pause_utc=%s seconds=60 resets=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_resets"
        sleep 60
    fi

    start_kernel_capture "$control_kernel"
    control_kernel_before=unavailable
    [ "$kernel_capture_method" = follow ] ||
        control_kernel_before=$(kernel_line_count)
    control_kernel_capture_method=$kernel_capture_method
    set +e
    run_bench "$control_log" 0 128 32 "$control_tokens" off
    control_status=$?
    set -e
    if [ "$control_kernel_capture_method" = follow ]; then
        stop_kernel_follow
    else
        kernel_delta_lines "$control_kernel_before" "$control_kernel"
    fi
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

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_label" "$arm_depth" "$arm_batch" "$arm_ubatch" \
        "$arm_submit_trace" "$max_nodes_per_submit" "$serialize_submissions" \
        "$cache_type_k" "$cache_type_v" "$flash_attention" "$arm_status" \
        "$resets" "$faults" "$arm_wall" "$decode" "$control_status" \
        "$control_decode" "$clock_report" "$health" "$hazard_class" \
        "$trace_dump" "$trace_log" >>"$summary"
    printf 'arm_stop_utc=%s label=%s status=%s decode=%s resets=%s faults=%s wall_s=%s control=%s control_tok_s=%s health=%s hazard_class=%s trace_dump=%s trace_log=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$arm_status" "$decode" \
        "$resets" "$faults" "$arm_wall" "$control_status" "$control_decode" \
        "$health" "$hazard_class" "$trace_dump" "$trace_log"

    if [ "$arm_status" -ne 0 ] || [ "$control_status" -ne 0 ] ||
       { [ "$resets" != unavailable ] && [ "$resets" -gt 0 ]; } ||
       { [ "$faults" != unavailable ] && [ "$faults" -gt 0 ]; }; then
        campaign_halted=1
        halt_arm=$arm_label
        halt_trace_dump=$trace_dump
        halt_trace_log=$trace_log
        if [ "$control_status" -ne 0 ]; then
            halt_reason=control-failed
        elif [ "$arm_status" -eq 124 ]; then
            halt_reason=arm-timed-out
        elif [ "$arm_status" -eq 137 ]; then
            halt_reason=arm-killed-after-timeout
        elif [ "$arm_status" -ne 0 ]; then
            halt_reason=arm-failed
        else
            halt_reason=kernel-hazard
        fi
    fi
}

# The three arms in order. P0 and P1 differ in the trace flag alone; T1 raises
# the batch to the geometry the quarantine record wedged at.
run_arm p0 16384 128 32 off
[ "$campaign_halted" -eq 1 ] || run_arm p1 16384 128 32 on
[ "$campaign_halted" -eq 1 ] || run_arm t1 16384 2048 32 on

if [ "$campaign_halted" -eq 1 ]; then
    printf 'trace_campaign=halted arm=%s reason=%s trace_dump=%s trace_log=%s output_directory=%s\n' \
        "$halt_arm" "$halt_reason" "$halt_trace_dump" "$halt_trace_log" \
        "$output_directory"
    if [ "$halt_trace_dump" = present ]; then
        printf 'trace_record=%s reads the submission serial, the last completed serial, the node and operation, the pipeline, and the dispatch geometry of every unretired dispatch\n' \
            "$halt_trace_log"
    elif [ "$halt_trace_dump" = absent ]; then
        printf 'trace_record=absent the traced arm printed no submission trace, so the failing dispatch stays unnamed\n'
    fi
    cat "$summary"
    exit 1
fi

printf 'trace_campaign=completed output_directory=%s\n' "$output_directory"
cat "$summary"
