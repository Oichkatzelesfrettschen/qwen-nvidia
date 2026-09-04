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
# launched pays its module load on first use. The prompts are cut from one
# prose file, and the reply ids and text, returned under return_tokens, have
# to agree between the closures at every length; the server's own prompt_ms
# and predicted_ms are the request-level prefill and decode costs. The SM clock
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
    printf '             QWEN_TAIL_PASSAGE      prose file the prompts are cut from, default CLAUDE.md\n' >&2
    printf '             QWEN_TAIL_DECIDE_ON    prefill or decode, the column the verdict reads, default prefill\n' >&2
    printf '             QWEN_TAIL_CONTROL_ARGS extra server argv for the control arm, default empty\n' >&2
    printf '             QWEN_TAIL_SUBJECT_ARGS extra server argv for the subject arm, default empty\n' >&2
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
passage=${QWEN_TAIL_PASSAGE:-"$script_directory/../CLAUDE.md"}
# An arm axis is a closure by default and a runtime flag where the two arms name
# one binary: the MMVQ campaign compares two builds that differ in a compile
# definition, and a sampling campaign compares one build launched two ways.
# Both are one changed variable between two concurrently served ports.
decide_on=${QWEN_TAIL_DECIDE_ON:-prefill}
control_arguments=${QWEN_TAIL_CONTROL_ARGS:-}
subject_arguments=${QWEN_TAIL_SUBJECT_ARGS:-}
case $decide_on in
prefill | decode) ;;
*) printf 'refused: QWEN_TAIL_DECIDE_ON takes prefill or decode\n' >&2; exit 2 ;;
esac
if [ "$control_server" = "$subject_server" ] && [ "$control_arguments" = "$subject_arguments" ]; then
    printf 'refused: the two arms name one binary and one argv, so nothing varies\n' >&2
    exit 2
fi
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

# Four pairs is the floor every derived statistic in the summary needs:
# statistics.quantiles requires four points, and the control-drift read
# compares the first three control observations against the last three, whose
# slices coincide at three pairs or fewer and report no movement for a control
# that moved. The refusal is here rather than in the summary because the
# device time is spent before the summary runs.
[ "$pairs" -ge 4 ] || { printf 'refused: paired promotion analysis requires at least four pairs\n' >&2; exit 2; }

mkdir -p "$output_directory"
scrub_home() { sed "s|${HOME:?}|\$HOME|g"; }
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_require >"$output_directory/ownership.txt.raw"
scrub_home <"$output_directory/ownership.txt.raw" >"$output_directory/ownership.txt"
rm -f "$output_directory/ownership.txt.raw"
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
    # The scrub belongs to the teardown rather than to the success path, because
    # every refusal between the load and the summary otherwise leaves a raw log
    # naming the home directory in the retained output. The loop skips a log the
    # run never wrote, so a failure ahead of the second server still reaches the
    # clock release below.
    for name in control subject; do
        [ -f "$output_directory/$name.server.log.raw" ] || continue
        scrub_home <"$output_directory/$name.server.log.raw" >"$output_directory/$name.server.log"
        rm -f "$output_directory/$name.server.log.raw"
    done
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
    # serve SERVER PORT LOG EXTRA_ARGV; sets served_pid. The extra argv is
    # unquoted on purpose: it carries whole flags an arm adds to the shared
    # geometry, and the shared geometry is what keeps the arms comparable.
    arm_extra_argv=$4
    # shellcheck disable=SC2086
    QWEN_CUDA_PROFILE=default "$wrapper" "$1" $arm_extra_argv \
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
serve "$control_server" "$control_port" "$output_directory/control.server.log.raw" "$control_arguments"
control_pid=$served_pid
ready "$control_port" "$control_pid" "$output_directory/control.server.log.raw"
serve "$subject_server" "$subject_port" "$output_directory/subject.server.log.raw" "$subject_arguments"
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
# Two arms can name one binary, in which case the digests match and the argv is
# the only thing that tells them apart, so the record carries both per arm.
{
    printf 'arm\tsha256\tserver\textra_argv\n'
    printf 'control\t%s\t%s\t%s\n' "$(sha256sum "$control_server" | cut -d ' ' -f 1)" \
        "$(printf '%s' "$control_server" | scrub_home)" "${control_arguments:--}"
    printf 'subject\t%s\t%s\t%s\n' "$(sha256sum "$subject_server" | cut -d ' ' -f 1)" \
        "$(printf '%s' "$subject_server" | scrub_home)" "${subject_arguments:--}"
} >"$output_directory/server-digests.tsv"
printf '%s\t%s\n' "$(sha256sum "$passage" | cut -d ' ' -f 1)" "$(printf '%s' "$passage" | scrub_home)" \
    >"$output_directory/passage-digest.tsv"

observations=$output_directory/observations.tsv
QWEN_TAIL_CONTROL_PORT=$control_port QWEN_TAIL_SUBJECT_PORT=$subject_port \
QWEN_TAIL_CONTROL_CLOSURE=$control_closure QWEN_TAIL_SUBJECT_CLOSURE=$subject_closure \
QWEN_TAIL_WIDTHS_RESOLVED="$widths" QWEN_TAIL_BASES_RESOLVED="$bases" \
QWEN_TAIL_PAIRS_RESOLVED=$pairs QWEN_TAIL_PREDICT_RESOLVED=$predict \
QWEN_TAIL_PASSAGE_RESOLVED=$passage QWEN_TAIL_REPLIES_RESOLVED=$output_directory/replies.jsonl \
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
# The prompt is a prose file rather than a repeated sentence, because a greedy
# continuation of a periodic passage is a copy of the passage that every model
# reproduces token for token; two closures can disagree numerically and still
# emit the same copy, so identity over that prompt separates nothing. A text
# without a period leaves the continuation to the model's own logits, and its
# digest is recorded beside the observations.
passage = open(os.environ["QWEN_TAIL_PASSAGE_RESOLVED"], encoding="utf-8").read()


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


# llama-server returns the sampled token ids only under return_tokens, which
# server-task.h defaults to false; server-context.cpp appends to
# generated_tokens inside `if (slot.task->params.return_tokens)`, so a request
# leaving the flag unset receives an absent array and a digest over the
# default would hash the same empty list for every reply of every closure.
# The reply is therefore required to carry exactly predicted_n ids, and the
# content text is digested beside them as a second reading of the same reply.
def ask(arm, base, width):
    reply = post(arm, "/completion", {"prompt": prompts[(base, width)], "n_predict": predict,
                                      "temperature": 0, "top_k": 1, "seed": 1, "cache_prompt": False,
                                      "return_tokens": True})
    timings = reply.get("timings") or {}
    generated = reply.get("tokens")
    if not isinstance(generated, list):
        raise RuntimeError(f"{arm}: completion omitted the requested raw token list")
    predicted_n = timings.get("predicted_n")
    if not isinstance(predicted_n, int) or predicted_n < 0:
        raise RuntimeError(f"{arm}: completion omitted a valid predicted_n")
    if predicted_n > 0 and not generated:
        raise RuntimeError(f"{arm}: completion returned an empty token list")
    if len(generated) != predicted_n:
        raise RuntimeError(f"{arm}: token-count mismatch: tokens={len(generated)} predicted_n={predicted_n}")
    if not all(isinstance(token, int) for token in generated):
        raise RuntimeError(f"{arm}: completion returned a token that is not an integer id")
    content = reply.get("content")
    if not isinstance(content, str):
        raise RuntimeError(f"{arm}: completion omitted textual content")
    token_digest = hashlib.sha256(json.dumps(generated, separators=(",", ":")).encode()).hexdigest()
    content_digest = hashlib.sha256(content.encode()).hexdigest()
    replies.write(json.dumps({"arm": arm, "closure": closures[arm], "base": base, "width": width,
                              "tokens": generated, "content": content}, separators=(",", ":")) + "\n")
    return timings, token_digest, content_digest


# Every reply's ids and text are retained beside the digests, so a divergent
# pair reports the position of its first differing id rather than two hashes.
replies = open(os.environ["QWEN_TAIL_REPLIES_RESOLVED"], "w", encoding="utf-8")


print("phase\tpair\tposition\tarm\tclosure\tbase\twidth\tlength\tprompt_n\tprompt_ms\tpredicted_n\tpredicted_ms\ttokens_sha256\tcontent_sha256")
for base in bases:
    for width in widths:
        for arm in ("control", "subject"):
            timings, digest, content_digest = ask(arm, base, width)
            print("\t".join(str(v) for v in ("warmup", 0, 0, arm, closures[arm], base, width, base + width,
                timings.get("prompt_n", "-"), timings.get("prompt_ms", "-"),
                timings.get("predicted_n", "-"), timings.get("predicted_ms", "-"), digest, content_digest)))
for pair in range(1, pairs + 1):
    order = ("control", "subject") if pair % 2 else ("subject", "control")
    for base in bases:
        for width in widths:
            for position, arm in enumerate(order, 1):
                timings, digest, content_digest = ask(arm, base, width)
                print("\t".join(str(v) for v in ("paired", pair, position, arm, closures[arm], base, width, base + width,
                    timings.get("prompt_n", "-"), timings.get("prompt_ms", "-"),
                    timings.get("predicted_n", "-"), timings.get("predicted_ms", "-"), digest, content_digest)))
PYTHON

cleanup
trap - EXIT HUP INT TERM

python3 - "$observations" "$output_directory/tails-summary.tsv" "$floor" "$output_directory/replies.jsonl" "$decide_on" <<'PYTHON'
import csv
import json
import math
import statistics
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8"), delimiter="\t"))
floor = float(sys.argv[3])
# A threshold that changes which mat-mul kernel a prefill launches acts on
# prompt_ms; a flag that moves sampling off the host acts on predicted_ms. Both
# are the same paired comparison over a different column, so the deciding column
# is named rather than assumed, and it defaults to the prefill reading every
# retained campaign in this tree was summarized under.
decide_on = sys.argv[5] if len(sys.argv) > 5 else "prefill"
decide_index = 0 if decide_on == "prefill" else 1
paired = defaultdict(dict)
digests = defaultdict(set)
contents = defaultdict(set)
for r in rows:
    key = (int(r["base"]), int(r["width"]))
    digests[key].add(r["tokens_sha256"])
    contents[key].add(r["content_sha256"])
    if r["phase"] == "paired":
        paired[(key, int(r["pair"]))][r["arm"]] = (float(r["prompt_ms"]), float(r["predicted_ms"]))
# The first position at which any reply of a length differs from the control
# arm's reply, or "-" where every reply at that length carries the same ids.
replies = defaultdict(list)
for line in open(sys.argv[4], encoding="utf-8"):
    reply = json.loads(line)
    replies[(reply["base"], reply["width"])].append(reply)
def first_divergence(key):
    reference = next(r["tokens"] for r in replies[key] if r["arm"] == "control")
    positions = []
    for reply in replies[key]:
        pairs = zip(reference, reply["tokens"])
        differing = [i for i, (a, b) in enumerate(pairs) if a != b]
        if differing or len(reply["tokens"]) != len(reference):
            positions.append(differing[0] if differing else min(len(reference), len(reply["tokens"])))
    return str(min(positions)) if positions else "-"
lengths = sorted({(int(r["base"]), int(r["width"])) for r in rows})
with open(sys.argv[2], "w", encoding="utf-8") as h:
    deciding, secondary = ("prefill", "decode") if decide_on == "prefill" else ("decode", "prefill")
    h.write(f"base\twidth\tlength\tpairs\tdecided_on\t{deciding}_ratio_median\t"
            f"{deciding}_ratio_geomean\t{deciding}_ratio_iqr\t{deciding}_ratio_min\t"
            f"{deciding}_ratio_max\t{secondary}_ratio_median\tcontrol_drift\tfloor\t"
            "clears_floor\tsample_count_valid\tpromotion_eligible\tineligibility_reason\t"
            "tokens_identical\tcontent_identical\tfirst_divergent_index\n")
    for key in lengths:
        pr, dr, ctl = [], [], []
        for (k, p), arms in sorted(paired.items()):
            if k != key or "control" not in arms or "subject" not in arms:
                continue
            # pr carries the deciding column and dr the other one, so the
            # ratio fields always report the reading the verdict rests on and
            # the second column stays visible beside it.
            other = 1 - decide_index
            pr.append(arms["control"][decide_index] / arms["subject"][decide_index])
            dr.append(arms["control"][other] / arms["subject"][other])
            ctl.append(arms["control"][decide_index])
        pr.sort()
        # Four pairs is the floor both derived statistics need. statistics.quantiles
        # requires four points, and the drift reads mean(ctl[:3]) against
        # mean(ctl[-3:]), whose slices coincide at three pairs or fewer and report
        # 0.0000 for any control that moved. Below the floor the row states n/a for
        # both and withholds admission rather than publishing a value its own
        # sample size cannot carry.
        # A sample too small to decide and a sample that decided against the
        # subject are two verdicts, so they occupy two fields. clears_floor
        # answers the floor comparison alone and reads n/a where the sample
        # cannot carry it; sample_count_valid states whether four pairs were
        # measured; promotion_eligible is the conjunction a reader acts on and
        # ineligibility_reason names which of the two withheld it.
        n = len(pr)
        if n >= 4:
            q = statistics.quantiles(pr, n=4)
            med = statistics.median(pr)
            geo = math.exp(sum(math.log(x) for x in pr) / n)
            iqr = f"{q[2] - q[0]:.4f}"
            first, last = statistics.mean(ctl[:3]), statistics.mean(ctl[-3:])
            drift = f"{abs(first - last) / first:.4f}"
            clears = "yes" if ((med - 1.0) > floor and (geo - 1.0) > floor and q[0] > 1.0) else "no"
            valid = "yes"
            reason = "-" if clears == "yes" else "below_floor"
            ratios = f"{med:.4f}\t{geo:.4f}\t{iqr}\t{pr[0]:.4f}\t{pr[-1]:.4f}\t{statistics.median(dr):.4f}"
        else:
            clears = "n/a"
            valid = "no"
            reason = "insufficient_pairs"
            drift = "n/a"
            print(f"{key[0]}+{key[1]}: {n} pairs is below the four-pair floor, so control_drift, "
                  f"the {decide_on} ratio IQR, and clears_floor read n/a and the length is "
                  "ineligible for promotion on sample count rather than on measured gain",
                  file=sys.stderr)
            if n:
                med = statistics.median(pr)
                geo = math.exp(sum(math.log(x) for x in pr) / n)
                ratios = f"{med:.4f}\t{geo:.4f}\tn/a\t{pr[0]:.4f}\t{pr[-1]:.4f}\t{statistics.median(dr):.4f}"
            else:
                ratios = "n/a\tn/a\tn/a\tn/a\tn/a\tn/a"
        eligible = "yes" if clears == "yes" and valid == "yes" else "no"
        h.write(f"{key[0]}\t{key[1]}\t{key[0] + key[1]}\t{n}\t{decide_on}\t{ratios}\t{drift}\t{floor}\t{clears}\t{valid}\t{eligible}\t{reason}\t{'yes' if len(digests[key]) == 1 else 'no'}\t{'yes' if len(contents[key]) == 1 else 'no'}\t{first_divergence(key)}\n")
print(open(sys.argv[2], encoding="utf-8").read())
PYTHON
