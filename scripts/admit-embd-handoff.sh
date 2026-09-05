#!/bin/sh
# Admit the projector-to-language-model device embedding handoff on one
# vision row, with a batch-owned device copy.
#
# The ordinary path moves a projector's output through four stages on the
# way to the language model: clip_encode reads the scheduler's output tensor
# into a host vector, mtmd_helper_decode_image_chunk hands a pointer into
# that vector to llama_batch::embd, llama_batch_allocr::ubatch_add copies
# the rows it splits off host to host, and llm_graph_input_embd::set_input
# uploads them into a graph input the scheduler stages through a host
# buffer. Under LLAMA_MTMD_EMBD_DEVICE=1 the projector copies its output
# device to device into a tensor the mtmd batch owns, llama_batch::embd_dev
# names that tensor and a row offset, and build_inp_embd reads the rows as a
# view, so the host detour is gone and one deliberate device-to-device copy
# into batch-owned storage remains.
#
# Three stages hold the mechanism to three claims.
#
# identity: host, device, and host-close arms run one request sequence at
# two submission geometries, the registry's and a split one whose n_batch
# and n_ubatch sit under every chunk, with the recorder on. The sequence
# carries one image in one ubatch, two same-shape images adjacent so the
# projector batches them, two images separated by text, and images whose
# chunks exceed the ubatch and the batch, so every row-offset path runs:
# a chunk contained in one ubatch, a chunk split across ubatches, several
# chunks in one batch at nonzero row offsets, a chunk split across
# llama_decode calls, and a final partial ubatch. read-embd-handoff-trace.py
# joins every slice the graph consumed to its source rows and holds the
# per-row digest chain, coverage, and ordering per chunk; the arms are then
# compared slice for slice on the byte digest and on the projector's per-row
# digests, and on every reply's token ids.
#
# lifetime: host and device arms run large-image requests the client
# abandons at three points, during image preprocessing, during the prefill,
# and during generation, each followed by an ordinary request, and the
# closing requests are compared on reply and slice digests while the server
# stays healthy; the device helper synchronizes the consumer before it
# returns, so the batch a cancellation frees has no graph in flight over it.
# The server reads the connection per generated token and never inside
# prompt processing, so an early disconnect takes effect at the first
# generation step; the comparison reads each cancel out of the server log
# with the position the slot released at.
# The identity device arms allocate one batch tensor per request, and the
# reader counts how often consecutive batches land at one storage address,
# which is the reuse the graph-reuse guard compares data, buffer, tensor,
# and offset against.
#
# transfer: host and device arms run the registry-geometry sequence once
# with the recorder off under Nsight Systems, and read-nsys-embd-transfers.py
# lists every copy against the embedding sizes the identity stage recorded.
# The host arm is the positive control, one device-to-host copy per batch
# and one host-to-device copy per ubatch; the device arm has to show one
# device-to-device copy per batch and no embedding-sized copy in either
# host direction. The recorder itself reads device bytes back for its
# digests, so the identity stage says nothing about traffic and this stage
# says nothing about bytes.
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
  QWEN_HANDOFF_STAGES          stages in order, default "identity lifetime transfer"
  QWEN_HANDOFF_REQUESTS        request shapes in order, default
                               "single pair-adjacent pair-text large large-pair-text"
  QWEN_HANDOFF_GEOMETRIES      identity geometries, default "registry split"
  QWEN_HANDOFF_REQUIRED_COVERAGE
                               row-offset conditions some identity geometry has to reach, default
                               "chunk_in_one_ubatch chunk_split_across_ubatches chunk_split_across_decodes
                               nonzero_row_offset_slices final_partial_ubatch"; several_chunks_in_one_batch
                               is reported and required only where listed, since a projector without
                               batch support cannot reach it
  QWEN_HANDOFF_SPLIT_BATCH     n_batch of the split geometry, default 64
  QWEN_HANDOFF_SPLIT_UBATCH    n_ubatch of the split geometry, default 32
  QWEN_HANDOFF_REPEATS         passes over the request list per identity arm, default 2
  QWEN_HANDOFF_PREDICT         reply tokens per request, default 48
  QWEN_HANDOFF_PORT            listener, default 8102
  QWEN_HANDOFF_ARMS            identity arms in order, default "host device host-close"
  QWEN_HANDOFF_NSYS            nsys binary for the transfer stage, default the one on PATH
  QWEN_HANDOFF_READY_SECONDS   readiness deadline, default 300
  QWEN_HANDOFF_REQUEST_SECONDS per-request deadline, default 600
USAGE
    exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
build_directory=$1
output_directory=$2
model_id=${3:-qwen35-2b}
stages=${QWEN_HANDOFF_STAGES:-"identity lifetime transfer"}
request_shapes=${QWEN_HANDOFF_REQUESTS:-"single pair-adjacent pair-text large large-pair-text"}
geometries=${QWEN_HANDOFF_GEOMETRIES:-"registry split"}
required_coverage=${QWEN_HANDOFF_REQUIRED_COVERAGE:-"chunk_in_one_ubatch chunk_split_across_ubatches chunk_split_across_decodes nonzero_row_offset_slices final_partial_ubatch"}
split_batch=${QWEN_HANDOFF_SPLIT_BATCH:-64}
split_ubatch=${QWEN_HANDOFF_SPLIT_UBATCH:-32}
repeats=${QWEN_HANDOFF_REPEATS:-2}
predict_tokens=${QWEN_HANDOFF_PREDICT:-48}
server_port=${QWEN_HANDOFF_PORT:-8102}
arms=${QWEN_HANDOFF_ARMS:-"host device host-close"}
nsys_binary=${QWEN_HANDOFF_NSYS:-nsys}
readiness_seconds=${QWEN_HANDOFF_READY_SECONDS:-300}
request_seconds=${QWEN_HANDOFF_REQUEST_SECONDS:-600}
for value in "$split_batch" "$split_ubatch" "$repeats" "$predict_tokens" "$server_port" "$readiness_seconds" "$request_seconds"; do
    case $value in '' | *[!0-9]* | 0) usage ;; esac
done
[ "$split_ubatch" -le "$split_batch" ] || usage
for stage in $stages; do
    case $stage in identity | lifetime | transfer) ;; *) usage ;; esac
done
for arm in $arms; do
    case $arm in host | device | host-close | device-close) ;; *) usage ;; esac
done
for geometry in $geometries; do
    case $geometry in registry | split) ;; *) usage ;; esac
done
for shape in $request_shapes; do
    case $shape in single | pair-adjacent | pair-text | large | large-pair-text) ;; *) usage ;; esac
done
for condition in $required_coverage; do
    case $condition in
        chunk_in_one_ubatch | chunk_split_across_ubatches | chunk_split_across_decodes | several_chunks_in_one_batch | nonzero_row_offset_slices | final_partial_ubatch) ;;
        *) usage ;;
    esac
done

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
registry_script=${QWEN_MODEL_REGISTRY_SCRIPT:-"$script_directory/model-registry.sh"}
models_directory=${QWEN_MODELS_DIRECTORY:-"${HOME:?}/models"}
image_directory=${QWEN_HANDOFF_IMAGE_DIRECTORY:-"$script_directory/quality-images"}
large_image_directory=${QWEN_HANDOFF_LARGE_IMAGE_DIRECTORY:-"$script_directory/handoff-images"}
trace_reader=$script_directory/read-embd-handoff-trace.py
transfer_reader=$script_directory/read-nsys-embd-transfers.py
profiler_wrapper=$script_directory/exec-profiler-clean-env.sh
server_binary=$build_directory/bin/llama-server
[ -x "$server_binary" ] || {
    printf 'refused: llama-server is absent: %s\n' "$server_binary" >&2
    exit 2
}
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    printf 'refused: output directory is not empty: %s\n' "$output_directory" >&2
    exit 2
fi
for image in bars.png compare-a.png compare-b.png shapes.png; do
    [ -f "$image_directory/$image" ] || {
        printf 'refused: fixture image absent: %s\n' "$image_directory/$image" >&2
        exit 2
    }
done
for image in bars-large.png shapes-large.png; do
    [ -f "$large_image_directory/$image" ] || {
        printf 'refused: large fixture absent: %s\n' "$large_image_directory/$image" >&2
        exit 2
    }
done
case " $stages " in
    *" transfer "*)
        command -v "$nsys_binary" >/dev/null 2>&1 || {
            printf 'refused: nsys is absent: %s\n' "$nsys_binary" >&2
            exit 2
        }
        ;;
esac

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
record stages "$stages"
record request_shapes "$request_shapes"
record geometries "$geometries"
record required_coverage "$required_coverage"
record split_geometry "batch=$split_batch ubatch=$split_ubatch"
record repeats "$repeats"
record predict_tokens "$predict_tokens"
record arms "$arms"
for image in bars.png compare-a.png compare-b.png shapes.png; do
    record "fixture:$image" "$(sha256sum "$image_directory/$image" | cut -d ' ' -f 1)"
done
for image in bars-large.png shapes-large.png; do
    record "fixture:$image" "$(sha256sum "$large_image_directory/$image" | cut -d ' ' -f 1)"
done

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
record geometry_registry "context=$model_context batch=$model_batch ubatch=$model_ubatch cache_k=$model_cache_k cache_v=$model_cache_v flash_attn=$model_flash_attention"
thread_count=${QWEN_HANDOFF_THREADS:-1}

"$script_directory/device-environment-identity.sh" "$output_directory/device-environment.tsv" >/dev/null 2>&1 || :
gpu_ownership_inspect >"$output_directory/clients-open.txt" 2>&1 || :
record clients_open "$(tr '\n' ';' <"$output_directory/clients-open.txt")"

server_pid=
profiler_pid=
stop_pid() {
    pid=$1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || :
        wait_iteration=0
        while kill -0 "$pid" 2>/dev/null && [ "$wait_iteration" -lt 90 ]; do
            sleep 1
            wait_iteration=$((wait_iteration + 1))
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || :
        wait "$pid" 2>/dev/null || :
    fi
}
stop_server() {
    stop_pid "$server_pid"
    server_pid=
    stop_pid "$profiler_pid"
    profiler_pid=
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

wait_ready() {
    # wait_ready ARM_DIRECTORY PID: readiness and the placement banner
    ready_iteration=0
    while [ "$ready_iteration" -lt "$readiness_seconds" ]; do
        if ! kill -0 "$2" 2>/dev/null; then
            printf 'refused: the server exited before readiness; see %s\n' "$1/server.log" >&2
            return 1
        fi
        if curl --silent --fail --max-time 2 "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            for placement_line in 'CUDA0 model buffer size' 'CUDA0 KV buffer size' 'CUDA0 compute buffer size'; do
                grep -qF "$placement_line" "$1/server.log" || {
                    printf 'refused: placement missing %s in %s\n' "$placement_line" "$1/server.log" >&2
                    return 1
                }
            done
            return 0
        fi
        ready_iteration=$((ready_iteration + 1))
        sleep 1
    done
    printf 'refused: the server stayed unready for %s seconds\n' "$readiness_seconds" >&2
    return 1
}

server_argv() {
    # server_argv BATCH UBATCH: the argv after the binary, one per line
    printf '%s\n' --model "$model_path" --mmproj "$projector_path" --host 127.0.0.1 --port "$server_port" \
        --ctx-size "$model_context" --batch-size "$1" --ubatch-size "$2" \
        --cache-type-k "$model_cache_k" --cache-type-v "$model_cache_v" --flash-attn "$model_flash_attention" \
        --device CUDA0 --split-mode none --override-tensor '.*=CUDA0' --fit off --n-gpu-layers all \
        --parallel 1 --threads "$thread_count" --threads-batch "$thread_count" \
        --no-context-shift --offline --log-verbosity 4
}

start_server() {
    # start_server ARM_DIRECTORY ARM_ENVIRONMENT TRACE BATCH UBATCH
    arm_directory=$1
    arm_environment=$2
    trace_setting=$3
    mkdir -p "$arm_directory"
    server_argv "$4" "$5" >"$arm_directory/argv.txt"
    set --
    while IFS= read -r argument; do set -- "$@" "$argument"; done <"$arm_directory/argv.txt"
    scrub_home <"$arm_directory/argv.txt" >"$arm_directory/argv.scrubbed" && mv "$arm_directory/argv.scrubbed" "$arm_directory/argv.txt"
    # shellcheck disable=SC2086
    env LLAMA_EMBD_HANDOFF_TRACE="$trace_setting" LLAMA_NO_CPU_FALLBACK=1 "LLAMA_MEDIA_MARKER=<__media__>" $arm_environment \
        "$server_binary" "$@" >"$arm_directory/server.log" 2>&1 9>&- &
    server_pid=$!
    wait_ready "$arm_directory" "$server_pid"
}

start_profiled_server() {
    # start_profiled_server ARM_DIRECTORY ARM_ENVIRONMENT BATCH UBATCH: the
    # recorder off, the server under nsys launch with a named session, so the
    # capture is started after the load and stopped before the server exits
    arm_directory=$1
    arm_environment=$2
    mkdir -p "$arm_directory"
    server_argv "$3" "$4" >"$arm_directory/argv.txt"
    set --
    while IFS= read -r argument; do set -- "$@" "$argument"; done <"$arm_directory/argv.txt"
    scrub_home <"$arm_directory/argv.txt" >"$arm_directory/argv.scrubbed" && mv "$arm_directory/argv.scrubbed" "$arm_directory/argv.txt"
    session_name="embd-handoff-$$-$(basename "$arm_directory")"
    printf '%s\n' "$session_name" >"$arm_directory/nsys-session.txt"
    # the wrapper starts the profiler from an allowlisted environment, so the
    # three names the server reads are set inside it, ahead of nsys, which
    # hands its environment to the target
    # shellcheck disable=SC2086
    "$profiler_wrapper" env LLAMA_NO_CPU_FALLBACK=1 "LLAMA_MEDIA_MARKER=<__media__>" $arm_environment \
        "$nsys_binary" launch --session-new="$session_name" --trace=cuda \
        "$server_binary" "$@" >"$arm_directory/server.log" 2>&1 9>&- &
    profiler_pid=$!
    wait_ready "$arm_directory" "$profiler_pid" || return 1
    # the server is the profiler's child holding the listener
    server_pid=$(ss -ltnpH "sport = :$server_port" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1)
    [ -n "$server_pid" ] || {
        printf 'refused: no process holds the listener on %s\n' "$server_port" >&2
        return 1
    }
    # sampling and context-switch tracing stay off: launch takes the trace
    # selection and start takes the sampler settings on this nsys
    "$nsys_binary" start --session="$session_name" --sample=none --cpuctxsw=none \
        --output "$arm_directory/profile" --force-overwrite=true \
        >"$arm_directory/nsys-start.txt" 2>&1 || {
        cat "$arm_directory/nsys-start.txt" >&2
        return 1
    }
}

stop_profiled_server() {
    # stop_profiled_server ARM_DIRECTORY: stop the capture, then the server
    session_name=$(cat "$1/nsys-session.txt")
    "$nsys_binary" stop --session="$session_name" >"$1/nsys-stop.txt" 2>&1 || {
        cat "$1/nsys-stop.txt" >&2
        stop_server
        return 1
    }
    stop_server
    "$nsys_binary" export --type sqlite --force-overwrite true \
        --output "$1/profile.sqlite" "$1/profile.nsys-rep" >"$1/nsys-export.txt" 2>&1 || {
        cat "$1/nsys-export.txt" >&2
        return 1
    }
    # the raw capture names the checkout and stays out of the record; the
    # export is what the reader consumes and its digest is what the record
    # keeps, since the artifact policy admits neither Nsight form
    rm -f "$1/profile.nsys-rep" "$1/nsys-session.txt"
    for text in nsys-start.txt nsys-stop.txt nsys-export.txt; do
        scrub_home <"$1/$text" >"$1/$text.scrubbed" && mv "$1/$text.scrubbed" "$1/$text"
    done
}

helper=$output_directory/handoff-helper.py
cat >"$helper" <<'PYTHON'
import base64
import http.client
import json
import socket
import sys
import time

# request SHAPE PREDICT OUT IMAGE_DIR LARGE_DIR: one greedy /completion of the named shape.
# reply RESPONSE OUT: the reply token ids and timings, refused on a short array.
# cancel SHAPE DELAY PORT PREDICT OUT IMAGE_DIR LARGE_DIR: send the request, close the connection after DELAY seconds.
SHAPES = {
    # (images, prompt with one <__media__> per image)
    "single": (("bars.png",), "<__media__>\nDescribe what this image shows, naming every label and number you can read."),
    "pair-adjacent": (("compare-a.png", "compare-b.png"),
                      "<__media__><__media__>\nTwo images are shown. How many discs does each hold?"),
    "pair-text": (("bars.png", "shapes.png"),
                  "First image:\n<__media__>\nSecond image:\n<__media__>\nDescribe each image, naming every label and number you can read."),
    "large": (("bars-large.png",), "<__media__>\nDescribe what this image shows, naming every label and number you can read."),
    "large-pair-text": (("bars-large.png", "shapes-large.png"),
                        "First image:\n<__media__>\nSecond image:\n<__media__>\nDescribe each image, naming every label and number you can read."),
}


def build(shape, predict, image_directory, large_directory):
    images, prompt = SHAPES[shape]
    encoded = []
    for name in images:
        directory = large_directory if name.endswith("-large.png") else image_directory
        with open(directory + "/" + name, "rb") as handle:
            encoded.append(base64.b64encode(handle.read()).decode("ascii"))
    return {
        "prompt": {"prompt_string": "<|im_start|>user\n" + prompt + "<|im_end|>\n<|im_start|>assistant\n",
                   "multimodal_data": encoded},
        "n_predict": predict,
        "temperature": 0,
        "top_k": 1,
        "seed": 1,
        "cache_prompt": False,
        "return_tokens": True,
        "samplers": ["top_k"],
    }


command = sys.argv[1]
if command == "request":
    shape, predict, out, image_directory, large_directory = sys.argv[2:7]
    json.dump(build(shape, int(predict), image_directory, large_directory), open(out, "w", encoding="utf-8"))
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
elif command == "cancel":
    shape, delay, port, predict, out, image_directory, large_directory = sys.argv[2:9]
    request = build(shape, int(predict), image_directory, large_directory)
    # an abandoned request has to outlive its client, so it ignores EOS
    request["ignore_eos"] = True
    body = json.dumps(request).encode("utf-8")
    connection = http.client.HTTPConnection("127.0.0.1", int(port), timeout=600)
    started = time.monotonic()
    connection.putrequest("POST", "/completion")
    connection.putheader("Content-Type", "application/json")
    connection.putheader("Content-Length", str(len(body)))
    connection.endheaders()
    connection.send(body)
    time.sleep(float(delay))
    received = 0
    try:
        connection.sock.setblocking(False)
        received = len(connection.sock.recv(65536))
    except (BlockingIOError, socket.error):
        received = 0
    connection.close()
    json.dump({"shape": shape, "delay_s": float(delay), "elapsed_s": round(time.monotonic() - started, 4),
               "bytes_received_before_close": received}, open(out, "w", encoding="utf-8"))
else:
    raise SystemExit("unknown command %s" % command)
PYTHON

refusals=0
send_request() {
    # send_request ARM_DIRECTORY LABEL SHAPE KEY: one request, its reply retained and scrubbed
    python3 "$helper" request "$3" "$predict_tokens" "$1/request-$2.json" "$image_directory" "$large_image_directory"
    if post /completion "$1/request-$2.json" "$1/response-$2.json" &&
        scrub_home <"$1/response-$2.json" >"$1/response-$2.scrubbed" &&
        mv "$1/response-$2.scrubbed" "$1/response-$2.json" &&
        python3 "$helper" reply "$1/response-$2.json" "$1/reply-$2.json"; then
        record "$4:$2" "completed prompt_n=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prompt_n"])' "$1/reply-$2.json") prompt_ms=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prompt_ms"])' "$1/reply-$2.json")"
        rm -f "$1/request-$2.json"
        return 0
    fi
    record "$4:$2" refused
    rm -f "$1/request-$2.json"
    return 1
}

run_sequence() {
    # run_sequence ARM_DIRECTORY KEY REPEATS: the request shapes, REPEATS times
    request_index=0
    repeat=1
    while [ "$repeat" -le "$3" ]; do
        for shape in $request_shapes; do
            request_index=$((request_index + 1))
            label=$(printf '%02d-%s' "$request_index" "$shape")
            send_request "$1" "$label" "$shape" "$2" || refusals=$((refusals + 1))
        done
        repeat=$((repeat + 1))
    done
}

finish_arm() {
    # finish_arm ARM_DIRECTORY KEY EXPECT: scrub the log and read the trace
    scrub_home <"$1/server.log" >"$1/server.log.scrubbed" && mv "$1/server.log.scrubbed" "$1/server.log"
    if python3 "$trace_reader" "$1/server.log" --out "$1" --expect "$3" >"$1/trace-summary.txt" 2>&1; then
        record "$2:trace" "holds $(grep -E '^(slices|entries|split_entries|multi_view_entries|multi_entry_batches|nonzero_chunk_offset_slices|device_data_reuses)=' "$1/trace-summary.txt" | tr '\n' ' ')"
    else
        record "$2:trace" "refused $(grep -c '^refused:' "$1/trace-summary.txt") $(grep -m1 '^refused:' "$1/trace-summary.txt")"
        refusals=$((refusals + 1))
    fi
}

arm_environment_of() {
    case $1 in device | device-close) printf 'LLAMA_MTMD_EMBD_DEVICE=1' ;; *) printf '' ;; esac
}
arm_mode_of() {
    case $1 in device | device-close) printf 'device' ;; *) printf 'host' ;; esac
}

run_identity_arm() {
    # run_identity_arm GEOMETRY ARM
    geometry=$1
    arm=$2
    key=identity:$geometry:$arm
    arm_directory=$output_directory/identity-$geometry/$arm
    case $geometry in
        split) batch=$split_batch; ubatch=$split_ubatch ;;
        *) batch=$model_batch; ubatch=$model_ubatch ;;
    esac
    if ! start_server "$arm_directory" "$(arm_environment_of "$arm")" 1 "$batch" "$ubatch"; then
        record "$key:server" refused
        refusals=$((refusals + 1))
        stop_server
        return 1
    fi
    expected_mode=$(arm_mode_of "$arm")
    case $expected_mode in device) expected_flag=on ;; *) expected_flag=off ;; esac
    if grep -qF "embd_device=$expected_flag" "$arm_directory/server.log"; then
        record "$key:embd_device" "$expected_flag"
    else
        record "$key:embd_device" "unreported expected=$expected_flag"
        refusals=$((refusals + 1))
    fi
    run_sequence "$arm_directory" "$key" "$repeats"
    stop_server
    finish_arm "$arm_directory" "$key" "$expected_mode"
}

run_lifetime_arm() {
    # run_lifetime_arm ARM: three abandoned large requests, each followed by
    # an ordinary one, then the large request completed and a closing one
    arm=$1
    key=lifetime:$arm
    arm_directory=$output_directory/lifetime/$arm
    if ! start_server "$arm_directory" "$(arm_environment_of "$arm")" 1 "$model_batch" "$model_ubatch"; then
        record "$key:server" refused
        refusals=$((refusals + 1))
        stop_server
        return 1
    fi
    expected_mode=$(arm_mode_of "$arm")
    # the first request warms the projector so the later cancellation
    # delays land where the log says they do rather than inside first-use
    send_request "$arm_directory" 00-warm single "$key" || refusals=$((refusals + 1))
    step=0
    for delay in 0.02 0.1 0.6; do
        step=$((step + 1))
        python3 "$helper" cancel large "$delay" "$server_port" 2048 "$arm_directory/cancel-$step.json" "$image_directory" "$large_image_directory"
        record "$key:cancel-$step" "$(tr -d '\n' <"$arm_directory/cancel-$step.json")"
        # the abandoned request is still being served or torn down; the next
        # one queues behind it and the reply it returns is what is compared
        label=$(printf '%02d-after-cancel-%s' "$step" single)
        send_request "$arm_directory" "$label" single "$key" || refusals=$((refusals + 1))
        if curl --silent --fail --max-time 5 "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            record "$key:health-$step" ok
        else
            record "$key:health-$step" refused
            refusals=$((refusals + 1))
        fi
    done
    send_request "$arm_directory" 04-large large "$key" || refusals=$((refusals + 1))
    send_request "$arm_directory" 05-close single "$key" || refusals=$((refusals + 1))
    stop_server
    finish_arm "$arm_directory" "$key" "$expected_mode"
}

run_transfer_arm() {
    # run_transfer_arm ARM: the registry-geometry sequence once, recorder off, under nsys
    arm=$1
    key=transfer:$arm
    arm_directory=$output_directory/transfer/$arm
    if ! start_profiled_server "$arm_directory" "$(arm_environment_of "$arm")" "$model_batch" "$model_ubatch"; then
        record "$key:server" refused
        refusals=$((refusals + 1))
        stop_server
        return 1
    fi
    run_sequence "$arm_directory" "$key" 1
    if ! stop_profiled_server "$arm_directory"; then
        record "$key:capture" refused
        refusals=$((refusals + 1))
        return 1
    fi
    scrub_home <"$arm_directory/server.log" >"$arm_directory/server.log.scrubbed" && mv "$arm_directory/server.log.scrubbed" "$arm_directory/server.log"
    if grep -q 'embd_handoff\|clip_embd_row' "$arm_directory/server.log"; then
        record "$key:recorder" "on refused"
        refusals=$((refusals + 1))
    else
        record "$key:recorder" off
    fi
    record "$key:capture" "$(sha256sum "$arm_directory/profile.sqlite" | cut -d ' ' -f 1)"
    # the export is read by the comparison below and then removed, so the
    # record carries the digest, the copy table, and the summary
    printf '%s\n' "$arm_directory/profile.sqlite" >>"$output_directory/captures-to-remove.txt"
}

for stage in $stages; do
    case $stage in
        identity)
            for geometry in $geometries; do
                for arm in $arms; do
                    run_identity_arm "$geometry" "$arm" || :
                done
            done
            ;;
        lifetime)
            for arm in host device; do
                run_lifetime_arm "$arm" || :
            done
            ;;
        transfer)
            for arm in host device; do
                run_transfer_arm "$arm" || :
            done
            ;;
    esac
done

gpu_ownership_inspect >"$output_directory/clients-close.txt" 2>&1 || :
record clients_close "$(tr '\n' ';' <"$output_directory/clients-close.txt")"

# The comparison holds every arm to the first arm of its stage and geometry:
# replies token for token, slices digest for digest on their joined
# position, the projector's per-row digests per chunk, and the device arm's
# own placement; the transfer captures are read against the embedding sizes
# the identity stage recorded at the registry geometry.
python3 - "$output_directory" "$stages" "$geometries" "$arms" "$transfer_reader" "$repeats" "$required_coverage" >"$output_directory/comparison.tsv" <<'PYTHON'
import json
import pathlib
import subprocess
import sys

directory = pathlib.Path(sys.argv[1])
stages = sys.argv[2].split()
geometries = sys.argv[3].split()
arms = sys.argv[4].split()
transfer_reader = sys.argv[5]
repeats = int(sys.argv[6])
required_coverage = sys.argv[7].split()
refused = 0
print("check\tstage\tarm\tresult\tdetail")


def replies(arm_directory):
    out = {}
    for path in sorted(arm_directory.glob("reply-*.json")):
        out[path.stem[len("reply-"):]] = json.load(open(path))["tokens"]
    return out


def table(path):
    if not path.exists():
        return []
    lines = path.read_text().splitlines()
    if not lines:
        return []
    columns = lines[0].split("\t")
    return [dict(zip(columns, line.split("\t"))) for line in lines[1:]]


def slice_key(row):
    return (row["request"], row["image_ordinal"], row["chunk_ordinal"], row["slice"])


def slice_value(row):
    return (row["n_tokens"], row["chunk_row_first"], row["tensor_row_first"], row["digest"])


def entry_key(row):
    return (row["request"], row["image_ordinal"], row["chunk_ordinal"])


def compare(label, base_directory, arm_directory, arm):
    global refused
    base_replies = replies(base_directory)
    arm_replies = replies(arm_directory)
    labels = sorted(set(base_replies) | set(arm_replies))
    missing = [l for l in labels if l not in arm_replies or l not in base_replies]
    differing = [l for l in labels if l in arm_replies and l in base_replies and arm_replies[l] != base_replies[l]]
    if missing or differing or not labels:
        refused += 1
        print("reply_identity\t%s\t%s\trefused\tmissing=%s differing=%s" % (label, arm, ",".join(missing) or "-", ",".join(differing) or "-"))
    else:
        print("reply_identity\t%s\t%s\tidentical\trequests=%d" % (label, arm, len(labels)))
    base_slices = {slice_key(r): slice_value(r) for r in table(base_directory / "slices.tsv")}
    arm_slices = {slice_key(r): slice_value(r) for r in table(arm_directory / "slices.tsv")}
    if not base_slices or base_slices != arm_slices:
        refused += 1
        differing = sorted(k for k in set(base_slices) | set(arm_slices) if base_slices.get(k) != arm_slices.get(k))
        print("slice_digests\t%s\t%s\trefused\tbase=%d arm=%d first_difference=%s" % (
            label, arm, len(base_slices), len(arm_slices), ":".join(differing[0]) if differing else "-"))
    else:
        print("slice_digests\t%s\t%s\tidentical\tslices=%d" % (label, arm, len(arm_slices)))
    base_entries = {entry_key(r): (r["n_tokens"], r["clip_rows"]) for r in table(base_directory / "entries.tsv")}
    arm_entries = {entry_key(r): (r["n_tokens"], r["clip_rows"]) for r in table(arm_directory / "entries.tsv")}
    if not base_entries or base_entries != arm_entries:
        refused += 1
        print("projector_rows\t%s\t%s\trefused\tbase=%d arm=%d" % (label, arm, len(base_entries), len(arm_entries)))
    else:
        print("projector_rows\t%s\t%s\tidentical\tchunks=%d" % (label, arm, len(arm_entries)))
    summary = arm_directory / "trace-summary.txt"
    verdict = "-"
    if summary.exists():
        for line in summary.read_text().splitlines():
            if line.startswith("verdict="):
                verdict = line.split("=", 1)[1]
    if verdict != "holds":
        refused += 1
        print("trace_verdict\t%s\t%s\trefused\t%s" % (label, arm, verdict))
    else:
        print("trace_verdict\t%s\t%s\tholds\t-" % (label, arm))


registry_slices = []
registry_entries = []
reached = {}
if "identity" in stages:
    for geometry in geometries:
        base = directory / ("identity-" + geometry) / arms[0]
        for arm in arms:
            compare(geometry, base, directory / ("identity-" + geometry) / arm, arm)
        device = [a for a in arms if a.startswith("device")]
        if device:
            rows = table(directory / ("identity-" + geometry) / device[0] / "slices.tsv")
            entries = table(directory / ("identity-" + geometry) / device[0] / "entries.tsv")
            if geometry == "registry":
                registry_slices, registry_entries = rows, entries
            conditions = {
                "chunk_in_one_ubatch": any(e["slices"] == "1" for e in entries),
                "chunk_split_across_ubatches": any(int(e["slices"]) > 1 for e in entries),
                "chunk_split_across_decodes": any(int(e["views"]) > 1 for e in entries),
                "several_chunks_in_one_batch": any(int(e["row_offset"]) > 0 for e in entries),
                "nonzero_row_offset_slices": any(int(r["chunk_row_first"]) > 0 for r in rows),
                "final_partial_ubatch": any(r["n_tokens"] != rows[0]["n_tokens"] for r in rows) if rows else False,
            }
            for k, v in conditions.items():
                reached[k] = reached.get(k, False) or v
            print("coverage\t%s\t%s\t%s\t%s" % (geometry, device[0], "holds" if all(conditions.values()) else "partial",
                                              " ".join("%s=%s" % (k, "yes" if v else "no") for k, v in conditions.items())))
            token_counts = sorted({(e["image"], e["n_tokens"]) for e in entries})
            print("encoder_tokens\t%s\t%s\tobserved\t%s" % (geometry, device[0], " ".join("%s:%s" % t for t in token_counts)))

if "identity" in stages:
    # every required condition has to be reached by some geometry
    unreached = [k for k in required_coverage if not reached.get(k, False)]
    if unreached:
        refused += 1
    print("required_coverage\tidentity\t-\t%s\treached=%s unreached=%s" % (
        "refused" if unreached else "holds",
        ",".join(k for k in required_coverage if reached.get(k, False)) or "-", ",".join(unreached) or "-"))

if "lifetime" in stages:
    base = directory / "lifetime" / "host"
    for arm in ("host", "device"):
        compare("lifetime", base, directory / "lifetime" / arm, arm)
        cancels = sorted((directory / "lifetime" / arm).glob("cancel-*.json"))
        print("cancellations\tlifetime\t%s\tobserved\t%s" % (arm, " ".join(
            "%s:elapsed=%s:received=%s" % (p.stem, json.load(open(p))["elapsed_s"], json.load(open(p))["bytes_received_before_close"]) for p in cancels)))
        # where the server acted on each disconnect: the cancel line and the
        # release that follows it, with the slot's position at release
        log = directory / "lifetime" / arm / "server.log"
        releases = []
        if log.exists():
            pending = False
            for line in log.read_text(errors="replace").splitlines():
                if "cancel task" in line:
                    pending = True
                elif pending and "stop processing: n_tokens = " in line:
                    releases.append(line.split("stop processing: n_tokens = ", 1)[1].split(",", 1)[0])
                    pending = False
        print("cancel_releases\tlifetime\t%s\tobserved\tcancelled=%d release_n_tokens=%s" % (arm, len(releases), ",".join(releases) or "-"))

if "transfer" in stages:
    # the embedding sizes: every ubatch slice and every batch's whole output
    sizes = set()
    row_bytes = None
    for r in registry_slices:
        sizes.add(int(r["byte_last_p1"]) - int(r["byte_first"]))
        row_bytes = (int(r["byte_last_p1"]) - int(r["byte_first"])) // int(r["n_tokens"])
    per_batch = {}
    for e in registry_entries:
        key = (e["request"], e["batch_serial"])
        per_batch[key] = per_batch.get(key, 0) + int(e["n_tokens"])
    if row_bytes:
        for n in per_batch.values():
            sizes.add(n * row_bytes)
    # A byte count alone is a coarse key: a scheduler-staged graph input such
    # as the attention mask can carry an embedding-sized payload by
    # coincidence, at the same position as the host path's upload, ahead of
    # the language model's first kernel. The host arm is the control: its
    # sized uploads beyond one per slice are the coincident population of
    # the sequence, as a multiset of byte counts, and a device-arm upload is
    # exempt only where it takes one of those byte counts out of that
    # multiset; every other embedding-sized or row-multiple host-direction
    # copy in the device arm is a refusal. The device-to-host side takes the
    # same discount, since a context checkpoint save reads a whole number of
    # rows back on both paths, and the device-to-device count has to equal
    # the batch count exactly.
    expected_htod = len(registry_slices) // max(1, repeats)
    expected_dtoh = len({(e["request"], e["batch_serial"]) for e in registry_entries}) // max(1, repeats)
    row_bytes = None
    for r in registry_slices:
        row_bytes = (int(r["byte_last_p1"]) - int(r["byte_first"])) // int(r["n_tokens"])
    copies_by_arm = {}
    for arm in ("host", "device"):
        capture = directory / "transfer" / arm / "profile.sqlite"
        if not capture.exists() or not sizes or not row_bytes:
            refused += 1
            print("transfer\ttransfer\t%s\trefused\tcapture_or_sizes_absent" % arm)
            continue
        completed = subprocess.run([sys.executable, transfer_reader, str(capture), "--sizes", ",".join(str(s) for s in sorted(sizes)),
                                    "--row-bytes", str(row_bytes),
                                    "--out", str(directory / "transfer" / arm / "copies.tsv")], capture_output=True, text=True)
        (directory / "transfer" / arm / "transfer-summary.txt").write_text(completed.stdout + completed.stderr)
        copies_by_arm[arm] = [r for r in table(directory / "transfer" / arm / "copies.tsv")
                              if r["embedding_sized"] == "yes" or r["row_multiple"] == "yes"]

    def multiset(rows):
        out = {}
        for r in rows:
            out[int(r["bytes"])] = out.get(int(r["bytes"]), 0) + 1
        return out

    host_copies = copies_by_arm.get("host", [])
    host_htod = [r for r in host_copies if r["kind"] == "Host-to-Device"]
    host_dtoh = [r for r in host_copies if r["kind"] == "Device-to-Host"]
    # the host arm's own uploads, one per slice of the single pass, taken out
    # of its sized uploads by byte count; what remains is coincident
    requests_per_pass = len({e["request"] for e in registry_entries}) // max(1, repeats)
    slice_sizes = {}
    for r in registry_slices:
        if int(r["request"]) > requests_per_pass:
            continue
        n = int(r["byte_last_p1"]) - int(r["byte_first"])
        slice_sizes[n] = slice_sizes.get(n, 0) + 1
    batch_sizes = {}
    per_batch_rows = {}
    for e in registry_entries:
        if int(e["request"]) > requests_per_pass:
            continue
        key = (e["request"], e["batch_serial"])
        per_batch_rows[key] = per_batch_rows.get(key, 0) + int(e["n_tokens"])
    for n_rows in per_batch_rows.values():
        batch_sizes[n_rows * row_bytes] = batch_sizes.get(n_rows * row_bytes, 0) + 1

    def excess(rows, own):
        out = multiset(rows)
        for n, count in own.items():
            out[n] = out.get(n, 0) - count
        return {n: c for n, c in out.items() if c > 0}

    excess_htod = excess(host_htod, slice_sizes)
    excess_dtoh = excess(host_dtoh, batch_sizes)
    for arm in ("host", "device"):
        if arm not in copies_by_arm:
            continue
        rows = copies_by_arm[arm]
        dtoh = sum(1 for r in rows if r["kind"] == "Device-to-Host")
        htod = sum(1 for r in rows if r["kind"] == "Host-to-Device")
        dtod = sum(1 for r in rows if r["kind"] == "Device-to-Device" and r["embedding_sized"] == "yes")
        detail = "dtoh=%d htod=%d dtod=%d row_bytes=%d sizes=%s" % (dtoh, htod, dtod, row_bytes, ",".join(str(s) for s in sorted(sizes)))
        if arm == "host":
            ok = dtoh >= expected_dtoh > 0 and htod >= expected_htod > 0
            print("transfer\ttransfer\thost\t%s\t%s expected_dtoh=%d expected_htod=%d coincident_uploads=%s coincident_reads=%s" % (
                "control_holds" if ok else "refused", detail, expected_dtoh, expected_htod,
                ",".join("%d:%d" % (n, c) for n, c in sorted(excess_htod.items())) or "-",
                ",".join("%d:%d" % (n, c) for n, c in sorted(excess_dtoh.items())) or "-"))
        else:
            allowance = {"Host-to-Device": dict(excess_htod), "Device-to-Host": dict(excess_dtoh)}
            unexplained = []
            for r in rows:
                if r["kind"] in allowance:
                    n = int(r["bytes"])
                    if allowance[r["kind"]].get(n, 0) > 0:
                        allowance[r["kind"]][n] -= 1
                    else:
                        unexplained.append(r)
            ok = not unexplained and dtod == expected_dtoh > 0
            print("transfer\ttransfer\tdevice\t%s\t%s expected_dtod=%d unexplained=%d host_copies=%s" % (
                "holds" if ok else "refused", detail, expected_dtoh, len(unexplained),
                ";".join("%s:%s:%s>%s" % (r["kind"], r["bytes"], r["kernel_before"], r["kernel_after"])
                         for r in rows if r["kind"] in ("Device-to-Host", "Host-to-Device")) or "-"))
        if not ok:
            refused += 1
    base = replies(directory / "transfer" / "host")
    subject = replies(directory / "transfer" / "device")
    if base and base == subject:
        print("reply_identity\ttransfer\tdevice\tidentical\trequests=%d" % len(base))
    else:
        refused += 1
        print("reply_identity\ttransfer\tdevice\trefused\thost=%d device=%d" % (len(base), len(subject)))

print("refused_checks\t-\t-\t%d\t-" % refused)
sys.exit(1 if refused else 0)
PYTHON
comparison_status=$?
if [ -f "$output_directory/captures-to-remove.txt" ]; then
    while IFS= read -r capture; do rm -f "$capture"; done <"$output_directory/captures-to-remove.txt"
    rm -f "$output_directory/captures-to-remove.txt"
fi
for ownership_record in ownership-open.txt clients-open.txt clients-close.txt summary.tsv; do
    scrub_home <"$output_directory/$ownership_record" >"$output_directory/$ownership_record.scrubbed" && mv "$output_directory/$ownership_record.scrubbed" "$output_directory/$ownership_record"
done
comparison_refusals=$(awk -F '\t' '$1 == "refused_checks" { print $4 }' "$output_directory/comparison.tsv")
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
