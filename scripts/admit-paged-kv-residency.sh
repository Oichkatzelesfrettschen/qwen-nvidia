#!/bin/sh
set -eu

# gpu-ownership: delegated to run-closure-identity-ab.sh, probe-paged-kv-residency-lifecycle.sh, and run-concurrent-sequence-sweep.sh, which acquire in turn.
#
# Admits P2-C, tail residency over the paged KV buffer, on one closure and
# one checkpoint. The subject is the control's own binary with
# LLAMA_KV_PAGED_BUFFER=1 and LLAMA_KV_PAGED_RESIDENCY=tails in its
# environment, so the closure, the placement, the cache triple, the
# submission geometry, and every request sequence are held and the residency
# policy is the one axis. Five stages answer the contract's matrix:
#
#   probe      both driver granularities and the checkpoint's row geometry
#   identity   ordinary control, tails subject, closing control over the six
#              state-carrying prompts, token ids and slot-0 state bytes compared
#   layout     every identity log held to its policy by read-paged-kv-layout.py
#   lifecycle  fully backed null, tails subject, closing null through save,
#              erase, restore, removal, and regrowth at the 4096-row envelope,
#              with the preregistered allocated and latency bounds
#   primed     the self-reproducible width-1 and width-3 sweep, replies equal
#              to the control's, delivered ratio recorded
#
# The verdict reads admitted where every stage completed with nothing
# refused; a run that skipped the sweep or lost a width reads partial.

usage() {
    cat >&2 <<'USAGE'
usage: admit-paged-kv-residency.sh BUILD_DIRECTORY OUTPUT_DIRECTORY [MODEL_ID]

BUILD_DIRECTORY holds bin/llama-server built with
patches/llama-cuda-paged-kv-buffer.patch carrying the residency engine.
Naming no MODEL_ID admits on qwen38-2b-distill. OUTPUT_DIRECTORY must be
absent or empty.

  QWEN_PAGED_KV_WIDTHS      concurrency levels for the primed sweep, default "1 3"
  QWEN_PAGED_KV_REPEATS     bursts per level, default 4
  QWEN_PAGED_KV_SKIP_SWEEP  1 runs the probe, identity, layout, and lifecycle alone
  QWEN_RESIDENCY_*          forwarded to probe-paged-kv-residency-lifecycle.sh
USAGE
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
build_directory=$1
output_directory=$2
model_id=${3:-qwen38-2b-distill}
widths=${QWEN_PAGED_KV_WIDTHS:-"1 3"}
repeats=${QWEN_PAGED_KV_REPEATS:-4}
skip_sweep=${QWEN_PAGED_KV_SKIP_SWEEP:-0}
case $skip_sweep in 0 | 1) ;; *) usage ;; esac

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
server_binary=$build_directory/bin/llama-server
[ -x "$server_binary" ] || {
    printf 'refused: llama-server is absent: %s\n' "$server_binary" >&2
    exit 2
}
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
# The sparse type and the require entry point are the symbols the residency
# policy resolves through; a closure without them serves the full policy
# under the tails name, which the KV constructor refuses, so the check is
# made ahead of any load.
for symbol in ggml_backend_cuda_paged_kv_sparse_buffer_type ggml_backend_cuda_paged_kv_require; do
    found=$( { nm -D "$server_binary"; for object in $(ldd "$server_binary" | awk '/=>/ { print $3 }'); do nm -D "$object" 2>/dev/null; done; } | grep -c " $symbol\$" || :)
    [ "$found" -gt 0 ] || {
        printf 'refused: the closure exports no %s\n' "$symbol" >&2
        exit 2
    }
done

subject_environment='LLAMA_KV_PAGED_BUFFER=1 LLAMA_KV_PAGED_RESIDENCY=tails'

umask 077
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
summary=$output_directory/summary.tsv
: >"$summary"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
record() { printf '%s\t%s\n' "$1" "$2" >>"$summary"; }
record model_id "$model_id"
record build_directory "$(printf '%s' "$build_directory" | scrub_home)"
record server_sha256 "$(sha256sum "$server_binary" | cut -d ' ' -f 1)"
record subject_environment "$subject_environment"
"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv"

refusals=0
stage() {
    stage_name=$1
    shift
    if "$@" >"$output_directory/$stage_name.stdout" 2>"$output_directory/$stage_name.stderr"; then
        record "stage:$stage_name" completed
    else
        record "stage:$stage_name" "failed exit=$?"
        refusals=$((refusals + 1))
    fi
}

stage probe "$script_directory/probe-cuda-vmm-layout.sh" "$output_directory/probe" "$model_id"
for key in granularity_minimum granularity_recommended vmm_supported probe_client_samples probe_alive_samples; do
    record "probe:$key" "$(sed -n "s/^$key=//p" "$output_directory/probe/probe.txt" 2>/dev/null || :)"
done
expected_tensors=$(awk -F'\t' 'NR > 1 && $9 == "minimum" { count++ } END { print count + 0 }' \
    "$output_directory/probe/vmm-layout.tsv" 2>/dev/null || echo 0)
expected_names=$(awk -F'\t' 'NR > 1 && $9 == "minimum" { printf "%scache_%s_l%s", (n++ ? "," : ""), tolower($3), $2 }' \
    "$output_directory/probe/vmm-layout.tsv" 2>/dev/null || :)
expected_layout=$(awk -F'\t' 'NR > 1 && $9 == "minimum" { printf "%scache_%s_l%s=%s:%s", (n++ ? "," : ""), tolower($3), $2, $4, $5 }' \
    "$output_directory/probe/vmm-layout.tsv" 2>/dev/null || :)
expected_cells=$("$script_directory/model-registry.sh" id "$model_id" context_default)
record expected_tensors "$expected_tensors"
record expected_cells "$expected_cells"
[ "$expected_tensors" -gt 0 ] || refusals=$((refusals + 1))

stage identity env "QWEN_IDENTITY_SUBJECT_ENV=$subject_environment" QWEN_IDENTITY_SLOT_STATE=1 \
    "$script_directory/run-closure-identity-ab.sh" "$build_directory" "$build_directory" \
    "$output_directory/identity" "$model_id"
identity_summary=$output_directory/identity/summary.tsv
identity_verdict=absent
if [ -s "$identity_summary" ]; then
    identity_verdict=$(awk -F'\t' '$1 == "verdict" { print $2 }' "$identity_summary")
    record identity_verdict "$(awk -F'\t' '$1 == "verdict" { print $2 "\t" $3 }' "$identity_summary")"
    record identity_tokens_identical "$(awk -F'\t' '$1 == "identity" && $5 == "identical" { count++ } END { print count + 0 }' "$identity_summary")"
    record identity_states_identical "$(awk -F'\t' '$1 == "state_identity" && $5 == "identical" { count++ } END { print count + 0 }' "$identity_summary")"
    record identity_placement "$(awk -F'\t' '$1 == "placement_match" { print $3 "=" $4 }' "$identity_summary" | tr '\n' ' ' | sed 's/ $//')"
    record identity_comparisons "$(awk -F'\t' '$1 == "comparisons" { print $2 }' "$identity_summary")"
fi

# The subject's identity log is read under the tails policy with the bounds;
# the identity prompts pad to smaller envelopes than the lifecycle's, so the
# allocated figure recorded here is the six-prompt sequence's own peak.
for arm in control-open subject control-close; do
    arm_log=$output_directory/identity/$model_id/$arm/server.log
    [ -s "$arm_log" ] || { record "layout:$arm" "not_run log_absent"; refusals=$((refusals + 1)); continue; }
    case $arm in
        subject) reader_arguments="--expect paged_kv_vmm --expect-residency tails --max-latency-median-us ${QWEN_RESIDENCY_MAX_MEDIAN_US:-2000} --max-latency-p95-us ${QWEN_RESIDENCY_MAX_P95_US:-10000}" ;;
        *) reader_arguments="--expect device_default" ;;
    esac
    # shellcheck disable=SC2086
    if python3 "$script_directory/read-paged-kv-layout.py" "$arm_log" $reader_arguments \
        --expect-tensors "$expected_tensors" --expect-names "$expected_names" --expect-layout "$expected_layout" \
        --expect-cells "$expected_cells" >"$output_directory/layout-$arm.tsv" 2>&1; then
        record "layout:$arm" layout_holds
    else
        record "layout:$arm" layout_refused
        refusals=$((refusals + 1))
    fi
done
for key in residency_commits residency_reclaims residency_refusals kv_physical_allocated_max_bytes \
    kv_physical_allocated_final_bytes memory_saved_bytes commit_latency_us_median commit_latency_us_p95 \
    reclaim_latency_us_median reclaim_latency_us_p95; do
    record "identity_subject:$key" "$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' "$output_directory/layout-subject.tsv" 2>/dev/null || :)"
done

# The lifecycle's arm list and its boundary requirement are the admission's
# own rather than the caller's: the three arms and the crossing are what the
# stage exists to compare, so a caller's QWEN_RESIDENCY_ARMS or
# QWEN_RESIDENCY_REQUIRE_BOUNDARIES is overridden here and the summary is
# then held to the tails arm and the cross-arm identity it produced.
stage lifecycle env QWEN_RESIDENCY_ARMS="full tails full-close" QWEN_RESIDENCY_REQUIRE_BOUNDARIES=1 \
    "$script_directory/probe-paged-kv-residency-lifecycle.sh" "$build_directory" "$output_directory/lifecycle" "$model_id"
lifecycle_summary=$output_directory/lifecycle/summary.tsv
lifecycle_gates=0
if [ -s "$lifecycle_summary" ]; then
    for gate in "identity:full:tails	yes" "identity:full:full-close	yes" "arm:tails:layout	layout_holds" "arm:tails:replies_abd	identical"; do
        grep -qxF "$gate" "$lifecycle_summary" && lifecycle_gates=$((lifecycle_gates + 1))
    done
    grep -q "^arm:tails:lifecycle_boundaries	crossed" "$lifecycle_summary" && lifecycle_gates=$((lifecycle_gates + 1))
fi
record lifecycle_gates "$lifecycle_gates/5"
[ "$lifecycle_gates" -eq 5 ] || refusals=$((refusals + 1))
if [ -s "$lifecycle_summary" ]; then
    while IFS="$(printf '\t')" read -r key value; do
        case $key in
            verdict | refusals | identity:* | arm:*:layout | arm:*:lifecycle_boundaries | arm:*:replies_abd | arm:*:state_ad | \
            arm:tails:kv_physical_allocated_max_bytes | arm:tails:kv_physical_allocated_final_bytes | arm:tails:memory_saved_bytes | \
            arm:tails:commit_latency_us_median | arm:tails:commit_latency_us_p95 | arm:tails:reclaim_latency_us_median | \
            arm:tails:reclaim_latency_us_p95 | arm:tails:residency_commits | arm:tails:residency_reclaims | arm:*:a:prompt_n | arm:*:b:prompt_n | arm:*:d:prompt_n)
                record "lifecycle:$key" "$value" ;;
        esac
    done <"$lifecycle_summary"
fi

primed_levels_complete=''
primed_identity=absent
if [ "$skip_sweep" = 0 ]; then
    stage primed env QWEN_CONCURRENCY_LEVELS="$widths" QWEN_CONCURRENCY_ADMISSION=primed \
        QWEN_CONCURRENCY_REPEATS="$repeats" QWEN_CONCURRENCY_SUBJECT="$server_binary" \
        "QWEN_CONCURRENCY_SUBJECT_ENV=$subject_environment" \
        "$script_directory/run-concurrent-sequence-sweep.sh" "$server_binary" "$model_id" \
        "$output_directory/primed"
    paired=$output_directory/primed/paired.tsv
    if [ -s "$paired" ]; then
        # paired.tsv: level, delivered_ratio_median, clears_floor,
        # reply_identity, pairs; reply identity is slot by slot.
        awk -F'\t' 'NR > 1 { print "primed:level-" $1 "\treply_identity=" $4 " delivered_ratio=" $2 " pairs=" $5 }' \
            "$paired" >>"$summary"
        primed_identity=$(awk -F'\t' 'NR > 1 && $4 != "identical" { bad++ } NR > 1 { seen++ } END { print (seen > 0 && bad == 0) ? "identical" : "diverged" }' "$paired")
        # Complete means every requested width has a row carrying every
        # requested pair; a width the sweep dropped or a burst it lost reads
        # as a shortfall rather than as an absent divergence.
        primed_levels_complete=$(awk -F'\t' -v repeats="$repeats" 'NR > 1 && $5 == repeats { print $1 }' "$paired" | sort -n | tr '\n' ' ' | sed 's/ $//')
    else
        primed_identity=absent
        primed_levels_complete=''
    fi
    record primed_reply_identity "$primed_identity"
    record primed_levels_complete "${primed_levels_complete:--}"
    # A primed level N serves N slots of the sweep's slot depth, one stream
    # each, so its cache holds slot_depth cells over N streams; the depth is
    # read from the sweep's own summary rather than assumed.
    # The sweep serves level plus slot offset slots, so the stream count is
    # bound to both as its summary records them. The control log of every
    # level is read too, since a paged setting inherited by the control arm
    # would turn the comparison into paged against paged and only the log
    # states which kind each arm served.
    primed_slot_depth=$(awk -F'\t' '$1 == "slot_depth" { print $2 }' "$output_directory/primed/summary.tsv" 2>/dev/null || :)
    primed_slot_offset=$(awk -F'\t' '$1 == "slot_offset" { print $2 }' "$output_directory/primed/summary.tsv" 2>/dev/null || :)
    # An absent or malformed depth or offset is a refusal rather than a zero,
    # since a zero would bind the layout to a geometry the sweep never wrote.
    case $primed_slot_depth in '' | *[!0-9]* | 0)
        record primed_geometry "refused slot_depth=${primed_slot_depth:--}"
        refusals=$((refusals + 1)); primed_slot_depth=0 ;;
    esac
    case $primed_slot_offset in '' | *[!0-9]*)
        record primed_geometry "refused slot_offset=${primed_slot_offset:--}"
        refusals=$((refusals + 1)); primed_slot_offset=0 ;;
    esac
    record primed_geometry "slot_depth=$primed_slot_depth slot_offset=$primed_slot_offset"
    for level in $widths; do
        level_streams=$((level + primed_slot_offset))
        for primed_arm in subject control; do
            case $primed_arm in
            subject) level_log=$output_directory/primed/level-$level.subject.log; expect_kind=paged_kv_vmm
                expect_extra="--expect-residency tails --expect-tensors $expected_tensors --expect-names $expected_names --expect-layout $expected_layout" ;;
            *) level_log=$output_directory/primed/level-$level.server.log; expect_kind=device_default; expect_extra='' ;;
            esac
            [ -s "$level_log" ] || { record "layout:primed-$level-$primed_arm" "not_run log_absent"; refusals=$((refusals + 1)); continue; }
            # shellcheck disable=SC2086
            if python3 "$script_directory/read-paged-kv-layout.py" "$level_log" --expect "$expect_kind" $expect_extra \
                --expect-cells "$primed_slot_depth" --expect-streams "$level_streams" \
                >"$output_directory/layout-primed-$level-$primed_arm.tsv" 2>&1; then
                record "layout:primed-$level-$primed_arm" layout_holds
            else
                record "layout:primed-$level-$primed_arm" layout_refused
                refusals=$((refusals + 1))
            fi
        done
    done
else
    record stage:primed "not_run reason=QWEN_PAGED_KV_SKIP_SWEEP"
fi


gate_widths_complete=yes
for gate_width in 1 3 $widths; do
    printf ' %s ' "$primed_levels_complete" | grep -q " $gate_width " || gate_widths_complete=no
done
record refusals "$refusals"
if [ "$refusals" -gt 0 ]; then
    verdict=refused
elif [ "$identity_verdict" != identical ] || [ "$primed_identity" != identical ] || [ "$skip_sweep" = 1 ] || [ "$gate_widths_complete" = no ]; then
    verdict=partial
else
    verdict=admitted
fi
record verdict "$verdict"
find "$output_directory" -maxdepth 1 -type f \( -name '*.tsv' -o -name '*.stdout' -o -name '*.stderr' \) \
    -exec sed -i "s#${HOME:?}#\$HOME#g" {} +
cat "$summary"
[ "$verdict" = admitted ]
