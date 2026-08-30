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
usage: run-ad104-b789-calibration.sh MATRIX_TSV OUTPUT_DIRECTORY

MATRIX_TSV carries one arm per row, tab separated, comments on lines opening
with `#`:

  arm_id  model_id  bench_binary  environment  note

  arm_id        a name unique in the file; the first row is also run last as
                the closing control.
  model_id      a scripts/models.tsv id whose artifact is present.
  bench_binary  path to the llama-bench this arm runs, so a build-time arm
                names its own tree.
  environment   space separated NAME=VALUE pairs exported for this arm alone,
                or `-`.
  note          free text recorded beside the arm.

  QWEN_CALIBRATION_PREFILL   prompt tokens, default 512
  QWEN_CALIBRATION_GENERATE  generated tokens, default 128
  QWEN_CALIBRATION_REPEATS   repetitions per arm, default 3

evidence/ada/b789-calibration-design.md states the preconditions, the stop
conditions, and what the run does not claim.
USAGE
    exit 2
}

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
prefill_tokens=${QWEN_CALIBRATION_PREFILL:-512}
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

# Preconditions. Each one is the confound the clean boot exists to remove, so a
# failure here ends the run rather than annotating it.
"$latch" require-clear || fail 'the GPU state latch refuses this run'
if pgrep -x llama-server >/dev/null 2>&1; then
    fail 'llama-server holds the device; run qwen-teardown.sh first'
fi
compute_clients=$("$nvidia_smi" --query-compute-apps=pid --format=csv,noheader \
    2>/dev/null | tr -d ' \n' || :)
[ -z "$compute_clients" ] || fail "a CUDA compute client holds the device: $compute_clients"
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
ring_signatures() {
    $dmesg_command --color=never 2>/dev/null |
        grep -Eac "$hazard_pattern" 2>/dev/null || printf '0\n'
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
    printf 'prefill_tokens=%s generate_tokens=%s repeats=%s\n' \
        "$prefill_tokens" "$generate_tokens" "$repeats"
} >"$manifest"

printf 'arm_id\tmodel_id\tposition\tstatus\tbench_sha256\tevidence\tnote\n' >"$summary"

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

    model_file=$("$registry_reader" id "$model_id" model_file) ||
        fail "no registry row matches id $model_id"
    model_path=$model_root/$model_file
    [ -f "$model_path" ] ||
        fail "arm $arm_id names an absent artifact: $model_path"
    [ -x "$bench_binary" ] ||
        fail "arm $arm_id names an unusable llama-bench: $bench_binary"

    arm_directory=$output_directory/$arm_position-$arm_id
    mkdir -p "$arm_directory"
    bench_digest=$(sha256sum "$bench_binary" | cut -d' ' -f1)
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

while IFS="$(printf '\t')" read -r arm_id model_id bench_binary arm_environment arm_note; do
    case $arm_id in
        '' | \#*) continue ;;
    esac
    arm_index=$((arm_index + 1))
    [ -n "$opening_arm" ] ||
        opening_arm="$arm_id	$model_id	$bench_binary	$arm_environment	$arm_note"
    run_arm "$arm_id" "$model_id" "$bench_binary" "${arm_environment:--}" \
        "${arm_note:--}" "$(printf '%02d' "$arm_index")" || break
done <"$matrix_file"

# The closing repeat of the opening arm. Agreement licenses reading the interior
# arms as effects of what the matrix varied; disagreement makes the drift the
# finding.
if [ -z "$halted" ] && [ -n "$opening_arm" ] && [ "$arm_index" -gt 1 ]; then
    arm_index=$((arm_index + 1))
    printf '%s\n' "$opening_arm" | {
        IFS="$(printf '\t')" read -r arm_id model_id bench_binary arm_environment arm_note
        run_arm "closing-$arm_id" "$model_id" "$bench_binary" \
            "${arm_environment:--}" 'closing control repeat of the opening arm' \
            "$(printf '%02d' "$arm_index")" || :
    }
fi

{
    printf 'compositor_occupancy_after_mib=%s\n' \
        "$("$nvidia_smi" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)"
    printf 'closing_ring_signatures=%s\n' "$(ring_signatures)"
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
