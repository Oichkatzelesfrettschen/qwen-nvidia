#!/bin/sh
set -eu

# run-graph-alias-ab.sh drives real llama-server processes, so its own gates are
# checked against scripts/test-fixtures/fake-llama-server.sh instead: the
# refusal while a server holds the device, the argv every arm hands the server,
# the divergent verdict with its first divergent token index, the identical
# verdict, and the absent patched build recorded as a check that did not run.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
harness=$script_directory/run-graph-alias-ab.sh
fixture=$script_directory/test-fixtures/fake-llama-server.sh
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

failures=0
report() {
    if [ "$1" = 0 ]; then
        printf 'ok %s\n' "$2"
    else
        printf 'FAIL %s\n' "$2"
        failures=$((failures + 1))
    fi
}

model_id=qwen38-2b-distill
model_file=$("$script_directory/model-registry.sh" id "$model_id" model_file)
models_directory=$temporary_directory/models
mkdir -p "$models_directory/$(dirname -- "$model_file")"
printf 'not a real gguf\n' >"$models_directory/$model_file"

production_build=$temporary_directory/build-production
alias_build=$temporary_directory/build-alias
for build_directory in "$production_build" "$alias_build"; do
    mkdir -p "$build_directory/bin"
    cp "$fixture" "$build_directory/bin/llama-server"
    chmod +x "$build_directory/bin/llama-server"
done
# The marker stands in for the patched dependency relation: the fixture returns
# the reordered sequence only from a build that lacks it with the optimizer on.
: >"$alias_build/alias-marker"

prompt_file=$temporary_directory/prompts.tsv
printf 'accumulator\tAdd numbers and show every running total.\n' >"$prompt_file"
printf 'stack\tPush and pop and print the stack each time.\n' >>"$prompt_file"

run_harness() {
    harness_output_directory=$1
    shift
    QWEN_MODELS_DIRECTORY=$models_directory \
    QWEN_ALIAS_AB_PROMPTS=$prompt_file \
    QWEN_ALIAS_AB_PORT=$fake_port \
    QWEN_SERVER_PORT=$unused_port \
    QWEN_ALIAS_AB_RESTARTS=2 \
    QWEN_ALIAS_AB_RUNS=2 \
    QWEN_ALIAS_AB_PREDICT=8 \
    QWEN_ALIAS_AB_READY_SECONDS=30 \
    QWEN_FAKE_SERVER_PORT=$fake_port \
    QWEN_FAKE_SERVER_STATE_DIRECTORY=$harness_output_directory/argv \
    QWEN_GPU_OWNERSHIP_LOCK=$campaign_lock \
    QWEN_GPU_OWNERSHIP_NVIDIA_SMI=$fake_nvidia_smi \
    QWEN_GPU_OWNERSHIP_CLIENTS=${QWEN_GPU_OWNERSHIP_CLIENTS:-} \
    QWEN_GPU_COMPUTE_LEASE=$temporary_directory/absent-lease.lock \
    "$@" \
        "$harness" "$harness_output_directory" "$model_id"
}

# The harness takes the campaign authority, so this test names its own lock file
# and its own driver. Both are inside the temporary directory, which keeps the
# run off /tmp/qwen-ad104-gpu-0.lock and off whatever the workstation's real
# device is doing.
campaign_lock=$temporary_directory/campaign.lock
fake_nvidia_smi=$temporary_directory/nvidia-smi
cat >"$fake_nvidia_smi" <<'SMI'
#!/bin/sh
printf '%s' "${QWEN_GPU_OWNERSHIP_CLIENTS:-}"
SMI
chmod +x "$fake_nvidia_smi"

fake_port=${QWEN_ALIAS_AB_TEST_PORT:-8137}
unused_port=${QWEN_ALIAS_AB_TEST_UNUSED_PORT:-8138}

# A server holding the device turns a correctness question into a scheduling
# one, so the harness refuses rather than measuring through the contention. What
# decides holding is the driver's compute-app list rather than a process name:
# the fake driver reports a foreign llama-server and the run ends before any arm.
refusal_status=0
QWEN_GPU_OWNERSHIP_CLIENTS='5200, llama-server, 5307 MiB
'
export QWEN_GPU_OWNERSHIP_CLIENTS
run_harness "$temporary_directory/refusal" \
    env QWEN_PRODUCTION_BUILD_DIR="$production_build" \
    >"$temporary_directory/refusal.log" 2>&1 || refusal_status=$?
QWEN_GPU_OWNERSHIP_CLIENTS=''
export QWEN_GPU_OWNERSHIP_CLIENTS
if [ "$refusal_status" -ne 0 ] &&
    grep -q 'verdict=refuse-project' "$temporary_directory/refusal.log"; then
    report 0 'refuses to run while a llama-server holds a CUDA context'
else
    report 1 "refuses to run while a llama-server holds a CUDA context (status $refusal_status)"
fi

# A process merely named llama-server holds no CUDA context, so the driver lists
# nothing and the run proceeds. That is the case the removed `pgrep -x` check
# refused and the reason a name was never the ownership authority.
if [ -x /usr/bin/sleep ]; then
    cp /usr/bin/sleep "$temporary_directory/llama-server"
    "$temporary_directory/llama-server" 20 &
    residue_pid=$!
    name_status=0
    run_harness "$temporary_directory/name-only" \
        env QWEN_PRODUCTION_BUILD_DIR="$production_build" \
        >"$temporary_directory/name-only.log" 2>&1 || name_status=$?
    kill "$residue_pid" 2>/dev/null || true
    wait "$residue_pid" 2>/dev/null || true
    if [ "$name_status" -eq 0 ] &&
        grep -q 'cuda_clients=none' "$temporary_directory/name-only.log"; then
        report 0 'a process named llama-server with no context admits the run'
    else
        report 1 "a process named llama-server with no context admits the run (status $name_status)"
    fi
else
    printf 'skip name-only check: /usr/bin/sleep is absent\n'
fi

# The optimizer arm returns a sequence that first differs at generated token 3,
# which is the verdict and the index the summary must carry.
divergent_directory=$temporary_directory/divergent
divergent_status=0
run_harness "$divergent_directory" \
    env QWEN_PRODUCTION_BUILD_DIR="$production_build" \
        QWEN_ALIAS_BUILD_DIR="$alias_build" \
        QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
        QWEN_FAKE_SERVER_TOKENS_OPTIMIZE='10 11 12 99 14 15 16 17' \
        >"$divergent_directory.log" 2>&1 || divergent_status=$?
mkdir -p "$divergent_directory"
cp "$divergent_directory.log" "$divergent_directory/harness.log" 2>/dev/null || true

if [ "$divergent_status" -eq 0 ] &&
    grep -q '^graph_alias_ab=divergent comparisons=' "$divergent_directory.log"; then
    report 0 'reports graph_alias_ab=divergent when the optimizer arm reorders'
else
    report 1 "reports graph_alias_ab=divergent when the optimizer arm reorders (status $divergent_status)"
fi

if [ "$(grep -c "^graph_alias_ab=divergent	model=$model_id	arm=production-optimize	prompt=.*	first_divergence=3$" \
    "$divergent_directory/summary.tsv")" -eq 2 ]; then
    report 0 'names first_divergence=3 for both prompts of the optimizer arm'
else
    report 1 'names first_divergence=3 for both prompts of the optimizer arm'
fi

if [ "$(grep -c "^graph_alias_ab=identical	model=$model_id	arm=alias-optimize	" \
    "$divergent_directory/summary.tsv")" -eq 2 ]; then
    report 0 'the alias build rejoins the optimizer-off reference'
else
    report 1 'the alias build rejoins the optimizer-off reference'
fi

# Two scopes over three arms over two prompts. The scopes are separate because
# a sample's position in the request sequence changes the answer on this
# appliance for a mechanism this tree records as unisolated.
if [ "$(grep -c '^graph_alias_selfconsistent=identical' \
    "$divergent_directory/summary.tsv")" -eq 12 ]; then
    report 0 'each arm repeats itself at matched position in both scopes'
else
    report 1 'each arm repeats itself at matched position in both scopes'
fi

if grep -q 'scope=across-start' "$divergent_directory/summary.tsv" &&
    grep -q 'scope=within-start' "$divergent_directory/summary.tsv"; then
    report 0 'self-consistency is reported per scope'
else
    report 1 'self-consistency is reported per scope'
fi

# Every arm names depth, submission geometry, and the cache triple explicitly,
# because an absent --batch-size falls through to the llama.cpp default of 2048
# and that geometry wedged the compute ring at depth 16384.
argv_records=$(cat "$divergent_directory"/argv/argv-*.txt)
argv_failures=0
for expected_argument in \
    "argument=--ctx-size" \
    "argument=$("$script_directory/model-registry.sh" id "$model_id" context_default)" \
    "argument=--batch-size" \
    "argument=$("$script_directory/model-registry.sh" id "$model_id" batch)" \
    "argument=--ubatch-size" \
    "argument=$("$script_directory/model-registry.sh" id "$model_id" ubatch)" \
    "argument=--cache-type-k" \
    "argument=--flash-attn" \
    "argument=--n-gpu-layers" \
    "argument=--parallel" \
    "argument=--device" \
    "argument=Vulkan0" \
    "argument=--split-mode" \
    "argument=--override-tensor" \
    "argument=.*=Vulkan0" \
    "argument=--fit" \
    "argument=off"; do
    printf '%s\n' "$argv_records" | grep -qxF "$expected_argument" ||
        argv_failures=$((argv_failures + 1))
done
report "$argv_failures" 'every arm names depth, geometry, the cache triple, and placement'

# Placement drift is the one difference a token-identity verdict cannot
# survive, so an arm whose load log fails to name Vulkan0 stops the run.
placement_directory=$temporary_directory/placement
placement_status=0
run_harness "$placement_directory" \
    env QWEN_PRODUCTION_BUILD_DIR="$production_build" \
        QWEN_FAKE_SERVER_PLACEMENT=cpu \
        QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
        >"$placement_directory.log" 2>&1 || placement_status=$?

if [ "$placement_status" -ne 0 ] &&
    grep -q 'placement=rejected' "$placement_directory.log"; then
    report 0 'an arm that fails to place on Vulkan0 stops the run'
else
    report 1 "an arm that fails to place on Vulkan0 stops the run (status $placement_status)"
fi

optimize_off_records=$(grep -l 'disable_graph_optimize=1' \
    "$divergent_directory"/argv/argv-*.txt | wc -l)
if [ "$optimize_off_records" -eq 2 ]; then
    report 0 'GGML_VK_DISABLE_GRAPH_OPTIMIZE reaches the optimizer-off arm alone'
else
    report 1 "GGML_VK_DISABLE_GRAPH_OPTIMIZE reaches the optimizer-off arm alone ($optimize_off_records of 2 starts)"
fi

# Without an injected reorder every arm returns the same sequence, so the same
# harness must reach the identical verdict rather than always finding a
# difference.
identical_directory=$temporary_directory/identical
identical_status=0
run_harness "$identical_directory" \
    env QWEN_PRODUCTION_BUILD_DIR="$production_build" \
        QWEN_ALIAS_BUILD_DIR="$alias_build" \
        QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
        >"$identical_directory.log" 2>&1 || identical_status=$?

if [ "$identical_status" -eq 0 ] &&
    grep -q '^graph_alias_ab=identical comparisons=4$' \
        "$identical_directory.log"; then
    report 0 'reports graph_alias_ab=identical over four comparisons'
else
    report 1 "reports graph_alias_ab=identical over four comparisons (status $identical_status)"
fi

# A lane that has not built the patched tree still answers the cheaper
# question, so the absent build is a recorded non-run rather than a failure.
absent_directory=$temporary_directory/absent
absent_status=0
run_harness "$absent_directory" \
    env QWEN_PRODUCTION_BUILD_DIR="$production_build" \
        QWEN_FAKE_SERVER_TOKENS='10 11 12 13 14 15 16 17' \
        >"$absent_directory.log" 2>&1 || absent_status=$?

if [ "$absent_status" -eq 0 ] &&
    grep -q 'reason=alias_build_absent' "$absent_directory/summary.tsv"; then
    report 0 'an absent patched build is recorded as alias_build_absent'
else
    report 1 "an absent patched build is recorded as alias_build_absent (status $absent_status)"
fi

if [ "$failures" -eq 0 ]; then
    printf 'test_run_graph_alias_ab=pass\n'
else
    printf 'test_run_graph_alias_ab=fail failures=%s\n' "$failures"
    exit 1
fi
