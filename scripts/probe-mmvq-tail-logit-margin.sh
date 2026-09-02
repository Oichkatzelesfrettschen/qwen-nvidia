#!/bin/sh
set -eu

# A reply that differs between two closures at one position is two argmax
# reads of two logit vectors, and the distance between the top candidates is
# what says whether the kernels disagree by rounding or by value. This probe
# serves one model on both closures the way run-mmvq-width-request-tails.sh
# does, cuts the same prose file to the same 512+B, 1024+B, and 2048+B
# prompts, and asks each server for the top four log-probabilities at one
# named position per prompt, so a divergent pair reports its margin in nats
# beside the two chosen ids, and an identical pair reports two equal vectors.

usage() {
    printf 'usage: %s CONTROL_SERVER SUBJECT_SERVER MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'environment: QWEN_MARGIN_PROBES   "BASE+WIDTH:POSITION ..." default "2048+19:0 1024+19:21 512+19:31 2048+20:0"\n' >&2
    printf '             QWEN_TAIL_PASSAGE    prose file the prompts are cut from, default CLAUDE.md\n' >&2
    printf '             QWEN_TAIL_PORT       control port, subject at +1, default 18150\n' >&2
    printf '             QWEN_MODEL_ROOT      default $HOME/models\n' >&2
    exit 2
}
[ "$#" -eq 4 ] || usage
control_server=$1
subject_server=$2
model_id=$3
output_directory=$4
[ -x "$control_server" ] && [ -x "$subject_server" ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
probes=${QWEN_MARGIN_PROBES:-"2048+19:0 1024+19:21 512+19:31 2048+20:0"}
port=${QWEN_TAIL_PORT:-18150}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
passage=${QWEN_TAIL_PASSAGE:-"$script_directory/../CLAUDE.md"}
[ -r "$passage" ] || {
    printf 'passage file is not readable: %s\n' "$passage" >&2
    exit 2
}
wrapper=$script_directory/cuda-runtime-env.sh

row=$("$script_directory/model-registry.sh" id "$model_id")
field() { printf '%s\n' "$row" | sed -n "s/^$1=//p"; }
model_path=$model_root/$(field model_file)
cache_type_k=$(field cache_type_k)
cache_type_v=$(field cache_type_v)
flash_attention=$(field flash_attention)
batch=$(field batch)
ubatch=$(field ubatch)

mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
scrub_home <"$output_directory/ownership.txt.raw" >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"

control_pid=''
subject_pid=''
cleanup() {
    for pid in "$control_pid" "$subject_pid"; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    control_pid=''
    subject_pid=''
}
trap cleanup EXIT HUP INT TERM
serve() {
    # serve SERVER PORT LOG; sets served_pid
    QWEN_CUDA_PROFILE=default "$wrapper" "$1" \
        --model "$model_path" --alias "$model_id" --host 127.0.0.1 --port "$2" --no-ui \
        --device CUDA0 --split-mode none --n-gpu-layers all --override-tensor '.*=CUDA0' \
        --fit off --parallel 1 --threads 6 --threads-batch 6 --ctx-size 4096 \
        --batch-size "$batch" --ubatch-size "$ubatch" \
        --cache-type-k "$cache_type_k" --cache-type-v "$cache_type_v" \
        --flash-attn "$flash_attention" \
        --cache-ram 0 --ctx-checkpoints 0 --no-context-shift --no-warmup -lv 10 \
        >"$3" 2>&1 9>&- &
    served_pid=$!
}
ready() {
    # ready PORT PID LOG
    attempt=0
    while [ "$attempt" -lt 3000 ]; do
        if grep -q 'CUDA0 model buffer size' "$3" && grep -q 'listening on' "$3" &&
            curl --silent --fail "http://127.0.0.1:$1/health" >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$2" 2>/dev/null || break
        attempt=$((attempt + 1))
        sleep 0.1
    done
    printf 'server on port %s did not become ready with a CUDA0 model buffer\n' "$1" >&2
    return 1
}
control_port=$port
subject_port=$((port + 1))
serve "$control_server" "$control_port" "$output_directory/control.server.log.raw"
control_pid=$served_pid
ready "$control_port" "$control_pid" "$output_directory/control.server.log.raw"
serve "$subject_server" "$subject_port" "$output_directory/subject.server.log.raw"
subject_pid=$served_pid
ready "$subject_port" "$subject_pid" "$output_directory/subject.server.log.raw"
for server in "$control_server" "$subject_server"; do
    printf '%s\t%s\n' "$(sha256sum "$server" | cut -d ' ' -f 1)" "$(printf '%s' "$server" | scrub_home)"
done >"$output_directory/server-digests.tsv"
printf '%s\t%s\n' "$(sha256sum "$passage" | cut -d ' ' -f 1)" "$(printf '%s' "$passage" | scrub_home)" \
    >"$output_directory/passage-digest.tsv"

QWEN_MARGIN_CONTROL_PORT=$control_port QWEN_MARGIN_SUBJECT_PORT=$subject_port \
QWEN_MARGIN_PROBES_RESOLVED="$probes" QWEN_MARGIN_PASSAGE_RESOLVED=$passage \
    python3 - >"$output_directory/logit-margins.tsv" <<'PYTHON'
import json
import os
import urllib.request

ports = {"control": os.environ["QWEN_MARGIN_CONTROL_PORT"], "subject": os.environ["QWEN_MARGIN_SUBJECT_PORT"]}


def post(arm, route, body):
    request = urllib.request.Request(f"http://127.0.0.1:{ports[arm]}{route}",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=600))


passage = open(os.environ["QWEN_MARGIN_PASSAGE_RESOLVED"], encoding="utf-8").read()
tokens = post("control", "/tokenize", {"content": passage, "add_special": False})["tokens"]
print("base\twidth\tposition\tarm\tchosen_id\ttop_ids\ttop_logprobs\tmargin_nats")
for probe in os.environ["QWEN_MARGIN_PROBES_RESOLVED"].split():
    length, position = probe.split(":")
    base, width = (int(v) for v in length.split("+"))
    position = int(position)
    prompt = post("control", "/detokenize", {"tokens": tokens[:base + width]})["content"]
    for arm in ("control", "subject"):
        reply = post(arm, "/completion", {"prompt": prompt, "n_predict": position + 1, "temperature": 0,
                                          "top_k": 1, "seed": 1, "cache_prompt": False,
                                          "return_tokens": True, "n_probs": 4})
        probabilities = reply["completion_probabilities"][position]
        top = probabilities["top_logprobs"][:4]
        margin = top[0]["logprob"] - top[1]["logprob"]
        print("\t".join(str(v) for v in (base, width, position, arm, probabilities["id"],
            " ".join(str(c["id"]) for c in top), " ".join(f"{c['logprob']:.4f}" for c in top), f"{margin:.4f}")))
PYTHON
cleanup
for name in control subject; do
    scrub_home <"$output_directory/$name.server.log.raw" | sed '/listening on/q' >"$output_directory/$name.server.load.log"
    rm -f "$output_directory/$name.server.log.raw"
done
trap - EXIT HUP INT TERM
cat "$output_directory/logit-margins.tsv"
