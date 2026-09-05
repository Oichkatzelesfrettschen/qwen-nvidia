#!/bin/sh
set -eu
# gpu-ownership: delegated to the serving session or harness the arms drive.
# Every arm posts to a router and an artifact listener that are already running,
# so the caller holds the owner lock and this runner holds none.
#
# Calibrate one vision reviewer against declared fixtures, so a verdict has a
# measured meaning before it decides anything. scripts/image-review.py bounds
# the reply shape with a grammar and parses a three-way status per constraint;
# what that leaves open is whether pass, fail, and uncertain follow the pixels,
# and six arms per repeat close it:
#
#   correct    artifact A, which meets every declared constraint by its own
#              generator's declaration; the reading is pass on every constraint
#   violating  artifact B under the same constraints, which meets none of them;
#              the reading is fail on at least one constraint
#   withheld   A's request with the image part removed; a pass on every
#              constraint reads the constraint text rather than the pixels
#   swapped    A's request carrying B's bytes; a pass on every constraint
#              follows the text, a fail follows the pixels
#   absent     a digest no artifact holds; the review refuses at the read,
#              which proves the artifact identity is checked ahead of the model
#   closing    artifact A again, so a drift across the repeat is visible
#
# Every arm sends --no-prompt-cache and every binding the caller states, so
# each verdict record is joined to the reviewer's projector and tuple. A
# malformed reply refuses with its code and is counted rather than retried:
# how often a reviewer leaves the schema is part of what is calibrated.
# The exit status reports whether the arms ran, and the readings report what
# the reviewer did; a reviewer that fails calibration is a finding rather than
# a runner error.

usage() {
    printf 'usage: %s ROUTER_ORIGIN ARTIFACT_ORIGIN MODEL SHA256_A SHA256_B SHA256_ABSENT PROMPT_HASH OUTPUT_DIR [--repeat N] [--binding KEY=VALUE]... --constraint NAME=DESCRIPTION...\n' "$0" >&2
    exit 2
}
[ "$#" -ge 9 ] || usage
router_origin=$1
artifact_origin=$2
model_id=$3
artifact_a=$4
artifact_b=$5
artifact_absent=$6
prompt_hash=$7
output_directory=$8
shift 8
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repeat_count=1
constraint_count=0
set -- "$@"
review_arguments=""
# collected as one string, since POSIX sh carries one array and the arm loop
# needs the arguments repeatedly; values hold no whitespace by the review
# module's own rule, and a constraint description may, so descriptions are
# stored quoted and re-read through eval
expecting=""
for argument in "$@"; do
    if [ -n "$expecting" ]; then
        case $expecting in
            repeat) repeat_count=$argument ;;
            binding) review_arguments="$review_arguments --binding '$argument'" ;;
            constraint)
                constraint_count=$((constraint_count + 1))
                escaped=$(printf '%s' "$argument" | sed "s/'/'\\\\''/g")
                review_arguments="$review_arguments --constraint '$escaped'" ;;
        esac
        expecting=""
        continue
    fi
    case $argument in
        --repeat) expecting=repeat ;;
        --binding) expecting=binding ;;
        --constraint) expecting=constraint ;;
        *) usage ;;
    esac
done
[ -z "$expecting" ] || usage
[ "$constraint_count" -ge 1 ] || usage
case $repeat_count in ''|*[!0-9]*|0) usage ;; esac
for digest in "$artifact_a" "$artifact_b" "$artifact_absent" "$prompt_hash"; do
    printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$' || usage
done
[ "$artifact_a" != "$artifact_b" ] || usage

mkdir -p "$output_directory"
summary_path=$output_directory/summary.tsv
audit_log_path=$output_directory/audit.log
printf 'repeat\tarm\tartifact\timage_mode\tstatus\tconstraints\tpassed\tfailed\tuncertain\tregenerate\treading\twall_seconds\texit_status\n' >"$summary_path"
: >"$audit_log_path"
transport_failures=0
malformed_replies=0

audit_field() {
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}

# run_arm REPEAT LABEL ARTIFACT IMAGE_MODE SWAP EXPECT
run_arm() {
    arm_repeat=$1
    arm_label=$2
    arm_artifact=$3
    arm_image_mode=$4
    arm_swap=$5
    arm_expect=$6
    arm_name=$arm_repeat-$arm_label
    arm_stdout=$output_directory/$arm_name.stdout
    arm_stderr=$output_directory/$arm_name.stderr
    arm_verdict=$output_directory/$arm_name.verdict.json
    rm -f "$arm_stdout" "$arm_stderr" "$arm_verdict" "$output_directory/$arm_name.raw"
    swap_argument=""
    [ -z "$arm_swap" ] || swap_argument="--swap-sha256 $arm_swap"
    # shellcheck disable=SC2086
    if eval python3 "$script_directory/image-review.py" \
        --router-origin "$router_origin" --artifact-origin "$artifact_origin" \
        --model "$model_id" --sha256 "$arm_artifact" --prompt-hash "$prompt_hash" \
        --image-mode "$arm_image_mode" $swap_argument --no-prompt-cache \
        --verdict-json "$arm_verdict" $review_arguments >"$arm_stdout" 2>"$arm_stderr"
    then
        arm_exit=0
    else
        arm_exit=$?
    fi
    arm_audit=$(tail -n 1 "$arm_stdout" 2>/dev/null || printf '')
    [ -n "$arm_audit" ] || arm_audit="image_review model=$model_id artifact=$arm_artifact status=refused:no_audit_line"
    printf '%s %s\n' "$arm_name" "$arm_audit" >>"$audit_log_path"
    arm_status=$(audit_field status "$arm_audit")
    arm_constraints=$(audit_field constraints "$arm_audit")
    arm_failed=$(audit_field failed "$arm_audit")
    arm_uncertain=$(audit_field uncertain "$arm_audit")
    arm_regenerate=$(audit_field regenerate "$arm_audit")
    arm_wall=$(audit_field wall_seconds "$arm_audit")
    arm_passed=-
    if [ "$arm_status" = ok ]; then
        arm_passed=$((arm_constraints - arm_failed - arm_uncertain))
    else
        arm_failed=-
        arm_uncertain=-
        arm_regenerate=-
    fi
    # the reading joins what the arm expected to what the reviewer stated
    reading=unexpected
    case $arm_expect in
        pass_all)
            if [ "$arm_status" = ok ]; then
                if [ "$arm_failed" -eq 0 ] && [ "$arm_uncertain" -eq 0 ]; then reading=grounded_pass
                elif [ "$arm_failed" -gt 0 ]; then reading=false_fail
                else reading=uncertain; fi
            fi ;;
        fail_any)
            if [ "$arm_status" = ok ]; then
                if [ "$arm_failed" -gt 0 ]; then reading=discriminated
                elif [ "$arm_uncertain" -gt 0 ]; then reading=uncertain
                else reading=false_pass; fi
            fi ;;
        withheld)
            if [ "$arm_status" = ok ]; then
                if [ "$arm_failed" -eq 0 ] && [ "$arm_uncertain" -eq 0 ]; then reading=ungrounded_pass
                else reading=withheld_declined; fi
            fi ;;
        swapped)
            if [ "$arm_status" = ok ]; then
                if [ "$arm_failed" -gt 0 ]; then reading=follows_pixels
                elif [ "$arm_uncertain" -gt 0 ]; then reading=uncertain
                else reading=follows_text; fi
            fi ;;
        refused_read)
            case $arm_status in
                refused:artifact_http_error) reading=refused_as_expected ;;
                ok) reading=absent_artifact_reviewed ;;
            esac ;;
    esac
    case $arm_status in
        ok) ;;
        refused:artifact_http_error) [ "$arm_expect" = refused_read ] || transport_failures=$((transport_failures + 1)) ;;
        refused:not_json|refused:not_json_object|refused:missing_keys|refused:extra_keys|refused:constraint_*|refused:status_not_enum|refused:*_not_bool|refused:*_not_string|refused:*_too_long|refused:empty_content|refused:tool_calls_present)
            malformed_replies=$((malformed_replies + 1)) ;;
        *) transport_failures=$((transport_failures + 1)) ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_repeat" "$arm_label" "$arm_artifact" "$arm_image_mode" "${arm_status:-unknown}" \
        "${arm_constraints:-0}" "$arm_passed" "$arm_failed" "$arm_uncertain" "$arm_regenerate" \
        "$reading" "${arm_wall:--}" "$arm_exit" >>"$summary_path"
}

repeat=1
while [ "$repeat" -le "$repeat_count" ]; do
    run_arm "$repeat" 01-correct "$artifact_a" real '' pass_all
    run_arm "$repeat" 02-violating "$artifact_b" real '' fail_any
    run_arm "$repeat" 03-withheld "$artifact_a" withheld '' withheld
    run_arm "$repeat" 04-swapped "$artifact_a" swapped "$artifact_b" swapped
    run_arm "$repeat" 05-absent "$artifact_absent" real '' refused_read
    run_arm "$repeat" 06-correct-closing "$artifact_a" real '' pass_all
    repeat=$((repeat + 1))
done

cat "$summary_path"
count_reading() { awk -F '\t' -v arm="$1" -v reading="$2" 'NR > 1 && $2 == arm && $11 == reading { n++ } END { print n + 0 }' "$summary_path"; }
grounded=$(count_reading 01-correct grounded_pass)
closing=$(count_reading 06-correct-closing grounded_pass)
discriminated=$(count_reading 02-violating discriminated)
ungrounded=$(count_reading 03-withheld ungrounded_pass)
follows_text=$(count_reading 04-swapped follows_text)
refused_reads=$(count_reading 05-absent refused_as_expected)
printf 'vision_review_calibration=%s repeats=%s grounded_pass=%s/%s closing_pass=%s/%s discriminated=%s/%s ungrounded_pass=%s/%s follows_text=%s/%s refused_reads=%s/%s malformed_replies=%s transport_failures=%s output=%s\n' \
    "$([ "$transport_failures" -eq 0 ] && printf complete || printf incomplete)" "$repeat_count" \
    "$grounded" "$repeat_count" "$closing" "$repeat_count" "$discriminated" "$repeat_count" \
    "$ungrounded" "$repeat_count" "$follows_text" "$repeat_count" "$refused_reads" "$repeat_count" \
    "$malformed_replies" "$transport_failures" "$output_directory"
[ "$transport_failures" -eq 0 ]
