#!/bin/sh
set -eu

# The filled-depth probe now names the backend it ran on rather than assuming
# CUDA, so its failure mode is a silent one: a Vulkan diagnostic arm emitting
# backend=cuda into scripts/validated-tuples.tsv would let
# check-validated-tuples.sh read it as a CUDA registry claim. These checks
# drive the harness against the fake server, which prints the CUDA0 or
# Vulkan0 load banner QWEN_FAKE_SERVER_PLACEMENT names and records the
# resolved wrapper's own environment fingerprint (cuda_devices and vk_icd)
# beside the launch argv, so the probe's device, override pattern, and
# wrapper selection are each proven independently of one another.

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
probe=$script_directory/probe-filled-depth.sh
fake_server=$script_directory/test-fixtures/fake-llama-server.sh
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
failures=0

report() {
    printf '%s=%s\n' "$1" "$2"
    [ "$2" = accepted ] || failures=$((failures + 1))
}

# The probe asks the driver which processes hold a CUDA context. This fixture
# drives a fake server against no device, so the stub answers with an empty
# compute-app list and the arm's outcome follows the probe rather than
# whatever the workstation's desktop happens to be rendering.
printf '#!/bin/sh\nexit 0\n' >"$temporary_directory/no-compute-apps.sh"
chmod +x "$temporary_directory/no-compute-apps.sh"

registry=$temporary_directory/models.tsv
{
    printf '# id\trole\tmodel_file\tfetch_script\tcontext_default\tcontext_ceiling\tcontext_target\tcache_type_k\tcache_type_v\tflash_attention\tprojector\tprojector_fetch_script\tdecode_tok_s\tprefill_tok_s\tquality\ttier\tbatch\tubatch\tvalidated_filled_depth\tvalidation_evidence\traw_tool_selection\tguarded_tool_execution\tmtp_layers\tspeculation_profile\tspeculation_evidence\tswitch_policy\n'
    printf 'fake-text\tfast-text\tFake-Text-GGUF/fake-text.gguf\tdownload-fake-text.sh\t4096\t4096\t4096\tq8_0\tq4_0\ton\tnone\t-\t1.00\t1.00\t1/55\tcandidate\t128\t32\t-\t-\t1/10\trefused\t0\toff\t-\tlru\n'
} >"$registry"

model_root=$temporary_directory/models
mkdir -p "$model_root/Fake-Text-GGUF"
printf 'fake text weights\n' >"$model_root/Fake-Text-GGUF/fake-text.gguf"

# An unknown backend is refused before the registry is read or the device is
# touched.
set +e
QWEN_PROBE_BACKEND=hip env QWEN_MODEL_REGISTRY="$registry" \
    QWEN_MODEL_ROOT="$model_root" QWEN_LLAMA_SERVER="$fake_server" \
    "$probe" fake-text "$temporary_directory/unknown-backend" \
    >/dev/null 2>"$temporary_directory/unknown-backend.err"
unknown_backend_status=$?
set -e
if [ "$unknown_backend_status" -eq 2 ] &&
    grep -qF 'QWEN_PROBE_BACKEND takes cuda or vulkan: hip' \
        "$temporary_directory/unknown-backend.err"; then
    report unknown_backend_refused accepted
else
    report unknown_backend_refused "status-$unknown_backend_status"
fi

# The default backend resolves to CUDA0 through cuda-runtime-env.sh.
cuda_directory=$temporary_directory/cuda-arm
cuda_argv=$temporary_directory/cuda-argv.txt
cuda_log=$temporary_directory/cuda.log
set +e
env QWEN_FAKE_SERVER_PLACEMENT=cuda QWEN_POLICY_TEST_OUTPUT="$cuda_argv" \
    QWEN_PROBE_PORT=18193 QWEN_FAKE_SERVER_PORT=18193 \
    QWEN_MODEL_REGISTRY="$registry" QWEN_MODEL_ROOT="$model_root" \
    QWEN_GPU_OWNERSHIP_NVIDIA_SMI="$temporary_directory/no-compute-apps.sh" \
    QWEN_GPU_OWNERSHIP_LOCK="$temporary_directory/ownership.lock" \
    QWEN_LLAMA_SERVER="$fake_server" \
    QWEN_PROBE_EVIDENCE_PATH="evidence/test-probe-filled-depth/fake-text/" \
    QWEN_PROBE_READY_TIMEOUT_S=30 \
    "$probe" fake-text "$cuda_directory" >"$cuda_log" 2>&1
cuda_status=$?
set -e
if [ "$cuda_status" -eq 0 ]; then
    report cuda_default_arm_completed accepted
else
    report cuda_default_arm_completed "status-$cuda_status"
    sed -n '1,40p' "$cuda_log" >&2
fi

cuda_argv_accepted=accepted
for required_argument in \
    "argument=--device" "argument=CUDA0" \
    "argument=--override-tensor" "argument=.*=CUDA0"; do
    grep -qxF "$required_argument" "$cuda_argv" 2>/dev/null ||
        cuda_argv_accepted="missing-$required_argument"
done
grep -qxF 'cuda_devices=0' "$cuda_argv" 2>/dev/null ||
    cuda_argv_accepted=missing-cuda-devices-marker
grep -qxF 'vk_icd=unset' "$cuda_argv" 2>/dev/null ||
    cuda_argv_accepted=missing-vk-icd-unset-marker
report cuda_default_wrapper_and_device "$cuda_argv_accepted"

grep -qF 'load_tensors: CUDA0 model buffer size' \
    "$cuda_directory/d4096-b128-ub32.server.log" 2>/dev/null &&
    report cuda_placement_banner accepted ||
    report cuda_placement_banner rejected

cuda_summary_row=$(awk -F'\t' 'NR == 2 { print }' \
    "$cuda_directory/filled-depth-summary.tsv" 2>/dev/null || true)
[ "$(printf '%s' "$cuda_summary_row" | awk -F'\t' '{ print $3 }')" = cuda ] &&
    report cuda_summary_backend_column accepted ||
    report cuda_summary_backend_column \
        "backend-$(printf '%s' "$cuda_summary_row" | awk -F'\t' '{ print $3 }')"

cuda_emitted_row=$(sed -n '1p' \
    "$cuda_directory/validated-tuples-rows.tsv" 2>/dev/null || true)
[ "$(printf '%s' "$cuda_emitted_row" | awk -F'\t' '{ print $13 }')" = cuda ] &&
    report cuda_emitted_backend_field accepted ||
    report cuda_emitted_backend_field \
        "backend-$(printf '%s' "$cuda_emitted_row" | awk -F'\t' '{ print $13 }')"

# QWEN_PROBE_BACKEND=vulkan resolves to Vulkan0 through vulkan-runtime-env.sh
# and the emitted ledger row names backend=vulkan, so a Vulkan diagnostic
# result can never be read as a CUDA registry claim.
vulkan_directory=$temporary_directory/vulkan-arm
vulkan_argv=$temporary_directory/vulkan-argv.txt
vulkan_log=$temporary_directory/vulkan.log
set +e
env QWEN_PROBE_BACKEND=vulkan QWEN_FAKE_SERVER_PLACEMENT=vulkan \
    QWEN_POLICY_TEST_OUTPUT="$vulkan_argv" QWEN_PROBE_PORT=18194 QWEN_FAKE_SERVER_PORT=18194 \
    QWEN_MODEL_REGISTRY="$registry" QWEN_MODEL_ROOT="$model_root" \
    QWEN_GPU_OWNERSHIP_NVIDIA_SMI="$temporary_directory/no-compute-apps.sh" \
    QWEN_GPU_OWNERSHIP_LOCK="$temporary_directory/ownership.lock" \
    QWEN_LLAMA_SERVER="$fake_server" \
    QWEN_PROBE_EVIDENCE_PATH="evidence/test-probe-filled-depth/fake-text/" \
    QWEN_PROBE_READY_TIMEOUT_S=30 \
    "$probe" fake-text "$vulkan_directory" >"$vulkan_log" 2>&1
vulkan_status=$?
set -e
if [ "$vulkan_status" -eq 0 ]; then
    report vulkan_backend_arm_completed accepted
else
    report vulkan_backend_arm_completed "status-$vulkan_status"
    sed -n '1,40p' "$vulkan_log" >&2
fi

vulkan_argv_accepted=accepted
for required_argument in \
    "argument=--device" "argument=Vulkan0" \
    "argument=--override-tensor" "argument=.*=Vulkan0"; do
    grep -qxF "$required_argument" "$vulkan_argv" 2>/dev/null ||
        vulkan_argv_accepted="missing-$required_argument"
done
grep -qxF 'cuda_devices=unset' "$vulkan_argv" 2>/dev/null ||
    vulkan_argv_accepted=missing-cuda-devices-unset-marker
grep -q '^vk_icd=/' "$vulkan_argv" 2>/dev/null ||
    vulkan_argv_accepted=missing-vk-icd-pinned-marker
report vulkan_backend_wrapper_and_device "$vulkan_argv_accepted"

grep -qF 'load_tensors: Vulkan0 model buffer size' \
    "$vulkan_directory/d4096-b128-ub32.server.log" 2>/dev/null &&
    report vulkan_placement_banner accepted ||
    report vulkan_placement_banner rejected

vulkan_summary_row=$(awk -F'\t' 'NR == 2 { print }' \
    "$vulkan_directory/filled-depth-summary.tsv" 2>/dev/null || true)
[ "$(printf '%s' "$vulkan_summary_row" | awk -F'\t' '{ print $3 }')" = vulkan ] &&
    report vulkan_summary_backend_column accepted ||
    report vulkan_summary_backend_column \
        "backend-$(printf '%s' "$vulkan_summary_row" | awk -F'\t' '{ print $3 }')"

vulkan_emitted_row=$(sed -n '1p' \
    "$vulkan_directory/validated-tuples-rows.tsv" 2>/dev/null || true)
[ "$(printf '%s' "$vulkan_emitted_row" | awk -F'\t' '{ print $13 }')" = vulkan ] &&
    report vulkan_emitted_backend_field accepted ||
    report vulkan_emitted_backend_field \
        "backend-$(printf '%s' "$vulkan_emitted_row" | awk -F'\t' '{ print $13 }')"

# QWEN_PROBE_DEVICE overrides the device name alone: the backend's own wrapper
# still runs and the override pattern still derives from the overridden name.
override_directory=$temporary_directory/cuda-override-arm
override_argv=$temporary_directory/cuda-override-argv.txt
override_log=$temporary_directory/cuda-override.log
set +e
env QWEN_PROBE_DEVICE=CUDA1 QWEN_FAKE_SERVER_PLACEMENT=cuda \
    QWEN_POLICY_TEST_OUTPUT="$override_argv" QWEN_PROBE_PORT=18195 QWEN_FAKE_SERVER_PORT=18195 \
    QWEN_MODEL_REGISTRY="$registry" QWEN_MODEL_ROOT="$model_root" \
    QWEN_GPU_OWNERSHIP_NVIDIA_SMI="$temporary_directory/no-compute-apps.sh" \
    QWEN_GPU_OWNERSHIP_LOCK="$temporary_directory/ownership.lock" \
    QWEN_LLAMA_SERVER="$fake_server" \
    QWEN_PROBE_EVIDENCE_PATH="evidence/test-probe-filled-depth/fake-text/" \
    QWEN_PROBE_READY_TIMEOUT_S=30 \
    "$probe" fake-text "$override_directory" >"$override_log" 2>&1
override_status=$?
set -e
override_accepted=accepted
[ "$override_status" -eq 0 ] || override_accepted="status-$override_status"
for required_argument in \
    "argument=--device" "argument=CUDA1" \
    "argument=--override-tensor" "argument=.*=CUDA1"; do
    grep -qxF "$required_argument" "$override_argv" 2>/dev/null ||
        override_accepted="missing-$required_argument"
done
grep -qxF 'vk_icd=unset' "$override_argv" 2>/dev/null ||
    override_accepted=missing-vk-icd-unset-marker
report device_override_keeps_backend_wrapper "$override_accepted"

if [ "$failures" -ne 0 ]; then
    printf 'probe_filled_depth_tests=failed failures=%s\n' "$failures" >&2
    exit 1
fi
printf 'probe_filled_depth_tests=passed\n'
