#!/bin/sh
set -eu

# gpu-ownership: delegated to the serving session the roster drives.
# The roster grades an appliance that is already serving and launches no device
# work of its own, so the session holds the owner lock and a claim here would
# refuse the appliance the run requires.

# Grade every servable checkpoint against scripts/quality-suite.tsv through one
# router listener, so a row's grade differs by the checkpoint alone.
#
# The arms run model-major rather than row-major because the router holds one
# child at a time: row-major would evict and reload on every request and pay a
# cold first token 55 times per checkpoint, where model-major pays one load per
# checkpoint. What that ordering costs is rate comparability -- the first and
# last arms are hours apart, and this tree reads a rate within a sweep -- so the
# per-row decode figures the suite records are incidental to the grade and rate
# comparisons belong to the bandwidth ladder.
#
# Each arm asserts that the id the router answered with is the id the arm asked
# for. The requested value and the applied value have diverged silently in this
# tree before, and a loop variable cannot detect it where the response can.

if [ "$#" -gt 1 ]; then
    printf 'usage: %s [OUTPUT_DIRECTORY]\n' "$0" >&2
    printf 'environment: QWEN_QUALITY_CATEGORIES QWEN_QUALITY_MAX_TOKENS\n' >&2
    printf '             QWEN_QUALITY_THINKING QWEN_QUALITY_LONG_CONTEXT_CHARACTERS\n' >&2
    printf '             QWEN_QUALITY_MODELS QWEN_QUALITY_SUITE QWEN_SERVER_PORT\n' >&2
    printf '             QWEN_QUALITY_OMIT_IMAGES\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output_directory=${1:-"${HOME:?}/qwen-quality-roster"}
endpoint=http://127.0.0.1:${QWEN_SERVER_PORT:-8080}
suite_runner=$script_directory/run-quality-suite.py
registry_script=$script_directory/model-registry.sh
categories=${QWEN_QUALITY_CATEGORIES:-}
max_tokens=${QWEN_QUALITY_MAX_TOKENS:-1024}
thinking=${QWEN_QUALITY_THINKING:-off}
long_context_characters=${QWEN_QUALITY_LONG_CONTEXT_CHARACTERS:-24000}
suite_path=${QWEN_QUALITY_SUITE:-$script_directory/quality-suite.tsv}
# The vision control arm. Withholding the image from rows that name one turns
# the same suite into the measurement of what the prompt alone answers, so the
# control differs from its arm in the image and in nothing else.
omit_images=${QWEN_QUALITY_OMIT_IMAGES:-0}

case $max_tokens in
    '' | *[!0-9]* | 0)
        printf 'token budget must be a positive integer: %s\n' "$max_tokens" >&2
        exit 2
        ;;
esac

case $omit_images in
    0 | 1) ;;
    *)
        printf 'image omission must be 0 or 1: %s\n' "$omit_images" >&2
        exit 2
        ;;
esac

case $thinking in
    on | off) ;;
    *)
        printf 'thinking must be on or off: %s\n' "$thinking" >&2
        exit 2
        ;;
esac

if [ ! -x "$suite_runner" ]; then
    printf 'quality suite runner is absent: %s\n' "$suite_runner" >&2
    exit 1
fi

if [ ! -r "$suite_path" ]; then
    printf 'quality suite is unreadable: %s\n' "$suite_path" >&2
    exit 1
fi

model_ids=${QWEN_QUALITY_MODELS:-$("$registry_script" servable-ids)}
if [ -z "$model_ids" ]; then
    printf 'the registry lists no servable rows\n' >&2
    exit 1
fi

# The endpoint decides what can be graded, so a checkpoint the registry admits
# and the listener does not hold is named before any arm spends device time.
served_listing=$(curl -s --max-time 30 "$endpoint/v1/models") || {
    printf 'the endpoint is unreachable: %s\n' "$endpoint" >&2
    exit 1
}
served_ids=$(printf '%s' "$served_listing" | python3 -c '
import json
import sys

document = json.load(sys.stdin)
for entry in document.get("data", []):
    print(entry.get("id", ""))
')

for model_id in $model_ids; do
    if ! printf '%s\n' "$served_ids" | grep -qx "$model_id"; then
        printf 'the listener does not hold registry row %s\n' "$model_id" >&2
        printf 'regenerate the preset file and relaunch before grading\n' >&2
        exit 1
    fi
done

mkdir -p "$output_directory"
summary_tsv=$output_directory/summary.tsv
printf 'model_id\trows\tpassed\tcompletion_rate\tempty_rate\ttruncated_rate\tcorrect_on_completed\treasoning_words\twall_seconds\n' \
    >"$summary_tsv"

failed_arms=0
for model_id in $model_ids; do
    arm_json=$output_directory/$model_id.json
    arm_log=$output_directory/$model_id.log
    printf 'arm=%s thinking=%s max_tokens=%s\n' "$model_id" "$thinking" "$max_tokens"

    set -- "$endpoint" "$arm_json" --model "$model_id" --suite "$suite_path" \
        --thinking "$thinking" --max-tokens "$max_tokens" \
        --long-context-characters "$long_context_characters"
    if [ -n "$categories" ]; then
        set -- "$@" --categories "$categories"
    fi
    if [ "$omit_images" = 1 ]; then
        set -- "$@" --omit-images
    fi

    if "$suite_runner" "$@" >"$arm_log" 2>&1; then
        arm_status=completed
    else
        arm_status=failed
        failed_arms=$((failed_arms + 1))
    fi
    tail -12 "$arm_log"

    # The served id is read back from the retained record rather than from the
    # arm's own stdout, so the assertion holds over the artifact a reader keeps.
    python3 - "$arm_json" "$model_id" "$summary_tsv" <<'PYTHON'
import json
import sys

arm_path, requested_id, summary_path = sys.argv[1:4]
with open(arm_path) as handle:
    document = json.load(handle)
summary = document["summary"]
served = summary.get("served_models") or []
if served != [requested_id]:
    print(f"served id disagrees with the arm: requested {requested_id}, "
          f"served {served or 'none'}", file=sys.stderr)
    raise SystemExit(1)

correct = summary.get("correct_on_completed")
with open(summary_path, "a") as handle:
    handle.write("\t".join([
        requested_id,
        str(summary["rows"]),
        str(summary["passed"]),
        f"{summary['completion_rate']:.3f}",
        f"{summary['empty_answer_rate']:.3f}",
        f"{summary['truncated_rate']:.3f}",
        "-" if correct is None else f"{correct:.3f}",
        str(summary["reasoning_words_total"]),
        f"{summary['wall_seconds_total']:.1f}",
    ]) + "\n")
PYTHON

    printf 'arm=%s status=%s record=%s\n\n' "$model_id" "$arm_status" "$arm_json"
done

printf '\n'
cat "$summary_tsv"
printf 'quality_roster=%s arms=%s failed=%s output=%s\n' \
    "$([ "$failed_arms" -eq 0 ] && printf completed || printf failed)" \
    "$(printf '%s\n' "$model_ids" | wc -l | tr -d ' ')" \
    "$failed_arms" "$output_directory"
[ "$failed_arms" -eq 0 ]
