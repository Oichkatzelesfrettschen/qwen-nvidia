#!/bin/sh
set -eu

# The Vulkan graph optimizer reorders nodes to widen parallelism, and its
# is_src_of relation at f280b269 compares node pointers and each node's own
# view_src base. Two distinct views of one underlying tensor therefore read as
# independent, so a write through one view can move past a read through
# another. A model that carries recurrent state through views selects a
# different token under greedy decoding with nothing logged, which is what
# upstream issue ggml-org/llama.cpp#27805 reports and commit b387ddfd8 fixes.
#
# This harness answers that as a token-identity question rather than a rate
# question. Every arm decodes the same prompt at temperature 0 with top_k 1, a
# fixed seed, ignore_eos, and cache_prompt off, and the comparison is over the
# exact token-id array llama-server returns under return_tokens. Three arms
# separate the two variables: the production build with the optimizer on, the
# same build with GGML_VK_DISABLE_GRAPH_OPTIMIZE=1, and a build carrying
# patches/llama-vulkan-view-alias-deps.patch with the optimizer on. The
# optimizer-off arm is the reference, because a graph the optimizer never
# touched carries the order ggml built.
#
# The reported symptom is per-start rather than per-request, so the sample
# budget splits across server restarts: QWEN_ALIAS_AB_RESTARTS fresh processes
# each answering QWEN_ALIAS_AB_RUNS requests. Self-consistency inside one arm
# is reported beside the cross-arm comparison, since the production arm
# disagreeing with itself reproduces the defect without the patched build
# existing at all.
#
# Every arm names depth, submission geometry, and the cache triple from
# remote/models.tsv explicitly. An absent --batch-size falls through to the
# llama.cpp default of 2048, which is the geometry that wedged the compute ring
# at depth 16384 in evidence/depth-versus-submission-geometry.md.

if [ "$#" -lt 1 ]; then
    printf 'usage: %s OUTPUT_DIRECTORY [MODEL_ID...]\n' "$0" >&2
    printf '  QWEN_PRODUCTION_BUILD_DIR names the unpatched build (required)\n' >&2
    printf '  QWEN_ALIAS_BUILD_DIR names the patched build (optional)\n' >&2
    exit 2
fi

output_directory=$1
shift
script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_script=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
server_relative_path=${QWEN_ALIAS_AB_SERVER_RELATIVE:-bin/llama-server}
production_build_directory=${QWEN_PRODUCTION_BUILD_DIR:-}
alias_build_directory=${QWEN_ALIAS_BUILD_DIR:-}
server_port=${QWEN_ALIAS_AB_PORT:-8099}
restart_count=${QWEN_ALIAS_AB_RESTARTS:-3}
run_count=${QWEN_ALIAS_AB_RUNS:-4}
predict_tokens=${QWEN_ALIAS_AB_PREDICT:-256}
sampling_seed=${QWEN_ALIAS_AB_SEED:-1}
thread_count=${QWEN_ALIAS_AB_THREADS:-1}
readiness_seconds=${QWEN_ALIAS_AB_READY_SECONDS:-180}
request_seconds=${QWEN_ALIAS_AB_REQUEST_SECONDS:-1800}
reference_arm=${QWEN_ALIAS_AB_REFERENCE_ARM:-production-optimize-off}
appliance_port=${QWEN_SERVER_PORT:-8080}

if [ "$#" -eq 0 ]; then
    set -- qwen38-2b-distill qwen38-4b-distill
fi

for positive_value in "$restart_count" "$run_count" "$predict_tokens" \
    "$thread_count" "$server_port"; do
    case $positive_value in
        '' | *[!0-9]* | 0)
            printf 'restarts, runs, predict, threads, and port must be positive integers: %s\n' \
                "$positive_value" >&2
            exit 2
            ;;
    esac
done

if [ -z "$production_build_directory" ]; then
    printf 'QWEN_PRODUCTION_BUILD_DIR is required\n' >&2
    exit 2
fi
if [ ! -x "$production_build_directory/$server_relative_path" ]; then
    printf 'production llama-server is absent: %s\n' \
        "$production_build_directory/$server_relative_path" >&2
    exit 2
fi

# A concurrent llama-server contends for the two Vega compute units and the one
# DDR4 controller, and a second process holding the device turns a correctness
# question into a scheduling one. The process check comes first because a
# foreign server on another port contends just as much as one on 8080.
if command -v pgrep >/dev/null 2>&1 && pgrep -x llama-server >/dev/null 2>&1; then
    printf 'llama-server is running; run %s after qwen-teardown.sh\n' \
        "$(basename "$0")" >&2
    exit 1
fi
if curl --silent --fail --max-time 2 \
    "http://127.0.0.1:$appliance_port/health" >/dev/null 2>&1; then
    printf 'a server answers /health on port %s; run %s after qwen-teardown.sh\n' \
        "$appliance_port" "$(basename "$0")" >&2
    exit 1
fi

umask 077
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)

# Six prompts that keep state alive across many decode steps: a running numeric
# accumulator, a stack discipline, an in-place list transform carried forward,
# a variable-rebinding trace, a state machine walked step by step, and a
# constraint set narrowed one clue at a time. Each one forces the model to read
# what it wrote, which is the traffic the aliased recurrent state carries.
prompt_file=${QWEN_ALIAS_AB_PROMPTS:-"$output_directory/prompts.tsv"}
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
# cache_prompt off makes every run pay its own prefill, so a reordering that
# only shows on the prefill graph is not masked by a reused KV prefix.
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

token_reader=$output_directory/read-tokens.py
cat >"$token_reader" <<'PYTHON'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
tokens = payload.get("tokens")
if not isinstance(tokens, list) or not tokens:
    sys.stderr.write("response carries no token array\n")
    raise SystemExit(1)
for token_id in tokens:
    if not isinstance(token_id, int):
        sys.stderr.write("token array holds a non-integer entry\n")
        raise SystemExit(1)
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

summary_file=$output_directory/summary.tsv
: >"$summary_file"
divergence_seen=0
comparison_count=0

{
    printf 'production_build=%s\n' "$production_build_directory"
    printf 'alias_build=%s\n' "${alias_build_directory:-absent}"
    printf 'reference_arm=%s\n' "$reference_arm"
    printf 'restarts=%s\nruns_per_start=%s\npredict_tokens=%s\nseed=%s\n' \
        "$restart_count" "$run_count" "$predict_tokens" "$sampling_seed"
    printf 'models=%s\n' "$*"
} >"$output_directory/inputs.txt"

start_server() {
    arm_build_directory=$1
    arm_disable_optimize=$2
    arm_model_path=$3
    arm_context=$4
    arm_batch=$5
    arm_ubatch=$6
    arm_cache_k=$7
    arm_cache_v=$8
    arm_flash_attention=$9
    arm_log=${10}

    # Placement is pinned the way qwen-capacity-policy.sh pins it for the
    # serving path. Left to --fit, llama.cpp decides placement per load from
    # the free VRAM it observes, so an arm that drifts layers onto the CPU
    # decodes deterministically in a different way: a drifted reference reads
    # as divergent and blames the optimizer, and a drifted production arm reads
    # as identical and hides it. LLAMA_NO_CPU_FALLBACK reaches the
    # llama-no-cpu-fallback patch both builds carry, so a fallback fails the
    # load rather than serving from the other device. The placement lines
    # read below are library info logs, which the server prints only from
    # --log-verbosity 4, the value qwen-capacity-policy.sh serves under.
    if [ "$arm_disable_optimize" = 1 ]; then
        LLAMA_NO_CPU_FALLBACK=1 GGML_VK_DISABLE_GRAPH_OPTIMIZE=1 \
            "$arm_build_directory/$server_relative_path" \
            --model "$arm_model_path" \
            --host 127.0.0.1 \
            --port "$server_port" \
            --ctx-size "$arm_context" \
            --batch-size "$arm_batch" \
            --ubatch-size "$arm_ubatch" \
            --cache-type-k "$arm_cache_k" \
            --cache-type-v "$arm_cache_v" \
            --flash-attn "$arm_flash_attention" \
            --device Vulkan0 \
            --split-mode none \
            --override-tensor '.*=Vulkan0' \
            --fit off \
            --n-gpu-layers all \
            --parallel 1 \
            --threads "$thread_count" \
            --threads-batch "$thread_count" \
            --no-context-shift \
            --offline \
            --log-verbosity 4 \
            >"$arm_log" 2>&1 &
    else
        LLAMA_NO_CPU_FALLBACK=1 \
            "$arm_build_directory/$server_relative_path" \
            --model "$arm_model_path" \
            --host 127.0.0.1 \
            --port "$server_port" \
            --ctx-size "$arm_context" \
            --batch-size "$arm_batch" \
            --ubatch-size "$arm_ubatch" \
            --cache-type-k "$arm_cache_k" \
            --cache-type-v "$arm_cache_v" \
            --flash-attn "$arm_flash_attention" \
            --device Vulkan0 \
            --split-mode none \
            --override-tensor '.*=Vulkan0' \
            --fit off \
            --n-gpu-layers all \
            --parallel 1 \
            --threads "$thread_count" \
            --threads-batch "$thread_count" \
            --no-context-shift \
            --offline \
            --log-verbosity 4 \
            >"$arm_log" 2>&1 &
    fi
    server_pid=$!

    ready_iteration=0
    while [ "$ready_iteration" -lt "$readiness_seconds" ]; do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            printf 'llama-server exited before readiness; see %s\n' "$arm_log" >&2
            return 1
        fi
        if curl --silent --fail --max-time 2 \
            "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            # The load log proves placement. A model, KV, or compute buffer
            # that failed to name Vulkan0 puts the arm on a different device
            # than its comparison partner, which is the one difference a
            # token-identity verdict cannot survive.
            for placement_line in \
                'Vulkan0 model buffer size' \
                'Vulkan0 KV buffer size' \
                'Vulkan0 compute buffer size'; do
                if ! grep -qF "$placement_line" "$arm_log"; then
                    printf 'placement=rejected missing=%s log=%s\n' \
                        "$placement_line" "$arm_log" >&2
                    return 1
                fi
            done
            return 0
        fi
        ready_iteration=$((ready_iteration + 1))
        sleep 1
    done
    printf 'llama-server stayed unready for %s seconds; see %s\n' \
        "$readiness_seconds" "$arm_log" >&2
    return 1
}

# Compare two token-id files and print the first index at which they differ,
# counting generated tokens from zero. A shared prefix ending where one file
# ends reports that length, which is a divergence in generated count.
first_divergence() {
    awk '
        FNR == NR { left[FNR - 1] = $0; left_count = FNR; next }
        { right[FNR - 1] = $0; right_count = FNR }
        END {
            limit = left_count < right_count ? left_count : right_count
            for (index_value = 0; index_value < limit; index_value++) {
                if (left[index_value] != right[index_value]) {
                    print index_value
                    exit
                }
            }
            if (left_count != right_count) {
                print limit
                exit
            }
            print -1
        }
    ' "$1" "$2"
}

for model_id in "$@"; do
    model_file=$(registry_field "$model_id" model_file)
    model_path=$models_directory/$model_file
    if [ ! -f "$model_path" ]; then
        printf 'graph_alias_ab=not_run\tmodel=%s\treason=model_absent\tpath=%s\n' \
            "$model_id" "$model_path" >>"$summary_file"
        continue
    fi
    model_context=$(registry_field "$model_id" context_default)
    model_batch=$(registry_field "$model_id" batch)
    model_ubatch=$(registry_field "$model_id" ubatch)
    model_cache_k=$(registry_field "$model_id" cache_type_k)
    model_cache_v=$(registry_field "$model_id" cache_type_v)
    model_flash_attention=$(registry_field "$model_id" flash_attention)

    printf 'arm_geometry\tmodel=%s\tcontext=%s\tbatch=%s\tubatch=%s\tcache_k=%s\tcache_v=%s\tflash_attn=%s\n' \
        "$model_id" "$model_context" "$model_batch" "$model_ubatch" \
        "$model_cache_k" "$model_cache_v" "$model_flash_attention" \
        >>"$summary_file"

    for arm_name in production-optimize production-optimize-off alias-optimize; do
        case $arm_name in
            production-optimize)
                arm_build=$production_build_directory
                arm_disable=0
                ;;
            production-optimize-off)
                arm_build=$production_build_directory
                arm_disable=1
                ;;
            alias-optimize)
                arm_build=$alias_build_directory
                arm_disable=0
                ;;
        esac

        # A lane that has not built the patched tree still answers the cheaper
        # question, so the absent build is recorded as a check that did not run
        # rather than failing the sweep.
        if [ -z "$arm_build" ] || [ ! -x "$arm_build/$server_relative_path" ]; then
            printf 'graph_alias_ab=not_run\tmodel=%s\tarm=%s\treason=alias_build_absent\n' \
                "$model_id" "$arm_name" >>"$summary_file"
            continue
        fi

        arm_directory=$output_directory/$model_id/$arm_name
        mkdir -p "$arm_directory"

        start_index=1
        while [ "$start_index" -le "$restart_count" ]; do
            start_server "$arm_build" "$arm_disable" "$model_path" \
                "$model_context" "$model_batch" "$model_ubatch" \
                "$model_cache_k" "$model_cache_v" "$model_flash_attention" \
                "$arm_directory/server-start-$start_index.log"

            run_index=1
            while [ "$run_index" -le "$run_count" ]; do
                while IFS="$(printf '\t')" read -r prompt_id prompt_text; do
                    [ -n "$prompt_id" ] || continue
                    prompt_directory=$arm_directory/$prompt_id
                    mkdir -p "$prompt_directory"
                    sample_label=start-$start_index-run-$run_index
                    printf '%s' "$prompt_text" \
                        >"$prompt_directory/prompt.txt"
                    python3 "$request_builder" "$prompt_directory/prompt.txt" \
                        "$predict_tokens" "$sampling_seed" \
                        >"$prompt_directory/request.json"
                    curl --silent --show-error --fail-with-body \
                        --max-time "$request_seconds" \
                        --header 'Content-Type: application/json' \
                        --data @"$prompt_directory/request.json" \
                        "http://127.0.0.1:$server_port/completion" \
                        >"$prompt_directory/response-$sample_label.json"
                    python3 "$token_reader" \
                        "$prompt_directory/response-$sample_label.json" \
                        >"$prompt_directory/tokens-$sample_label.txt"
                done <"$prompt_file"
                run_index=$((run_index + 1))
            done

            stop_server
            start_index=$((start_index + 1))
        done

        # Self-consistency inside the arm, at matched request position. This
        # appliance answers arith-05 with 37 cold and 23 warm from the same
        # prompt_n, and evidence discipline records that sequence effect as
        # real and unisolated. Comparing every sample against one canonical
        # sample would fold it into the optimizer verdict, so the across-start
        # scope compares run 1 of each start against run 1 of the first, where
        # both samples sit at the same position behind the same prompt
        # sequence, and the within-start scope compares later runs against
        # run 1 of their own start.
        while IFS="$(printf '\t')" read -r prompt_id prompt_text; do
            [ -n "$prompt_id" ] || continue
            prompt_directory=$arm_directory/$prompt_id
            for consistency_scope in across-start within-start; do
                sample_total=0
                self_divergent=0
                start_index=1
                while [ "$start_index" -le "$restart_count" ]; do
                    if [ "$consistency_scope" = across-start ]; then
                        canonical_file=$prompt_directory/tokens-start-1-run-1.txt
                        first_run_index=1
                        final_run_index=1
                        [ "$start_index" -gt 1 ] || final_run_index=0
                    else
                        canonical_file=$prompt_directory/tokens-start-$start_index-run-1.txt
                        first_run_index=2
                        final_run_index=$run_count
                    fi
                    run_index=$first_run_index
                    while [ "$run_index" -le "$final_run_index" ]; do
                        sample_label=start-$start_index-run-$run_index
                        sample_file=$prompt_directory/tokens-$sample_label.txt
                        sample_total=$((sample_total + 1))
                        divergence_index=$(first_divergence "$canonical_file" \
                            "$sample_file")
                        if [ "$divergence_index" != -1 ] && [ "$self_divergent" = 0 ]; then
                            self_divergent=1
                            printf 'graph_alias_selfconsistent=divergent\tmodel=%s\tarm=%s\tprompt=%s\tscope=%s\tsample=%s\tfirst_divergence=%s\n' \
                                "$model_id" "$arm_name" "$prompt_id" \
                                "$consistency_scope" "$sample_label" \
                                "$divergence_index" >>"$summary_file"
                            divergence_seen=1
                        fi
                        run_index=$((run_index + 1))
                    done
                    start_index=$((start_index + 1))
                done
                if [ "$self_divergent" = 0 ]; then
                    printf 'graph_alias_selfconsistent=identical\tmodel=%s\tarm=%s\tprompt=%s\tscope=%s\tcomparisons=%s\n' \
                        "$model_id" "$arm_name" "$prompt_id" \
                        "$consistency_scope" "$sample_total" >>"$summary_file"
                fi
            done
        done <"$prompt_file"
    done

    # Cross-arm comparison against the reference arm's first sample. An arm
    # whose reference file is absent is reported as unrun rather than passed.
    reference_directory=$output_directory/$model_id/$reference_arm
    for arm_name in production-optimize production-optimize-off alias-optimize; do
        [ "$arm_name" != "$reference_arm" ] || continue
        arm_directory=$output_directory/$model_id/$arm_name
        while IFS="$(printf '\t')" read -r prompt_id prompt_text; do
            [ -n "$prompt_id" ] || continue
            reference_file=$reference_directory/$prompt_id/tokens-start-1-run-1.txt
            arm_file=$arm_directory/$prompt_id/tokens-start-1-run-1.txt
            if [ ! -s "$reference_file" ] || [ ! -s "$arm_file" ]; then
                printf 'graph_alias_ab=not_run\tmodel=%s\tarm=%s\tprompt=%s\treference_arm=%s\treason=sample_absent\n' \
                    "$model_id" "$arm_name" "$prompt_id" "$reference_arm" \
                    >>"$summary_file"
                continue
            fi
            comparison_count=$((comparison_count + 1))
            divergence_index=$(first_divergence "$reference_file" "$arm_file")
            if [ "$divergence_index" = -1 ]; then
                printf 'graph_alias_ab=identical\tmodel=%s\tarm=%s\tprompt=%s\treference_arm=%s\n' \
                    "$model_id" "$arm_name" "$prompt_id" "$reference_arm" \
                    >>"$summary_file"
            else
                divergence_seen=1
                printf 'graph_alias_ab=divergent\tmodel=%s\tarm=%s\tprompt=%s\treference_arm=%s\tfirst_divergence=%s\n' \
                    "$model_id" "$arm_name" "$prompt_id" "$reference_arm" \
                    "$divergence_index" >>"$summary_file"
            fi
        done <"$prompt_file"
    done
done

cat "$summary_file"
if [ "$comparison_count" -eq 0 ]; then
    printf 'graph_alias_ab=not_run reason=no_comparison_ran\n'
    exit 1
fi
if [ "$divergence_seen" = 1 ]; then
    printf 'graph_alias_ab=divergent comparisons=%s\n' "$comparison_count"
else
    printf 'graph_alias_ab=identical comparisons=%s\n' "$comparison_count"
fi
