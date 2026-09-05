#!/bin/sh
set -eu

# Fill and decode a near-full cache on one named backend for a text row. An
# allocation and a validated depth are two claims: a server that loads a
# 65536-token allocation has proven it can reserve the memory and has not
# proven a near-full cache executes. This harness runs llama-server standalone
# at the row's own cache triple and submission geometry with strict placement
# on the resolved device, converges a padding prompt into the acceptance
# window through /tokenize, and requires the decode to retrieve a needle
# planted at the head of the fill, so the arm proves execution and long-range
# attention rather than allocation alone.
#
# QWEN_PROBE_BACKEND names the backend and takes cuda alone, and the name
# carries through every retained artifact rather than living in the argv
# alone: device CUDA0, override pattern .*=CUDA0, and wrapper
# scripts/cuda-runtime-env.sh. Vulkan arms were a diagnostic selection on the
# same harness and are retired with Vulkan serving; the ledger keeps its
# backend column because rows measured under that selection remain history.
# The wrapper applies the scheduling policy and the environment scrub
# qwen-capacity-policy.sh applies to a served launch, so the arm measures the
# tuple under the environment the appliance would build it under.
# QWEN_PROBE_DEVICE overrides the resolved device name alone, keeping the
# backend's own wrapper and deriving the override pattern from the overridden
# name, for a caller measuring a second device enumerated under the same
# backend.
#
# filled-depth-summary.tsv and the emitted validated-tuples row both carry the
# resolved backend, because scripts/check-validated-tuples.sh admits a row only
# where its backend equals the one the host serves: a depth filled on another
# backend proves nothing about the CUDA registry claim the row would otherwise
# be read against.
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
    printf '  QWEN_PROBE_BACKEND  cuda, the one serving backend; names the device,\n' >&2
    printf '                      the tensor override, and the runtime wrapper\n' >&2
    printf '  QWEN_PROBE_DEVICE   overrides the resolved device name alone,\n' >&2
    printf '                      default CUDA0\n' >&2
    printf '  QWEN_PROBE_PORT     listener, default 18093\n' >&2
    printf '  QWEN_PROBE_BATCH    batch size, default the row batch\n' >&2
    printf '  QWEN_PROBE_UBATCH   ubatch size, default the row ubatch\n' >&2
    printf '  QWEN_PROBE_EVIDENCE_PATH  repository-relative arm directory the\n' >&2
    printf '                      emitted ledger rows name, default this run\n' >&2
    printf '                      output directory\n' >&2
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

# The backend decides three things together: the device the arm places every
# tensor on, the tensor-override pattern that names it, and the runtime
# wrapper that builds the environment the appliance would build for a served
# launch on that backend. QWEN_PROBE_DEVICE overrides the device name alone,
# so a caller measuring a second enumerated device keeps the backend's own
# wrapper and override derivation.
probe_backend=${QWEN_PROBE_BACKEND:-cuda}
case $probe_backend in
    cuda)
        default_device=CUDA0
        runtime_wrapper=$script_directory/cuda-runtime-env.sh
        ;;
    *)
        printf 'QWEN_PROBE_BACKEND takes cuda: %s\n' "$probe_backend" >&2
        printf 'Vulkan depth arms are retired with Vulkan serving on this host\n' >&2
        exit 2
        ;;
esac
resolved_device=${QWEN_PROBE_DEVICE:-$default_device}
# The device name has to belong to the backend that owns it: a CUDA arm
# naming Vulkan0 or CPU would run another backend under this backend's wrapper
# and ledger label, so the canonical enumeration form is required ahead of any
# launch.
case $probe_backend:$resolved_device in
    cuda:CUDA[0-9]|cuda:CUDA[0-9][0-9]) ;;
    *)
        printf 'QWEN_PROBE_DEVICE %s does not belong to backend %s\n' \
            "$resolved_device" "$probe_backend" >&2
        exit 2
        ;;
esac
override_pattern=".*=$resolved_device"

# The ledger row names the arm that proves it rather than the model that ran
# it. One model directory holds several geometries, so a row bound to the model
# leaves check-validated-tuples.sh unable to say which retained arm carries the
# depth the row claims: the served 2048/512 arm and the 1024/256 extension both
# resolved to the same path and neither identified its own result. The path
# defaults to this run's own output directory, and QWEN_PROBE_EVIDENCE_PATH
# names it where the run writes outside the tree.
resolve_evidence_path() {
    resolved_evidence=${QWEN_PROBE_EVIDENCE_PATH:-}
    if [ -z "$resolved_evidence" ]; then
        evidence_absolute=$(CDPATH='' cd -- "$output_directory" && pwd) || return 1
        repository_root=$(CDPATH='' cd -- "$script_directory/.." && pwd) || return 1
        case $evidence_absolute in
            "$repository_root"/evidence/*)
                resolved_evidence=${evidence_absolute#"$repository_root"/}
                ;;
            *)
                printf '%s\n' "output directory lies outside evidence/;" \
                    "set QWEN_PROBE_EVIDENCE_PATH: $output_directory" >&2
                return 1
                ;;
        esac
    fi
    case $resolved_evidence in
        evidence/*) ;;
        *)
            printf 'evidence path is not repository-relative under evidence/: %s\n' \
                "$resolved_evidence" >&2
            return 1
            ;;
    esac
    case $resolved_evidence in
        */../* | ../* | */..)
            printf 'evidence path traverses upward: %s\n' "$resolved_evidence" >&2
            return 1
            ;;
    esac
    printf '%s/' "${resolved_evidence%/}"
}

[ -x "$llama_server" ] || {
    printf 'llama-server is not executable: %s\n' "$llama_server" >&2
    exit 1
}
[ -x "$runtime_wrapper" ] || {
    printf 'runtime wrapper is not executable: %s\n' "$runtime_wrapper" >&2
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
printf 'arm\tmodel_id\tbackend\tdepth\tbatch\tubatch\tcache_k\tcache_v\tflash_attn\tstatus\tprompt_n\tcompletion_tokens\tneedle\thealth\tserver_log\tplacement\tnice\tioclass\n' \
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

# Strict placement on the resolved device with the CPU fallback refused, one
# slot, and the prompt cache off, so prompt_n reports the tokens the arm
# actually prefilled. The launch runs through the backend's own runtime
# wrapper rather than a raw invocation, so the wrapper supplies the backend
# scrub and the placement policy; the probe retains its own nice-19
# measurement scheduling through QWEN_SERVING_NICE, which the wrapper applies
# in place of the served default of 0, and the observed nice and I/O class
# are read back from the kernel into the arm summary. The wrapper profile is
# pinned to default, because an ambient no-graphs, pdl, or custom profile
# would change the arm's allocation and the tuple schema records no profile.
start_server() {
    env QWEN_SERVING_NICE=19 QWEN_CUDA_PROFILE=default QWEN_VULKAN_PROFILE=default \
        ionice -c 3 "$runtime_wrapper" "$llama_server" \
        --model "$model_path" \
        --alias "$model_id" \
        --host 127.0.0.1 \
        --port "$server_port" \
        --no-ui \
        --device "$resolved_device" \
        --split-mode none \
        --n-gpu-layers all \
        --override-tensor "$override_pattern" \
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tserver-never-ready\tn/a\tn/a\tn/a\tn/a\t%s\tn/a\tn/a\tn/a\n' \
            "$arm_label" "$model_id" "$probe_backend" "$depth" "$batch_size" \
            "$ubatch_size" "$cache_type_k" "$cache_type_v" "$flash_attention" \
            "$arm_log" >>"$summary"
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
    # The ledger backend is what the server proved rather than what the
    # environment asked: every buffer class has to name the resolved device
    # in the load banner and no fallback line may appear, or the arm carries
    # placement=off-device and emits no row.
    placement=on-device
    for banner in "$resolved_device model buffer size" \
        "$resolved_device KV buffer size" "$resolved_device compute buffer size"; do
        grep -qF "$banner" "$arm_log" || placement=off-device
    done
    grep -qF 'CPU fallback rejected' "$arm_log" && placement=off-device
    observed_nice=n/a
    observed_ioclass=n/a
    if [ -n "$server_pid" ] && [ -r "/proc/$server_pid/stat" ]; then
        observed_nice=$(awk '{ print $19 }' "/proc/$server_pid/stat")
        observed_ioclass=$(ionice -p "$server_pid" 2>/dev/null | cut -d: -f1 || printf 'n/a')
        [ -n "$observed_ioclass" ] || observed_ioclass=n/a
    fi
    stop_server

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arm_label" "$model_id" "$probe_backend" "$depth" "$batch_size" \
        "$ubatch_size" "$cache_type_k" "$cache_type_v" "$flash_attention" \
        "${arm_status:-failed}" "${prompt_n:-n/a}" "${completion:-n/a}" \
        "${needle_state:-n/a}" "$health" "$arm_log" "$placement" \
        "$observed_nice" "$observed_ioclass" >>"$summary"
    [ "${arm_status:-failed}" = ok ] && [ "$health" = healthy ] &&
        [ "$placement" = on-device ] || overall_status=failed
done

# One appendable ledger row per healthy arm, written beside the evidence: a
# validated row in scripts/validated-tuples.tsv requires its evidence path to
# exist in the tree, so the row joins the ledger with the directory it names.
arm_evidence_path=$(resolve_evidence_path) || exit 1
llama_cpp_commit=$(git -C "${HOME:?}/src/llama.cpp-qwen-nvidia" rev-parse HEAD)
runner_sha256=$(sha256sum "$0" | cut -d ' ' -f 1)
kernel_release=$(uname -r)
gpu_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
# The ledger's vulkan_driver column stays for the rows retained from the
# Vulkan diagnostic arms; a CUDA arm carries the nvidia-smi driver version on
# gpu_module and records no separate Vulkan identity.
vulkan_driver_version=-
measured_at=$(date -u +%Y-%m-%d)
awk -F'\t' -v OFS='\t' -v model_id="$model_id" \
    -v evidence="$arm_evidence_path" -v commit="$llama_cpp_commit" \
    -v runner="$runner_sha256" -v kernel="$kernel_release" \
    -v gpu_module="$gpu_driver" -v backend="$probe_backend" \
    -v vulkan_driver="$vulkan_driver_version" -v measured_at="$measured_at" '
    NR > 1 && $10 == "ok" && $14 == "healthy" && $16 == "on-device" {
        print model_id "-" backend "-d" $4 "-b" $5 "-ub" $6, model_id, "standalone",
            $4, $5, $6, $7, $8, $9, 1, 1, "none", backend, "validated",
            evidence, commit, runner, kernel, vulkan_driver, gpu_module, measured_at
    }' "$summary" >"$emitted_rows"

printf 'filled_depth=%s model_id=%s output_directory=%s emitted_rows=%s\n' \
    "$overall_status" "$model_id" "$output_directory" "$emitted_rows"
cat "$summary"
[ "$overall_status" = completed ]
