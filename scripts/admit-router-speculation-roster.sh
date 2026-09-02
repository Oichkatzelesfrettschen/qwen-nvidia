#!/bin/sh
# Drive every servable row of a running router once and read back what the
# registry claimed about it.
#
# Speculation is a per-section setting, so the claim that reaches the device is
# the child's own argv rather than the registry field or the generated preset.
# The router spawns each child with the section's keys, and `/proc/PID/cmdline`
# is where a `--spec-type` that was emitted but overwritten would show its
# absence: server-models.cpp ends preset assembly with `preset.merge(base_preset)`
# and common_preset::merge overwrites, which is the mechanism a global setting
# used to reach every child through.
#
# The prediction block is read from the load rather than from occupancy. An
# ordinary load reports each of its tensors as `model has unused tensor ... --
# ignoring` and an MTP load reports none, and the 2B's block is 37,767,168 bytes,
# which is inside what the compositor moves between arms.
#
# Occupancy is sampled while the switch runs, and what it reports is framebuffer
# occupancy at the sampler's interval. nvidia-smi reads the framebuffer counter
# alone: it misses a spike shorter than its interval and counts none of the
# driver-managed system memory that
# evidence/quarantine/qwen38-9b-distill-router-load.md records the refusal in.
# The figure bounds the settled pair rather than naming the switch peak.
set -eu

# gpu-ownership: held by the router this harness reads.
# The roster drives a router that is already serving and launches nothing. That
# router holds the campaign lock through run-qwen-capacity-server.sh, so a claim
# taken here would refuse against the exact appliance the run requires.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
    printf '  QWEN_ADMISSION_ORIGIN   router origin, default http://127.0.0.1:8080\n' >&2
    printf '  QWEN_ADMISSION_TIMEOUT  seconds per reply, default 240\n' >&2
    printf '  QWEN_ADMISSION_INTERVAL occupancy sample interval, default 0.2\n' >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
output_directory=$1

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_reader=$script_directory/model-registry.sh
latch=$script_directory/gpu-state-latch.sh
registry=${QWEN_MODEL_REGISTRY:-$script_directory/models.tsv}
speculation_profiles=${QWEN_SPECULATION_PROFILES:-$script_directory/speculation-profiles.tsv}
origin=${QWEN_ADMISSION_ORIGIN:-http://127.0.0.1:8080}
reply_timeout=${QWEN_ADMISSION_TIMEOUT:-240}
sample_interval=${QWEN_ADMISSION_INTERVAL:-0.2}
state_directory=${QWEN_WEBUI_STATE_DIRECTORY:-"${HOME:?}/qwen-webui-state"}
server_log=$state_directory/server.log
nvidia_smi=${QWEN_NVIDIA_SMI:-nvidia-smi}

mkdir -p "$output_directory"
summary=$output_directory/summary.tsv
checks=$output_directory/checks.tsv
failures=0

report() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:--}" >>"$checks"
    printf '%s=%s%s\n' "$1" "$2" "${3:+ $3}"
    [ "$2" = accepted ] || failures=$((failures + 1))
}
printf 'check\tstatus\tdetail\n' >"$checks"

curl -sf -m 10 "$origin/health" >/dev/null 2>&1 ||
    { printf 'the router does not answer %s/health\n' "$origin" >&2; exit 1; }

# The occupancy sampler runs for the whole admission beside the arms, because a
# per-arm reading taken after /health answered is a settled figure and the
# switch is what this run is about.
occupancy_log=$output_directory/occupancy.tsv
printf 'utc\tfb_used_mib\tbar1_used_mib\n' >"$occupancy_log"
(
    while :; do
        fb=$("$nvidia_smi" --query-gpu=memory.used --format=csv,noheader,nounits \
            2>/dev/null | head -1 || printf '-')
        bar1=$("$nvidia_smi" -q -d MEMORY 2>/dev/null |
            awk '/BAR1 Memory Usage/ { inside = 1; next }
                 inside && /Used/ { print $3; exit }' || printf '-')
        printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$fb" "$bar1" \
            >>"$occupancy_log"
        sleep "$sample_interval"
    done
) &
sampler_pid=$!
trap 'kill "$sampler_pid" 2>/dev/null || :' EXIT INT TERM

server_log_start=0
[ -r "$server_log" ] && server_log_start=$(wc -l <"$server_log")

roster=$(curl -sf -m 10 "$origin/v1/models" |
    python3 -c 'import sys, json; print("\n".join(row["id"] for row in json.load(sys.stdin)["data"]))')
roster_count=$(printf '%s\n' "$roster" | grep -c . || :)

servable=$("$registry_reader" servable-ids | sort)
roster_sorted=$(printf '%s\n' "$roster" | sort)
missing_from_roster=$(printf '%s\n' "$servable" |
    while read -r candidate; do
        [ -n "$candidate" ] || continue
        printf '%s\n' "$roster_sorted" | grep -qx "$candidate" || printf '%s ' "$candidate"
    done)
# A servable id absent from the roster is an artifact this host has not fetched
# rather than a refused row, so it is reported rather than failed; an id in the
# roster that the registry does not call servable is the failure.
foreign_in_roster=$(printf '%s\n' "$roster_sorted" |
    while read -r candidate; do
        [ -n "$candidate" ] || continue
        printf '%s\n' "$servable" | grep -qx "$candidate" || printf '%s ' "$candidate"
    done)
if [ -z "$foreign_in_roster" ]; then
    report roster_matches_registry accepted "rows=$roster_count unfetched=${missing_from_roster:-none}"
else
    report roster_matches_registry rejected "foreign=$foreign_in_roster"
fi

printf 'model_id\tspeculation_profile\texpected_spec\tchild_spec\tunused_tensor_lines\tfinish\treply\n' \
    >"$summary"

answered=0
spec_flag_failures=0
prediction_block_failures=0
for model_id in $roster; do
    [ -n "$model_id" ] || continue
    expected_profile=$("$registry_reader" id "$model_id" speculation_profile 2>/dev/null || printf off)
    expected_spec=$(awk -F'\t' -v id="$expected_profile" \
        '!/^#/ && $1 == id { print $2 }' "$speculation_profiles")
    [ -n "$expected_spec" ] || expected_spec=none

    log_before=0
    [ -r "$server_log" ] && log_before=$(wc -l <"$server_log")

    arm_directory=$output_directory/$model_id
    mkdir -p "$arm_directory"
    printf '{"model":"%s","messages":[{"role":"user","content":"What is the capital of Norway? Answer with one word."}],"max_tokens":512,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' \
        "$model_id" >"$arm_directory/request.json"
    curl -sf -m "$reply_timeout" "$origin/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d @"$arm_directory/request.json" >"$arm_directory/response.json" 2>&1 || :

    parsed=$(python3 - "$arm_directory/response.json" <<'PARSE'
import json, sys
try:
    document = json.load(open(sys.argv[1]))
    choice = document["choices"][0]
    reply = (choice["message"].get("content") or "").strip().replace("\t", " ")
    print("\t".join([document.get("model", "-"),
                     choice.get("finish_reason", "-"),
                     reply[:80] or "-"]))
except Exception as error:
    print("\t".join(["-", "-", "unparsed:%s" % type(error).__name__]))
PARSE
)
    served_model=$(printf '%s' "$parsed" | cut -f1)
    finish_reason=$(printf '%s' "$parsed" | cut -f2)
    reply_text=$(printf '%s' "$parsed" | cut -f3)

    # The child that ran the request is the llama-server whose argv names this
    # alias, which is where an overwritten section setting shows its absence.
    child_spec=none
    for candidate_pid in $(pgrep -x llama-server 2>/dev/null || :); do
        candidate_argv=$(tr '\0' ' ' <"/proc/$candidate_pid/cmdline" 2>/dev/null || :)
        case $candidate_argv in
            *"--alias $model_id "*)
                case $candidate_argv in
                    *'--spec-type '*)
                        child_spec=$(printf '%s' "$candidate_argv" |
                            sed 's/.*--spec-type \([^ ]*\).*/\1/')
                        ;;
                esac
                ;;
        esac
    done

    log_after=0
    [ -r "$server_log" ] && log_after=$(wc -l <"$server_log")
    unused_lines=0
    if [ "$log_after" -gt "$log_before" ]; then
        unused_lines=$(tail -n "$((log_after - log_before))" "$server_log" |
            grep -c 'model has unused tensor' || :)
    fi

    if [ "$served_model" = "$model_id" ] && [ "$reply_text" != '-' ] &&
        [ "$finish_reason" = stop ]; then
        answered=$((answered + 1))
    fi
    if [ "$child_spec" != "$expected_spec" ] &&
        ! { [ "$expected_spec" = none ] && [ "$child_spec" = none ]; }; then
        spec_flag_failures=$((spec_flag_failures + 1))
    fi
    if [ "$expected_spec" != none ] && [ "$unused_lines" -ne 0 ]; then
        prediction_block_failures=$((prediction_block_failures + 1))
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$model_id" "$expected_profile" "$expected_spec" "$child_spec" \
        "$unused_lines" "$finish_reason" "$reply_text" >>"$summary"
done

if [ "$answered" -eq "$roster_count" ]; then
    report every_row_answers accepted "$answered/$roster_count"
else
    report every_row_answers rejected "$answered/$roster_count"
fi

if [ "$spec_flag_failures" -eq 0 ]; then
    report child_argv_matches_profile accepted
else
    report child_argv_matches_profile rejected "rows=$spec_flag_failures"
fi

if [ "$prediction_block_failures" -eq 0 ]; then
    report prediction_block_loaded accepted "no unused-tensor line on a speculating row"
else
    report prediction_block_loaded rejected "rows=$prediction_block_failures"
fi

placement_rows=0
foreign_placement=0
for candidate_pid in $(pgrep -x llama-server 2>/dev/null || :); do
    candidate_argv=$(tr '\0' ' ' <"/proc/$candidate_pid/cmdline" 2>/dev/null || :)
    case $candidate_argv in
        *'--alias '*)
            placement_rows=$((placement_rows + 1))
            case $candidate_argv in
                *'--override-tensor .*=CUDA0'*'--device CUDA0'* | \
                *'--device CUDA0'*'--override-tensor .*=CUDA0'*) ;;
                *) foreign_placement=$((foreign_placement + 1)) ;;
            esac
            ;;
    esac
done
if [ "$foreign_placement" -eq 0 ]; then
    report child_placement_cuda0 accepted "children=$placement_rows"
else
    report child_placement_cuda0 rejected "children=$foreign_placement"
fi

peak_fb=$(awk -F'\t' 'NR > 1 && $2 ~ /^[0-9]+$/ && $2 + 0 > peak { peak = $2 } END { print peak + 0 }' \
    "$occupancy_log")
peak_bar1=$(awk -F'\t' 'NR > 1 && $3 ~ /^[0-9]+$/ && $3 + 0 > peak { peak = $3 } END { print peak + 0 }' \
    "$occupancy_log")
carve_out=$("$nvidia_smi" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
samples=$(($(wc -l <"$occupancy_log") - 1))
if [ "$peak_fb" -lt "$carve_out" ]; then
    report occupancy_inside_carve_out accepted \
        "observed_fb_peak=${peak_fb}MiB bar1_peak=${peak_bar1}MiB total=${carve_out}MiB samples=$samples interval=${sample_interval}s"
else
    report occupancy_inside_carve_out rejected "observed_fb_peak=${peak_fb}MiB"
fi

new_log_lines=0
[ -r "$server_log" ] && new_log_lines=$(($(wc -l <"$server_log") - server_log_start))
hazard_lines=0
if [ "$new_log_lines" -gt 0 ]; then
    hazard_lines=$(tail -n "$new_log_lines" "$server_log" |
        grep -ciE 'CUDA error|out of memory|device-side assert' || :)
fi
if [ "$hazard_lines" -eq 0 ]; then
    report server_log_clean accepted "lines=$new_log_lines"
else
    report server_log_clean rejected "hazards=$hazard_lines"
fi

if "$latch" require-clear >/dev/null 2>&1; then
    report latch_clear_after accepted
else
    report latch_clear_after rejected "the run set the GPU state latch"
fi

# The mutation fixture. A registry that claims a speculation profile on a row
# whose prediction block the GGUF does not declare has to be refused at
# generation rather than emitted and discovered by a child that fails to load.
mutation_directory=$output_directory/mutation
mkdir -p "$mutation_directory"
mutation_registry=$mutation_directory/models.tsv
awk -F'\t' -v OFS='\t' '
    /^#/ { print; next }
    NF < 26 { print; next }
    !mutated && $23 == "0" && $24 == "off" {
        $24 = "mtp1"; $25 = "capability-only"; mutated = 1
    }
    { print }
' "$registry" >"$mutation_registry"
mutated_row=$(awk -F'\t' '!/^#/ && NF >= 26 && $23 == "0" && $24 == "mtp1" { print $1; exit }' \
    "$mutation_registry")
if QWEN_MODEL_REGISTRY=$mutation_registry \
    "$script_directory/build-router-presets.sh" "$mutation_directory/presets.ini" \
    >"$mutation_directory/stdout" 2>"$mutation_directory/stderr"; then
    report mutation_refused rejected "the generator emitted a preset for $mutated_row"
elif grep -q 'carries mtp_layers=0' "$mutation_directory/stderr"; then
    report mutation_refused accepted "row=$mutated_row"
else
    report mutation_refused rejected "refused for another reason"
fi

kill "$sampler_pid" 2>/dev/null || :
trap - EXIT INT TERM

printf 'admission=%s checks=%s failures=%s summary=%s\n' \
    "$([ "$failures" -eq 0 ] && printf accepted || printf rejected)" \
    "$(($(wc -l <"$checks") - 1))" "$failures" "$summary"
[ "$failures" -eq 0 ]
