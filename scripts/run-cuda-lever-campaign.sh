#!/bin/sh
set -eu

# Measure what the CUDA runtime levers are worth on one checkpoint, with an
# adjacent default beside every subject arm.
#
# A lever here moves five to eight percent and the sweep's own forward-to-reverse
# instability is one to two, so the two are separated by adjacency rather than by
# margin: each subject profile runs between two default arms, and the reported
# ratio is against the mean of the defaults touching it. A campaign that ran all
# defaults first would attribute the session's drift to whichever lever ran last.
#
# The arm order runs each subject once forward and once reversed, so a subject
# meets both ends of the campaign the way run-cuda-baseline-sweep.sh makes a
# checkpoint meet both ends of a sweep.
#
# Device ownership is held for the whole campaign through
# gpu-workload-ownership.sh, and the desktop client set is recorded before every
# arm. A client set that changes between an arm and the default beside it ends
# the campaign, because a browser taking and releasing a CUDA context moves the
# quantity under measurement by more than the lever does.
#
# Each profile also runs one greedy fixed-seed completion. Token identity against
# the adjacent default separates a performance lever from a numerical-policy
# change, which a rate alone cannot report.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY MODEL_PATH\n' "$0" >&2
    printf '  QWEN_LEVER_PROFILES   subject profiles, default "no-graphs no-fusion pdl"\n' >&2
    printf '  QWEN_LLAMA_BENCH      llama-bench built with CUDA\n' >&2
    printf '  QWEN_LLAMA_CLI        llama-cli for the token-identity control\n' >&2
    printf '  QWEN_BENCH_REPEATS    repetitions per arm, default 3\n' >&2
    printf '  QWEN_CONTROL_TOKENS   control completion length, default 32\n' >&2
    exit 2
}

[ "$#" -eq 2 ] || usage

output_directory=$1
model_path=$2

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
[ -f "$model_path" ] || {
    printf 'model file is absent: %s\n' "$model_path" >&2
    exit 2
}

sweep=$script_directory/run-cuda-baseline-sweep.sh
[ -x "$sweep" ] || { printf 'missing: %s\n' "$sweep" >&2; exit 2; }
runtime_wrapper=$script_directory/cuda-runtime-env.sh
llama_cli=${QWEN_LLAMA_CLI:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-cli"}
subject_profiles=${QWEN_LEVER_PROFILES:-'no-graphs no-fusion pdl'}
control_tokens=${QWEN_CONTROL_TOKENS:-32}
model_label=$(basename "$model_path" .gguf)

mkdir -p "$output_directory"
summary=$output_directory/lever-summary.tsv
printf 'slot\tarm\tprofile\tdirection\tprefill_tok_s\tdecode_tok_s\tstatus\tdesktop_clients\tcontrol_digest\n' \
    >"$summary"

# The lock is held for the whole campaign, so the descriptor stays open and every
# child that outlives an arm closes it explicitly.
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_acquire || exit $?
QWEN_GPU_OWNERSHIP_HELD=1
export QWEN_GPU_OWNERSHIP_HELD
gpu_ownership_inspect >"$output_directory/ownership-open.txt" || exit 1

# The desktop client set is a covariate rather than a constant, so it is read as
# a sorted name list and compared between adjacent arms.
desktop_client_set() {
    nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader \
        2>/dev/null |
        cut -d, -f2 |
        sed 's/^ *//; s/ .*//; s#.*/##' |
        sort -u |
        tr '\n' ',' |
        sed 's/,$//'
}

opening_clients=$(desktop_client_set)
printf 'campaign_start_utc=%s model=%s clients=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model_label" "$opening_clients" \
    | tee "$output_directory/campaign-metadata.txt"

# One greedy completion at temperature 0 with a fixed seed. The digest of the
# emitted text is what a later arm is compared against; identical digests leave
# the rate arm readable, and a difference is a numerical-policy finding rather
# than a performance one.
control_digest() {
    control_profile=$1
    control_log=$output_directory/$2.control.txt
    if QWEN_CUDA_PROFILE=$control_profile "$runtime_wrapper" \
        "$llama_cli" \
        --model "$model_path" \
        --device CUDA0 \
        --n-gpu-layers 99 \
        --override-tensor '.*=CUDA0' \
        --temp 0 \
        --top-k 1 \
        --seed 20260831 \
        --n-predict "$control_tokens" \
        --prompt 'Name three properties of a quantized matrix multiplication.' \
        --no-warmup \
        --no-display-prompt \
        --single-turn \
        --simple-io \
        >"$control_log" 2>"$control_log.stderr" 9>&-; then
        # llama-cli closes the completion with its own rate line, which differs
        # between two runs that emitted identical tokens. Removing that one line
        # leaves the banner, the build identity, and the generated text, so the
        # digest reports token identity rather than timing.
        sed '/^\[ Prompt: .* t\/s \]$/d' "$control_log" |
            sha256sum | cut -d' ' -f1 | cut -c1-16
    else
        printf 'control-failed\n'
    fi
}

slot=0
campaign_failed=0
run_arm() {
    arm_label=$1
    arm_profile=$2
    arm_direction=$3
    slot=$((slot + 1))
    arm_clients=$(desktop_client_set)
    if [ "$arm_clients" != "$opening_clients" ]; then
        printf 'refused: the desktop client set changed from %s to %s at %s\n' \
            "$opening_clients" "$arm_clients" "$arm_label" >&2
        campaign_failed=1
        return 1
    fi
    arm_directory=$output_directory/$(printf '%02d' "$slot")-$arm_label
    set +e
    QWEN_CUDA_PROFILE=$arm_profile "$sweep" "$arm_directory" "$model_path" \
        >"$arm_directory.stdout" 2>"$arm_directory.stderr"
    arm_status=$?
    set -e
    arm_prefill='n/a'
    arm_decode='n/a'
    if [ -f "$arm_directory/baseline-summary.tsv" ]; then
        arm_prefill=$(awk -F'\t' 'NR>1 && $4 != "n/a" { total += $4; count += 1 }
            END { if (count > 0) printf "%.2f", total / count; else printf "n/a" }' \
            "$arm_directory/baseline-summary.tsv")
        arm_decode=$(awk -F'\t' 'NR>1 && $5 != "n/a" { total += $5; count += 1 }
            END { if (count > 0) printf "%.2f", total / count; else printf "n/a" }' \
            "$arm_directory/baseline-summary.tsv")
    fi
    arm_control=$(control_digest "$arm_profile" "$(printf '%02d' "$slot")-$arm_label")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$slot" "$arm_label" "$arm_profile" "$arm_direction" \
        "$arm_prefill" "$arm_decode" \
        "$([ "$arm_status" -eq 0 ] && printf 'completed' || printf "failed-$arm_status")" \
        "$arm_clients" "$arm_control" >>"$summary"
    [ "$arm_status" -eq 0 ] || campaign_failed=1
    return 0
}

# Forward: a default before and after every subject. Reverse: the subjects in
# the opposite order, so each meets both ends of the campaign's own drift.
run_arm default-a default forward || true
for subject_profile in $subject_profiles; do
    [ "$campaign_failed" -eq 1 ] && break
    run_arm "$subject_profile-forward" "$subject_profile" forward || break
    run_arm "default-after-$subject_profile" default forward || break
done

if [ "$campaign_failed" -eq 0 ]; then
    reversed_profiles=''
    for subject_profile in $subject_profiles; do
        reversed_profiles="$subject_profile $reversed_profiles"
    done
    for subject_profile in $reversed_profiles; do
        [ "$campaign_failed" -eq 1 ] && break
        run_arm "$subject_profile-reverse" "$subject_profile" reverse || break
        run_arm "default-before-$subject_profile" default reverse || break
    done
fi

gpu_ownership_inspect >"$output_directory/ownership-close.txt" || campaign_failed=1

printf 'campaign_stop_utc=%s model=%s failed=%s summary=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model_label" "$campaign_failed" "$summary"
[ "$campaign_failed" -eq 0 ]
