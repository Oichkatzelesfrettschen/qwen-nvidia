#!/bin/sh
set -eu

# gpu-ownership: top-level owner; acquires the lock for the whole run and launches every server with 9>&-.
#
# Drives one paged KV buffer through the lifecycle the P2-C contract names
# and reads what it cost. Every arm serves the same closure, the same
# checkpoint at its registry tuple, and the same request sequence; the arms
# differ in LLAMA_KV_PAGED_RESIDENCY alone, so the fully backed null and the
# tails subject answer the same questions and the closing null states whether
# the device moved under the pair.
#
# The sequence per arm: one prompt cut to QWEN_RESIDENCY_ROWS tokens through
# the server's own tokenizer, so the attention envelope pads to the 4096-row
# extent the contract sizes at 36 MiB; a greedy reply A; a slot save; a slot
# erase, which is the removal that leaves the tail outside the envelope; a
# restore of the saved state, which commits the destination ahead of the
# bytes; the same prompt again for reply B; one short unrelated prompt for
# reply C, whose prefix mismatch removes the long sequence; the long prompt
# once more for reply D, which regrows the envelope over units the reclaim
# released and the commit zeroed; and a second slot save. Reply identity
# across A, B, and D inside one arm states that save, erase, restore, and
# regrowth leave the arithmetic alone; identity across arms states that the
# residency policy does; the saved state bytes state the same for the
# logical cache contents. The subject's log is read by read-paged-kv-layout.py
# under the tails expectation with the preregistered bounds: allocated at or
# under 60 MiB at the 4096-row envelope, commit and reclaim under 2 ms at the
# median and 10 ms at the 95th percentile.

usage() {
    cat >&2 <<'USAGE'
usage: probe-paged-kv-residency-lifecycle.sh BUILD_DIRECTORY OUTPUT_DIRECTORY [MODEL_ID]

BUILD_DIRECTORY holds bin/llama-server built with
patches/llama-cuda-paged-kv-buffer.patch. Naming no MODEL_ID runs
qwen38-2b-distill. OUTPUT_DIRECTORY must be absent or empty.

  QWEN_RESIDENCY_ROWS         prompt length in tokens, default 3900
  QWEN_RESIDENCY_PREDICT      tokens per long reply, default 64
  QWEN_RESIDENCY_PORT         listener, default 8101
  QWEN_RESIDENCY_ARMS         arms in order, default "full tails full-close"
  QWEN_RESIDENCY_MAX_ALLOCATED_BYTES  the allocated bound, default 62914560
  QWEN_RESIDENCY_MAX_MEDIAN_US        the median latency bound, default 2000
  QWEN_RESIDENCY_MAX_P95_US           the p95 latency bound, default 10000
  QWEN_RESIDENCY_REQUIRE_BOUNDARIES   1 refuses a tails arm whose lifecycle crossed no unit boundary, default 1
  QWEN_RESIDENCY_KEEP_STATE           1 retains the saved slot states beside their digests
  QWEN_RESIDENCY_READY_SECONDS        readiness deadline, default 300
  QWEN_RESIDENCY_REQUEST_SECONDS      per-request deadline, default 600
USAGE
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
build_directory=$1
output_directory=$2
model_id=${3:-qwen38-2b-distill}
prompt_rows=${QWEN_RESIDENCY_ROWS:-3900}
predict_tokens=${QWEN_RESIDENCY_PREDICT:-64}
server_port=${QWEN_RESIDENCY_PORT:-8101}
arms=${QWEN_RESIDENCY_ARMS:-"full tails full-close"}
max_allocated_bytes=${QWEN_RESIDENCY_MAX_ALLOCATED_BYTES:-62914560}
max_median_us=${QWEN_RESIDENCY_MAX_MEDIAN_US:-2000}
max_p95_us=${QWEN_RESIDENCY_MAX_P95_US:-10000}
require_boundaries=${QWEN_RESIDENCY_REQUIRE_BOUNDARIES:-1}
case $require_boundaries in 0 | 1) ;; *) usage ;; esac
readiness_seconds=${QWEN_RESIDENCY_READY_SECONDS:-300}
request_seconds=${QWEN_RESIDENCY_REQUEST_SECONDS:-600}
for value in "$prompt_rows" "$predict_tokens" "$server_port" "$max_allocated_bytes" "$max_median_us" "$max_p95_us" \
    "$readiness_seconds" "$request_seconds"; do
    case $value in '' | *[!0-9]* | 0) usage ;; esac
done
for arm in $arms; do
    case $arm in full | tails | full-close | tails-close) ;; *) usage ;; esac
done

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_script=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
server_binary=$build_directory/bin/llama-server
[ -x "$server_binary" ] || {
    printf 'refused: llama-server is absent: %s\n' "$server_binary" >&2
    exit 2
}
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory is not empty: %s\n' "$output_directory" >&2
    exit 2
fi

. "$script_directory/gpu-workload-ownership.sh"

umask 077
mkdir -p "$output_directory"
output_directory=$(CDPATH='' cd -- "$output_directory" && pwd)
summary=$output_directory/summary.tsv
: >"$summary"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
record() { printf '%s\t%s\n' "$1" "$2" >>"$summary"; }

gpu_ownership_require >"$output_directory/ownership-open.txt" || {
    ownership_status=$?
    cat "$output_directory/ownership-open.txt" >&2
    exit "$ownership_status"
}

record model_id "$model_id"
record build_directory "$(printf '%s' "$build_directory" | scrub_home)"
record server_sha256 "$(sha256sum "$server_binary" | cut -d ' ' -f 1)"
record prompt_rows "$prompt_rows"
record predict_tokens "$predict_tokens"
record arms "$arms"
record bounds "allocated<=$max_allocated_bytes median_us<=$max_median_us p95_us<=$max_p95_us"
record require_boundaries "$require_boundaries"

registry_field() { "$registry_script" id "$1" "$2"; }
model_file=$(registry_field "$model_id" model_file)
model_path=$models_directory/$model_file
[ -f "$model_path" ] || {
    printf 'refused: model file absent: %s\n' "$model_path" >&2
    record verdict "refused model_absent"
    exit 1
}
model_context=$(registry_field "$model_id" context_default)
model_batch=$(registry_field "$model_id" batch)
model_ubatch=$(registry_field "$model_id" ubatch)
model_cache_k=$(registry_field "$model_id" cache_type_k)
model_cache_v=$(registry_field "$model_id" cache_type_v)
model_flash_attention=$(registry_field "$model_id" flash_attention)
record geometry "context=$model_context batch=$model_batch ubatch=$model_ubatch cache_k=$model_cache_k cache_v=$model_cache_v flash_attn=$model_flash_attention"
[ "$prompt_rows" -lt "$model_context" ] || {
    printf 'refused: prompt rows %s reach the context %s\n' "$prompt_rows" "$model_context" >&2
    record verdict "refused prompt_exceeds_context"
    exit 2
}

thread_count=${QWEN_RESIDENCY_THREADS:-1}
client_set() {
    nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null |
        sed "s|${HOME:?}|\$HOME|g" | sort | tr '\n' ';'
}
record clients_open "$(client_set)"

"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv" >/dev/null 2>&1 || :

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

post() {
    # post ROUTE DATA_FILE OUT_FILE
    curl --silent --show-error --fail-with-body --max-time "$request_seconds" \
        --header 'Content-Type: application/json' --data @"$2" \
        "http://127.0.0.1:$server_port$1" >"$3"
}

start_server() {
    arm_directory=$1
    arm_residency=$2
    mkdir -p "$arm_directory/slots"
    env LLAMA_KV_PAGED_BUFFER=1 "LLAMA_KV_PAGED_RESIDENCY=$arm_residency" LLAMA_NO_CPU_FALLBACK=1 \
        "$server_binary" \
        --slot-save-path "$arm_directory/slots" \
        --model "$model_path" \
        --host 127.0.0.1 \
        --port "$server_port" \
        --ctx-size "$model_context" \
        --batch-size "$model_batch" \
        --ubatch-size "$model_ubatch" \
        --cache-type-k "$model_cache_k" \
        --cache-type-v "$model_cache_v" \
        --flash-attn "$model_flash_attention" \
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
        >"$arm_directory/server.log" 2>&1 9>&- &
    server_pid=$!
    ready_iteration=0
    while [ "$ready_iteration" -lt "$readiness_seconds" ]; do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            printf 'refused: llama-server exited before readiness; see %s\n' "$arm_directory/server.log" >&2
            return 1
        fi
        if curl --silent --fail --max-time 2 "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            for placement_line in 'CUDA0 model buffer size' 'CUDA0 KV buffer size' 'CUDA0 compute buffer size'; do
                grep -qF "$placement_line" "$arm_directory/server.log" || {
                    printf 'refused: placement missing %s in %s\n' "$placement_line" "$arm_directory/server.log" >&2
                    return 1
                }
            done
            return 0
        fi
        ready_iteration=$((ready_iteration + 1))
        sleep 1
    done
    printf 'refused: llama-server stayed unready for %s seconds\n' "$readiness_seconds" >&2
    return 1
}

helper=$output_directory/lifecycle-helper.py
cat >"$helper" <<'PYTHON'
import json
import sys

# cut-prompt ROWS OUT: a prompt of ROWS tokens through the server's tokenizer,
# by round-tripping a repeated paragraph through /tokenize and /detokenize.
# request PROMPT_FILE PREDICT OUT: a greedy cached completion request.
# tokens RESPONSE PREDICT OUT: the reply token ids, refused on a short array.
# prompt_n RESPONSE: the prompt tokens the server evaluated for the request.
command = sys.argv[1]
if command == "tokenize-body":
    text = open(sys.argv[2], encoding="utf-8").read()
    json.dump({"content": text, "add_special": False, "with_pieces": False}, sys.stdout)
elif command == "cut-tokens":
    rows = int(sys.argv[3])
    tokens = json.load(open(sys.argv[2], encoding="utf-8"))["tokens"]
    if len(tokens) < rows:
        sys.stderr.write("the source text tokenizes to %d tokens, under %d\n" % (len(tokens), rows))
        raise SystemExit(1)
    json.dump({"tokens": tokens[:rows]}, sys.stdout)
elif command == "detokenized-text":
    sys.stdout.write(json.load(open(sys.argv[2], encoding="utf-8"))["content"])
elif command == "request":
    prompt_text = open(sys.argv[2], encoding="utf-8").read()
    json.dump({"prompt": prompt_text, "n_predict": int(sys.argv[3]), "temperature": 0, "top_k": 1, "seed": 1,
               "ignore_eos": True, "cache_prompt": True, "return_tokens": True, "stream": False}, sys.stdout)
elif command == "tokens":
    payload = json.load(open(sys.argv[2], encoding="utf-8"))
    expected = int(sys.argv[3])
    tokens = payload.get("tokens")
    if not isinstance(tokens, list) or len(tokens) != expected or any(not isinstance(t, int) for t in tokens):
        sys.stderr.write("the reply carries %s of %d tokens\n" % (len(tokens) if isinstance(tokens, list) else "no", expected))
        raise SystemExit(1)
    for t in tokens:
        print(t)
elif command == "prompt_n":
    payload = json.load(open(sys.argv[2], encoding="utf-8"))
    print(payload.get("timings", {}).get("prompt_n", payload.get("tokens_evaluated", "-")))
else:
    raise SystemExit("unknown command")
PYTHON

source_text=$output_directory/source-text.txt
paragraph='The measurement holds for the device software stack it ran under, and the record names that stack beside every rate. A default here changes when a measurement on this host moves it, and the evidence directory holds those measurements. State the falsification criterion before running a probe; when a result deviates from prediction, the deviation is the finding. '
: >"$source_text"
repeat=0
while [ "$repeat" -lt $((prompt_rows / 20 + 10)) ]; do
    printf '%s' "$paragraph" >>"$source_text"
    repeat=$((repeat + 1))
done
short_prompt=$output_directory/prompt-short.txt
printf 'Name three primary colors and stop.' >"$short_prompt"

refusals=0
for arm in $arms; do
    case $arm in
        full | full-close) arm_residency=full ;;
        tails | tails-close) arm_residency=tails ;;
    esac
    arm_directory=$output_directory/$arm
    mkdir -p "$arm_directory"
    if ! start_server "$arm_directory" "$arm_residency"; then
        record "arm:$arm" "refused server_unready"
        refusals=$((refusals + 1))
        stop_server
        continue
    fi
    record "arm:$arm:residency" "$arm_residency"
    record "arm:$arm:placement" "$(grep -E 'CUDA0 (model|KV|compute) buffer size' "$arm_directory/server.log" | sed 's/^.*CUDA0/CUDA0/' | sort | sha256sum | cut -c1-64)"

    # The long prompt: cut once per arm through this server's tokenizer so
    # every arm asks the same tokenizer the same question.
    long_prompt=$arm_directory/prompt-long.txt
    python3 "$helper" tokenize-body "$source_text" >"$arm_directory/tokenize-request.json"
    if ! post /tokenize "$arm_directory/tokenize-request.json" "$arm_directory/tokenize-response.json" ||
        ! python3 "$helper" cut-tokens "$arm_directory/tokenize-response.json" "$prompt_rows" >"$arm_directory/detokenize-request.json" ||
        ! post /detokenize "$arm_directory/detokenize-request.json" "$arm_directory/detokenize-response.json" ||
        ! python3 "$helper" detokenized-text "$arm_directory/detokenize-response.json" >"$long_prompt"; then
        record "arm:$arm" "refused prompt_cut"
        refusals=$((refusals + 1))
        stop_server
        continue
    fi
    record "arm:$arm:prompt_sha256" "$(sha256sum "$long_prompt" | cut -c1-64)"

    step_failed=''
    run_step() {
        # run_step LABEL PROMPT_FILE PREDICT
        step_label=$1
        step_directory=$arm_directory/$step_label
        mkdir -p "$step_directory"
        python3 "$helper" request "$2" "$3" >"$step_directory/request.json"
        if post /completion "$step_directory/request.json" "$step_directory/response.json" &&
            python3 "$helper" tokens "$step_directory/response.json" "$3" >"$step_directory/tokens.txt"; then
            record "arm:$arm:$step_label:tokens_sha256" "$(sha256sum "$step_directory/tokens.txt" | cut -c1-64)"
            record "arm:$arm:$step_label:prompt_n" "$(python3 "$helper" prompt_n "$step_directory/response.json")"
        else
            record "arm:$arm:$step_label" "refused request"
            step_failed=$step_label
        fi
    }
    slot_action() {
        # slot_action ACTION FILENAME LABEL
        printf '{"filename":"%s"}' "$2" >"$arm_directory/$3.json"
        if post "/slots/0?action=$1" "$arm_directory/$3.json" "$arm_directory/$3-response.json"; then
            record "arm:$arm:$3" completed
        else
            record "arm:$arm:$3" "refused $1"
            step_failed=$3
        fi
    }

    run_step a "$long_prompt" "$predict_tokens"
    [ -z "$step_failed" ] && slot_action save a.bin save-a
    [ -z "$step_failed" ] && [ -s "$arm_directory/slots/a.bin" ] && record "arm:$arm:state_a_sha256" "$(sha256sum "$arm_directory/slots/a.bin" | cut -c1-64)"
    [ -z "$step_failed" ] && slot_action erase - erase-a
    [ -z "$step_failed" ] && slot_action restore a.bin restore-a
    [ -z "$step_failed" ] && run_step b "$long_prompt" "$predict_tokens"
    [ -z "$step_failed" ] && run_step c "$short_prompt" 16
    [ -z "$step_failed" ] && run_step d "$long_prompt" "$predict_tokens"
    [ -z "$step_failed" ] && slot_action save d.bin save-d
    [ -z "$step_failed" ] && [ -s "$arm_directory/slots/d.bin" ] && record "arm:$arm:state_d_sha256" "$(sha256sum "$arm_directory/slots/d.bin" | cut -c1-64)"
    stop_server
    if [ -n "$step_failed" ]; then
        record "arm:$arm" "refused step=$step_failed"
        refusals=$((refusals + 1))
        continue
    fi

    # Inside one arm, A, B, and D are the same prompt under greedy decoding
    # before and after the save, erase, restore, removal, and regrowth.
    if cmp -s "$arm_directory/a/tokens.txt" "$arm_directory/b/tokens.txt" && cmp -s "$arm_directory/a/tokens.txt" "$arm_directory/d/tokens.txt"; then
        record "arm:$arm:replies_abd" identical
    else
        record "arm:$arm:replies_abd" divergent
        refusals=$((refusals + 1))
    fi
    if cmp -s "$arm_directory/slots/a.bin" "$arm_directory/slots/d.bin"; then
        record "arm:$arm:state_ad" identical
    else
        record "arm:$arm:state_ad" "differ"
    fi

    # The layout reader holds the log to its policy, with the bounds on the
    # tails arms.
    case $arm_residency in
        tails) reader_extra="--expect-residency tails --max-allocated-bytes $max_allocated_bytes --max-latency-median-us $max_median_us --max-latency-p95-us $max_p95_us" ;;
        *) reader_extra="--expect-residency full" ;;
    esac
    # shellcheck disable=SC2086
    if python3 "$script_directory/read-paged-kv-layout.py" "$arm_directory/server.log" --expect paged_kv_vmm \
        --expect-cells "$model_context" $reader_extra >"$output_directory/layout-$arm.tsv" 2>&1; then
        record "arm:$arm:layout" layout_holds
    else
        record "arm:$arm:layout" layout_refused
        refusals=$((refusals + 1))
    fi
    for key in residency_commits residency_reclaims residency_refusals kv_physical_allocated_max_bytes \
        kv_physical_allocated_final_bytes kv_physical_released_final_bytes memory_saved_bytes \
        commit_latency_us_median commit_latency_us_p95 commit_latency_us_max \
        reclaim_latency_us_median reclaim_latency_us_p95 reclaim_latency_us_max; do
        record "arm:$arm:$key" "$(awk -F'\t' -v k="$key" '$1 == k { print $2 }' "$output_directory/layout-$arm.tsv")"
    done
    # A tails arm at a prompt past the first K unit crossing (row 3856 on
    # the 2B layout) commits at load, at the restore, and at the regrowth,
    # and reclaims at the erase and at the short prompt's removal; fewer
    # transactions than that means a lifecycle step reached no boundary. A
    # prompt under the crossing crosses nothing by arithmetic, so a smoke run
    # at a short prompt turns the requirement off and the record says so.
    if [ "$arm_residency" = tails ]; then
        commits=$(awk -F'\t' '$1 == "residency_commits" { print $2 }' "$output_directory/layout-$arm.tsv")
        reclaims=$(awk -F'\t' '$1 == "residency_reclaims" { print $2 }' "$output_directory/layout-$arm.tsv")
        if [ "${commits:-0}" -ge 3 ] && [ "${reclaims:-0}" -ge 2 ]; then
            record "arm:$arm:lifecycle_boundaries" "crossed commits=$commits reclaims=$reclaims"
        elif [ "$require_boundaries" = 1 ]; then
            record "arm:$arm:lifecycle_boundaries" "under_expected commits=${commits:-0} reclaims=${reclaims:-0}"
            refusals=$((refusals + 1))
        else
            record "arm:$arm:lifecycle_boundaries" "not_required commits=${commits:-0} reclaims=${reclaims:-0}"
        fi
    fi
done
record clients_close "$(client_set)"

# Across arms: every reply and every saved state of the tails arm equals the
# fully backed null's, and the closing null equals the opening one.
first_full=''
for arm in $arms; do
    case $arm in full) first_full=$arm; break ;; esac
done
if [ -n "$first_full" ]; then
    for arm in $arms; do
        [ "$arm" != "$first_full" ] || continue
        [ -d "$output_directory/$arm/a" ] || continue
        arm_identical=yes
        for step in a b c d; do
            cmp -s "$output_directory/$first_full/$step/tokens.txt" "$output_directory/$arm/$step/tokens.txt" || arm_identical=no
        done
        for state in a d; do
            cmp -s "$output_directory/$first_full/slots/$state.bin" "$output_directory/$arm/slots/$state.bin" || arm_identical=no
        done
        record "identity:$first_full:$arm" "$arm_identical"
        [ "$arm_identical" = yes ] || refusals=$((refusals + 1))
    done
fi
record refusals "$refusals"
if [ "$refusals" -eq 0 ]; then
    record verdict lifecycle_holds
else
    record verdict lifecycle_refused
fi

# The saved states are compared above and their digests recorded; the bytes
# themselves are 38 MiB per file and leave unless a caller keeps them. Every
# retained text file then has the home prefix replaced with $HOME and any
# link address with <mac>, the way the identity harness closes its run.
if [ "${QWEN_RESIDENCY_KEEP_STATE:-0}" != 1 ]; then
    find "$output_directory" -path '*/slots/*.bin' -type f -exec rm -f {} +
fi
find "$output_directory" -type f \( -name '*.txt' -o -name '*.json' -o -name '*.log' \
    -o -name '*.tsv' -o -name '*.stdout' -o -name '*.stderr' \) \
    -exec sed -i -E \
        -e "s#${HOME:?}#\$HOME#g" \
        -e 's/([0-9A-Fa-f]{2}:){5,}[0-9A-Fa-f]{2}/<mac>/g' \
        -e 's/[[:space:]]+$//' {} +
[ "$refusals" -eq 0 ]
