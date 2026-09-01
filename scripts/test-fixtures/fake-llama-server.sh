#!/bin/sh
set -eu

# The stand-in for llama-server that lets a policy test, a projector probe, and
# the graph-alias lane run without the device. It answers in three stages, and
# each stage has its own gate so no stage hides another: an identity query, the
# launch argv record, and a served endpoint.

# A build identity answers before the argv recorder runs, so an identity query
# leaves the recorded launch argv of the run under test in place.
if [ "${1:-}" = --version ]; then
    printf 'version: 0 (fake)\nbuild: 0000000 with fake\n'
    exit 0
fi

# One server answers both port names, because a fake llama-server serving
# /tokenize and /v1/chat/completions for a projector probe and one serving
# /completion for a token-identity sweep are the same process with different
# routes exercised. Two names rather than one keeps each caller's variable, and
# naming both asks one process for two listeners.
if [ -n "${QWEN_POLICY_TEST_HTTP_PORT:-}" ] && [ -n "${QWEN_FAKE_SERVER_PORT:-}" ]; then
    printf 'set one of QWEN_POLICY_TEST_HTTP_PORT and QWEN_FAKE_SERVER_PORT\n' >&2
    exit 2
fi
serving_port=${QWEN_POLICY_TEST_HTTP_PORT:-${QWEN_FAKE_SERVER_PORT:-}}

# The argv record has two destinations because it has two readers. A single
# launch under test writes one file named by QWEN_POLICY_TEST_OUTPUT; a sweep
# that starts many servers in turn writes one file per process into
# QWEN_FAKE_SERVER_STATE_DIRECTORY, since a single path would retain the last
# launch alone. Either destination satisfies the requirement, so a caller that
# names neither is the argument error it always was.
if [ -z "${QWEN_POLICY_TEST_OUTPUT:-}" ] &&
    [ -z "${QWEN_FAKE_SERVER_STATE_DIRECTORY:-}" ]; then
    printf 'QWEN_POLICY_TEST_OUTPUT is required\n' >&2
    exit 2
fi

record_launch() {
    printf 'affinity=%s\n' "$(awk '/Cpus_allowed_list/ { print $2 }' /proc/self/status)"
    printf 'nice=%s\n' "$(ps -o ni= -p $$ | tr -d ' ')"
    printf 'low=%s\n' "${GGML_VK_LOW_PRIORITY:-unset}"
    printf 'duty=%s\n' "${GGML_VK_DUTY_CYCLE_PERCENT:-unset}"
    printf 'serialized=%s\n' "${GGML_VK_SERIALIZE_SUBMISSIONS:-unset}"
    printf 'max_nodes=%s\n' "${GGML_VK_MAX_NODES_PER_SUBMIT:-unset}"
    # cuda-runtime-env.sh exports QWEN_CUDA_PROFILE and vulkan-runtime-env.sh
    # exports QWEN_VULKAN_PROFILE; QWEN_SERVING_BACKEND selects exactly one
    # wrapper per launch, so exactly one of the two is ever set.
    printf 'profile=%s\n' "${QWEN_CUDA_PROFILE:-${QWEN_VULKAN_PROFILE:-unset}}"
    printf 'amd_priority=%s\n' "${AMD_PRIORITY:-unset}"
    printf 'memory_priority=%s\n' "${GGML_VK_ENABLE_MEMORY_PRIORITY:-unset}"
    printf 'allow_graphics=%s\n' "${GGML_VK_ALLOW_GRAPHICS_QUEUE:-unset}"
    printf 'strict=%s\n' "${LLAMA_NO_CPU_FALLBACK:-unset}"
    printf 'disable_graph_optimize=%s\n' "${GGML_VK_DISABLE_GRAPH_OPTIMIZE:-unset}"
    printf 'display=%s\n' "${DISPLAY-unset}"
    printf 'wayland=%s\n' "${WAYLAND_DISPLAY-unset}"
    printf 'cuda_disable_graphs=%s\n' "${GGML_CUDA_DISABLE_GRAPHS:-unset}"
    printf 'cuda_disable_fusion=%s\n' "${GGML_CUDA_DISABLE_FUSION:-unset}"
    printf 'cuda_pdl=%s\n' "${GGML_CUDA_PDL:-unset}"
    printf 'cuda_unified_memory=%s\n' "${GGML_CUDA_ENABLE_UNIFIED_MEMORY:-unset}"
    printf 'cuda_devices=%s\n' "${CUDA_VISIBLE_DEVICES:-unset}"
    printf 'argument_count=%s\n' "$#"
    for argument in "$@"; do
        printf 'argument=%s\n' "$argument"
    done
}

if [ -n "${QWEN_POLICY_TEST_OUTPUT:-}" ]; then
    record_launch "$@" >"$QWEN_POLICY_TEST_OUTPUT"
fi
if [ -n "${QWEN_FAKE_SERVER_STATE_DIRECTORY:-}" ]; then
    mkdir -p "$QWEN_FAKE_SERVER_STATE_DIRECTORY"
    record_launch "$@" >"$QWEN_FAKE_SERVER_STATE_DIRECTORY/argv-$$.txt"
fi

# The strict-placement checks read two refusals ahead of the served load, and
# each is keyed on the argv the check passes: a load placed on the host by
# `--device none` ends at the buffer selection, and a device load carrying no
# `--override-tensor` ends at the graph check on the token embedding. Both are
# the lines patches/llama-no-cpu-fallback.patch prints, so a fixture test of
# test-strict-cuda-placement.sh reaches every branch without the device.
if [ -n "${QWEN_FAKE_SERVER_STRICT:-}" ]; then
    case " $* " in
        *' --device none '*)
            printf 'tensor token_embd.weight selected CPU buffer CPU while LLAMA_NO_CPU_FALLBACK is enabled\n' >&2
            exit 1
            ;;
    esac
    case " $* " in
        *' --override-tensor '*) ;;
        *)
            printf 'CPU fallback rejected for graph node inp_embd (GET_ROWS)\n' >&2
            exit 1
            ;;
    esac
fi

[ -n "$serving_port" ] || exit 0

# The token array /completion returns depends on the two variables the
# graph-alias lane separates: whether GGML_VK_DISABLE_GRAPH_OPTIMIZE is set,
# and whether the build directory this copy was launched from carries an
# alias-marker file. A build lacking the marker with the optimizer on returns
# the reordered sequence, which reproduces both the divergent and the identical
# outcome without a device.
fake_build_directory=$(dirname -- "$(dirname -- "$0")")
fake_tokens=${QWEN_FAKE_SERVER_TOKENS:-'10 11 12 13 14 15 16 17'}
if [ -z "${GGML_VK_DISABLE_GRAPH_OPTIMIZE:-}" ] &&
    [ ! -e "$fake_build_directory/alias-marker" ] &&
    [ -n "${QWEN_FAKE_SERVER_TOKENS_OPTIMIZE:-}" ]; then
    fake_tokens=$QWEN_FAKE_SERVER_TOKENS_OPTIMIZE
fi

# The load banner llama-server prints for a fully offloaded model. A caller that
# reads placement from the log sees the same three lines here, and
# QWEN_FAKE_SERVER_PLACEMENT=cpu withholds them so the caller's rejection path
# is reachable too.
case ${QWEN_FAKE_SERVER_PLACEMENT:-vulkan} in
    vulkan)
        printf 'load_tensors: Vulkan0 model buffer size = 1234.00 MiB\n'
        printf 'llama_kv_cache: Vulkan0 KV buffer size = 56.00 MiB\n'
        printf 'llama_context: Vulkan0 compute buffer size = 78.00 MiB\n'
        ;;
    cuda)
        printf 'load_tensors: CUDA0 model buffer size = 1234.00 MiB\n'
        printf 'llama_kv_cache: CUDA0 KV buffer size = 56.00 MiB\n'
        printf 'llama_context: CUDA0 compute buffer size = 78.00 MiB\n'
        ;;
esac

# One whitespace-separated word stands for one token and each image part
# contributes a fixed lump, which is the shape a projector-loaded prompt has:
# the /tokenize route sees the text alone and timings.prompt_n carries the image
# tokens beside it.
QWEN_FAKE_SERVER_RESOLVED_PORT=$serving_port \
QWEN_FAKE_SERVER_RESOLVED_TOKENS=$fake_tokens \
QWEN_POLICY_TEST_IMAGE_TOKENS=${QWEN_POLICY_TEST_IMAGE_TOKENS:-300} \
QWEN_POLICY_TEST_REPLY=${QWEN_POLICY_TEST_REPLY:-JUN} \
QWEN_POLICY_TEST_PREDICTED_CAP=${QWEN_POLICY_TEST_PREDICTED_CAP:-0} \
    exec python3 - <<'PY'
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(os.environ["QWEN_FAKE_SERVER_RESOLVED_PORT"])
tokens = [int(value) for value in os.environ["QWEN_FAKE_SERVER_RESOLVED_TOKENS"].split()]
image_tokens = int(os.environ["QWEN_POLICY_TEST_IMAGE_TOKENS"])
reply = os.environ["QWEN_POLICY_TEST_REPLY"]
# The completion text a strict-placement check compares across two requests.
content = os.environ.get("QWEN_FAKE_SERVER_CONTENT", "")
# A positive cap stops the reply short of the requested length, which is the
# shape a fixed-length decode fails in: the answer arrives and carries fewer
# tokens than the caller asked for.
predicted_cap = int(os.environ["QWEN_POLICY_TEST_PREDICTED_CAP"])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def respond(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self.respond({"status": "ok"})
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length).decode() or "{}")
        if self.path.startswith("/tokenize"):
            words = len(str(body.get("content", "")).split())
            self.respond({"tokens": list(range(words))})
            return
        # The token-identity route. A fixed cycle over the configured array
        # fills the requested length, so the reply is exactly as long as
        # n_predict asked and differs between arms only where the array does.
        if self.path.startswith("/completion"):
            predict = int(body.get("n_predict") or len(tokens))
            emitted = [tokens[index % len(tokens)] for index in range(predict)]
            self.respond({"content": content, "tokens": emitted,
                          "tokens_predicted": predict})
            return
        if not self.path.startswith("/v1/chat/completions"):
            self.send_error(404)
            return
        prompt_tokens = 0
        for message in body.get("messages") or []:
            for part in message.get("content") or []:
                if part.get("type") == "text":
                    prompt_tokens += len(part.get("text", "").split())
                if part.get("type") == "image_url":
                    prompt_tokens += image_tokens
        predicted = int(body.get("max_tokens") or 1)
        if predicted_cap > 0:
            predicted = min(predicted, predicted_cap)
        self.respond({
            "choices": [{"message": {"role": "assistant", "content": reply}}],
            "timings": {"prompt_n": prompt_tokens, "prompt_ms": 1000.0,
                        "predicted_n": predicted, "predicted_per_second": 4.5}})


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
