#!/bin/sh
# The registered AD104 calibration, run once on a clean boot under the
# preconditions evidence/ada/b789-calibration-design.md states.
#
# The arm matrix is an input rather than a constant. B7, B8, and B9 name nothing
# in this repository -- no script registers them and no evidence file defines
# them -- so this harness carries the run's discipline and refuses to supply its
# content. A matrix file is what unblocks it.
#
# Each arm runs through scripts/run-cuda-baseline-sweep.sh, which already owns
# the served tuple, the `-ot .*=CUDA0` placement under LLAMA_NO_CPU_FALLBACK=1,
# the repetition count, and the mirrored forward-and-reverse order that makes a
# paired mean readable. This script adds what a kernel-policy comparison needs
# around those arms: the clean-state preconditions, the identity of the binary
# every arm ran, a health check between arms that halts rather than continues,
# and the closing repeat of the opening arm that licenses reading the interior.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: run-ad104-b789-calibration.sh [--validate] MATRIX_TSV OUTPUT_DIRECTORY

--validate checks the matrix against the registry, the artifacts, and the
vocabulary without touching the device, and runs nothing.

MATRIX_TSV carries one arm per row, tab separated, comments on lines opening
with `#`, and these sixteen columns:

  arm_id                 unique in the file; the first row is also run last as
                         the closing control.
  model_id               a scripts/models.tsv id whose artifact is present.
  quant_family           the ggml tensor type this arm is about. An artifact
                         holds several, so this names the one the prediction is
                         stated against rather than the file's label.
  b_definition           what B means for this arm, spelled out rather than
                         implied by the arm name.
  ne11                   the value of B, passed as llama-bench's prompt length
                         so one ubatch carries exactly that many columns.
  bench_binary           the llama-bench this arm runs.
  bench_sha256           its expected digest, or `-` to record what is found.
  source_revision        the llama.cpp revision that binary was built from.
  build_configuration    the build tree's distinguishing options.
  environment            space separated NAME=VALUE pairs for this arm, or `-`.
  expected_kernel_family MMVQ, MMQ, MMF, or CUBLAS.
  expected_math_path     DP4A, INT8_MMA, FP16_MMA, or CUBLAS.
  path_evidence          `observed` where a runtime marker names the kernel,
                         `derived` where it follows from source constants alone.
  prediction             what this arm is expected to show.
  falsifier              what result refutes it.
  note                   free text.

  QWEN_CALIBRATION_GENERATE  generated tokens per arm, default 128. Decode runs
                             at ne11 of 1 on every arm, so the tg row is a
                             within-arm control that should not move across B.
  QWEN_CALIBRATION_REPEATS   repetitions per arm, default 3
  QWEN_CALIBRATION_LOCK      lock path, default /tmp/qwen-ad104-gpu-0.lock

evidence/ada/b789-calibration-design.md states the preconditions, the stop
conditions, and what the run does not claim.
USAGE
    exit 2
}

validate_only=0
if [ "${1:-}" = --validate ]; then
    validate_only=1
    shift
fi
[ "$#" -eq 2 ] || usage
matrix_file=$1
output_directory=$2

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd)
registry_reader=$script_directory/model-registry.sh
sweep=$script_directory/run-cuda-baseline-sweep.sh
latch=$script_directory/gpu-state-latch.sh
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
nvidia_smi=${QWEN_NVIDIA_SMI:-nvidia-smi}
generate_tokens=${QWEN_CALIBRATION_GENERATE:-128}
repeats=${QWEN_CALIBRATION_REPEATS:-3}

if [ ! -r "$matrix_file" ]; then
    printf 'the arm matrix is unreadable: %s\n' "$matrix_file" >&2
    printf 'B7, B8, and B9 are undefined in this tree; see %s\n' \
        'evidence/ada/b789-calibration-design.md' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/summary.tsv
manifest=$output_directory/manifest.txt

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

# Matrix validation runs without the device, so a matrix edit is checked before
# the boot it would otherwise be discovered on. It reads the same fields the run
# reads and refuses the same way.
if [ "$validate_only" -eq 1 ]; then
    validation_failures=0
    validate_report() {
        printf '%s=%s%s\n' "$1" "$2" "${3:+ $3}"
        [ "$2" = accepted ] || validation_failures=$((validation_failures + 1))
    }
    seen_ids=$(mktemp)
    row_count=0
    field_failures=''
    while IFS="$(printf '\t')" read -r arm_id model_id quant_family b_definition \
        arm_ne11 bench_binary bench_sha256 source_revision build_configuration \
        arm_environment expected_kernel_family expected_math_path path_evidence \
        arm_prediction arm_falsifier arm_note; do
        case $arm_id in
            '' | \#*) continue ;;
        esac
        row_count=$((row_count + 1))
        for required_field in "$model_id" "$quant_family" "$b_definition" \
            "$arm_ne11" "$bench_binary" "$source_revision" \
            "$build_configuration" "$expected_kernel_family" \
            "$expected_math_path" "$path_evidence" "$arm_prediction" \
            "$arm_falsifier"; do
            [ -n "$required_field" ] ||
                field_failures="$field_failures $arm_id:empty-field"
        done
        case $arm_ne11 in
            '' | *[!0-9]*) field_failures="$field_failures $arm_id:ne11=$arm_ne11" ;;
        esac
        case $expected_kernel_family in
            MMVQ | MMQ | MMF | CUBLAS | mixed) ;;
            *) field_failures="$field_failures $arm_id:kernel=$expected_kernel_family" ;;
        esac
        case $expected_math_path in
            DP4A | INT8_MMA | FP16_MMA | CUBLAS | mixed) ;;
            *) field_failures="$field_failures $arm_id:math=$expected_math_path" ;;
        esac
        case $path_evidence in
            observed | derived) ;;
            *) field_failures="$field_failures $arm_id:evidence=$path_evidence" ;;
        esac
        if grep -qx "$arm_id" "$seen_ids" 2>/dev/null; then
            field_failures="$field_failures $arm_id:duplicate"
        fi
        printf '%s\n' "$arm_id" >>"$seen_ids"
        case $bench_binary in
            '$HOME'/*) resolved_bench=${HOME:?}/${bench_binary#\$HOME/} ;;
            *) resolved_bench=$bench_binary ;;
        esac
        [ -x "$resolved_bench" ] ||
            field_failures="$field_failures $arm_id:bench-absent"
        if [ -n "$bench_sha256" ] && [ "$bench_sha256" != '-' ] &&
            [ -x "$resolved_bench" ]; then
            observed_digest=$(sha256sum "$resolved_bench" | cut -d' ' -f1)
            [ "$observed_digest" = "$bench_sha256" ] ||
                field_failures="$field_failures $arm_id:digest"
        fi
        model_file=$("$registry_reader" id "$model_id" model_file 2>/dev/null) ||
            model_file=''
        if [ -z "$model_file" ]; then
            field_failures="$field_failures $arm_id:no-registry-row"
        elif [ ! -f "$model_root/$model_file" ]; then
            field_failures="$field_failures $arm_id:artifact-absent"
        fi
    done <"$matrix_file"
    rm -f "$seen_ids"
    if [ "$row_count" -gt 0 ]; then
        validate_report matrix_rows accepted "$row_count"
    else
        validate_report matrix_rows rejected 'the matrix carries no arm'
    fi
    if [ -z "$field_failures" ]; then
        validate_report matrix_fields accepted
    else
        validate_report matrix_fields rejected "$field_failures"
    fi
    printf 'matrix_validation=%s failures=%s\n' \
        "$([ "$validation_failures" -eq 0 ] && printf accepted || printf rejected)" \
        "$validation_failures"
    [ "$validation_failures" -eq 0 ]
    exit $?
fi

# The lock excludes a second calibration rather than the device generally: a
# lock only excludes what also takes it, and nothing else in this tree does. The
# process and compute-client checks below are what exclude the appliance. The
# descriptor is held for the whole campaign including the closing control and
# the post-run health read, so it is opened here and never closed explicitly.
calibration_lock=${QWEN_CALIBRATION_LOCK:-/tmp/qwen-ad104-gpu-0.lock}
exec 9>"$calibration_lock"
flock -n 9 || {
    printf 'refused: the AD104 calibration lock is held: %s\n' "$calibration_lock" >&2
    exit 75
}

# Preconditions. Each one is the confound the clean boot exists to remove, so a
# failure here ends the run rather than annotating it.
"$latch" require-clear || fail 'the GPU state latch refuses this run'
if pgrep -x llama-server >/dev/null 2>&1; then
    fail 'llama-server holds the device; run qwen-teardown.sh first'
fi
# The desktop is a live consumer of the same device and its clients are the
# covariate every recorded rate carries, so the compositor and its graphics
# peers are recorded rather than excluded. A project workload is the confound
# the clean boot exists to remove, so a client whose name matches one ends the
# run.
compute_client_rows=$("$nvidia_smi" \
    --query-compute-apps=pid,process_name,used_memory --format=csv,noheader \
    2>/dev/null || :)
project_clients=$(printf '%s\n' "$compute_client_rows" |
    grep -E 'llama|nsys|ncu|python|image-service' || :)
[ -z "$project_clients" ] ||
    fail "a project CUDA workload holds the device: $project_clients"
printf '# pid, process_name, used_memory\n%s\n' "$compute_client_rows" \
    >"$output_directory/resident-compute-clients.txt"
"$nvidia_smi" -q >/dev/null 2>&1 || fail 'nvidia-smi does not answer'

# The ring signature count is the between-arm health check, so it is read once
# before the first arm and compared after each.
hazard_pattern='NV_ERR_NO_MEMORY|NV_ERR_INVALID_STATE|dmaAllocMapping|mapping_reuse|mmuWalkMap|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed|GPU reset|ring[^[:cntrl:]]*timeout'
dmesg_command='dmesg'
if ! dmesg --color=never >/dev/null 2>&1; then
    if sudo -n dmesg --color=never >/dev/null 2>&1; then
        dmesg_command='sudo -n dmesg'
    else
        fail 'the kernel ring is unreadable directly and through sudo -n, so no stop condition can be observed'
    fi
fi
bar1_field() {
    "$nvidia_smi" -q -d MEMORY 2>/dev/null |
        awk -v want="$1" '/BAR1 Memory Usage/ { inside = 1; next }
             inside && $1 == want { print $3; exit }' || printf 'unavailable\n'
}

host_mapping_line() {
    awk '$1 == "MemAvailable:" { a = $2 } $1 == "Mlocked:" { m = $2 }
         $1 == "Unevictable:" { u = $2 } $1 == "PageTables:" { p = $2 }
         $1 == "SUnreclaim:" { s = $2 }
         END { printf "mem_available_kib=%s mlocked_kib=%s unevictable_kib=%s page_tables_kib=%s sunreclaim_kib=%s",
                   a + 0, m + 0, u + 0, p + 0, s + 0 }' /proc/meminfo 2>/dev/null ||
        printf 'unavailable'
}

ring_signatures() {
    # grep -c prints its count and still exits 1 when that count is zero, which
    # is the state a clean boot is in, so the status is discarded and the count
    # is read from the output alone. A trailing second line here would corrupt
    # the manifest this run is read out of later.
    signature_count=$($dmesg_command --color=never 2>/dev/null |
        grep -Eac "$hazard_pattern" 2>/dev/null || :)
    case $signature_count in
        '' | *[!0-9]*) printf '0\n' ;;
        *) printf '%s\n' "$signature_count" ;;
    esac
}
baseline_signatures=$(ring_signatures)

# The identity of everything the run depends on, recorded before the first arm.
{
    printf 'utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown)"
    printf 'repository_revision=%s\n' \
        "$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || printf unknown)"
    printf 'matrix_sha256=%s\n' "$(sha256sum "$matrix_file" | cut -d' ' -f1)"
    printf 'driver=%s\n' \
        "$("$nvidia_smi" --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    printf 'power_limit=%s\n' \
        "$("$nvidia_smi" --query-gpu=power.limit --format=csv,noheader 2>/dev/null | head -1)"
    printf 'persistence_mode=%s\n' \
        "$("$nvidia_smi" --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1)"
    printf 'compositor_occupancy_before_mib=%s\n' \
        "$("$nvidia_smi" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)"
    printf 'baseline_ring_signatures=%s\n' "$baseline_signatures"
    printf 'calibration_lock=%s\n' "$calibration_lock"
    printf 'bar1_total_mib=%s bar1_used_mib_before=%s\n' \
        "$(bar1_field Total)" "$(bar1_field Used)"
    printf 'host_mapping_before=%s\n' "$(host_mapping_line)"
    printf 'generate_tokens=%s repeats=%s\n' "$generate_tokens" "$repeats"
} >"$manifest"

printf 'arm_id\tmodel_id\tposition\tstatus\tbench_sha256\tevidence\tnote\n' >"$summary"
printf 'arm_id\tquant_family\tb_definition\tne11\texpected_kernel_family\texpected_math_path\tpath_evidence\tprediction\tfalsifier\n' \
    >"$output_directory/expectations.tsv"

arm_index=0
opening_arm=''
halted=''

run_arm() {
    arm_id=$1
    model_id=$2
    bench_binary=$3
    arm_environment=$4
    arm_note=$5
    arm_position=$6
    prefill_tokens=$7
    expected_digest=$8

    model_file=$("$registry_reader" id "$model_id" model_file) ||
        fail "no registry row matches id $model_id"
    model_path=$model_root/$model_file
    [ -f "$model_path" ] ||
        fail "arm $arm_id names an absent artifact: $model_path"
    # A checked-in matrix carries `$HOME` rather than a local absolute path,
    # which CLAUDE.md keeps out of commits, so the one prefix is expanded here
    # rather than by an eval over a field a file supplies.
    case $bench_binary in
        '$HOME'/*) bench_binary=${HOME:?}/${bench_binary#\$HOME/} ;;
    esac
    [ -x "$bench_binary" ] ||
        fail "arm $arm_id names an unusable llama-bench: $bench_binary"

    arm_directory=$output_directory/$arm_position-$arm_id
    mkdir -p "$arm_directory"
    bench_digest=$(sha256sum "$bench_binary" | cut -d' ' -f1)
    if [ "$expected_digest" != '-' ] && [ "$expected_digest" != "$bench_digest" ]; then
        fail "arm $arm_id names bench_sha256 $expected_digest and the binary reads $bench_digest"
    fi
    {
        printf 'phase=before utc=%s bar1_used_mib=%s bar1_free_mib=%s %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(bar1_field Used)" \
            "$(bar1_field Free)" "$(host_mapping_line)"
    } >"$arm_directory/mapping.txt"
    {
        printf 'arm_id=%s model_id=%s position=%s\n' \
            "$arm_id" "$model_id" "$arm_position"
        printf 'bench_binary=%s bench_sha256=%s\n' "$bench_binary" "$bench_digest"
        printf 'environment=%s\n' "$arm_environment"
        printf 'note=%s\n' "$arm_note"
    } >"$arm_directory/arm.txt"

    arm_status=completed
    if [ "$arm_environment" = '-' ]; then
        QWEN_LLAMA_BENCH=$bench_binary \
        QWEN_BENCH_PREFILL=$prefill_tokens \
        QWEN_BENCH_GENERATE=$generate_tokens \
        QWEN_BENCH_REPEATS=$repeats \
            "$sweep" "$arm_directory/sweep" "$model_path" \
            >"$arm_directory/sweep.stdout" 2>"$arm_directory/sweep.stderr" ||
            arm_status=failed
    else
        env $arm_environment \
            QWEN_LLAMA_BENCH="$bench_binary" \
            QWEN_BENCH_PREFILL="$prefill_tokens" \
            QWEN_BENCH_GENERATE="$generate_tokens" \
            QWEN_BENCH_REPEATS="$repeats" \
            "$sweep" "$arm_directory/sweep" "$model_path" \
            >"$arm_directory/sweep.stdout" 2>"$arm_directory/sweep.stderr" ||
            arm_status=failed
    fi

    printf 'phase=after utc=%s bar1_used_mib=%s bar1_free_mib=%s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(bar1_field Used)" \
        "$(bar1_field Free)" "$(host_mapping_line)" >>"$arm_directory/mapping.txt"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_id" "$model_id" "$arm_position" "$arm_status" "$bench_digest" \
        "$arm_directory" "$arm_note" >>"$summary"
    printf 'arm=%s position=%s status=%s\n' "$arm_id" "$arm_position" "$arm_status"

    # The between-arm health check. A new driver signature ends the run on the
    # boot it appeared on, because a retry there measures the state the clean
    # boot exists to exclude.
    current_signatures=$(ring_signatures)
    if [ "$current_signatures" != "$baseline_signatures" ]; then
        halted="ring signatures moved $baseline_signatures->$current_signatures after arm $arm_id"
        return 1
    fi
    if ! "$latch" require-clear >/dev/null 2>&1; then
        halted="the GPU state latch was set during arm $arm_id"
        return 1
    fi
    if ! "$nvidia_smi" -q >/dev/null 2>&1; then
        halted="nvidia-smi stopped answering after arm $arm_id"
        return 1
    fi
    if [ "$arm_status" = failed ]; then
        halted="arm $arm_id did not complete"
        return 1
    fi
    return 0
}

while IFS="$(printf '\t')" read -r arm_id model_id quant_family b_definition \
    arm_ne11 bench_binary bench_sha256 source_revision build_configuration \
    arm_environment expected_kernel_family expected_math_path path_evidence \
    arm_prediction arm_falsifier arm_note; do
    case $arm_id in
        '' | \#*) continue ;;
    esac
    case $arm_ne11 in
        '' | *[!0-9]*) fail "arm $arm_id carries a non-numeric ne11: $arm_ne11" ;;
    esac
    arm_index=$((arm_index + 1))
    if [ -z "$opening_arm" ]; then
        opening_arm=$arm_id
        opening_model=$model_id
        opening_bench=$bench_binary
        opening_environment=${arm_environment:--}
        opening_ne11=$arm_ne11
        opening_digest=${bench_sha256:--}
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_id" "$quant_family" "$b_definition" "$arm_ne11" \
        "$expected_kernel_family" "$expected_math_path" "$path_evidence" \
        "$arm_prediction" "$arm_falsifier" >>"$output_directory/expectations.tsv"
    run_arm "$arm_id" "$model_id" "$bench_binary" "${arm_environment:--}" \
        "${arm_note:--}" "$(printf '%02d' "$arm_index")" "$arm_ne11" \
        "${bench_sha256:--}" || break
done <"$matrix_file"

# The closing repeat of the opening arm. Agreement licenses reading the interior
# arms as effects of what the matrix varied; disagreement makes the drift the
# finding.
if [ -z "$halted" ] && [ -n "$opening_arm" ] && [ "$arm_index" -gt 1 ]; then
    arm_index=$((arm_index + 1))
    # The opening arm's fields are held in scalars rather than re-read through a
    # pipe, because a pipeline runs its right side in a subshell and a stop
    # condition the closing arm trips there would leave the manifest reading
    # completed.
    run_arm "closing-$opening_arm" "$opening_model" "$opening_bench" \
        "$opening_environment" 'closing control repeat of the opening arm' \
        "$(printf '%02d' "$arm_index")" "$opening_ne11" "$opening_digest" || :
fi

{
    printf 'compositor_occupancy_after_mib=%s\n' \
        "$("$nvidia_smi" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)"
    printf 'closing_ring_signatures=%s\n' "$(ring_signatures)"
    printf 'bar1_used_mib_after=%s bar1_free_mib_after=%s\n' \
        "$(bar1_field Used)" "$(bar1_field Free)"
    printf 'host_mapping_after=%s\n' "$(host_mapping_line)"
    printf 'arms_run=%s\n' "$arm_index"
    if [ -n "$halted" ]; then
        printf 'terminal_state=halted reason=%s\n' "$halted"
    else
        printf 'terminal_state=completed\n'
    fi
} >>"$manifest"

if [ -n "$halted" ]; then
    printf 'calibration=halted reason=%s summary=%s\n' "$halted" "$summary" >&2
    exit 1
fi
printf 'calibration=completed arms=%s summary=%s\n' "$arm_index" "$summary"
