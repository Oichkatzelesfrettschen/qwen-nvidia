#!/bin/sh
# Observe which CUDA mat-mul kernel each B7/B8/B9 arm launches.
#
# The matrix derives its kernel families from source constants and every row
# reads path_evidence=derived. This harness replaces that derivation with a
# runtime observation, and the kernel symbol is what carries it: mmvq.cu:544
# declares `template <ggml_type type, int ncols_dst, bool has_fusion, ...>
# __global__ void mul_mat_vec_q`, so a launched MMVQ kernel demangles to
# `mul_mat_vec_q<(ggml_type)12, 7, ...>` and names the quantization type and B
# in the symbol itself. MMQ demangles to `mul_mat_q<(ggml_type)T, mmq_x, ...>`,
# whose second parameter is the tile width rather than B, so an MMQ arm reads
# its type from the symbol and its B from the arm. Nsight Systems records the
# launched name without replaying a kernel, which is what keeps this audit off
# the timing campaign: it establishes the path and its rates are discarded.
#
# GGML_TYPE_Q2_K is 10, Q3_K 11, Q4_K 12, Q5_K 13, and Q6_K 14 in
# ggml/include/ggml.h, and the reader maps the numeric template argument back
# through that table rather than trusting a name in the matrix.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: run-ad104-path-audit.sh [--dry-run] MATRIX_TSV OUTPUT_DIRECTORY [ARM_ID...]

Runs one short profiled prefill per arm and reports the kernel family the
device executed. Naming no ARM_ID audits every row of the matrix.

--dry-run resolves the matrix, the binaries, and the artifacts and runs
nothing on the device.

  QWEN_AUDIT_LOCK      GPU lock path, default /tmp/qwen-ad104-gpu-0.lock
  QWEN_AUDIT_NSYS      nsys binary, default the one on PATH
  QWEN_AUDIT_GENERATE  generated tokens per arm, default 1

The audit refuses to start while a qwen server holds the device, holds the
same lock the calibration holds, and halts on a new kernel-ring signature.
USAGE
    exit 2
}

dry_run=0
case ${1:-} in
    --dry-run) dry_run=1; shift ;;
esac
[ "$#" -ge 2 ] || usage

matrix=$1
output_directory=$2
shift 2

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_reader=$script_directory/model-registry.sh
sweep_wrapper=$script_directory/cuda-runtime-env.sh
latch=$script_directory/gpu-state-latch.sh
kernel_reader=$script_directory/read-nsys-mat-mul-kernels.py
model_root=${QWEN_MODEL_ROOT:-${HOME:?}/models}
nsys=${QWEN_AUDIT_NSYS:-nsys}
generate_tokens=${QWEN_AUDIT_GENERATE:-1}

fail() {
    printf 'refused: %s\n' "$1" >&2
    exit 1
}

[ -f "$matrix" ] || fail "the matrix is absent: $matrix"
[ -x "$registry_reader" ] || fail "the registry reader is absent: $registry_reader"
[ -x "$sweep_wrapper" ] || fail "the CUDA runtime wrapper is absent: $sweep_wrapper"
[ -x "$kernel_reader" ] || fail "the kernel reader is absent: $kernel_reader"
command -v "$nsys" >/dev/null 2>&1 || fail "nsys is absent: $nsys"

mkdir -p "$output_directory"

selected_arms=$*

matrix_rows=$(
    awk -F'\t' -v wanted="$selected_arms" '
        /^#/ { next }
        NF == 0 { next }
        {
            if (NF < 16) {
                printf "matrix row %d carries %d fields where 16 are required\n", NR, NF > "/dev/stderr"
                invalid = 1
                next
            }
            if (wanted != "") {
                found = 0
                split(wanted, want_list, " ")
                for (i in want_list) if (want_list[i] == $1) found = 1
                if (!found) next
            }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $5, $6, $7, $11, $12
        }
        END { if (invalid) exit 1 }
    ' "$matrix"
) || fail "the matrix does not validate"

[ -n "$matrix_rows" ] || fail "no matrix row matches the requested arms"

if [ "$dry_run" -eq 0 ]; then
    if pgrep -f 'llama-server' >/dev/null 2>&1; then
        fail 'a llama-server holds the device; tear the appliance down first'
    fi
    audit_lock=${QWEN_AUDIT_LOCK:-/tmp/qwen-ad104-gpu-0.lock}
    exec 9>"$audit_lock"
    flock -n 9 || {
        printf 'refused: the AD104 calibration lock is held: %s\n' "$audit_lock" >&2
        exit 75
    }
    [ ! -x "$latch" ] || "$latch" require-clear ||
        fail 'the GPU state latch is set'
fi

# kernel.dmesg_restrict is 1 on this host, so an unprivileged dmesg is refused
# and a cold sudo timestamp refuses `sudo -n` with it. Falling back to a reader
# that answers nothing would leave grep -Eac counting an empty stream as zero,
# which is byte-identical to a clean ring and disarms the halt this audit rests
# on, so an unreadable ring ends the run instead.
if dmesg --color=never >/dev/null 2>&1; then
    dmesg_command='dmesg'
elif sudo -n dmesg --color=never >/dev/null 2>&1; then
    dmesg_command='sudo -n dmesg'
else
    fail 'the kernel ring is unreadable directly and through sudo -n, so no stop condition can be observed'
fi
hazard_pattern='ring[^[:cntrl:]]*timeout|GPU reset|NVRM[^[:cntrl:]]*Xid|has fallen off the bus|RmInitAdapter failed|NV_ERR_NO_MEMORY'

ring_signatures() {
    count=$($dmesg_command --color=never 2>/dev/null | grep -Eac "$hazard_pattern" 2>/dev/null || :)
    case $count in
        '' | *[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$count" ;;
    esac
}
baseline_signatures=$(ring_signatures)

observations=$output_directory/kernel-observations.tsv
summary=$output_directory/summary.tsv
printf 'arm_id\tquant_family\tne11\tkernel_name\tkernel_family\tobserved_type\tobserved_ncols\tlaunch_count\ttotal_gpu_ns\tpath_evidence\n' >"$observations"
printf 'arm_id\tne11\texpected_kernel_family\tobserved_kernel_families\tverdict\n' >"$summary"

printf 'audit_start_utc=%s dry_run=%s baseline_ring_signatures=%s nsys=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dry_run" "$baseline_signatures" \
    "$($nsys --version 2>&1 | head -1)" | tee "$output_directory/run.txt"

arm_position=0
resolved_rows=$output_directory/.arms
printf '%s\n' "$matrix_rows" >"$resolved_rows"

# The loop reads a file rather than a pipe, so a halt inside it ends the run
# rather than ending a subshell whose exit the caller never sees.
while IFS="$(printf '\t')" read -r \
    arm_id model_id quant_family ne11 bench_binary bench_sha256 \
    expected_kernel_family expected_math_path
do
    arm_position=$((arm_position + 1))
    case $bench_binary in
        '$HOME'/*) bench_binary=${HOME:?}/${bench_binary#\$HOME/} ;;
    esac
    model_file=$("$registry_reader" id "$model_id" model_file) ||
        fail "no registry row matches id $model_id"
    model_path=$model_root/$model_file
    [ -f "$model_path" ] || fail "arm $arm_id names an absent artifact: $model_path"
    [ -x "$bench_binary" ] || fail "arm $arm_id names an unusable llama-bench: $bench_binary"
    bench_digest=$(sha256sum "$bench_binary" | cut -d' ' -f1)
    if [ "$bench_sha256" != '-' ] && [ "$bench_sha256" != "$bench_digest" ]; then
        fail "arm $arm_id names bench_sha256 $bench_sha256 and the binary reads $bench_digest"
    fi

    arm_directory=$output_directory/$(printf '%02d' "$arm_position")-$arm_id
    mkdir -p "$arm_directory"
    printf 'arm_id=%s model_id=%s ne11=%s quant_family=%s\n' \
        "$arm_id" "$model_id" "$ne11" "$quant_family" >"$arm_directory/arm.txt"
    printf 'bench_binary=%s bench_sha256=%s\n' "$bench_binary" "$bench_digest" \
        >>"$arm_directory/arm.txt"
    printf 'expected_kernel_family=%s expected_math_path=%s\n' \
        "$expected_kernel_family" "$expected_math_path" >>"$arm_directory/arm.txt"

    if [ "$dry_run" -eq 1 ]; then
        printf 'arm=%s position=%s status=resolved\n' "$arm_id" "$arm_position"
        continue
    fi

    cache_type_k=$("$registry_reader" id "$model_id" cache_type_k)
    cache_type_v=$("$registry_reader" id "$model_id" cache_type_v)

    # --sample=none and --cpuctxsw=none keep the profiler off the host sampler,
    # since the audit reads launched kernel names and discards every duration.
    "$nsys" profile \
        --trace=cuda --sample=none --cpuctxsw=none \
        --output "$arm_directory/profile" --force-overwrite true \
        -- "$sweep_wrapper" "$bench_binary" -m "$model_path" --device CUDA0 \
        -ngl 99 -ot '.*=CUDA0' -fa 1 \
        -ctk "$cache_type_k" -ctv "$cache_type_v" \
        -p "$ne11" -n "$generate_tokens" -r 1 -o md \
        >"$arm_directory/profile.stdout" 2>"$arm_directory/profile.stderr" || {
        printf 'arm=%s position=%s status=failed\n' "$arm_id" "$arm_position"
        printf '%s\t%s\t%s\t%s\t%s\n' "$arm_id" "$ne11" \
            "$expected_kernel_family" '-' 'profile-failed' >>"$summary"
        continue
    }

    # nsys stats --report cuda_gpu_kern_sum returns a header and no rows
    # against this capture under Nsight Systems 2026.1.3 while
    # CUPTI_ACTIVITY_KIND_KERNEL holds every launch, so the audit exports the
    # SQLite and reads the activity table rather than the report.
    "$nsys" export --type sqlite --force-overwrite true \
        --output "$arm_directory/profile.sqlite" "$arm_directory/profile.nsys-rep" \
        >"$arm_directory/export.stdout" 2>"$arm_directory/export.stderr" || {
        printf 'arm=%s position=%s status=export-failed\n' "$arm_id" "$arm_position"
        printf '%s\t%s\t%s\t%s\t%s\n' "$arm_id" "$ne11" \
            "$expected_kernel_family" '-' 'export-failed' >>"$summary"
        continue
    }

    arm_observations=$arm_directory/kernels.tsv
    "$kernel_reader" "$arm_directory/profile.sqlite" \
        --arm-id "$arm_id" --quant-family "$quant_family" --ne11 "$ne11" \
        >"$arm_observations" 2>"$arm_directory/kernels.stderr" || {
        printf 'arm=%s position=%s status=no-mat-mul-kernel\n' "$arm_id" "$arm_position"
        printf '%s\t%s\t%s\t%s\t%s\n' "$arm_id" "$ne11" \
            "$expected_kernel_family" '-' 'no-mat-mul-kernel' >>"$summary"
        continue
    }
    cat "$arm_observations" >>"$observations"

    observed_families=$(cut -f5 "$arm_observations" | sort -u | paste -sd, -)

    # The claim an arm makes is about one quantization type rather than about
    # the artifact, since a Q4_K_M file also carries Q6_K and both families
    # launch in one forward pass at B8. A prefill of ne11 tokens and the
    # decode step that follows it share one capture, so an MMVQ row is read as
    # this arm's own only where its ncols_dst template argument equals ne11 --
    # which is also what makes "B is ne11" an observation rather than a reading
    # of the source. MMQ's second template parameter is the tile width, so an
    # MMQ row is read for its type and the arm requires the contradicting MMVQ
    # row at ne11 to be absent.
    verdict=$(
        awk -F'\t' -v quant="$quant_family" -v b="$ne11" \
            -v expected="$expected_kernel_family" '
            $6 == quant && $5 == "MMVQ" && $7 == b { mmvq_at_b = 1 }
            $6 == quant && $5 == "MMQ" { mmq_present = 1 }
            $6 == quant { type_present = 1 }
            END {
                if (!type_present) { print "type-absent"; exit }
                if (expected == "MMVQ") {
                    if (mmq_present) { print "differs-mmq-present"; exit }
                    if (!mmvq_at_b) { print "differs-no-mmvq-at-b"; exit }
                    print "agrees"; exit
                }
                if (expected == "MMQ") {
                    if (mmvq_at_b) { print "differs-mmvq-at-b"; exit }
                    if (!mmq_present) { print "differs-no-mmq"; exit }
                    print "agrees"; exit
                }
                print "expectation-unhandled"
            }
        ' "$arm_observations"
    )
    printf '%s\t%s\t%s\t%s\t%s\n' "$arm_id" "$ne11" \
        "$expected_kernel_family" "${observed_families:--}" "$verdict" >>"$summary"
    printf 'arm=%s position=%s quant=%s expected=%s observed=%s verdict=%s\n' \
        "$arm_id" "$arm_position" "$quant_family" "$expected_kernel_family" \
        "${observed_families:--}" "$verdict"

    current_signatures=$(ring_signatures)
    if [ "$current_signatures" != "$baseline_signatures" ]; then
        printf 'halted=ring_signatures_moved %s->%s after arm %s\n' \
            "$baseline_signatures" "$current_signatures" "$arm_id" \
            | tee -a "$output_directory/run.txt" >&2
        exit 1
    fi
done <"$resolved_rows"
rm -f "$resolved_rows"

printf 'audit_end_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$output_directory/run.txt"

differing=$(awk -F'\t' 'NR > 1 && $5 != "agrees"' "$summary" | wc -l)
printf 'arms=%s differing=%s observations=%s\n' \
    "$(( $(wc -l <"$summary") - 1 ))" "$differing" \
    "$(( $(wc -l <"$observations") - 1 ))"
[ "$differing" -eq 0 ] || {
    printf 'refused: %s arm(s) executed a kernel family the matrix does not expect\n' \
        "$differing" >&2
    exit 1
}
