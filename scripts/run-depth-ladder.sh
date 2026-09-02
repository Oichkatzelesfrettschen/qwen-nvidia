#!/bin/sh
set -eu

# gpu-ownership: delegated to the serving session.
# This harness starts qwen-webui-session.sh, which is the top-level GPU owner and
# takes the owner lock itself for the whole serving lifetime. The harness holds
# no claim of its own -- one would refuse the session it launched -- and instead
# waits for the `gpu_owner` line the session writes to session.status as proof
# that the lock is held, then drives its arms through that session.

# Drive the exact-token prefill ladder against a single guarded server load.
# One model load serves every rung, so the retained per-rung timings differ
# only by prompt depth rather than by allocation or warm-up state.

if [ "$#" -lt 6 ]; then
    printf 'usage: %s PROFILE MODEL_PATH CONTEXT_SIZE REQUIRED_VULKAN_MIB CORPUS STATE_DIRECTORY [DECODE_TOKENS [DEPTH...]]\n' \
        "$0" >&2
    exit 2
fi

profile=$1
model_path=$2
context_size=$3
required_vulkan_mib=$4
corpus=$5
state_directory=$6
decode_tokens=${7:-128}
shift 7 2>/dev/null || shift 6
if [ "$#" -gt 0 ]; then
    depths="$*"
else
    depths="4096 8192 16384 24000"
fi

initial_guard_nice=$(ps -o ni= -p $$ | tr -d ' ')
if ! renice -n 0 -p $$ >/dev/null 2>&1; then
    printf 'ladder guard cannot normalize CPU priority from nice %s\n' \
        "$initial_guard_nice" >&2
    exit 2
fi
taskset -pc 1 $$ >/dev/null
ionice -c 3 -p $$

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH='' cd -- "$script_directory/.." && pwd)
llama_server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-qwen-cuda-sm89/bin/llama-server"}
static_path=$repository_directory/webui
server_port=${QWEN_SERVER_PORT:-8080}
session_pid=""

cleanup() {
    if [ -n "$session_pid" ]; then
        kill "$session_pid" 2>/dev/null || true
        wait "$session_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

# The profile vocabulary belongs to the backend that serves. qwen-webui-session.sh
# forwards this value to whichever wrapper QWEN_SERVING_BACKEND selects, so the
# ladder's own guard names that wrapper's vocabulary: cuda-runtime-env.sh's
# names under the cuda default, vulkan-runtime-env.sh's under
# QWEN_SERVING_BACKEND=vulkan.
case ${QWEN_SERVING_BACKEND:-cuda} in
    cuda)
        case $profile in
            default | no-graphs | no-fusion | pdl | unified | custom) ;;
            *)
                printf 'unknown CUDA profile: %s\n' "$profile" >&2
                exit 2
                ;;
        esac
        ;;
    vulkan)
        case $profile in
            default | custom) ;;
            *)
                printf 'unknown Vulkan profile: %s\n' "$profile" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        printf 'QWEN_SERVING_BACKEND takes cuda or vulkan: %s\n' \
            "${QWEN_SERVING_BACKEND:-cuda}" >&2
        exit 2
        ;;
esac
if [ ! -x "$llama_server" ] || [ ! -f "$model_path" ] || [ ! -s "$corpus" ]; then
    printf 'server, model, and corpus must exist before a ladder run\n' >&2
    exit 2
fi
if pgrep -x llama-server >/dev/null 2>&1; then
    printf 'another llama-server process is already running\n' >&2
    exit 2
fi

for depth in $depths; do
    case $depth in
        '' | *[!0-9]*)
            printf 'depth must be a positive integer: %s\n' "$depth" >&2
            exit 2
            ;;
    esac
    if [ $((depth + decode_tokens)) -gt "$context_size" ]; then
        printf 'depth %s plus %s decode tokens exceeds the %s token context\n' \
            "$depth" "$decode_tokens" "$context_size" >&2
        exit 2
    fi
done

umask 077
mkdir -p "$state_directory"
printf 'profile=%s\nmodel=%s\ncontext_size=%s\nrequired_vulkan_mib=%s\ncorpus=%s\ndecode_tokens=%s\ndepths=%s\nlatency_mode=%s\n' \
    "$profile" "$model_path" "$context_size" "$required_vulkan_mib" \
    "$corpus" "$decode_tokens" "$depths" "${QWEN_LATENCY_MODE:-terminate}" \
    >"$state_directory/benchmark-inputs.txt"

"$script_directory/qwen-webui-session.sh" \
    "$llama_server" "$model_path" "$static_path" "$context_size" \
    "$required_vulkan_mib" "$server_port" "$state_directory" "$profile" &
session_pid=$!

ready=0
attempt=0
while [ "$attempt" -lt 6000 ]; do
    if grep -F 'state=running ' "$state_directory/session.status" \
        >/dev/null 2>&1 && \
       grep -F 'gpu_owner lock=' "$state_directory/session.status" \
        >/dev/null 2>&1 && \
       curl --silent --fail "http://127.0.0.1:$server_port/health" \
        >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$session_pid" 2>/dev/null; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    printf 'guarded server did not become ready\n' >&2
    [ -r "$state_directory/session.status" ] && \
        sed -n '1p' "$state_directory/session.status" >&2
    [ -r "$state_directory/server.log" ] && \
        tail -n 80 "$state_directory/server.log" >&2
    exit 1
fi

api_key=''
if [ -s "$state_directory/api.key" ]; then
    api_key=$(sed -n '1p' "$state_directory/api.key")
fi
ladder_status=0
: >"$state_directory/ladder-summary.tsv"
printf 'depth\tprefill_tok_per_second\tdecode_tok_per_second\tstatus\n' \
    >>"$state_directory/ladder-summary.tsv"

for depth in $depths; do
    printf 'rung_start_utc=%s depth=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$depth"
    set +e
    QWEN_API_KEY=$api_key taskset -c 0 nice -n 19 ionice -c 3 \
        "$script_directory/run-depth-benchmark.py" \
        "http://127.0.0.1:$server_port" "$corpus" "$depth" "$decode_tokens" \
        "$state_directory/depth-$depth.json" \
        >"$state_directory/depth-$depth.result" \
        2>"$state_directory/depth-$depth.error"
    rung_status=$?
    set -e
    if [ "$rung_status" -eq 0 ]; then
        prefill=$(jq -r '.prefill_tokens_per_second' \
            "$state_directory/depth-$depth.result")
        decode=$(jq -r '.decode_tokens_per_second' \
            "$state_directory/depth-$depth.result")
    else
        prefill=n/a
        decode=n/a
        ladder_status=1
        cat "$state_directory/depth-$depth.error" >&2
    fi
    printf '%s\t%s\t%s\t%s\n' "$depth" "$prefill" "$decode" "$rung_status" \
        >>"$state_directory/ladder-summary.tsv"
    printf 'rung_stop_utc=%s depth=%s status=%s prefill=%s decode=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$depth" "$rung_status" \
        "$prefill" "$decode"
    if ! kill -0 "$(sed -n '1p' "$state_directory/server.pid")" 2>/dev/null; then
        printf 'server exited before the ladder completed\n' >&2
        ladder_status=1
        break
    fi
done

server_pid=$(sed -n '1p' "$state_directory/server.pid")
case $server_pid in
    '' | *[!0-9]*) ;;
    *)
        if kill -0 "$server_pid" 2>/dev/null && \
           [ "$(ps -o comm= -p "$server_pid" | tr -d ' ')" = llama-server ]; then
            kill -TERM "$server_pid"
        fi
        ;;
esac
set +e
wait "$session_pid"
session_status=$?
set -e
session_pid=""

printf 'ladder_status=%s\nsession_status=%s\n' \
    "$ladder_status" "$session_status" >"$state_directory/benchmark-status.txt"
cat "$state_directory/ladder-summary.tsv"
exit "$ladder_status"
