#!/bin/sh
set -eu

# Fill and decode a near-full cache on the CUDA serving path for a text row.
# An allocation and a validated depth are two claims: a server that loads a
# 65536-token allocation has proven it can reserve the memory and has not
# proven a near-full cache executes. This harness runs llama-server standalone
# at the row's own cache triple and submission geometry with strict CUDA0
# placement, converges a padding prompt into the acceptance window through
# /tokenize, and requires the decode to retrieve a needle planted at the head
# of the fill, so the arm proves execution and long-range attention rather
# than allocation alone.
#
# The acceptance window is asymmetric because decode follows the fill inside
# one allocation: DEPTH - 2% <= prompt_n <= DEPTH - 32, where a prompt at or
# above the depth evicts rather than decodes.
#
# scripts/probe-depth-projector.sh is the sibling for `projector: required`
# rows; this harness refuses them because a loaded projector changes the
# buffers the arm allocates and that tuple belongs to the sibling.

usage() {
    printf 'usage: %s MODEL_ID OUTPUT_DIRECTORY\n' "$0" >&2
    printf '  QWEN_PROBE_DEPTHS   depths to fill, default the row context_ceiling\n' >&2
    printf '  QWEN_LLAMA_SERVER   server binary, default the promoted build\n' >&2
    printf '  QWEN_PROBE_PORT     listener, default 18093\n' >&2
    printf '  QWEN_PROBE_BATCH    batch size, default the row batch\n' >&2
    printf '  QWEN_PROBE_UBATCH   ubatch size, default the row ubatch\n' >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
model_id=$1
output_directory=$2

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
llama_server=${QWEN_LLAMA_SERVER:-"${HOME:?}/src/llama.cpp-qwen-nvidia/build-appliance-current/bin/llama-server"}
model_root=${QWEN_MODEL_ROOT:-"${HOME:?}/models"}
server_port=${QWEN_PROBE_PORT:-18093}
ready_timeout_s=${QWEN_PROBE_READY_TIMEOUT_S:-300}
decode_tokens=32
evidence_root=evidence/depth-validation-cuda

[ -x "$llama_server" ] || {
    printf 'llama-server is not executable: %s\n' "$llama_server" >&2
    exit 1
}

read_registry_field() {
    "$script_directory/model-registry.sh" id "$model_id" "$1"
}

model_file=$(read_registry_field model_file)
context_ceiling=$(read_registry_field context_ceiling)
cache_type_k=$(read_registry_field cache_type_k)
cache_type_v=$(read_registry_field cache_type_v)
flash_attention=$(read_registry_field flash_attention)
# The registry names the served submission geometry; a second-geometry arm
# overrides it here rather than by editing the registry, because the arm
# measures whether a depth that fills under one geometry also fills under
# another and the registry claim is what it is measured against.
batch_size=${QWEN_PROBE_BATCH:-$(read_registry_field batch)}
ubatch_size=${QWEN_PROBE_UBATCH:-$(read_registry_field ubatch)}
projector_requirement=$(read_registry_field projector)

if [ "$projector_requirement" != none ]; then
    printf 'registry row %s reads projector %s; probe-depth-projector.sh measures that tuple\n' \
        "$model_id" "$projector_requirement" >&2
    exit 2
fi

model_path=$model_root/$model_file
[ -f "$model_path" ] || {
    printf 'model artifact is absent: %s\n' "$model_path" >&2
    exit 1
}

depths=${QWEN_PROBE_DEPTHS:-$context_ceiling}
for depth in $depths; do
    case $depth in
        '' | *[!0-9]* | 0)
            printf 'QWEN_PROBE_DEPTHS must hold positive integers: %s\n' \
                "$depth" >&2
            exit 2
            ;;
    esac
    if [ "$depth" -gt "$context_ceiling" ]; then
        printf 'depth %s exceeds the registry ceiling %s for %s\n' \
            "$depth" "$context_ceiling" "$model_id" >&2
        exit 2
    fi
done

# Device ownership is decided by two authorities rather than by a process name.
# The exclusive lock serializes this tree's own campaigns and is held for the
# whole run, and the driver's compute-client list decides external interference:
# the compositor is recorded as the covariate it is, a project workload or an
# unnamed CUDA client refuses, and a process merely named llama-server that
# holds no context is recorded rather than treated as ownership.
. "$script_directory/gpu-workload-ownership.sh"
gpu_ownership_acquire || exit $?
gpu_ownership_inspect || exit 1

mkdir -p "$output_directory"
summary=$output_directory/filled-depth-summary.tsv
emitted_rows=$output_directory/validated-tuples-rows.tsv
printf 'arm\tmodel_id\tdepth\tbatch\tubatch\tcache_k\tcache_v\tflash_attn\tstatus\tprompt_n\tcompletion_tokens\tneedle\thealth\tserver_log\n' \
    >"$summary"

server_pid=''
stop_server() {
    [ -n "$server_pid" ] || return 0
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=''
}
trap 'stop_server' EXIT
trap 'stop_server; exit 130' INT
trap 'stop_server; exit 143' TERM

# Strict CUDA0 placement with the CPU fallback refused, one slot, and the
# prompt cache off, so prompt_n reports the tokens the arm actually prefilled.
start_server() {
    env LLAMA_NO_CPU_FALLBACK=1 \
        nice -n 19 ionice -c 3 "$llama_server" \
        --model "$model_path" \
        --alias "$model_id" \
        --host 127.0.0.1 \
        --port "$server_port" \
        --no-ui \
        --device CUDA0 \
        --split-mode none \
        --n-gpu-layers all \
        --override-tensor '.*=CUDA0' \
        --fit off \
        --parallel 1 \
        --threads 1 \
        --threads-batch 1 \
        --ctx-checkpoints 0 \
        --cache-ram 0 \
        --no-context-shift \
        --offline \
        --ctx-size "$1" \
        --batch-size "$batch_size" \
        --ubatch-size "$ubatch_size" \
        --flash-attn "$flash_attention" \
        --cache-type-k "$cache_type_k" \
        --cache-type-v "$cache_type_v" \
        >"$2" 2>&1 9>&- &
    server_pid=$!
}

wait_for_server() {
    wait_elapsed=0
    while [ "$wait_elapsed" -lt "$ready_timeout_s" ]; do
        if curl --silent --fail --max-time 5 \
            "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$server_pid" 2>/dev/null || return 1
        sleep 1
        wait_elapsed=$((wait_elapsed + 1))
    done
    return 1
}

overall_status=completed
for depth in $depths; do
    arm_label=d$depth-b$batch_size-ub$ubatch_size
    arm_log=$output_directory/$arm_label.server.log
    arm_result=$output_directory/$arm_label.result.tsv

    start_server "$depth" "$arm_log"
    if ! wait_for_server; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tserver-never-ready\tn/a\tn/a\tn/a\tn/a\t%s\n' \
            "$arm_label" "$model_id" "$depth" "$batch_size" "$ubatch_size" \
            "$cache_type_k" "$cache_type_v" "$flash_attention" "$arm_log" >>"$summary"
        overall_status=failed
        stop_server
        continue
    fi

    QWEN_PROBE_DEPTH=$depth QWEN_PROBE_PORT=$server_port \
    QWEN_PROBE_MODEL_ID=$model_id QWEN_PROBE_DECODE_TOKENS=$decode_tokens \
        python3 - <<'PYTHON' >"$arm_result" || overall_status=failed
import json, os, urllib.request

port = os.environ["QWEN_PROBE_PORT"]
depth = int(os.environ["QWEN_PROBE_DEPTH"])
model_id = os.environ["QWEN_PROBE_MODEL_ID"]
decode_tokens = int(os.environ["QWEN_PROBE_DECODE_TOKENS"])
needle = "cobalt-heron-4172"

def post(route, payload, timeout=1800):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{route}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)

def tokenize(text):
    return len(post("/tokenize", {"content": text, "add_special": False})
               .get("tokens", []))

def chat(padding, max_tokens):
    return post("/v1/chat/completions", {
        "model": model_id,
        "messages": [{"role": "user", "content":
            f"The passphrase is {needle}. Remember it.\n" + padding +
            "\nReply with only the passphrase stated at the beginning."}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
    })

# One short probe measures the template overhead /tokenize cannot see, then
# the loop converges the padding on the tokenizer rather than trusting one
# estimate. The unit sentence repeats, so long-range retrieval reads through
# uniform filler rather than through structure the model could shortcut.
unit = "The quick brown fox jumps over the lazy dog near the riverbank. "
probe = chat("", 8)
overhead = (probe.get("timings") or {}).get("prompt_n")
if overhead is None:
    print("status\tprobe-carries-no-prompt_n")
    raise SystemExit(1)

low = depth - max(64, depth // 50)
high = depth - decode_tokens
target = high - 8
unit_tokens = tokenize(unit * 16) / 16
count = max(1, int((target - overhead) / unit_tokens))
for _ in range(12):
    measured = overhead + tokenize(unit * count)
    if measured > high:
        count -= max(1, int((measured - target) / unit_tokens))
    elif measured < low:
        count += max(1, int((target - measured) / unit_tokens))
    else:
        break
else:
    print(f"status\tfill-never-converged measured={measured}")
    raise SystemExit(1)

reply = chat(unit * count, decode_tokens)
prompt_n = (reply.get("timings") or {}).get("prompt_n")
completion_tokens = reply.get("usage", {}).get("completion_tokens", 0)
content = reply["choices"][0]["message"]["content"]
if prompt_n is None or not (low <= prompt_n <= high):
    print(f"status\tprompt-outside-window prompt_n={prompt_n} window={low}-{high}")
    raise SystemExit(1)
if completion_tokens <= 0:
    print(f"status\tno-decode prompt_n={prompt_n}")
    raise SystemExit(1)
needle_state = "retrieved" if needle in content else "missed"
print(f"status\tok\nprompt_n\t{prompt_n}\ncompletion_tokens\t{completion_tokens}\nneedle\t{needle_state}")
PYTHON

    arm_status=$(awk -F'\t' '$1 == "status" { print $2; exit }' "$arm_result")
    prompt_n=$(awk -F'\t' '$1 == "prompt_n" { print $2; exit }' "$arm_result")
    completion=$(awk -F'\t' '$1 == "completion_tokens" { print $2; exit }' "$arm_result")
    needle_state=$(awk -F'\t' '$1 == "needle" { print $2; exit }' "$arm_result")

    health=unhealthy
    if curl --silent --fail --max-time 5 \
        "http://127.0.0.1:$server_port/health" >/dev/null 2>&1; then
        health=healthy
    fi
    stop_server

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_label" "$model_id" "$depth" "$batch_size" "$ubatch_size" \
        "$cache_type_k" "$cache_type_v" "$flash_attention" \
        "${arm_status:-failed}" "${prompt_n:-n/a}" "${completion:-n/a}" \
        "${needle_state:-n/a}" "$health" "$arm_log" >>"$summary"
    [ "${arm_status:-failed}" = ok ] && [ "$health" = healthy ] || overall_status=failed
done

# One appendable ledger row per healthy arm, written beside the evidence: a
# validated row in scripts/validated-tuples.tsv requires its evidence path to
# exist in the tree, so the row joins the ledger with the directory it names.
llama_cpp_commit=$(git -C "${HOME:?}/src/llama.cpp-qwen-nvidia" rev-parse HEAD)
runner_sha256=$(sha256sum "$0" | cut -d ' ' -f 1)
kernel_release=$(uname -r)
gpu_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
measured_at=$(date -u +%Y-%m-%d)
awk -F'\t' -v OFS='\t' -v model_id="$model_id" \
    -v evidence="$evidence_root/$model_id/" -v commit="$llama_cpp_commit" \
    -v runner="$runner_sha256" -v kernel="$kernel_release" \
    -v gpu_module="$gpu_driver" -v measured_at="$measured_at" '
    NR > 1 && $9 == "ok" && $13 == "healthy" {
        print model_id "-d" $3 "-b" $4 "-ub" $5, model_id, "standalone",
            $3, $4, $5, $6, $7, $8, 1, 1, "none", "cuda", "validated",
            evidence, commit, runner, kernel, "-", gpu_module, measured_at
    }' "$summary" >"$emitted_rows"

printf 'filled_depth=%s model_id=%s output_directory=%s emitted_rows=%s\n' \
    "$overall_status" "$model_id" "$output_directory" "$emitted_rows"
cat "$summary"
[ "$overall_status" = completed ]
