#!/bin/sh
set -eu

# gpu-ownership: delegated to the serving session the control arms drive.
# Every arm posts to a router and an artifact listener that are already running,
# so the session holds the owner lock and this harness holds none.

# Four reviews of one artifact that turn a passing verdict into a causal claim.
# scripts/image-review.py bounds the reply's shape with a grammar and refuses
# every other shape, so a 4/4 result states that the model answered inside the
# schema. What it leaves open is where the answer came from, and two control
# arms close it: `--image-mode withheld` keeps the multipart text part and drops
# the image part, and `--image-mode swapped` sends a second artifact's bytes
# under the same prompt hash, constraint list, model, temperature, reply budget,
# thinking setting, and absent `tools` key.
#
# The arms run real-A, withheld-A, swapped-A-with-B, real-A. Every arm sends
# --no-prompt-cache, because the four requests share their system instruction
# and text part as a prefix and a warm prefix changes an answer rather than only
# its timing on this backend: arith-05 answers 37 cold and 23 warm at the same
# prompt_n. With the cache off, each arm meets the server the way the first one
# did, arm 2's prefill genuinely excludes the image tokens it dropped, and the
# closing real arm agreeing with the opening one is what licenses reading arms 2
# and 3 as image effects rather than as position in a request sequence.
#
# The falsifiers this run registers:
#
#   1. The withheld arm passes every constraint it cannot see. A verdict that
#      survives the removal of the image reports the model answering from the
#      constraint text, its world knowledge, or the shape of the question, and
#      the visual grounding the review claims is refuted.
#   2. The swapped arm's observations agree with artifact A rather than with
#      artifact B. The request carries B's pixels alone, so an observation
#      describing A reports the same thing arm 2 does through a second route.
#
# This script reports the fields an audit line already carries -- per-arm
# constraint counts, the failed count, the regenerate flag, wall seconds, and
# the exit status -- and grades no prose. Falsifier 2 is settled by a reader
# against the retained `.verdict.json` and `.raw` files, since agreement between
# an observation and an image is a judgment no field states.

usage() {
    printf 'usage: %s ROUTER_ORIGIN ARTIFACT_ORIGIN MODEL SHA256_A SHA256_B PROMPT_HASH OUTPUT_DIR [--constraint NAME=DESCRIPTION ...] [--api-key-file PATH]\n' "$0" >&2
    printf '\nSHA256_A is the artifact under review and SHA256_B the artifact the swapped arm sends.\n' >&2
    printf 'The credential reaches image-review.py through --api-key-file or QWEN_API_KEY.\n' >&2
    exit 2
}

[ "$#" -ge 7 ] || usage

router_origin=$1
artifact_origin=$2
model_id=$3
artifact_a=$4
artifact_b=$5
prompt_hash=$6
output_directory=$7
shift 7

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

is_digest() {
    printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'
}

for digest_argument in "$artifact_a" "$artifact_b" "$prompt_hash"; do
    if ! is_digest "$digest_argument"; then
        printf '%s: a digest is 64 lowercase hex digits: %s\n' "$0" "$digest_argument" >&2
        exit 2
    fi
done

# A swapped arm sending the reviewed artifact's own bytes is a real arm wearing
# a control's label, and the summary would report a control that proved nothing.
if [ "$artifact_a" = "$artifact_b" ]; then
    printf '%s: the swap artifact is the artifact under review\n' "$0" >&2
    exit 2
fi

# The trailing options are forwarded verbatim to each child, so a typo here
# produces one usage message rather than four identical child failures.
expecting_option_value=no
constraint_count=0
for trailing_argument in "$@"; do
    if [ "$expecting_option_value" = yes ]; then
        expecting_option_value=no
        continue
    fi
    case $trailing_argument in
        --constraint)
            constraint_count=$((constraint_count + 1))
            expecting_option_value=yes
            ;;
        --api-key-file)
            expecting_option_value=yes
            ;;
        *)
            usage
            ;;
    esac
done
[ "$expecting_option_value" = no ] || usage
[ "$constraint_count" -ge 1 ] || usage

mkdir -p "$output_directory"
summary_path=$output_directory/summary.tsv
audit_log_path=$output_directory/audit.log
printf 'arm\timage_mode\tswap_sha256\tstatus\tconstraints\tpassed\tfailed\tuncertain\tregenerate\twall_seconds\texit_status\n' >"$summary_path"
: >"$audit_log_path"

refused_arms=0

# Read one key=value field from an audit line image-review.py wrote. Every arm
# emits the line, refusals included, so the summary reads one source whether the
# arm produced a verdict or a refusal code.
audit_field() {
    audit_field_name=$1
    audit_field_line=$2
    printf '%s\n' "$audit_field_line" \
        | tr ' ' '\n' \
        | sed -n "s/^${audit_field_name}=//p" \
        | head -n 1
}

run_arm() {
    arm_label=$1
    arm_image_mode=$2
    arm_swap_digest=$3
    shift 3
    arm_stdout=$output_directory/$arm_label.stdout
    arm_stderr=$output_directory/$arm_label.stderr
    arm_verdict=$output_directory/$arm_label.verdict.json
    # image-review.py writes a verdict record on success alone, so a re-run into
    # a used directory would pair this run's refusal with the previous run's
    # verdict. The arm's whole file set leaves before the arm runs.
    rm -f "$arm_stdout" "$arm_stderr" "$arm_verdict" \
        "$output_directory/$arm_label.raw"
    if [ -n "$arm_swap_digest" ]; then
        set -- --swap-sha256 "$arm_swap_digest" "$@"
    fi
    if python3 "$script_directory/image-review.py" \
        --router-origin "$router_origin" \
        --artifact-origin "$artifact_origin" \
        --model "$model_id" \
        --sha256 "$artifact_a" \
        --prompt-hash "$prompt_hash" \
        --image-mode "$arm_image_mode" \
        --no-prompt-cache \
        --verdict-json "$arm_verdict" \
        "$@" >"$arm_stdout" 2>"$arm_stderr"
    then
        arm_exit_status=0
    else
        arm_exit_status=$?
    fi
    arm_audit=$(tail -n 1 "$arm_stdout" 2>/dev/null || printf '')
    if [ -z "$arm_audit" ]; then
        arm_audit="image_review model=$model_id artifact=$artifact_a prompt_hash=$prompt_hash constraints=0 image_mode=$arm_image_mode status=refused:no_audit_line"
    fi
    printf '%s %s\n' "$arm_label" "$arm_audit" >>"$audit_log_path"
    arm_status=$(audit_field status "$arm_audit")
    arm_constraints=$(audit_field constraints "$arm_audit")
    arm_failed=$(audit_field failed "$arm_audit")
    arm_uncertain=$(audit_field uncertain "$arm_audit")
    arm_regenerate=$(audit_field regenerate "$arm_audit")
    arm_wall_seconds=$(audit_field wall_seconds "$arm_audit")
    arm_swap_field=$(audit_field swap_sha256 "$arm_audit")
    if [ "$arm_status" = ok ]; then
        arm_passed=$((arm_constraints - arm_failed - arm_uncertain))
    else
        arm_passed=-
        arm_failed=-
        arm_uncertain=-
        arm_regenerate=-
        refused_arms=$((refused_arms + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_label" "$arm_image_mode" "${arm_swap_field:--}" \
        "${arm_status:-unknown}" "${arm_constraints:-0}" "$arm_passed" \
        "$arm_failed" "$arm_uncertain" "$arm_regenerate" "${arm_wall_seconds:--}" \
        "$arm_exit_status" >>"$summary_path"
}

run_arm 01-real real '' "$@"
run_arm 02-withheld withheld '' "$@"
run_arm 03-swapped swapped "$artifact_b" "$@"
run_arm 04-real-closing real '' "$@"

cat "$summary_path"

if [ "$refused_arms" -gt 0 ]; then
    printf 'vision_review_control=incomplete refused_arms=%s\n' "$refused_arms"
    exit 1
fi
printf 'vision_review_control=complete arms=4 output=%s\n' "$output_directory"
