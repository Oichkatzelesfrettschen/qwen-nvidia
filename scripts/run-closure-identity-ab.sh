#!/bin/sh
set -eu

# Compare two CUDA closures by the token ids they emit, not by their rates.
#
# A closure pair that differs by one build constant has to answer whether the
# constant changed the model's output before it is allowed to answer whether it
# changed the model's speed. Greedy decoding on this backend is deterministic
# within a fixed request sequence (evidence/quality-roster/), so two closures
# that compute the same values emit the same token ids, and any difference is
# the arithmetic moving. run-graph-alias-ab.sh asks the same question of the
# Vulkan graph optimizer and pins --device Vulkan0 in both of its branches,
# which is why this harness exists beside it rather than inside it.
#
# Three arms run in order: the control, the subject, then the control again.
# The closing control is what licenses reading a subject difference as the
# closure rather than as drift, because a device whose state moved under the
# pair disagrees with its own opening arm. The compute-client set is read
# around every arm and a change between adjacent arms ends the run, since a
# browser that started between two arms is a covariate that moved.
#
# Placement is pinned the way qwen-capacity-policy.sh pins it. Left to --fit,
# llama.cpp decides placement per load from the free VRAM it observes, and the
# desktop moves that figure between two loads on this host, so a drifted
# control reads as divergent and a drifted subject reads as identical.
# LLAMA_NO_CPU_FALLBACK reaches the llama-no-cpu-fallback patch both closures
# carry, so a fallback fails the load rather than serving from the host. The
# placement lines are info logs the server prints only at --log-verbosity 4.

usage() {
    cat >&2 <<'USAGE'
usage: run-closure-identity-ab.sh CONTROL_BUILD SUBJECT_BUILD OUTPUT_DIRECTORY [MODEL_ID...]

Runs control, subject, and control again against one another and reports
whether the two closures emit identical token ids under identical placement.
Naming no MODEL_ID runs qwen38-2b-distill.

  QWEN_IDENTITY_PORT     listener, default 8099
  QWEN_IDENTITY_PREDICT  tokens per request, default 256
  QWEN_IDENTITY_SEED     sampling seed, default 1
  QWEN_IDENTITY_THREADS  host threads, default 1
  QWEN_IDENTITY_PROMPTS  prompt TSV, default the six state-carrying prompts
USAGE
    exit 2
}

[ "$#" -ge 3 ] || usage
control_build=$1
subject_build=$2
output_directory=$3
shift 3
[ "$#" -gt 0 ] || set -- qwen38-2b-distill

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_script=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
server_relative_path=bin/llama-server
server_port=${QWEN_IDENTITY_PORT:-8099}
predict_tokens=${QWEN_IDENTITY_PREDICT:-256}
sampling_seed=${QWEN_IDENTITY_SEED:-1}
thread_count=${QWEN_IDENTITY_THREADS:-1}
readiness_seconds=${QWEN_IDENTITY_READY_SECONDS:-300}
request_seconds=${QWEN_IDENTITY_REQUEST_SECONDS:-1800}
appliance_port=${QWEN_SERVER_PORT:-8080}

for build in "$control_build" "$subject_build"; do
    [ -x "$build/$server_relative_path" ] || {
        printf 'refused: llama-server is absent: %s/%s\n' \
            "$build" "$server_relative_path" >&2
        exit 2
    }
done
case $predict_tokens in '' | *[!0-9]* | 0)
    printf 'refused: predict tokens must be a positive integer: %s\n' \
        "$predict_tokens" >&2; exit 2 ;;
esac

. "$script_directory/gpu-workload-ownership.sh"

umask 077
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
summary_file=$output_directory/summary.tsv
: >"$summary_file"

gpu_ownership_require > "$output_directory/ownership-open.txt" || {
    ownership_status=$?
    cat "$output_directory/ownership-open.txt" >&2
    exit "$ownership_status"
}
cat "$output_directory/ownership-open.txt"

if curl --silent --fail --max-time 2 \
    "http://127.0.0.1:$appliance_port/health" >/dev/null 2>&1; then
    printf 'refused: a server answers /health on port %s; run qwen-teardown.sh first\n' \
        "$appliance_port" >&2
    exit 1
fi

# The kernel ring is read rather than assumed clean. An unreadable ring records
# not_run with its reason, because a hazard nobody looked for is not an absence.
hazard_pattern='ring[^[:cntrl:]]*timeout|GPU reset|VM fault|device loss|device lost|NVRM[^[:cntrl:]]*Xid|GPU has fallen off the bus|RmInitAdapter failed'
read_kernel_ring() {
    ring_label=$1
    # The redirect is performed by this shell into a file it owns, so the
    # privilege sudo grants covers reading the ring alone.
    # shellcheck disable=SC2024
    if dmesg --color=never >"$output_directory/ring-$ring_label.txt" 2>/dev/null; then
        ring_source=direct
    elif sudo -n dmesg --color=never >"$output_directory/ring-$ring_label.txt" 2>/dev/null; then
        ring_source=sudo
    else
        printf 'kernel_ring\t%s\tnot_run\tdmesg unreadable directly and through sudo -n\n' \
            "$ring_label" >>"$summary_file"
        return 0
    fi
    ring_hits=$(grep -Ec "$hazard_pattern" "$output_directory/ring-$ring_label.txt" || :)
    printf 'kernel_ring\t%s\tread\tsource=%s hazard_lines=%s\n' \
        "$ring_label" "$ring_source" "$ring_hits" >>"$summary_file"
}
read_kernel_ring open

prompt_file=${QWEN_IDENTITY_PROMPTS:-"$output_directory/prompts.tsv"}
if [ ! -s "$prompt_file" ]; then
    cat >"$prompt_file" <<'PROMPTS'
accumulator	Start with the number 7. Apply these operations in order and show the running total after every single step: add 13, multiply by 3, subtract 8, divide by 2, add 45, multiply by 4, subtract 111, add 19, multiply by 2, subtract 37, add 88, divide by 5. State the value after each operation on its own line, then give the final value.
stack	Simulate a stack, one operation per line, printing the complete stack contents after every operation: push A, push B, push C, pop, push D, push E, pop, pop, push F, push G, push H, pop, push I, pop, pop, push J. Then report the final stack from bottom to top and the full sequence of popped values in order.
list-transform	Begin with the list [4, 9, 2, 7, 1, 8, 3, 6, 5]. Apply each rule to the result of the previous rule and print the whole list after each rule: double every element, remove every element above 15, append the sum of the current list, sort ascending, subtract the smallest element from every element, reverse the list, append the count of nonzero elements. Show every intermediate list.
variable-trace	Trace this program line by line and print the value of every variable after each line: a = 3; b = a + 4; c = b * 2; a = c - b; d = a + c; b = d - a; c = b + d; a = c - d; d = a * b; b = d - c; c = a + b; a = c * 2; b = a - d. After the trace, give the final values of a, b, c, and d.
state-machine	A machine has states S0, S1, S2, S3 and transitions: on 0 go S0->S1, S1->S2, S2->S3, S3->S0; on 1 go S0->S2, S1->S0, S2->S1, S3->S2. Starting in S0, process the input 0110100111010011 one symbol at a time. Print the state after each symbol, then report the final state and how many times each state was visited.
constraints	Five houses in a row are numbered 1 to 5. Each has one colour from red, blue, green, white, yellow and one occupant from Ana, Ben, Cara, Dan, Eve. Apply these clues one at a time, and after each clue print everything you have established so far: the red house is immediately left of the green house; Ana lives in the blue house; Cara lives in house 1; the yellow house is house 5; Ben lives immediately right of the white house; Dan does not live in house 3; the green house is house 4. Then give the complete assignment.
PROMPTS
fi

request_builder=$output_directory/build-request.py
cat >"$request_builder" <<'PYTHON'
import json
import sys

prompt_path, predict, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(prompt_path, "r", encoding="utf-8") as handle:
    prompt_text = handle.read()
# cache_prompt off makes every request pay its own prefill, so a closure that
# changes the prefill graph is not masked by a reused KV prefix.
json.dump(
    {
        "prompt": prompt_text,
        "n_predict": predict,
        "temperature": 0,
        "top_k": 1,
        "seed": seed,
        "ignore_eos": True,
        "cache_prompt": False,
        "return_tokens": True,
        "stream": False,
    },
    sys.stdout,
)
PYTHON

# The reader refuses an absent, empty, non-integer, or short token array before
# anything is hashed. A run that left return_tokens unset once produced 264
# identical digests that were all sha256 of the empty array, and ignore_eos is
# on here, so an array shorter than n_predict ended for a reason this harness
# has not looked at.
token_reader=$output_directory/read-tokens.py
cat >"$token_reader" <<'PYTHON'
import json
import sys

response_path, expected = sys.argv[1], int(sys.argv[2])
with open(response_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
tokens = payload.get("tokens")
if not isinstance(tokens, list) or not tokens:
    sys.stderr.write("response carries no token array\n")
    raise SystemExit(1)
for token_id in tokens:
    if not isinstance(token_id, int):
        sys.stderr.write("token array holds a non-integer entry\n")
        raise SystemExit(1)
if len(tokens) != expected:
    sys.stderr.write(
        f"token array holds {len(tokens)} of {expected} predicted tokens\n")
    raise SystemExit(1)
for token_id in tokens:
    print(token_id)
PYTHON

server_pid=''
stop_server() {
    [ -n "$server_pid" ] || return 0
    kill "$server_pid" 2>/dev/null || true
    wait_iteration=0
    while [ "$wait_iteration" -lt 60 ] && kill -0 "$server_pid" 2>/dev/null; do
        wait_iteration=$((wait_iteration + 1))
        sleep 1
    done
    kill -9 "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''
}
trap 'stop_server' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

registry_field() {
    "$registry_script" id "$1" "$2"
}

start_server() {
    arm_build=$1
    arm_model_path=$2
    arm_context=$3
    arm_batch=$4
    arm_ubatch=$5
    arm_cache_k=$6
    arm_cache_v=$7
    arm_flash_attention=$8
    arm_log=$9

    LLAMA_NO_CPU_FALLBACK=1 \
        "$arm_build/$server_relative_path" \
        --model "$arm_model_path" \
        --host 127.0.0.1 \
        --port "$server_port" \
        --ctx-size "$arm_context" \
        --batch-size "$arm_batch" \
        --ubatch-size "$arm_ubatch" \
        --cache-type-k "$arm_cache_k" \
        --cache-type-v "$arm_cache_v" \
        --flash-attn "$arm_flash_attention" \
        --device CUDA0 \
        --split-mode none \
        --override-tensor '.*=CUDA0' \
        --fit off \
        --n-gpu-layers all \
        --parallel 1 \
        --threads "$thread_count" \
        --threads-batch "$thread_count" \
        --no-context-shift \
        --offline \
        --log-verbosity 4 \
        >"$arm_log" 2>&1 9>&- &
    server_pid=$!

    ready_iteration=0
    while [ "$ready_iteration" -lt "$readiness_seconds" ]; do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            printf 'refused: llama-server exited before readiness; see %s\n' \
                "$arm_log" >&2
            return 1
        fi
        if curl --silent --fail --max-time 2 \
            "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            for placement_line in 'CUDA0 model buffer size' \
                'CUDA0 KV buffer size' 'CUDA0 compute buffer size'; do
                grep -qF "$placement_line" "$arm_log" || {
                    printf 'refused: placement missing %s in %s\n' \
                        "$placement_line" "$arm_log" >&2
                    return 1
                }
            done
            return 0
        fi
        ready_iteration=$((ready_iteration + 1))
        sleep 1
    done
    printf 'refused: llama-server stayed unready for %s seconds; see %s\n' \
        "$readiness_seconds" "$arm_log" >&2
    return 1
}

# The placement fingerprint is the three CUDA0 buffer lines with their sizes,
# which is what makes "the same placement" checkable rather than asserted.
placement_fingerprint() {
    grep -E 'CUDA0 (model|KV|compute) buffer size' "$1" |
        sed 's/^.*CUDA0/CUDA0/' | sort | sha256sum | awk '{ print $1 }'
}

first_divergence() {
    awk '
        FNR == NR { left[FNR - 1] = $0; left_count = FNR; next }
        { right[FNR - 1] = $0; right_count = FNR }
        END {
            limit = left_count < right_count ? left_count : right_count
            for (i = 0; i < limit; i++) {
                if (left[i] != right[i]) { print i; exit }
            }
            if (left_count != right_count) { print limit; exit }
            print -1
        }
    ' "$1" "$2"
}

client_fingerprint() {
    gpu_ownership_inspect 2>/dev/null |
        awk '/^cuda_client / { print $2 }' | sort | tr '\n' ',' 
}

opening_clients=$(client_fingerprint)
printf 'clients\topen\t%s\n' "${opening_clients:--}" >>"$summary_file"

divergences=0
refusals=0

for model_id in "$@"; do
    model_file=$(registry_field "$model_id" model_file)
    model_path=$models_directory/$model_file
    if [ ! -f "$model_path" ]; then
        printf 'closure_identity\t%s\tnot_run\tmodel_absent\n' \
            "$model_id" >>"$summary_file"
        continue
    fi
    model_context=$(registry_field "$model_id" context_default)
    model_batch=$(registry_field "$model_id" batch)
    model_ubatch=$(registry_field "$model_id" ubatch)
    model_cache_k=$(registry_field "$model_id" cache_type_k)
    model_cache_v=$(registry_field "$model_id" cache_type_v)
    model_flash_attention=$(registry_field "$model_id" flash_attention)
    printf 'geometry\t%s\tcontext=%s batch=%s ubatch=%s cache_k=%s cache_v=%s flash_attn=%s\n' \
        "$model_id" "$model_context" "$model_batch" "$model_ubatch" \
        "$model_cache_k" "$model_cache_v" "$model_flash_attention" \
        >>"$summary_file"

    for arm_name in control-open subject control-close; do
        case $arm_name in
            subject) arm_build=$subject_build ;;
            *) arm_build=$control_build ;;
        esac
        arm_directory=$output_directory/$model_id/$arm_name
        mkdir -p "$arm_directory"

        arm_clients=$(client_fingerprint)
        if [ "$arm_clients" != "$opening_clients" ]; then
            printf 'clients\t%s\tchanged\t%s\n' "$arm_name" "${arm_clients:--}" \
                >>"$summary_file"
            printf 'refused: the compute-client set changed before arm %s\n' \
                "$arm_name" >&2
            refusals=$((refusals + 1))
            break
        fi

        start_server "$arm_build" "$model_path" "$model_context" \
            "$model_batch" "$model_ubatch" "$model_cache_k" \
            "$model_cache_v" "$model_flash_attention" \
            "$arm_directory/server.log" || {
            printf 'closure_identity\t%s\t%s\trefused\tserver_start\n' \
                "$model_id" "$arm_name" >>"$summary_file"
            refusals=$((refusals + 1))
            break
        }
        printf 'placement\t%s\t%s\t%s\n' "$model_id" "$arm_name" \
            "$(placement_fingerprint "$arm_directory/server.log")" \
            >>"$summary_file"

        while IFS="$(printf '\t')" read -r prompt_id prompt_text; do
            [ -n "$prompt_id" ] || continue
            prompt_directory=$arm_directory/$prompt_id
            mkdir -p "$prompt_directory"
            printf '%s' "$prompt_text" >"$prompt_directory/prompt.txt"
            python3 "$request_builder" "$prompt_directory/prompt.txt" \
                "$predict_tokens" "$sampling_seed" \
                >"$prompt_directory/request.json"
            curl --silent --show-error --fail-with-body \
                --max-time "$request_seconds" \
                --header 'Content-Type: application/json' \
                --data @"$prompt_directory/request.json" \
                "http://127.0.0.1:$server_port/completion" \
                >"$prompt_directory/response.json"
            python3 "$token_reader" "$prompt_directory/response.json" \
                "$predict_tokens" >"$prompt_directory/tokens.txt"
            printf 'tokens\t%s\t%s\t%s\t%s\n' "$model_id" "$arm_name" \
                "$prompt_id" \
                "$(sha256sum "$prompt_directory/tokens.txt" | awk '{ print $1 }')" \
                >>"$summary_file"
        done <"$prompt_file"

        stop_server
    done

    control_directory=$output_directory/$model_id/control-open
    for comparison in subject control-close; do
        comparison_directory=$output_directory/$model_id/$comparison
        [ -d "$comparison_directory" ] || continue
        while IFS="$(printf '\t')" read -r prompt_id prompt_text; do
            [ -n "$prompt_id" ] || continue
            left=$control_directory/$prompt_id/tokens.txt
            right=$comparison_directory/$prompt_id/tokens.txt
            if [ ! -s "$left" ] || [ ! -s "$right" ]; then
                printf 'identity\t%s\t%s\t%s\tnot_run\tmissing_tokens\n' \
                    "$model_id" "$comparison" "$prompt_id" >>"$summary_file"
                continue
            fi
            divergent_at=$(first_divergence "$left" "$right")
            if [ "$divergent_at" = '-1' ]; then
                printf 'identity\t%s\t%s\t%s\tidentical\tdivergent_at=-\n' \
                    "$model_id" "$comparison" "$prompt_id" >>"$summary_file"
            else
                printf 'identity\t%s\t%s\t%s\tdivergent\tdivergent_at=%s\n' \
                    "$model_id" "$comparison" "$prompt_id" "$divergent_at" \
                    >>"$summary_file"
                divergences=$((divergences + 1))
            fi
        done <"$prompt_file"
    done

    open_placement=$(awk -F'\t' -v m="$model_id" \
        '$1 == "placement" && $2 == m && $3 == "control-open" { print $4 }' \
        "$summary_file")
    for comparison in subject control-close; do
        comparison_placement=$(awk -F'\t' -v m="$model_id" -v a="$comparison" \
            '$1 == "placement" && $2 == m && $3 == a { print $4 }' "$summary_file")
        [ -n "$comparison_placement" ] || continue
        if [ "$comparison_placement" = "$open_placement" ]; then
            printf 'placement_match\t%s\t%s\tsame\n' "$model_id" "$comparison" \
                >>"$summary_file"
        else
            printf 'placement_match\t%s\t%s\tdiffers\n' "$model_id" "$comparison" \
                >>"$summary_file"
            refusals=$((refusals + 1))
        fi
    done
done

# Retained evidence carries the checkout and model paths the run resolved, and
# a Git copy replaces the home prefix with $HOME. Scrubbing every retained text
# file at the end closes that at the source rather than leaving it to the
# authority check to catch one directory at a time.
scrub_local_paths() {
    find "$1" -type f \( -name '*.txt' -o -name '*.json' -o -name '*.log' \
        -o -name '*.tsv' -o -name '*.stdout' -o -name '*.stderr' \) \
        -exec sed -i "s#$HOME#\$HOME#g" {} +
}

closing_clients=$(client_fingerprint)
printf 'clients\tclose\t%s\n' "${closing_clients:--}" >>"$summary_file"
read_kernel_ring close

# The three outcomes are distinct and only one of them is a finding about the
# closures. A refusal names a harness or environment fault and the arm is rerun;
# a control-close divergence names device drift under the pair; a subject
# divergence at an unchanged threshold value names the patch itself.
subject_divergences=$(awk -F'\t' \
    '$1 == "identity" && $3 == "subject" && $5 == "divergent" { count++ } END { print count + 0 }' \
    "$summary_file")
control_divergences=$(awk -F'\t' \
    '$1 == "identity" && $3 == "control-close" && $5 == "divergent" { count++ } END { print count + 0 }' \
    "$summary_file")

if [ "$refusals" -gt 0 ]; then
    verdict=refused
elif [ "$control_divergences" -gt 0 ]; then
    verdict=control-drift
elif [ "$subject_divergences" -gt 0 ]; then
    verdict=subject-divergent
else
    verdict=identical
fi
printf 'verdict\t%s\tsubject_divergences=%s control_divergences=%s refusals=%s\n' \
    "$verdict" "$subject_divergences" "$control_divergences" "$refusals" \
    >>"$summary_file"

scrub_local_paths "$output_directory"
cat "$summary_file"
printf 'closure_identity=%s subject_divergences=%s control_divergences=%s refusals=%s\n' \
    "$verdict" "$subject_divergences" "$control_divergences" "$refusals"
[ "$verdict" = identical ] || exit 1
