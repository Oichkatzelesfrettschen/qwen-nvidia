#!/bin/sh
set -eu

# A llama-bench crossover measures one micro-batch in isolation. This harness
# asks the served path the same question as pairs: two closures that differ in
# one dispatch threshold serve the same model at once, each through its own
# llama-server on its own port at the served tuple, and every prompt length is
# answered by both in alternating order, control then subject on odd repeats
# and subject then control on even ones, so drift and order bias cancel
# inside the pair. A prompt of 512+B, 1024+B, or 2048+B fills whole ubatches
# of 512 and leaves a tail of B columns, which is where a threshold acts
# inside a request. The first request at each length on each server is the
# uncounted warm-up, since a kernel instantiation the process has never
# launched pays its module load on first use. The reply tokens have to agree
# between the closures at every length, and the server's own prompt_ms and
# predicted_ms are the request-level prefill and decode costs. The SM clock
# is pinned for the campaign where QWEN_TAIL_LOCK_CLOCKS names it, because a
# thirty-millisecond request on an idle card measures the clock ramp.

usage() {
    printf 'usage: %s CONTROL_SERVER SUBJECT_SERVER MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf 'environment: QWEN_TAIL_WIDTHS       default "19 20"\n' >&2
    printf '             QWEN_TAIL_BASES        default "512 1024 2048"\n' >&2
    printf '             QWEN_TAIL_PAIRS        default 10\n' >&2
    printf '             QWEN_TAIL_PREDICT      default 32\n' >&2
    printf '             QWEN_TAIL_FLOOR        paired-gain floor, default 0.051\n' >&2
    printf '             QWEN_TAIL_PORT         control port, subject at +1, default 18120\n' >&2
    printf '             QWEN_TAIL_LOCK_CLOCKS  SM MHz to pin through sudo -n nvidia-smi, default unset\n' >&2
    printf '             QWEN_MODEL_ROOT        default $HOME/models\n' >&2
    exit 2
}
[ "$#" -eq 4 ] || usage
control_server=$1
subject_server=$2
model_id=$3
output_directory=$4
[ -x "$control_server" ] && [ -x "$subject_server" ] || usage

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
widths=${QWEN_TAIL_WIDTHS:-"19 20"}
bases=${QWEN_TAIL_BASES:-"512 1024 2048"}
pairs=${QWEN_TAIL_PAIRS:-10}
predict=${QWEN_TAIL_PREDICT:-32}
floor=${QWEN_TAIL_FLOOR:-0.051}
port=${QWEN_TAIL_PORT:-18120}
lock_clocks=${QWEN_TAIL_LOCK_CLOCKS:-}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
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
gpu_ownership_require >"$output_directory/ownership.txt"
"$script_directory/gpu-state-latch.sh" require-clear >"$output_directory/gpu-state-latch.txt"

control_pid=''
subject_pid=''
clocks_locked=0
cleanup() {
    for pid in "$control_pid" "$subject_pid"; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    control_pid=''
    subject_pid=''
    if [ "$clocks_locked" -eq 1 ]; then
        sudo -n nvidia-smi --reset-gpu-clocks >/dev/null 2>&1 || :
        clocks_locked=0
        printf 'gpu_clocks=released\n'
    fi
}
trap cleanup EXIT HUP INT TERM
if [ -n "$lock_clocks" ]; then
    { sudo -n nvidia-smi --lock-gpu-clocks="$lock_clocks,$lock_clocks"; } >"$output_directory/clock-lock.txt" 2>&1 || {
        printf 'clock lock refused: %s\n' "$(cat "$output_directory/clock-lock.txt")" >&2
        exit 75
    }
    clocks_locked=1
    sleep 2
    printf 'gpu_clocks=locked sm_mhz=%s observed=%s\n' "$lock_clocks" \
        "$(nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits | head -1)" | tee -a "$output_directory/clock-lock.txt"
fi

# The server is started in this shell rather than inside a command
# substitution, so its pid is this shell's child and `wait` in the teardown
# blocks until it has left; a pid read back from a subshell is nobody's child
# here and `wait` on it returns at once with the server still resident.
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
# /health answers ahead of the load banner in this build, and the model-buffer
# line is an INFO line the default verbosity hides, so the argv sets -lv 10 and
# readiness is the banner itself: the model buffer on CUDA0 and the listening
# line, bounded.
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
for name in control subject; do
    if grep -q 'CPU fallback rejected\|CPU_Mapped model buffer' "$output_directory/$name.server.log.raw"; then
        printf '%s server left a tensor on the host\n' "$name" >&2
        exit 1
    fi
done
control_closure=$(basename "$(dirname "$(dirname "$control_server")")")
subject_closure=$(basename "$(dirname "$(dirname "$subject_server")")")
for server in "$control_server" "$subject_server"; do
    printf '%s\t%s\n' "$(sha256sum "$server" | cut -d ' ' -f 1)" "$(printf '%s' "$server" | scrub_home)"
done >"$output_directory/server-digests.tsv"

observations=$output_directory/observations.tsv
QWEN_TAIL_CONTROL_PORT=$control_port QWEN_TAIL_SUBJECT_PORT=$subject_port \
QWEN_TAIL_CONTROL_CLOSURE=$control_closure QWEN_TAIL_SUBJECT_CLOSURE=$subject_closure \
QWEN_TAIL_WIDTHS_RESOLVED="$widths" QWEN_TAIL_BASES_RESOLVED="$bases" \
QWEN_TAIL_PAIRS_RESOLVED=$pairs QWEN_TAIL_PREDICT_RESOLVED=$predict \
    python3 - >"$observations" <<'PYTHON'
import hashlib
import json
import os
import urllib.request

ports = {"control": os.environ["QWEN_TAIL_CONTROL_PORT"], "subject": os.environ["QWEN_TAIL_SUBJECT_PORT"]}
closures = {"control": os.environ["QWEN_TAIL_CONTROL_CLOSURE"], "subject": os.environ["QWEN_TAIL_SUBJECT_CLOSURE"]}
widths = [int(w) for w in os.environ["QWEN_TAIL_WIDTHS_RESOLVED"].split()]
bases = [int(b) for b in os.environ["QWEN_TAIL_BASES_RESOLVED"].split()]
pairs = int(os.environ["QWEN_TAIL_PAIRS_RESOLVED"])
predict = int(os.environ["QWEN_TAIL_PREDICT_RESOLVED"])
passage = ("The measurement runs on one card shared with a desktop, so every rate "
           "carries the compositor as a covariate rather than as a condition to "
           "exclude. A prefill fills whole micro-batches and leaves a tail whose "
           "column count is where a dispatch threshold acts inside a request. ") * 200


def post(arm, route, body, timeout=600):
    request = urllib.request.Request(f"http://127.0.0.1:{ports[arm]}{route}",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=timeout))


tokens = post("control", "/tokenize", {"content": passage, "add_special": False})["tokens"]
prompts = {}
for base in bases:
    for width in widths:
        length = base + width
        if len(tokens) < length:
            raise SystemExit(f"passage tokenizes to {len(tokens)} < {length}")
        prompts[(base, width)] = post("control", "/detokenize", {"tokens": tokens[:length]})["content"]


def ask(arm, base, width):
    reply = post(arm, "/completion", {"prompt": prompts[(base, width)], "n_predict": predict,
                                      "temperature": 0, "top_k": 1, "seed": 1, "cache_prompt": False})
    timings = reply.get("timings") or {}
    digest = hashlib.sha256(json.dumps(reply.get("tokens", []), separators=(",", ":")).encode()).hexdigest()
    return timings, digest


print("phase\tpair\tposition\tarm\tclosure\tbase\twidth\tlength\tprompt_n\tprompt_ms\tpredicted_n\tpredicted_ms\ttokens_sha256")
for base in bases:
    for width in widths:
        for arm in ("control", "subject"):
            timings, digest = ask(arm, base, width)
            print("\t".join(str(v) for v in ("warmup", 0, 0, arm, closures[arm], base, width, base + width,
                timings.get("prompt_n", "-"), timings.get("prompt_ms", "-"),
                timings.get("predicted_n", "-"), timings.get("predicted_ms", "-"), digest)))
for pair in range(1, pairs + 1):
    order = ("control", "subject") if pair % 2 else ("subject", "control")
    for base in bases:
        for width in widths:
            for position, arm in enumerate(order, 1):
                timings, digest = ask(arm, base, width)
                print("\t".join(str(v) for v in ("paired", pair, position, arm, closures[arm], base, width, base + width,
                    timings.get("prompt_n", "-"), timings.get("prompt_ms", "-"),
                    timings.get("predicted_n", "-"), timings.get("predicted_ms", "-"), digest)))
PYTHON

cleanup
for name in control subject; do
    scrub_home <"$output_directory/$name.server.log.raw" >"$output_directory/$name.server.log"
    rm -f "$output_directory/$name.server.log.raw"
done
trap - EXIT HUP INT TERM

python3 - "$observations" "$output_directory/tails-summary.tsv" "$floor" <<'PYTHON'
import csv
import math
import statistics
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8"), delimiter="\t"))
floor = float(sys.argv[3])
paired = defaultdict(dict)
digests = defaultdict(set)
for r in rows:
    key = (int(r["base"]), int(r["width"]))
    digests[key].add(r["tokens_sha256"])
    if r["phase"] == "paired":
        paired[(key, int(r["pair"]))][r["arm"]] = (float(r["prompt_ms"]), float(r["predicted_ms"]))
lengths = sorted({(int(r["base"]), int(r["width"])) for r in rows})
with open(sys.argv[2], "w", encoding="utf-8") as h:
    h.write("base\twidth\tlength\tpairs\tprefill_ratio_median\tprefill_ratio_geomean\tprefill_ratio_iqr\tprefill_ratio_min\tprefill_ratio_max\tdecode_ratio_median\tcontrol_drift\tfloor\tclears_floor\ttokens_identical\n")
    for key in lengths:
        pr, dr, ctl = [], [], []
        for (k, p), arms in sorted(paired.items()):
            if k != key or "control" not in arms or "subject" not in arms:
                continue
            pr.append(arms["control"][0] / arms["subject"][0])
            dr.append(arms["control"][1] / arms["subject"][1])
            ctl.append(arms["control"][0])
        pr.sort()
        med = statistics.median(pr)
        geo = math.exp(sum(math.log(x) for x in pr) / len(pr))
        q = statistics.quantiles(pr, n=4) if len(pr) >= 4 else [pr[0], med, pr[-1]]
        first, last = statistics.mean(ctl[:3]), statistics.mean(ctl[-3:])
        drift = abs(first - last) / first
        clears = (med - 1.0) > floor and (geo - 1.0) > floor and q[0] > 1.0
        h.write(f"{key[0]}\t{key[1]}\t{key[0] + key[1]}\t{len(pr)}\t{med:.4f}\t{geo:.4f}\t{q[2] - q[0]:.4f}\t{pr[0]:.4f}\t{pr[-1]:.4f}\t{statistics.median(dr):.4f}\t{drift:.4f}\t{floor}\t{'yes' if clears else 'no'}\t{'yes' if len(digests[key]) == 1 else 'no'}\n")
print(open(sys.argv[2], encoding="utf-8").read())
PYTHON
