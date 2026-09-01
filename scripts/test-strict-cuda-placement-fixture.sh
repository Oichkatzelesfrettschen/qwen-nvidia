#!/bin/sh
set -eu

# test-strict-cuda-placement.sh against the fake server. The fake answers the
# two refusal stages from its argv and the served stage from its HTTP routes, so
# every branch the check reads on the device is reached here, including the
# fixed-seed comparison of two completions and the placement lines a full
# CUDA0 load prints. A fake that withholds the CUDA0 banner, or answers the
# two completions differently, is refused, which is what proves the check
# reads them rather than the exit status alone.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
check=$script_directory/test-strict-cuda-placement.sh
fake=$script_directory/test-fixtures/fake-llama-server.sh
work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT HUP INT TERM
failures=0

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

model=$work_directory/model.gguf
printf 'GGUF' >"$model"
port_base=18194

run_check() {
    set +e
    QWEN_FAKE_SERVER_STRICT=1 QWEN_FAKE_SERVER_PORT=$((port_base + 2)) \
    QWEN_STRICT_PORT_BASE=$port_base \
    QWEN_FAKE_SERVER_STATE_DIRECTORY=$work_directory/argv \
    QWEN_TEST_EVIDENCE_DIRECTORY=$work_directory/evidence \
        "$@" "$check" --llama-server "$fake" --model "$model" \
        >"$work_directory/out" 2>"$work_directory/err"
    run_status=$?
    set -e
}

run_check env QWEN_FAKE_SERVER_PLACEMENT=cuda QWEN_FAKE_SERVER_CONTENT=deterministic
if [ "$run_status" -eq 0 ] &&
    grep -F 'strict_cuda_completion=accepted deterministic_completion=accepted' \
        "$work_directory/out" >/dev/null &&
    [ -f "$work_directory/evidence/cpu-tensor.log" ] &&
    [ -f "$work_directory/evidence/cpu-graph.log" ] &&
    [ -f "$work_directory/evidence/response-2.json" ]; then
    report strict_cuda_placement_accepts_full_offload accepted
else
    report strict_cuda_placement_accepts_full_offload rejected
    cat "$work_directory/err" >&2
fi

# The served stage names CUDA0 in every buffer class; a Vulkan0 banner is the
# other backend and is refused on the model buffer line.
run_check env QWEN_FAKE_SERVER_PLACEMENT=vulkan QWEN_FAKE_SERVER_CONTENT=deterministic
if [ "$run_status" -ne 0 ]; then
    report strict_cuda_placement_refuses_other_backend accepted
else
    report strict_cuda_placement_refuses_other_backend rejected
fi

# An empty completion is refused: the check compares content and requires it.
run_check env QWEN_FAKE_SERVER_PLACEMENT=cuda
if [ "$run_status" -ne 0 ] &&
    grep -F 'not deterministic' "$work_directory/err" >/dev/null; then
    report strict_cuda_placement_requires_completion_content accepted
else
    report strict_cuda_placement_requires_completion_content rejected
fi

# Without the strict refusals the fake loads a host placement cleanly, and the
# check refuses on the first stage.
set +e
QWEN_FAKE_SERVER_PLACEMENT=cuda QWEN_FAKE_SERVER_PORT=$((port_base + 2)) \
QWEN_STRICT_PORT_BASE=$port_base \
QWEN_FAKE_SERVER_STATE_DIRECTORY=$work_directory/argv \
    "$check" --llama-server "$fake" --model "$model" \
    >"$work_directory/out" 2>"$work_directory/err"
lenient_status=$?
set -e
if [ "$lenient_status" -ne 0 ] &&
    grep -F 'CPU tensor placement was not rejected' "$work_directory/err" >/dev/null; then
    report strict_cuda_placement_requires_host_refusal accepted
else
    report strict_cuda_placement_requires_host_refusal rejected
fi

if [ "$failures" -eq 0 ]; then
    printf 'strict_cuda_placement_fixture=accepted cases=4\n'
else
    printf 'strict_cuda_placement_fixture=rejected failures=%s\n' "$failures" >&2
    exit 1
fi
