#!/bin/sh
set -eu

# gpu-ownership: delegated to run-closure-identity-ab.sh and run-concurrent-sequence-sweep.sh, which acquire in turn.
#
# Admits the paged KV buffer mechanism on one closure and one checkpoint by
# asking one question: can the ordinary K and V tensor layout live over a CUDA
# virtual memory management reservation with the same tensor addresses,
# types, strides, bytes, graph behavior, and outputs. The subject is the
# control's own binary with LLAMA_KV_PAGED_BUFFER=1 in its environment, so
# the closure, the placement, the cache triple, the submission geometry, and
# the request sequence are held and the buffer kind is the one axis.
#
# Four records decide it. The granularity probe states the driver contract
# and the checkpoint's row geometry against it. The batch-1 identity arms run
# control, subject, and control again over the six state-carrying prompts,
# comparing token ids and the bytes of slot 0's saved state after every
# prompt. The layout reader holds every subject log to the alignment and
# accounting claim and every control log to the absence of the mechanism.
# The primed width-3 sweep runs the same two arms at widths 1 and 3 under the
# admission evidence/ada/concurrent-sequences/README-PRIMED.md shows
# self-reproducible, and requires every subject reply to equal the control's.
# The mechanism reads memory_saved=0 by construction: the whole reservation
# is physically backed, and a sparse mapping is a later transition.

usage() {
    cat >&2 <<'USAGE'
usage: admit-paged-kv-buffer.sh BUILD_DIRECTORY OUTPUT_DIRECTORY [MODEL_ID]

BUILD_DIRECTORY holds bin/llama-server built with
patches/llama-cuda-paged-kv-buffer.patch. Naming no MODEL_ID admits on
qwen38-2b-distill. OUTPUT_DIRECTORY must be absent or empty.

  QWEN_PAGED_KV_WIDTHS    concurrency levels for the primed sweep, default "1 3"
  QWEN_PAGED_KV_REPEATS   bursts per level, default 4
  QWEN_PAGED_KV_SKIP_SWEEP  1 runs the probe and the batch-1 arms alone

The verdict reads admitted only where the batch-1 arms are complete and the
sweep ran widths 1 and 3 with every pair; a narrower run that refuses
nothing reads partial.
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
# The switch has to exist in the closure before an arm asks for it, and the
# proc-address entry is the symbol the library resolves it through.
paged_symbol=$( { nm -D "$server_binary"; for object in $(ldd "$server_binary" | awk '/=>/ { print $3 }'); do nm -D "$object" 2>/dev/null; done; } | grep -c ' ggml_backend_cuda_paged_kv_buffer_type$' || :)
[ "$paged_symbol" -gt 0 ] || {
    printf 'refused: the closure exports no ggml_backend_cuda_paged_kv_buffer_type\n' >&2
    exit 2
}

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
record subject_environment LLAMA_KV_PAGED_BUFFER=1
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
# The probe's geometry pass is the independent census of the attention KV
# tensors the reader holds every paged log to: one row per operand per
# attention layer at the minimum unit.
expected_tensors=$(awk -F'\t' 'NR > 1 && $9 == "minimum" { count++ } END { print count + 0 }' \
    "$output_directory/probe/vmm-layout.tsv" 2>/dev/null || echo 0)
record expected_tensors "$expected_tensors"
[ "$expected_tensors" -gt 0 ] || refusals=$((refusals + 1))

stage identity env QWEN_IDENTITY_SUBJECT_ENV=LLAMA_KV_PAGED_BUFFER=1 QWEN_IDENTITY_SLOT_STATE=1 \
    "$script_directory/run-closure-identity-ab.sh" "$build_directory" "$build_directory" \
    "$output_directory/identity" "$model_id"
identity_summary=$output_directory/identity/summary.tsv
if [ -s "$identity_summary" ]; then
    record identity_verdict "$(awk -F'\t' '$1 == "verdict" { print $2 "\t" $3 }' "$identity_summary")"
    record identity_tokens_identical "$(awk -F'\t' '$1 == "identity" && $5 == "identical" { count++ } END { print count + 0 }' "$identity_summary")"
    record identity_states_identical "$(awk -F'\t' '$1 == "state_identity" && $5 == "identical" { count++ } END { print count + 0 }' "$identity_summary")"
    record identity_placement "$(awk -F'\t' '$1 == "placement_match" { print $3 "=" $4 }' "$identity_summary" | tr '\n' ' ')"
    record identity_comparisons "$(awk -F'\t' '$1 == "comparisons" { print $2 }' "$identity_summary")"
fi

for arm in control-open subject control-close; do
    arm_log=$output_directory/identity/$model_id/$arm/server.log
    [ -s "$arm_log" ] || { record "layout:$arm" "not_run log_absent"; refusals=$((refusals + 1)); continue; }
    case $arm in subject) expect=paged_kv_vmm ;; *) expect=device_default ;; esac
    case $expect in paged_kv_vmm) expect_tensors="--expect-tensors $expected_tensors" ;; *) expect_tensors='' ;; esac
    # shellcheck disable=SC2086
    if python3 "$script_directory/read-paged-kv-layout.py" "$arm_log" --expect "$expect" $expect_tensors \
        >"$output_directory/layout-$arm.tsv" 2>&1; then
        record "layout:$arm" layout_holds
    else
        record "layout:$arm" layout_refused
        refusals=$((refusals + 1))
    fi
done
for key in kv_logical_bytes kv_virtual_reserved_bytes kv_physical_mapped_bytes kv_alignment_padding_bytes \
    unit_bytes vmm_granularity_minimum vmm_granularity_recommended attention_layer_count memory_saved_bytes; do
    record "subject:$key" "$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' "$output_directory/layout-subject.tsv" 2>/dev/null || :)"
done

if [ "$skip_sweep" = 0 ]; then
    stage primed env QWEN_CONCURRENCY_LEVELS="$widths" QWEN_CONCURRENCY_ADMISSION=primed \
        QWEN_CONCURRENCY_REPEATS="$repeats" QWEN_CONCURRENCY_SUBJECT="$server_binary" \
        QWEN_CONCURRENCY_SUBJECT_ENV=LLAMA_KV_PAGED_BUFFER=1 \
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
    for level in $widths; do
        level_log=$output_directory/primed/level-$level.subject.log
        [ -s "$level_log" ] || { record "layout:primed-$level" "not_run log_absent"; refusals=$((refusals + 1)); continue; }
        if python3 "$script_directory/read-paged-kv-layout.py" "$level_log" --expect paged_kv_vmm \
            --expect-tensors "$expected_tensors" \
            >"$output_directory/layout-primed-$level.tsv" 2>&1; then
            record "layout:primed-$level" layout_holds
        else
            record "layout:primed-$level" layout_refused
            refusals=$((refusals + 1))
        fi
    done
else
    record stage:primed "not_run reason=QWEN_PAGED_KV_SKIP_SWEEP"
fi

identity_verdict=$(awk -F'\t' '$1 == "identity_verdict" { print $2 }' "$summary")
primed_identity=$(awk -F'\t' '$1 == "primed_reply_identity" { print $2 }' "$summary")
primed_levels_complete=$(awk -F'\t' '$1 == "primed_levels_complete" { print $2 }' "$summary")
gate_widths_complete=yes
for gate_width in 1 3; do
    printf ' %s ' "$primed_levels_complete" | grep -q " $gate_width " || gate_widths_complete=no
done
if [ "$refusals" -gt 0 ]; then
    verdict=refused
elif [ "$identity_verdict" = subject-divergent ] || [ "$identity_verdict" = control-drift ]; then
    verdict=rejected
elif [ "$skip_sweep" = 0 ] && [ "$primed_identity" = diverged ]; then
    verdict=rejected
elif [ "$identity_verdict" != identical ] || [ "$skip_sweep" = 1 ] || [ "$gate_widths_complete" = no ]; then
    verdict=partial
else
    verdict=admitted
fi
record verdict "$verdict"
record refusals "$refusals"
find "$output_directory" -maxdepth 1 -type f \( -name '*.tsv' -o -name '*.stdout' -o -name '*.stderr' \) \
    -exec sed -i "s#${HOME:?}#\$HOME#g" {} +
cat "$summary"
[ "$verdict" = admitted ]
