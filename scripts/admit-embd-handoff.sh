#!/bin/sh
# Admit the projector-to-language-model device handoff on one vision row.
#
# The ordinary path moves a projector's output through the host four times:
# clip_encode reads the scheduler's output tensor into a host vector,
# mtmd_helper_decode_image_chunk hands that vector to llama_batch::embd,
# llama_batch_allocr::ubatch_add copies the rows it splits off, and
# llm_graph_input_embd::set_input uploads them into the graph's input, which
# the scheduler stages through a host buffer. Under LLAMA_MTMD_EMBD_DEVICE=1
# the projector copies its output device to device into a tensor the mtmd
# batch owns, llama_batch::embd_dev names that tensor and a row offset, and
# build_inp_embd reads the rows as a view, so the bytes stay on the device
# from the projector's last node to the language model's first.
#
# Three arms run the same request sequence against the same closure: the
# host path, the device path, and the host path again. Every request is a
# greedy /completion carrying one fixture image, cache off, and the arms are
# compared on the reply token ids and on the digests the handoff trace
# writes under LLAMA_EMBD_HANDOFF_TRACE=1: clip_embd_handoff digests the
# projector's output where it landed and embd_handoff digests the bytes the
# graph consumes per ubatch. Identical digest sequences across the arms
# state that the device view holds the same bytes the host path uploaded;
# identical replies state that the language model read them the same way.
# The device arm also has to name a device buffer on every line, since a
# projector that ran on the host would make the copy host to device and the
# claim empty. The closing arm licenses reading a device-versus-host
# difference as the mechanism rather than as position in the sequence.
#
# gpu-ownership: acquires the owner lock for its whole run.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: admit-embd-handoff.sh BUILD_DIRECTORY OUTPUT_DIRECTORY [MODEL_ID]

BUILD_DIRECTORY holds bin/llama-server built with
patches/llama-mtmd-device-embd.patch applied. MODEL_ID names a registry row
carrying a projector; qwen35-2b by default. OUTPUT_DIRECTORY must be empty.

environment:
  QWEN_HANDOFF_IMAGES          fixture names under scripts/quality-images, default "bars.png compare-a.png shapes.png"
  QWEN_HANDOFF_REPEATS         passes over the image list per arm, default 2
  QWEN_HANDOFF_PREDICT         reply tokens per request, default 48
  QWEN_HANDOFF_PORT            listener, default 8102
  QWEN_HANDOFF_ARMS            arms in order, default "host device host-close"
  QWEN_HANDOFF_READY_SECONDS   readiness deadline, default 300
  QWEN_HANDOFF_REQUEST_SECONDS per-request deadline, default 600
USAGE
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
build_directory=$1
output_directory=$2
model_id=${3:-qwen35-2b}
images=${QWEN_HANDOFF_IMAGES:-"bars.png compare-a.png shapes.png"}
repeats=${QWEN_HANDOFF_REPEATS:-2}
predict_tokens=${QWEN_HANDOFF_PREDICT:-48}
server_port=${QWEN_HANDOFF_PORT:-8102}
arms=${QWEN_HANDOFF_ARMS:-"host device host-close"}
readiness_seconds=${QWEN_HANDOFF_READY_SECONDS:-300}
request_seconds=${QWEN_HANDOFF_REQUEST_SECONDS:-600}
for value in "$repeats" "$predict_tokens" "$server_port" "$readiness_seconds" "$request_seconds"; do
    case $value in '' | *[!0-9]* | 0) usage ;; esac
done
for arm in $arms; do
    case $arm in host | device | host-close | device-close) ;; *) usage ;; esac
done

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_script=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
image_directory=${QWEN_HANDOFF_IMAGE_DIRECTORY:-"$script_directory/quality-images"}
server_binary=$build_directory/bin/llama-server
[ -x "$server_binary" ] || {
    printf 'refused: llama-server is absent: %s\n' "$server_binary" >&2
    exit 2
}
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
for image in $images; do
    [ -f "$image_directory/$image" ] || {
        printf 'refused: fixture image absent: %s\n' "$image_directory/$image" >&2
        exit 2
    }
done

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
record images "$images"
record repeats "$repeats"
record predict_tokens "$predict_tokens"
record arms "$arms"

registry_field() { "$registry_script" id "$1" "$2"; }
model_file=$(registry_field "$model_id" model_file)
model_path=$models_directory/$model_file
[ -f "$model_path" ] || {
    printf 'refused: model file absent: %s\n' "$model_path" >&2
    record verdict "refused model_absent"
    exit 1
}
projector_path=$("$script_directory/select-projector.sh" "$model_path" || :)
[ -n "$projector_path" ] && [ -f "$projector_path" ] || {
    printf 'refused: no projector beside %s\n' "$model_path" >&2
    record verdict "refused projector_absent"
    exit 1
}
record model_sha256 "$(sha256sum "$model_path" | cut -d ' ' -f 1)"
record projector "$(basename "$projector_path")"
record projector_sha256 "$(sha256sum "$projector_path" | cut -d ' ' -f 1)"
model_context=$(registry_field "$model_id" context_default)
model_batch=$(registry_field "$model_id" batch)
model_ubatch=$(registry_field "$model_id" ubatch)
model_cache_k=$(registry_field "$model_id" cache_type_k)
model_cache_v=$(registry_field "$model_id" cache_type_v)
model_flash_attention=$(registry_field "$model_id" flash_attention)
record geometry "context=$model_context batch=$model_batch ubatch=$model_ubatch cache_k=$model_cache_k cache_v=$model_cache_v flash_attn=$model_flash_attention"
thread_count=${QWEN_HANDOFF_THREADS:-1}

"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv" >/dev/null 2>&1 || :
gpu_ownership_inspect >"$output_directory/clients-open.txt" 2>&1 || :
record clients_open "$(tr '\n' ';' <"$output_directory/clients-open.txt")"

server_pid=
stop_server() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || :
        wait_iteration=0
        while kill -0 "$server_pid" 2>/dev/null && [ "$wait_iteration" -lt 60 ]; do
            sleep 1
            wait_iteration=$((wait_iteration + 1))
        done
        kill -0 "$server_pid" 2>/dev/null && kill -KILL "$server_pid" 2>/dev/null || :
        wait "$server_pid" 2>/dev/null || :
    fi
    server_pid=
}
trap 'stop_server' EXIT INT TERM

post() {
    # post ROUTE DATA_FILE OUT_FILE
    curl --silent --show-error --fail-with-body --max-time "$request_seconds" \
        --header 'Content-Type: application/json' --data @"$2" \
        "http://127.0.0.1:$server_port$1" >"$3"
}

start_server() {
    arm_directory=$1
    arm_environment=$2
    mkdir -p "$arm_directory"
    # shellcheck disable=SC2086
    env LLAMA_EMBD_HANDOFF_TRACE=1 LLAMA_NO_CPU_FALLBACK=1 "LLAMA_MEDIA_MARKER=<__media__>" $arm_environment \
        "$server_binary" \
        --model "$model_path" \
        --mmproj "$projector_path" \
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

helper=$output_directory/handoff-helper.py
cat >"$helper" <<'PYTHON'
import base64
import json
import re
import sys

# request IMAGE PREDICT OUT: one greedy /completion carrying the image.
# reply RESPONSE OUT: the reply token ids and timings, refused on a short array.
# trace SERVER_LOG OUT_TSV: the handoff lines the log holds, one row each.
command = sys.argv[1]
if command == "request":
    with open(sys.argv[2], "rb") as handle:
        encoded = base64.b64encode(handle.read()).decode("ascii")
    prompt = ("<|im_start|>user\n<__media__>\nDescribe what this image shows, "
              "naming every label and number you can read.<|im_end|>\n<|im_start|>assistant\n")
    json.dump({
        "prompt": {"prompt_string": prompt, "multimodal_data": [encoded]},
        "n_predict": int(sys.argv[3]),
        "temperature": 0,
        "top_k": 1,
        "seed": 1,
        "cache_prompt": False,
        "return_tokens": True,
        "samplers": ["top_k"],
    }, open(sys.argv[4], "w", encoding="utf-8"))
elif command == "reply":
    record = json.load(open(sys.argv[2], encoding="utf-8"))
    tokens = record.get("tokens")
    if not isinstance(tokens, list) or not tokens:
        sys.stderr.write("the reply carries no token ids\n")
        raise SystemExit(1)
    timings = record.get("timings", {})
    json.dump({"tokens": tokens, "prompt_n": timings.get("prompt_n"),
               "prompt_ms": timings.get("prompt_ms"), "predicted_n": timings.get("predicted_n"),
               "predicted_ms": timings.get("predicted_ms")}, open(sys.argv[3], "w", encoding="utf-8"))
elif command == "trace":
    clip_line = re.compile(r"clip_embd_handoff dst=(\S+) src_backend=(\S+)(?: dst_buffer=(\S+))? bytes=(\d+) digest=([0-9a-f]{16})")
    embd_line = re.compile(r"embd_handoff source=(\S+) n_tokens=(\d+) n_embd=(\d+) offset=(-?\d+) buffer=(\S+) digest=([0-9a-f]{16})")
    rows = []
    for line in open(sys.argv[2], encoding="utf-8", errors="replace"):
        match = clip_line.search(line)
        if match:
            dst, src_backend, dst_buffer, nbytes, digest = match.groups()
            rows.append(("clip", dst, src_backend, dst_buffer or "-", nbytes, "-", "-", digest))
            continue
        match = embd_line.search(line)
        if match and "clip_embd_handoff" not in line:
            source, n_tokens, n_embd, offset, buffer, digest = match.groups()
            rows.append(("graph", source, buffer, "-", str(int(n_tokens) * int(n_embd) * 4), n_tokens, offset, digest))
    with open(sys.argv[3], "w", encoding="utf-8") as out:
        out.write("kind\tplacement\tbackend\tdst_buffer\tbytes\tn_tokens\toffset\tdigest\n")
        for row in rows:
            out.write("\t".join(row) + "\n")
else:
    raise SystemExit("unknown command %s" % command)
PYTHON

refusals=0
run_arm() {
    arm=$1
    arm_directory=$output_directory/$arm
    case $arm in
        device | device-close) arm_environment="LLAMA_MTMD_EMBD_DEVICE=1"; expected_mode=on ;;
        *) arm_environment=""; expected_mode=off ;;
    esac
    if ! start_server "$arm_directory" "$arm_environment"; then
        record "arm:$arm:server" refused
        refusals=$((refusals + 1))
        stop_server
        return 1
    fi
    if grep -qF "embd_device=$expected_mode" "$arm_directory/server.log"; then
        record "arm:$arm:embd_device" "$expected_mode"
    else
        record "arm:$arm:embd_device" "unreported expected=$expected_mode"
        refusals=$((refusals + 1))
    fi
    request_index=0
    repeat=1
    while [ "$repeat" -le "$repeats" ]; do
        for image in $images; do
            request_index=$((request_index + 1))
            label=$(printf '%02d-%s' "$request_index" "${image%.*}")
            python3 "$helper" request "$image_directory/$image" "$predict_tokens" "$arm_directory/request-$label.json"
            # the reply echoes the model path in generation_settings, so the
            # retained copy is scrubbed the way the log is
            if post /completion "$arm_directory/request-$label.json" "$arm_directory/response-$label.json" &&
                scrub_home <"$arm_directory/response-$label.json" >"$arm_directory/response-$label.scrubbed" &&
                mv "$arm_directory/response-$label.scrubbed" "$arm_directory/response-$label.json" &&
                python3 "$helper" reply "$arm_directory/response-$label.json" "$arm_directory/reply-$label.json"; then
                record "arm:$arm:$label" "completed prompt_n=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prompt_n"])' "$arm_directory/reply-$label.json") prompt_ms=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prompt_ms"])' "$arm_directory/reply-$label.json")"
            else
                record "arm:$arm:$label" refused
                refusals=$((refusals + 1))
            fi
            rm -f "$arm_directory/request-$label.json"
        done
        repeat=$((repeat + 1))
    done
    stop_server
    python3 "$helper" trace "$arm_directory/server.log" "$arm_directory/trace.tsv"
    scrub_home <"$arm_directory/server.log" >"$arm_directory/server.log.scrubbed" && mv "$arm_directory/server.log.scrubbed" "$arm_directory/server.log"
    record "arm:$arm:trace_rows" "$(awk 'NR > 1 { n++ } END { print n + 0 }' "$arm_directory/trace.tsv")"
}

for arm in $arms; do
    run_arm "$arm" || :
done

gpu_ownership_inspect >"$output_directory/clients-close.txt" 2>&1 || :
record clients_close "$(tr '\n' ';' <"$output_directory/clients-close.txt")"

# The comparison reads every arm against the first and holds the device arm
# to its own claims: every graph row reads source=device on a CUDA0 buffer,
# every clip row reads dst=device from a CUDA0 source, and the digest
# sequences of both kinds equal the host arm's row for row.
python3 - "$output_directory" "$arms" >"$output_directory/comparison.tsv" <<'PYTHON'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
arms = sys.argv[2].split()
first = arms[0]

def replies(arm):
    out = {}
    for path in sorted((directory / arm).glob("reply-*.json")):
        out[path.stem[len("reply-"):]] = json.load(open(path))["tokens"]
    return out

def trace(arm):
    rows = []
    path = directory / arm / "trace.tsv"
    if not path.exists():
        return rows
    lines = path.read_text().splitlines()
    for line in lines[1:]:
        rows.append(line.split("\t"))
    return rows

base_replies = replies(first)
base_trace = trace(first)
print("check\tarm\tresult\tdetail")
refused = 0
for arm in arms:
    arm_replies = replies(arm)
    labels = sorted(set(base_replies) | set(arm_replies))
    missing = [l for l in labels if l not in arm_replies or l not in base_replies]
    differing = [l for l in labels if l in arm_replies and l in base_replies and arm_replies[l] != base_replies[l]]
    if missing or differing or not labels:
        refused += 1
        print("reply_identity\t%s\trefused\tmissing=%s differing=%s" % (arm, ",".join(missing) or "-", ",".join(differing) or "-"))
    else:
        print("reply_identity\t%s\tidentical\trequests=%d" % (arm, len(labels)))
    arm_trace = trace(arm)
    for kind in ("clip", "graph"):
        base_digests = [r[7] for r in base_trace if r[0] == kind]
        arm_digests = [r[7] for r in arm_trace if r[0] == kind]
        if not base_digests or base_digests != arm_digests:
            refused += 1
            print("%s_digests\t%s\trefused\tbase=%d arm=%d" % (kind, arm, len(base_digests), len(arm_digests)))
        else:
            print("%s_digests\t%s\tidentical\trows=%d" % (kind, arm, len(arm_digests)))
    expect_device = arm.startswith("device")
    graph_rows = [r for r in arm_trace if r[0] == "graph"]
    clip_rows = [r for r in arm_trace if r[0] == "clip"]
    if expect_device:
        bad_graph = [r for r in graph_rows if r[1] != "device" or "CUDA0" not in r[2]]
        bad_clip = [r for r in clip_rows if r[1] != "device" or r[2] != "CUDA0" or "CUDA0" not in r[3]]
    else:
        bad_graph = [r for r in graph_rows if r[1] != "host"]
        bad_clip = [r for r in clip_rows if r[1] != "host" or r[2] != "CUDA0"]
    if not graph_rows or not clip_rows or bad_graph or bad_clip:
        refused += 1
        print("placement\t%s\trefused\tgraph_rows=%d clip_rows=%d bad_graph=%d bad_clip=%d" % (arm, len(graph_rows), len(clip_rows), len(bad_graph), len(bad_clip)))
    else:
        print("placement\t%s\tholds\tgraph_rows=%d clip_rows=%d" % (arm, len(graph_rows), len(clip_rows)))
    # where a chunk decodes in one ubatch the graph reads exactly the bytes
    # the projector wrote, so the two digests agree row for row
    if len(clip_rows) == len(graph_rows):
        agree = all(c[7] == g[7] for c, g in zip(clip_rows, graph_rows))
        print("clip_to_graph\t%s\t%s\trows=%d" % (arm, "agree" if agree else "differ", len(clip_rows)))
        if not agree:
            refused += 1
    else:
        print("clip_to_graph\t%s\tnot_compared\tclip=%d graph=%d" % (arm, len(clip_rows), len(graph_rows)))
print("refused_checks\t-\t%d\t-" % refused)
sys.exit(1 if refused else 0)
PYTHON
comparison_status=$?
comparison_refusals=$(awk -F '\t' '$1 == "refused_checks" { print $3 }' "$output_directory/comparison.tsv")
record comparison_refusals "${comparison_refusals:-unread}"
refusals=$((refusals + ${comparison_refusals:-1}))
if [ "$refusals" -eq 0 ] && [ "$comparison_status" -eq 0 ]; then
    record verdict admitted
    printf 'admitted: %s\n' "$output_directory" | scrub_home
    exit 0
fi
record verdict "refused refusals=$refusals"
printf 'refused: %s refusals, see %s\n' "$refusals" "$output_directory/summary.tsv" | scrub_home >&2
exit 1
