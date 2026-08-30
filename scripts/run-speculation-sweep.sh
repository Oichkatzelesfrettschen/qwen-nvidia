#!/bin/sh
set -eu

# Measure served decode with and without speculation, one llama-server per arm.
#
# llama-bench holds no draft model, so speculation is measured through the
# server that runs it: each arm loads a target, optionally a draft, answers the
# same prompts at temperature 0 with a fixed reply budget, and reports the rate
# llama-server itself timed. Greedy sampling makes the accepted-token count a
# property of the two models and the prompt rather than of a seed.
#
# Content decides acceptance, so the prompt set spans three registers -- prose
# continuation, code, and arithmetic reasoning -- and every arm answers all
# three. A single-prompt speedup states what one draft distribution did on one
# text.
#
# The falsifier the sweep is built around: speculation pays where decode is
# bound by the target's weight traffic and the draft's proposals are usually
# accepted. This device holds about 500 GB/s against the 34 GB/s the APU tree
# measured, and a 2B target already decodes above 200 tok/s here, so the draft's
# own forward passes and the verification batch may cost more than the target's
# saved passes. An arm that decodes slower than its baseline is the finding
# rather than a failure.
#
# Residency is the other constraint a paired arm can fail on: the target, the
# draft, and both KV caches share one 12 GiB carve-out with the desktop, so
# every arm records the device occupancy its own run reached.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY TARGET_MODEL [DRAFT_MODEL]\n' "$0" >&2
    printf '  QWEN_SPEC_ARMS       arm list, default baseline draft2 draft4 draft8 mtp ngram\n' >&2
    printf '  QWEN_SERVER_PORT     listener, default 8199\n' >&2
    printf '  QWEN_SPEC_PREDICT    reply tokens per prompt, default 256\n' >&2
    printf '  QWEN_SPEC_CONTEXT    context depth, default 8192\n' >&2
    printf '  QWEN_CACHE_TYPE_K    K cache type, default q8_0\n' >&2
    printf '  QWEN_CACHE_TYPE_V    V cache type, default q4_0\n' >&2
    printf '  QWEN_LLAMA_SERVER    llama-server built with CUDA\n' >&2
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

output_directory=$1
target_model=$2
draft_model=${3:-}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-server"}
clock_sampler=${QWEN_CLOCK_SAMPLER:-"$script_directory/sample-nvidia-clocks.sh"}
server_port=${QWEN_SERVER_PORT:-8199}
predict_tokens=${QWEN_SPEC_PREDICT:-256}
context_depth=${QWEN_SPEC_CONTEXT:-8192}
cache_type_k=${QWEN_CACHE_TYPE_K:-q8_0}
cache_type_v=${QWEN_CACHE_TYPE_V:-q4_0}
arms=${QWEN_SPEC_ARMS:-'baseline draft2 draft4 draft8 mtp ngram'}
readiness_seconds=${QWEN_SPEC_READINESS_SECONDS:-180}

[ -x "$server" ] || {
    printf 'llama-server is absent or not executable: %s\n' "$server" >&2
    exit 2
}
[ -f "$target_model" ] || {
    printf 'target model is absent: %s\n' "$target_model" >&2
    exit 2
}
if [ -n "$draft_model" ] && [ ! -f "$draft_model" ]; then
    printf 'draft model is absent: %s\n' "$draft_model" >&2
    exit 2
fi
command -v curl >/dev/null 2>&1 || {
    printf 'curl is absent from PATH\n' >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is absent from PATH\n' >&2
    exit 1
}
if pgrep -x llama-server >/dev/null 2>&1 || pgrep -x llama-bench >/dev/null 2>&1; then
    printf 'another llama process holds the device\n' >&2
    exit 2
fi

mkdir -p "$output_directory"
summary=$output_directory/speculation-summary.tsv
printf 'arm\tspec_type\tdraft_n_max\tprompt_id\tprompt_tok_s\tdecode_tok_s\tpredicted_n\tunique_4gram_ratio\tvram_peak_mib\tstatus\n' \
    >"$summary"

target_id=$(basename "$target_model" .gguf)
draft_id=${draft_model:+$(basename "$draft_model" .gguf)}
printf 'sweep_start_utc=%s target=%s draft=%s depth=%s predict=%s cache=%s/%s arms=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target_id" "${draft_id:--}" \
    "$context_depth" "$predict_tokens" "$cache_type_k" "$cache_type_v" \
    "$arms" | tee "$output_directory/sweep-metadata.txt"

# The three registers a draft model succeeds or fails on separately. Each is one
# line so the request body is assembled without a here-document per arm.
prompt_prose='Continue this paragraph in the same register, about 150 words: The harbour emptied at dusk, and the crane operators walked home along the seawall.'
prompt_code='Write a POSIX shell function that reads a TSV file on standard input and prints the mean of the third column, refusing a row whose third field is not numeric. Explain each line briefly.'
prompt_math='A train leaves at 09:14 travelling 78 km/h and a second leaves the same station at 09:41 travelling 104 km/h on the same track. Work out step by step when and where the second catches the first.'

server_pid=''
sampler_pid=''
stop_arm() {
    if [ -n "$sampler_pid" ]; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
        sampler_pid=''
    fi
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=''
    fi
}
trap 'stop_arm' EXIT
trap 'stop_arm; exit 130' INT
trap 'stop_arm; exit 143' TERM

sweep_failed=0

# One request, one reply, and the server's own timings. Non-streamed so the
# whole timing object arrives in the response body rather than in a final SSE
# frame, and cache_prompt off so an arm's first prompt is charged the same
# prefill as its later ones.
request_rate() {
    request_prompt=$1
    request_output=$2
    python3 - "$server_port" "$predict_tokens" "$request_output" <<'PYTHON' "$request_prompt"
import json
import sys
import urllib.error
import urllib.request

port, predict, output_path, prompt = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
body = json.dumps({
    "prompt": prompt,
    "n_predict": predict,
    "temperature": 0,
    "top_k": 1,
    "cache_prompt": False,
    "stream": False,
}).encode()
request = urllib.request.Request(
    f"http://127.0.0.1:{port}/completion",
    data=body,
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=900) as response:
        payload = json.load(response)
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as failure:
    print(f"request_failed={failure}", file=sys.stderr)
    sys.exit(1)
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=1)
timings = payload.get("timings", {})

# A greedy 256-token continuation can enter a loop, and a looping reply is
# exactly what an n-gram drafter predicts perfectly. The fraction of distinct
# 4-grams in the reply separates a real acceptance rate from a degenerate one,
# so it travels beside the rate rather than being inferred from it.
words = payload.get("content", "").split()
grams = [tuple(words[i:i + 4]) for i in range(max(0, len(words) - 3))]
unique_ratio = "%.4f" % (len(set(grams)) / len(grams)) if grams else "n/a"
print("%s\t%s\t%s\t%s" % (
    timings.get("prompt_per_second", "n/a"),
    timings.get("predicted_per_second", "n/a"),
    timings.get("predicted_n", "n/a"),
    unique_ratio,
))
PYTHON
}

run_arm() {
    arm_label=$1
    spec_type=$2
    draft_n_max=$3
    arm_directory=$output_directory/$arm_label
    mkdir -p "$arm_directory"
    server_log=$arm_directory/server.log
    arm_samples=$arm_directory/clocks.tsv

    set -- --model "$target_model" --port "$server_port" --host 127.0.0.1 \
        --n-gpu-layers 99 --ctx-size "$context_depth" --flash-attn on \
        --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
        --threads 6 --no-warmup --jinja
    if [ "$spec_type" != none ]; then
        set -- "$@" --spec-type "$spec_type" --spec-draft-n-max "$draft_n_max"
    fi
    case $spec_type in
        draft-simple)
            set -- "$@" --spec-draft-model "$draft_model" --spec-draft-ngl 99
            ;;
    esac

    printf 'arm_start_utc=%s arm=%s spec_type=%s n_max=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$spec_type" "$draft_n_max"

    "$clock_sampler" "$arm_samples" 1 &
    sampler_pid=$!
    "$server" "$@" >"$server_log" 2>&1 &
    server_pid=$!

    arm_status=ready
    waited=0
    while :; do
        if curl --silent --fail --max-time 2 \
            "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            break
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            arm_status=server_exited
            break
        fi
        if [ "$waited" -ge "$readiness_seconds" ]; then
            arm_status=readiness_timeout
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    for prompt_id in prose code math; do
        case $prompt_id in
            prose) prompt_text=$prompt_prose ;;
            code)  prompt_text=$prompt_code ;;
            math)  prompt_text=$prompt_math ;;
        esac
        if [ "$arm_status" != ready ]; then
            printf '%s\t%s\t%s\t%s\tn/a\tn/a\tn/a\tn/a\tn/a\t%s\n' \
                "$arm_label" "$spec_type" "$draft_n_max" "$prompt_id" \
                "$arm_status" >>"$summary"
            sweep_failed=1
            continue
        fi
        set +e
        rates=$(request_rate "$prompt_text" "$arm_directory/$prompt_id.json" \
            2>>"$arm_directory/request.err")
        request_status=$?
        set -e
        if [ "$request_status" -ne 0 ] || [ -z "$rates" ]; then
            printf '%s\t%s\t%s\t%s\tn/a\tn/a\tn/a\tn/a\tn/a\trequest_failed\n' \
                "$arm_label" "$spec_type" "$draft_n_max" "$prompt_id" >>"$summary"
            sweep_failed=1
            continue
        fi
        vram_peak=$(awk -F'\t' '$7 ~ /^[0-9]+$/ && $7 + 0 > peak { peak = $7 + 0 }
            END { print (peak ? peak : "unavailable") }' "$arm_samples")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$arm_label" "$spec_type" "$draft_n_max" "$prompt_id" "$rates" \
            "$vram_peak" | awk -F'\t' 'BEGIN { OFS = "\t" }
            { print $1, $2, $3, $4, $5, $6, $7, $8, $9, "ok" }' >>"$summary"
    done

    # The acceptance counters live in the server's own log rather than in the
    # response body, so the arm keeps its log and reports what it found.
    accepted=$(grep -aiE 'n_accept|accept.*=' "$server_log" | tail -3 || true)
    [ -z "$accepted" ] || printf 'arm=%s acceptance: %s\n' "$arm_label" \
        "$(printf '%s' "$accepted" | tr '\n' ' ')"

    stop_arm
    printf 'arm_stop_utc=%s arm=%s status=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$arm_label" "$arm_status"
}

for arm in $arms; do
    case $arm in
        baseline) run_arm baseline none 0 ;;
        draft2 | draft4 | draft8)
            if [ -z "$draft_model" ]; then
                printf 'arm %s needs a draft model and none was named\n' "$arm" >&2
                sweep_failed=1
                continue
            fi
            run_arm "$arm" draft-simple "${arm#draft}"
            ;;
        mtp)    run_arm mtp draft-mtp 1 ;;
        ngram)  run_arm ngram ngram-simple 4 ;;
        *)
            printf 'arm outside the vocabulary: %s\n' "$arm" >&2
            exit 2
            ;;
    esac
done

printf '\nper-arm means over the three prompts:\n'
# The per-prompt rates are printed beside the mean because one degenerate reply
# moves a three-prompt mean by more than any arm here separates.
awk -F'\t' 'NR > 1 && $10 == "ok" {
        decode[$1] += $6; prompt_rate[$1] += $5; count[$1]++
        vram[$1] = ($9 + 0 > vram[$1] ? $9 + 0 : vram[$1])
        spec[$1] = $2 "/" $3
        rate[$1 "/" $4] = $6
        unique[$1 "/" $4] = $8
    }
    END {
        printf "%-12s %-22s %12s %12s %10s %28s %22s\n", "arm", "spec_type/n_max",
            "prompt_t/s", "decode_t/s", "vram_mib", "decode by prose/code/math",
            "unique 4-gram ratio"
        for (arm in count) {
            printf "%-12s %-22s %12.2f %12.2f %10d %9.1f %9.1f %8.1f %7s %7s %6s\n",
                arm, spec[arm], prompt_rate[arm] / count[arm],
                decode[arm] / count[arm], vram[arm],
                rate[arm "/prose"], rate[arm "/code"], rate[arm "/math"],
                unique[arm "/prose"], unique[arm "/code"], unique[arm "/math"]
        }
    }' "$summary" | tee "$output_directory/arm-means.txt"

printf 'sweep_stop_utc=%s failed=%s summary=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sweep_failed" "$summary"
exit "$sweep_failed"
