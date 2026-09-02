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
#
# A margin is comparable between the two arms only where both reached the
# position under the same preceding token history. Each server is free-running
# under its own greedy sampler, so once the emitted ids differ the two logit
# vectors at a later position are conditioned on different prefixes and stop
# isolating kernel arithmetic: the probe compares tokens[:POSITION] across the
# arms and refuses the probe by name where they differ, naming the index the
# histories parted at beside the position that was asked for.

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
[ "$ubatch" -eq 512 ] || {
    printf 'the tail lengths assume ubatch 512; %s carries %s\n' "$model_id" "$ubatch" >&2
    exit 2
}

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
    # The scrub belongs to the teardown rather than to the success path, because
    # every refusal between the load and the margin table otherwise leaves a raw
    # log naming the home directory in the retained output. The loop skips a log
    # the run never wrote, so a refusal ahead of the second server still scrubs
    # the first.
    for name in control subject; do
        [ -f "$output_directory/$name.server.log.raw" ] || continue
        scrub_home <"$output_directory/$name.server.log.raw" | sed '/listening on/q' \
            >"$output_directory/$name.server.load.log"
        rm -f "$output_directory/$name.server.log.raw"
    done
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
# A margin read against a model the scheduler left partly on the host compares
# two host kernels rather than the two device closures the probe names, so the
# load banner is required to carry neither refusal line.
for name in control subject; do
    if grep -q 'CPU fallback rejected\|CPU_Mapped model buffer' "$output_directory/$name.server.log.raw"; then
        printf '%s server left a tensor on the host\n' "$name" >&2
        exit 1
    fi
done
for server in "$control_server" "$subject_server"; do
    printf '%s\t%s\n' "$(sha256sum "$server" | cut -d ' ' -f 1)" "$(printf '%s' "$server" | scrub_home)"
done >"$output_directory/server-digests.tsv"
printf '%s\t%s\n' "$(sha256sum "$passage" | cut -d ' ' -f 1)" "$(printf '%s' "$passage" | scrub_home)" \
    >"$output_directory/passage-digest.tsv"

QWEN_MARGIN_CONTROL_PORT=$control_port QWEN_MARGIN_SUBJECT_PORT=$subject_port \
QWEN_MARGIN_PROBES_RESOLVED="$probes" QWEN_MARGIN_PASSAGE_RESOLVED=$passage \
QWEN_MARGIN_TABLE_RESOLVED=$output_directory/logit-margins.tsv \
    python3 - <<'PYTHON'
import json
import os
import urllib.request

ports = {"control": os.environ["QWEN_MARGIN_CONTROL_PORT"], "subject": os.environ["QWEN_MARGIN_SUBJECT_PORT"]}


def post(arm, route, body):
    request = urllib.request.Request(f"http://127.0.0.1:{ports[arm]}{route}",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=600))


# One reply read under the five properties a margin comparison rests on: the
# sampled ids are present as integers, their count equals the predicted_n
# reported beside them, the named position exists, that position carries at
# least two candidates so a distance between the top two exists, and the id
# the sampler chose is among them. Each refusal names the arm and the probe,
# since a reply that fails any of them describes the reader rather than the
# kernel.
def read_position(arm, label, position, reply):
    generated = reply.get("tokens")
    if not isinstance(generated, list) or not all(isinstance(token, int) for token in generated):
        raise SystemExit(f"{label} {arm}: completion omitted the requested raw token list")
    predicted_n = (reply.get("timings") or {}).get("predicted_n")
    if not isinstance(predicted_n, int) or predicted_n < 0:
        raise SystemExit(f"{label} {arm}: completion omitted a valid predicted_n")
    if len(generated) != predicted_n:
        raise SystemExit(f"{label} {arm}: token-count mismatch: tokens={len(generated)} predicted_n={predicted_n}")
    probabilities = reply.get("completion_probabilities") or []
    if len(probabilities) <= position or len(generated) <= position:
        raise SystemExit(f"{label} {arm}: the reply is shorter than position {position}")
    at = probabilities[position]
    top = (at.get("top_logprobs") or [])[:4]
    if len(top) < 2:
        raise SystemExit(f"{label} {arm}: position {position} carries no top-candidate pair")
    chosen = at.get("id")
    if chosen not in [candidate.get("id") for candidate in top]:
        raise SystemExit(f"{label} {arm}: the chosen id {chosen} is absent from the candidates at position {position}")
    return generated, chosen, top


passage = open(os.environ["QWEN_MARGIN_PASSAGE_RESOLVED"], encoding="utf-8").read()
tokens = post("control", "/tokenize", {"content": passage, "add_special": False})["tokens"]
rows = []
for probe in os.environ["QWEN_MARGIN_PROBES_RESOLVED"].split():
    length, position = probe.split(":")
    base, width = (int(v) for v in length.split("+"))
    position = int(position)
    label = f"{base}+{width}:{position}"
    prompt = post("control", "/detokenize", {"tokens": tokens[:base + width]})["content"]
    read = {}
    for arm in ("control", "subject"):
        reply = post(arm, "/completion", {"prompt": prompt, "n_predict": position + 1, "temperature": 0,
                                          "top_k": 1, "seed": 1, "cache_prompt": False,
                                          "return_tokens": True, "n_probs": 4})
        read[arm] = read_position(arm, label, position, reply)
    control_ids, subject_ids = read["control"][0], read["subject"][0]
    parted = [index for index in range(position)
              if control_ids[index] != subject_ids[index]]
    if parted:
        raise SystemExit(f"{label}: the histories parted at index {parted[0]}, so position {position} "
                         "compares two vectors conditioned on different prefixes")
    divergent = str(position) if control_ids[position] != subject_ids[position] else "-"
    row = [base, width, position, divergent]
    for arm in ("control", "subject"):
        _, chosen, top = read[arm]
        row += [chosen, " ".join(str(candidate["id"]) for candidate in top),
                " ".join(f"{candidate['logprob']:.4f}" for candidate in top),
                f"{top[0]['logprob'] - top[1]['logprob']:.4f}"]
    rows.append(row)

with open(os.environ["QWEN_MARGIN_TABLE_RESOLVED"], "w", encoding="utf-8") as table:
    table.write("base\twidth\tposition\tdivergent_at\tcontrol_chosen_id\tcontrol_top_ids\t"
                "control_top_logprobs\tcontrol_margin_nats\tsubject_chosen_id\tsubject_top_ids\t"
                "subject_top_logprobs\tsubject_margin_nats\n")
    for row in rows:
        table.write("\t".join(str(value) for value in row) + "\n")
PYTHON
cleanup
trap - EXIT HUP INT TERM
cat "$output_directory/logit-margins.tsv"
