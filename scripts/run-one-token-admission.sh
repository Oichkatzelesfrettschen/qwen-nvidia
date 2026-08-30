#!/bin/sh
set -eu

# Load every static-admitted candidate once and require it to produce a token.
#
# Static admission reads what a file declares. It cannot show that the artifact
# parses completely, that its tensor types have kernels in this build, that the
# graph constructs, that the device holds it, or that a token comes out. A
# runtime class establishes a shared throughput expectation and nothing about a
# particular artifact, so every row runs rather than one representative per
# class.
#
# scripts/test-strict-vulkan-placement.sh is the admission itself: it requires
# CPU tensor placement and CPU graph placement to be rejected, brings a strict
# Vulkan server up, drives a two-token completion, and requires the model, KV,
# and compute buffers to name Vulkan0 with no CPU fallback reached. A control
# arm runs the same check against a checkpoint this tree already serves, after
# each new runtime class and after any failure, so a later refusal is read
# against a device that was working rather than against an unknown one.
#
# The load is text-only. A projector is a separate artifact that encodes images
# into one checkpoint's embedding space, so admitting it is a separate arm, and
# a row that loads and decodes without one is admitted for text rather than
# refused for vision. Those rows stay in the ledger as throughput and quality
# subjects; `projector` in the summary states whether the vision path was
# exercised, and `not-run` is what every row reads until that arm exists.
#
# The device is exclusive for the duration. The appliance listener holds the
# GPU, so it comes down before this runs and back up after.

renice -n 19 -p $$ >/dev/null 2>&1 || true
ionice -c 3 -p $$ >/dev/null 2>&1 || true

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'usage: %s STATIC_ADMISSION_TSV [OUTPUT_DIRECTORY]\n' "$0" >&2
    printf 'environment: QWEN_LLAMA_SERVER QWEN_CANDIDATE_ROOT QWEN_CONTROL_MODEL\n' >&2
    printf '             QWEN_ADMISSION_STAGES QWEN_ADMISSION_ROWS\n' >&2
    printf '             QWEN_PLACEMENT_CHECK QWEN_CANDIDATE_FETCH QWEN_CANDIDATE_LEDGER\n' >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
record=$1
output_directory=${2:-"${HOME:?}/qwen-webui-state/one-token-admission"}
llama_server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-server"}
# Staged artifacts sit beside the tier tree rather than inside it.
# build-router-presets.sh owns $QWEN_MODEL_ROOT/candidates as the candidate tier
# link directory and exits 1 on any real entry it finds there, so a fetch
# staged into that path stops the picker from being regenerated at all.
candidate_root=${QWEN_CANDIDATE_ROOT:-"${HOME:?}/models/candidate-staging"}
control_model=${QWEN_CONTROL_MODEL:-"${HOME:?}/models/Qwen3.8-2B-Distill-GGUF/Qwen3.8-2B-Q4_K_M.gguf"}
placement=${QWEN_PLACEMENT_CHECK:-$script_directory/test-strict-vulkan-placement.sh}
fetch=${QWEN_CANDIDATE_FETCH:-$script_directory/fetch-candidate-artifact.sh}
# `fetch` alone downloads without touching the device, which is what lets the
# transfers run while the appliance is still serving.
stages=${QWEN_ADMISSION_STAGES:-fetch,load}
selected_rows=${QWEN_ADMISSION_ROWS:-}
candidate_ledger=${QWEN_CANDIDATE_LEDGER:-$script_directory/../evidence/model-admission/candidate-ledger.tsv}

for required in "$record" "$candidate_ledger"; do
    [ -r "$required" ] || { printf 'unreadable: %s\n' "$required" >&2; exit 2; }
done
for required in "$placement" "$fetch"; do
    [ -x "$required" ] || {
        printf 'admission helper is not executable: %s\n' "$required" >&2
        exit 2
    }
done
case $stages in
    *load*)
        [ -x "$llama_server" ] || {
            printf 'llama-server is not executable: %s\n' "$llama_server" >&2
            exit 2
        }
        [ -f "$control_model" ] || {
            printf 'control model is absent: %s\n' "$control_model" >&2
            exit 2
        }
        ;;
esac

mkdir -p "$output_directory"
summary=$output_directory/admission-summary.tsv
ledger_scope=$output_directory/candidate-ledger-scope.txt
python3 - "$candidate_ledger" >"$ledger_scope" <<'PYTHON'
import csv
import sys

with open(sys.argv[1], encoding="utf-8", newline="") as handle:
    rows = (line for line in handle if not line.startswith("#") and line.strip())
    reader = csv.DictReader(rows, delimiter="\t")
    required = {"candidate_id", "admission_stage"}
    if reader.fieldnames is None or not required.issubset(reader.fieldnames):
        raise SystemExit("candidate ledger lacks candidate_id or admission_stage")
    seen = set()
    for row in reader:
        if None in row or any(value is None for value in row.values()):
            raise SystemExit("candidate ledger carries a malformed row")
        candidate_id = row["candidate_id"]
        if not candidate_id or candidate_id in seen:
            raise SystemExit(f"candidate ledger carries an invalid duplicate id: {candidate_id}")
        seen.add(candidate_id)
        if row["admission_stage"] in {"served", "static-admitted"}:
            print(candidate_id)
PYTHON
if [ ! -s "$summary" ]; then
    printf 'candidate_id\tarchitecture\tartifact\tobserved_sha256\tfetch\tload\tprojector\tcontrol\tdetail\n' \
        >"$summary"
fi

run_control() {
    control_reason=$1
    control_log=$output_directory/control-$control_reason.log
    if "$placement" --llama-server "$llama_server" --model "$control_model" \
            >"$control_log" 2>&1; then
        printf 'control=accepted reason=%s\n' "$control_reason"
        control_state=accepted
    else
        printf 'control=rejected reason=%s log=%s\n' "$control_reason" "$control_log" >&2
        control_state=rejected
    fi
}

selected() {
    [ -z "$selected_rows" ] && return 0
    for wanted in $(printf '%s\n' "$selected_rows" | tr ',' ' '); do
        [ "$wanted" = "$1" ] && return 0
    done
    return 1
}

in_ledger_scope() {
    grep -Fx "$1" "$ledger_scope" >/dev/null
}

fetch_digest() {
    printf '%s\n' "$1" |
        sed -n 's/.*observed_sha256=\([0-9a-f][0-9a-f]*\).*/\1/p;
                s/.*verified_sha256=\([0-9a-f][0-9a-f]*\).*/\1/p' |
        sed -n '1p'
}

runtime_class_of() {
    printf '%s\n' "$1" | awk -F/ '
        {
            runtime_class = $1
            for (field_index = 2; field_index <= NF; field_index++) {
                if ($field_index ~ /^(embedding_length|feed_forward_length|attention[.]head_count|attention[.]head_count_kv)=/) {
                    runtime_class = runtime_class "/" $field_index
                }
            }
            print runtime_class
        }
    '
}

artifact_set_of() {
    python3 - "$1" "$2" <<'PYTHON'
import re
import sys

artifact = sys.argv[1]
try:
    shard_count = int(sys.argv[2])
except ValueError:
    raise SystemExit("split_shards is not an integer") from None
if shard_count < 1:
    raise SystemExit("split_shards must be positive")
if shard_count == 1:
    print(artifact)
    raise SystemExit(0)
matched = re.fullmatch(r"(.+)-([0-9]{5})-of-([0-9]{5})([.]gguf)", artifact, re.I)
if matched is None:
    raise SystemExit("split artifact does not carry a canonical shard suffix")
selected_index = int(matched.group(2))
declared_count = int(matched.group(3))
if selected_index != 1 or declared_count != shard_count:
    raise SystemExit(
        f"split artifact selects shard {selected_index} of {declared_count}, "
        f"but the admission row declares {shard_count} shards"
    )
for shard_index in range(1, shard_count + 1):
    print(
        f"{matched.group(1)}-{shard_index:05d}-of-{shard_count:05d}"
        f"{matched.group(4)}"
    )
PYTHON
}

seen_classes=''
control_state=not-run
tab=$(printf '\t')

# The record's first column is the header and `admission` names whether the
# static read parsed, so a row that failed there has nothing to load.
while IFS="$tab" read -r candidate_id repository revision admission architecture \
        _block_count _nextn _vocabulary _pre _template_sha _template_bytes \
        _tokens_sha artifact _artifact_bytes _loaded _skipped _shards \
        _gguf_count _rule _window _thinking _think_block _tools _tool_calls \
        fingerprint; do
    [ "$candidate_id" = "candidate_id" ] && continue
    [ "$admission" = "parsed" ] || continue
    in_ledger_scope "$candidate_id" || continue
    selected "$candidate_id" || continue

    candidate_directory=$candidate_root/$candidate_id
    artifact_path=$candidate_directory/$artifact
    fetch_state=skipped
    load_state=not-run
    projector_state=not-run
    detail='-'
    observed_sha256='-'

    case $stages in
        *fetch*)
            if ! artifact_set=$(artifact_set_of "$artifact" "$_shards" 2>&1); then
                fetch_state=failed
                detail=$(printf '%s' "$artifact_set" | tr '\n' ' ' | cut -c1-160)
            else
                fetch_state=retained
                while IFS= read -r shard_artifact; do
                    if fetch_line=$("$fetch" "$repository" "$revision" \
                            "$shard_artifact" "$candidate_directory" 2>&1); then
                        shard_fetch_state=$(printf '%s' "$fetch_line" |
                            sed -n 's/.*artifact_status=\([a-z]*\).*/\1/p')
                        [ "$shard_fetch_state" != fetched ] || fetch_state=fetched
                        if [ "$shard_artifact" = "$artifact" ]; then
                            observed_sha256=$(fetch_digest "$fetch_line")
                        fi
                    else
                        fetch_state=failed
                        detail=$(printf '%s' "$fetch_line" | tr '\n' ' ' | cut -c1-160)
                        break
                    fi
                done <<EOF
$artifact_set
EOF
            fi
            ;;
    esac

    case $stages in
        *load*)
            if [ "$fetch_state" = failed ]; then
                load_state=not-run
            else
                # A class is a shared throughput expectation, so the control
                # runs when one is met for the first time: a refusal then reads
                # against a device that had just answered.
                class=$(runtime_class_of "$fingerprint")
                case " $seen_classes " in
                    *" $class "*) ;;
                    *)
                        seen_classes="$seen_classes $class"
                        run_control "class-$(printf '%s' "$class" | tr '/' '-')"
                        ;;
                esac
                load_log=$output_directory/$candidate_id.load.log
                if "$placement" --llama-server "$llama_server" \
                        --model "$artifact_path" >"$load_log" 2>&1; then
                    load_state=accepted
                else
                    load_state=rejected
                    detail=$(tail -3 "$load_log" | tr '\n' ' ' | cut -c1-160)
                    run_control "after-$candidate_id"
                fi
            fi
            ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$candidate_id" "$architecture" "$artifact" "$observed_sha256" \
        "$fetch_state" "$load_state" "$projector_state" "$control_state" \
        "$detail" >>"$summary"
    printf 'row=%s fetch=%s load=%s control=%s\n' \
        "$candidate_id" "$fetch_state" "$load_state" "$control_state"
done <"$record"

printf 'one_token_admission=complete summary=%s\n' "$summary"
