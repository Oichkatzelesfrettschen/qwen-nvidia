#!/bin/sh
set -eu

# The runtime dispatch census. One llama-server per arm, built from the
# diagnostic closure that carries patches/llama-cuda-dispatch-census.patch, runs
# under GGML_CUDA_DISPATCH_CENSUS so every mat-mul launch records the path it
# took -- MMVQ, MMQ, MMVF, MMF, or one of the four cuBLAS entries -- with the
# tensor it multiplied, its types, shape, and strides, one row per distinct
# shape per graph compute. A text arm answers one completion whose prompt is
# trimmed to exactly QWEN_CENSUS_PREFILL tokens through /tokenize and
# /detokenize and decodes QWEN_CENSUS_GENERATE tokens, so the prefill and the
# decode populations are one request read by the row's own ne11. A vision arm
# loads its projector and answers three chat requests: text alone, the fixture
# image cold, and the same image again warm, at QWEN_CENSUS_VISION_GENERATE
# tokens each, so the difference between the first and the second isolates
# the encoder and projector population and the third separates first-use
# initialization from steady dispatch. Every request runs with the prompt
# cache off, since a cached image prefix would skip the encoder the arm exists
# to count. requests.tsv carries each request's wall-clock window and the
# server's own timings, and summarize-dispatch-census.py joins the census rows
# to those windows.
#
# The harness measures no rate. The counter costs a map insertion per launch
# and a file append per graph, so the timings the server reports here belong
# to the instrumented closure alone and populate no registry field.
#
# The device is owned through gpu-workload-ownership.sh for the whole run and
# the client set is read before and after every arm as the covariate this
# workstation always carries; a browser or Discord GPU process is recorded
# rather than refused.

usage() {
    printf 'usage: %s OUTPUT_DIRECTORY [ARM_ID ...]\n' "$0" >&2
    printf 'arms: T0 qwen35-08b, T1 qwen35-08b-f16, T2 qwen35-08b-bf16,\n' >&2
    printf '      T3 qwen38-2b-distill, T4 qwen38-4b-distill, T5 qwen38-9b-distill,\n' >&2
    printf '      V0 lfm25-vl-450m, V1 lfm25-vl-16b, V2 qwen35-4b-base\n' >&2
    printf 'environment: QWEN_LLAMA_SERVER  llama-server of a closure carrying the census hooks\n' >&2
    printf '             QWEN_MODEL_ROOT    default $HOME/models\n' >&2
    printf '             QWEN_CENSUS_PORT   default 18110\n' >&2
    printf '             QWEN_CENSUS_CONTEXT default 8192\n' >&2
    printf '             QWEN_CENSUS_PREFILL default 512, QWEN_CENSUS_GENERATE default 64\n' >&2
    printf '             QWEN_CENSUS_VISION_GENERATE default 32\n' >&2
    printf '             QWEN_CENSUS_IMAGE  default scripts/quality-images/bars.png\n' >&2
    exit 2
}
[ "$#" -ge 1 ] || usage
output_directory=$1
shift
arms=${*:-T0 T1 T2 T3 T4 T5 V0 V1 V2}

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
llama_server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-a925c84db3a2/bin/llama-server"}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
port=${QWEN_CENSUS_PORT:-18110}
context=${QWEN_CENSUS_CONTEXT:-8192}
prefill_tokens=${QWEN_CENSUS_PREFILL:-512}
generate_tokens=${QWEN_CENSUS_GENERATE:-64}
vision_generate_tokens=${QWEN_CENSUS_VISION_GENERATE:-32}
image=${QWEN_CENSUS_IMAGE:-$script_directory/quality-images/bars.png}
threads=${QWEN_CENSUS_THREADS:-6}
wrapper=$script_directory/cuda-runtime-env.sh
sampler=$script_directory/sample-nvidia-clocks.sh

[ -x "$llama_server" ] || { printf 'llama-server is not executable: %s\n' "$llama_server" >&2; exit 2; }
[ -f "$image" ] || { printf 'image fixture is absent: %s\n' "$image" >&2; exit 2; }
# The production closure carries no hook, so a census run against it would
# retain an empty file and read as a population of zero. The symbol is the
# proof the closure is the instrumented one.
closure_library=$(dirname -- "$llama_server")/libggml-cuda.so
if ! nm -D "$closure_library" 2>/dev/null | grep -q ggml_cuda_dispatch_census_record; then
    printf 'closure carries no dispatch census hook: %s\n' "$closure_library" >&2
    exit 2
fi

model_of_arm() {
    case $1 in
        T0) printf 'qwen35-08b\n' ;;
        T1) printf 'qwen35-08b-f16\n' ;;
        T2) printf 'qwen35-08b-bf16\n' ;;
        T3) printf 'qwen38-2b-distill\n' ;;
        T4) printf 'qwen38-4b-distill\n' ;;
        T5) printf 'qwen38-9b-distill\n' ;;
        V0) printf 'lfm25-vl-450m\n' ;;
        V1) printf 'lfm25-vl-16b\n' ;;
        V2) printf 'qwen35-4b-base\n' ;;
        *) printf 'unknown arm: %s\n' "$1" >&2; return 1 ;;
    esac
}

mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
now_ns() { date +%s%N; }

. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership-run.txt"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"

server_pid=""
sampler_pid=""
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if [ -n "$sampler_pid" ]; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

post_json() {
    curl --silent --show-error --max-time 600 -H 'Content-Type: application/json' \
        --data-binary @- "http://127.0.0.1:$port$1"
}

record_request() {
    # request_id label t_start t_end reply_path
    python3 - "$arm_requests" "$1" "$2" "$3" "$4" "$5" <<'PYTHON'
import json
import sys

path, request_id, label, t_start, t_end, reply_path = sys.argv[1:7]
try:
    reply = json.load(open(reply_path, encoding="utf-8"))
except (OSError, ValueError):
    reply = {}
timings = reply.get("timings") or {}
status = "ok" if reply and "error" not in reply else "error"
content = reply.get("content")
if content is None and reply.get("choices"):
    content = reply["choices"][0].get("message", {}).get("content")
with open(path, "a", encoding="utf-8") as handle:
    handle.write("\t".join(str(v) for v in (
        request_id, label, t_start, t_end, status,
        timings.get("prompt_n", "-"), timings.get("predicted_n", "-"),
        timings.get("prompt_ms", "-"), timings.get("predicted_ms", "-"),
        len(content or ""))) + "\n")
PYTHON
}

chat_body() {
    # label max_tokens with_image
    python3 - "$1" "$2" "$3" "$image" <<'PYTHON'
import base64
import json
import mimetypes
import sys

text, max_tokens, with_image, image_path = sys.argv[1:5]
parts = [{"type": "text", "text": text}]
if with_image == "yes":
    media_type = mimetypes.guess_type(image_path)[0] or "image/png"
    with open(image_path, "rb") as handle:
        parts.append({"type": "image_url", "image_url": {
            "url": f"data:{media_type};base64," + base64.b64encode(handle.read()).decode()}})
print(json.dumps({
    "messages": [{"role": "user", "content": parts}],
    "max_tokens": int(max_tokens), "temperature": 0, "top_k": 1, "seed": 1,
    "cache_prompt": False, "chat_template_kwargs": {"enable_thinking": False}}))
PYTHON
}

run_request() {
    # request_id label route body_file
    request_reply=$arm_directory/$1.reply.json
    t_start=$(now_ns)
    post_json "$3" <"$4" >"$request_reply" || :
    t_end=$(now_ns)
    record_request "$1" "$2" "$t_start" "$t_end" "$request_reply"
}

printf 'arm\tmodel_id\tmodel_file\tprojector\trequests\tcensus_rows\tstatus\n' >"$output_directory/arms.tsv"

for arm in $arms; do
    model_id=$(model_of_arm "$arm")
    arm_directory=$output_directory/$arm-$model_id
    mkdir -p "$arm_directory"
    arm_requests=$arm_directory/requests.tsv
    printf 'request_id\tlabel\tt_start_ns\tt_end_ns\tstatus\tprompt_n\tpredicted_n\tprompt_ms\tpredicted_ms\tcontent_chars\n' >"$arm_requests"

    row=$("$script_directory/model-registry.sh" id "$model_id")
    printf '%s\n' "$row" >"$arm_directory/registry-row.txt"
    field() { printf '%s\n' "$row" | sed -n "s/^$1=//p"; }
    model_path=$model_root/$(field model_file)
    cache_type_k=$(field cache_type_k)
    cache_type_v=$(field cache_type_v)
    flash_attention=$(field flash_attention)
    batch=$(field batch)
    ubatch=$(field ubatch)
    projector_state=$(field projector)
    projector_path=-
    if [ "$projector_state" = required ]; then
        projector_path=$("$script_directory/select-projector.sh" "$model_path")
        if [ -z "$projector_path" ]; then
            printf '%s: projector unresolved for %s\n' "$arm" "$model_id" >&2
            printf '%s\t%s\t%s\t-\t0\t0\tprojector-unresolved\n' "$arm" "$model_id" "$(field model_file)" >>"$output_directory/arms.tsv"
            continue
        fi
    fi

    gpu_ownership_inspect >"$arm_directory/ownership-before.raw" 2>&1 || :
    scrub_home <"$arm_directory/ownership-before.raw" >"$arm_directory/ownership-before.txt"
    rm -f "$arm_directory/ownership-before.raw"
    "$sampler" "$arm_directory/clocks.tsv" 1 >/dev/null 2>&1 9>&- &
    sampler_pid=$!

    census_file=$arm_directory/census.tsv
    rm -f "$census_file"
    server_log=$arm_directory/server.log
    t_launch=$(now_ns)
    set -- --model "$model_path"
    [ "$projector_path" = - ] || set -- "$@" --mmproj "$projector_path"
    GGML_CUDA_DISPATCH_CENSUS=$census_file QWEN_CUDA_PROFILE=default \
        "$wrapper" "$llama_server" "$@" \
        --alias "$model_id" --host 127.0.0.1 --port "$port" --no-ui \
        --device CUDA0 --split-mode none --n-gpu-layers all \
        --override-tensor '.*=CUDA0' --fit off --parallel 1 \
        --threads "$threads" --threads-batch "$threads" \
        --ctx-size "$context" --batch-size "$batch" --ubatch-size "$ubatch" \
        --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
        --flash-attn "$flash_attention" \
        --cache-ram 0 --ctx-checkpoints 0 --no-context-shift --no-warmup \
        >"$server_log.raw" 2>&1 9>&- &
    server_pid=$!
    ready=0
    attempt=0
    while [ "$attempt" -lt 1800 ]; do
        if curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
            ready=1
            break
        fi
        kill -0 "$server_pid" 2>/dev/null || break
        attempt=$((attempt + 1))
        sleep 0.1
    done
    t_ready=$(now_ns)
    if [ "$ready" -ne 1 ]; then
        printf '%s: server did not become ready\n' "$arm" >&2
        arm_status=load-failed
    else
        printf 'load_ns=%s\n' "$((t_ready - t_launch))" >"$arm_directory/load.txt"
        case $arm in
            T*)
                # Trim a long passage to exactly the requested prefill length.
                python3 - "$port" "$prefill_tokens" >"$arm_directory/prompt.txt" <<'PYTHON'
import json
import sys
import urllib.request

port, want = sys.argv[1], int(sys.argv[2])
passage = ("The measurement runs on one card shared with a desktop, so every rate "
           "carries the compositor as a covariate rather than as a condition to "
           "exclude. A prefill of five hundred and twelve tokens fills one micro-batch "
           "exactly, and the decode that follows streams the weights once per token. ") * 40

def post(route, body):
    request = urllib.request.Request(f"http://127.0.0.1:{port}{route}",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=120))

tokens = post("/tokenize", {"content": passage, "add_special": False})["tokens"]
if len(tokens) < want:
    raise SystemExit(f"passage tokenizes to {len(tokens)} < {want}")
print(post("/detokenize", {"tokens": tokens[:want]})["content"], end="")
PYTHON
                python3 - "$arm_directory/prompt.txt" "$generate_tokens" >"$arm_directory/r1.body.json" <<'PYTHON'
import json
import sys

prompt = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"prompt": prompt, "n_predict": int(sys.argv[2]), "temperature": 0,
                  "top_k": 1, "seed": 1, "cache_prompt": False}))
PYTHON
                run_request r1 "text-pp${prefill_tokens}-tg${generate_tokens}" /completion "$arm_directory/r1.body.json"
                ;;
            V*)
                chat_body "Describe, in one sentence, what a bar chart of monthly totals would show." "$vision_generate_tokens" no >"$arm_directory/r1.body.json"
                chat_body "Which month has the tallest bar, and what is its value?" "$vision_generate_tokens" yes >"$arm_directory/r2.body.json"
                run_request r1 text-only /v1/chat/completions "$arm_directory/r1.body.json"
                run_request r2 cold-image /v1/chat/completions "$arm_directory/r2.body.json"
                run_request r3 warm-image /v1/chat/completions "$arm_directory/r2.body.json"
                ;;
        esac
        arm_status=ok
    fi

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    sampler_pid=""
    scrub_home <"$server_log.raw" >"$server_log"
    rm -f "$server_log.raw"
    gpu_ownership_inspect >"$arm_directory/ownership-after.raw" 2>&1 || :
    scrub_home <"$arm_directory/ownership-after.raw" >"$arm_directory/ownership-after.txt"
    rm -f "$arm_directory/ownership-after.raw"
    rm -f "$arm_directory"/*.body.json

    census_rows=$( [ -f "$census_file" ] && grep -c . "$census_file" || echo 0 )
    request_count=$(($(grep -c . "$arm_requests") - 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$arm" "$model_id" "$(field model_file)" \
        "$(printf '%s' "$projector_path" | scrub_home)" "$request_count" "$census_rows" "$arm_status" \
        >>"$output_directory/arms.tsv"
    printf 'arm=%s model=%s requests=%s census_rows=%s status=%s\n' \
        "$arm" "$model_id" "$request_count" "$census_rows" "$arm_status"
done

gpu_ownership_inspect >"$output_directory/ownership-end.raw" 2>&1 || :
scrub_home <"$output_directory/ownership-end.raw" >"$output_directory/ownership-end.txt"
rm -f "$output_directory/ownership-end.raw"
"$llama_server" --version 2>&1 | scrub_home >"$output_directory/server-version.txt"
python3 "$script_directory/summarize-dispatch-census.py" "$output_directory"
