#!/bin/sh
set -eu

# Exercise the evidence contracts without a GPU. Missing sensors remain missing,
# failed arms cannot print a completed terminal state, and every background or
# server process reaches its cleanup path.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
active_fixture=initialization
diagnostic_file=
cleanup() {
    cleanup_status=$?
    if [ "$cleanup_status" -ne 0 ]; then
        printf 'measurement fixture failed: %s (status %s)\n' \
            "$active_fixture" "$cleanup_status" >&2
        if [ -n "$diagnostic_file" ] && [ -f "$diagnostic_file" ]; then
            printf 'measurement fixture diagnostic: %s\n' \
                "$diagnostic_file" >&2
            sed -n '1,160p' "$diagnostic_file" >&2
        fi
    fi
    rm -rf -- "$temporary_directory"
    exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

active_fixture=gpu-clock-sampling
drm_device=$temporary_directory/drm-device
hwmon_root=$temporary_directory/hwmon
mkdir -p "$drm_device" "$hwmon_root"
printf '2: 933Mhz *\n' >"$drm_device/pp_dpm_mclk"

sample_output=$temporary_directory/clocks.tsv
QWEN_DRM_DEVICE=$drm_device QWEN_HWMON_ROOT=$hwmon_root \
    "$script_directory/sample-gpu-clocks.sh" "$sample_output" 0.05 &
sample_pid=$!
sample_attempt=0
while [ ! -s "$sample_output" ] && [ "$sample_attempt" -lt 20 ]; do
    sample_attempt=$((sample_attempt + 1))
    sleep 0.05
done
kill "$sample_pid" 2>/dev/null || true
wait "$sample_pid" 2>/dev/null || true

sample_row=$(sed -n '1p' "$sample_output")
sample_mclk=$(printf '%s\n' "$sample_row" | awk -F'\t' '{ print $1 }')
sample_sclk=$(printf '%s\n' "$sample_row" | awk -F'\t' '{ print $2 }')
sample_temperature=$(printf '%s\n' "$sample_row" | awk -F'\t' '{ print $3 }')
sample_vram=$(printf '%s\n' "$sample_row" | awk -F'\t' '{ print $5 }')
sample_gtt=$(printf '%s\n' "$sample_row" | awk -F'\t' '{ print $6 }')
if [ "$sample_mclk" != 933 ] || [ "$sample_sclk" != unavailable ] || \
   [ "$sample_temperature" != unavailable ] || \
   [ "$sample_vram" != unavailable ] || [ "$sample_gtt" != unavailable ]; then
    printf 'sampler collapsed a missing sensor into a measurement: %s\n' \
        "$sample_row" >&2
    exit 1
fi
if QWEN_DRM_DEVICE=$drm_device QWEN_HWMON_ROOT=$hwmon_root \
    "$script_directory/sample-gpu-clocks.sh" "$sample_output" 0 \
    >"$temporary_directory/interval.stdout" \
    2>"$temporary_directory/interval.stderr"; then
    printf 'sampler accepted a zero interval\n' >&2
    exit 1
fi
grep -F 'interval must be a positive number' \
    "$temporary_directory/interval.stderr" >/dev/null

fake_sampler=$temporary_directory/fake-clock-sampler.sh
apply_fake_sampler=$temporary_directory/fake-sampler-body
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'output_file=$1' \
    'printf "%s\\n" "$$" >"${QWEN_TEST_SAMPLER_PID_FILE:?}"' \
    'printf "933\\t1100\\t88000\\t5.00\\t1024\\t2048\\n" >"$output_file"' \
    'trap "exit 0" HUP INT TERM' \
    'while :; do sleep 1; done' >"$apply_fake_sampler"
cp "$apply_fake_sampler" "$fake_sampler"
chmod +x "$fake_sampler"

# A sampler that exits without writing reproduces what a loaded scheduler does to
# the real one: the probe kills it as soon as the arm ends, so a fast arm can
# reach the summary before the first row is written and the file never exists.
silent_sampler=$temporary_directory/silent-clock-sampler.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'printf "%s\\n" "$$" >"${QWEN_TEST_SAMPLER_PID_FILE:?}"' \
    'exit 0' >"$silent_sampler"
chmod +x "$silent_sampler"

fake_bench=$temporary_directory/llama-bench
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'case ${QWEN_TEST_BENCH_MODE:-success} in' \
    '  failure) exit 7 ;;' \
    '  unparseable) printf "benchmark produced no timing row\\n"; exit 0 ;;' \
    '  delayed_success) sleep 2 ;;' \
    '  wrong_prefill) sleep 2; printf "| fake | pp512 | 99.00 +/- 0.10 |\\n| fake | tg64 | 3.00 +/- 0.10 |\\n"; exit 0 ;;' \
    '  wrong_decode) sleep 2; printf "| fake | tg128 | 99.00 +/- 0.10 |\\n"; exit 0 ;;' \
    '  misleading_columns) sleep 2; printf "| pp32 | pp512 | 99.00 +/- 0.10 |\\n| tg64 | tg128 | 99.00 +/- 0.10 |\\n"; exit 0 ;;' \
    '  exact_depth_labels) sleep 2; printf "| fake | pp32 @ d32 | 12.00 +/- 0.10 |\\n| fake | tg64 @ d32 | 3.00 +/- 0.10 |\\n"; exit 0 ;;' \
    '  device_banner) sleep 2; printf "ggml_vulkan: Found 1 Vulkan devices:\\n| fake | pp32 | 12.00 +/- 0.10 |\\n| fake | tg64 | 3.00 +/- 0.10 |\\n\\nbuild: f280b26 (1)\\n"; exit 0 ;;' \
    'esac' \
    'printf "| fake | tg64 | 3.00 +/- 0.10 |\\n"' >"$fake_bench"
chmod +x "$fake_bench"
model_path=$temporary_directory/model.gguf
: >"$model_path"

sampler_pid_file=$temporary_directory/sampler.pid
successful_output=$temporary_directory/repeatability-success
active_fixture=bench-repeatability-success
diagnostic_file=$temporary_directory/success.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_IDLE_SECONDS=0 \
    "$script_directory/measure-bench-repeatability.sh" "$model_path" \
    "$successful_output" >"$temporary_directory/success.stdout" \
    2>"$temporary_directory/success.stderr"
grep -F 'bench_repeatability=completed' \
    "$temporary_directory/success.stdout" >/dev/null
if kill -0 "$(cat "$sampler_pid_file")" 2>/dev/null; then
    printf 'successful measurement left its sampler alive\n' >&2
    exit 1
fi

failed_output=$temporary_directory/repeatability-failure
active_fixture=bench-repeatability-failure
diagnostic_file=$temporary_directory/failure.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_IDLE_SECONDS=0 \
    QWEN_TEST_BENCH_MODE=failure \
    "$script_directory/measure-bench-repeatability.sh" "$model_path" \
    "$failed_output" >"$temporary_directory/failure.stdout" \
    2>"$temporary_directory/failure.stderr"; then
    printf 'failed measurement returned success\n' >&2
    exit 1
fi
grep -F 'bench_repeatability=failed' \
    "$temporary_directory/failure.stderr" >/dev/null
if grep -F 'bench_repeatability=completed' \
    "$temporary_directory/failure.stdout" >/dev/null; then
    printf 'failed measurement printed a completed terminal state\n' >&2
    exit 1
fi
if kill -0 "$(cat "$sampler_pid_file")" 2>/dev/null; then
    printf 'failed measurement left its sampler alive\n' >&2
    exit 1
fi

fake_state=$temporary_directory/state
fake_result=$temporary_directory/served-result
mkdir -p "$fake_state"
fake_launch=$temporary_directory/fake-launch.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'state_directory=${QWEN_WEBUI_STATE_DIRECTORY:?}' \
    'printf "%s\\n" "$state_directory" >"${QWEN_TEST_LAUNCH_STATE_MARKER:?}"' \
    'printf "server=fake\\nprofile=fake\\ncache=fake\\n" >"$state_directory/session.status"' \
    >"$fake_launch"
chmod +x "$fake_launch"
fake_teardown=$temporary_directory/fake-teardown.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'printf "%s\\n" "${QWEN_WEBUI_STATE_DIRECTORY:?}" >"${QWEN_TEST_TEARDOWN_STATE_MARKER:?}"' \
    'printf "called\\n" >"${QWEN_TEST_TEARDOWN_MARKER:?}"' \
    >"$fake_teardown"
chmod +x "$fake_teardown"
teardown_marker=$temporary_directory/teardown-called
launch_state_marker=$temporary_directory/launch-state
teardown_state_marker=$temporary_directory/teardown-state
active_fixture=served-decode-failure
diagnostic_file=$temporary_directory/served.stderr
if QWEN_LAUNCH_SCRIPT=$fake_launch QWEN_TEARDOWN_SCRIPT=$fake_teardown \
    QWEN_STATE_DIRECTORY=$fake_state QWEN_RESULT_DIRECTORY=$fake_result \
    QWEN_TEST_LAUNCH_STATE_MARKER=$launch_state_marker \
    QWEN_TEST_TEARDOWN_STATE_MARKER=$teardown_state_marker \
    QWEN_TEST_TEARDOWN_MARKER=$teardown_marker QWEN_SERVER_PORT=9 \
    "$script_directory/measure-served-decode.sh" fixture "$model_path" \
    >"$temporary_directory/served.stdout" \
    2>"$temporary_directory/served.stderr"; then
    printf 'served measurement accepted a failed request\n' >&2
    exit 1
fi
test -s "$teardown_marker"
grep -Fx "$fake_state" "$launch_state_marker" >/dev/null
grep -Fx "$fake_state" "$teardown_state_marker" >/dev/null
grep -F 'served_decode=failed' "$temporary_directory/served.stderr" >/dev/null
if grep -F 'served_decode=completed' "$temporary_directory/served.stdout" >/dev/null; then
    printf 'failed served measurement printed a completed terminal state\n' >&2
    exit 1
fi

# Hazardous GPU harnesses reject both server and benchmark contention before
# creating a summary or starting a sampler.
contender_directory=$temporary_directory/contender
mkdir -p "$contender_directory"
ln -s /bin/sleep "$contender_directory/llama-bench"
"$contender_directory/llama-bench" 30 &
contender_pid=$!
contender_attempt=0
while ! pgrep -x llama-bench >/dev/null 2>&1 && \
      [ "$contender_attempt" -lt 20 ]; do
    contender_attempt=$((contender_attempt + 1))
    sleep 0.05
done
active_fixture=depth-wedge-process-contention
diagnostic_file=$temporary_directory/contended-wedge.stderr
if QWEN_LLAMA_BENCH=$fake_bench \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$temporary_directory/contended-wedge" \
    >"$temporary_directory/contended-wedge.stdout" \
    2>"$temporary_directory/contended-wedge.stderr"; then
    printf 'depth wedge accepted an existing llama-bench workload\n' >&2
    exit 1
fi
grep -F 'another llama process holds the device' \
    "$temporary_directory/contended-wedge.stderr" >/dev/null
active_fixture=cache-factorial-process-contention
diagnostic_file=$temporary_directory/contended-factorial.stderr
if QWEN_LLAMA_BENCH=$fake_bench \
    "$script_directory/run-kv-cache-factorial.sh" "$model_path" \
    "$temporary_directory/contended-factorial" \
    >"$temporary_directory/contended-factorial.stdout" \
    2>"$temporary_directory/contended-factorial.stderr"; then
    printf 'cache factorial accepted an existing llama-bench workload\n' >&2
    exit 1
fi
grep -F 'another llama process holds the device' \
    "$temporary_directory/contended-factorial.stderr" >/dev/null
kill "$contender_pid" 2>/dev/null || true
wait "$contender_pid" 2>/dev/null || true

# Unreadable dmesg removes a stale per-arm delta instead of converting an old
# reset into a current measurement. A successful bench with no timing row is a
# parser failure for both the arm and its mandatory recovery control.
fake_bin=$temporary_directory/fake-bin
mkdir -p "$fake_bin"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$fake_bin/dmesg"
chmod +x "$fake_bin/dmesg"
wedge_output=$temporary_directory/wedge
mkdir -p "$wedge_output"
printf 'GPU reset from an earlier run\n' >"$wedge_output/d1-b1-ub1.dmesg.txt"
active_fixture=depth-wedge-unreadable-kernel-log
diagnostic_file=$temporary_directory/wedge.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$wedge_output" \
    >"$temporary_directory/wedge.stdout" \
    2>"$temporary_directory/wedge.stderr"
if [ -e "$wedge_output/d1-b1-ub1.dmesg.txt" ]; then
    printf 'depth wedge retained a stale kernel delta when dmesg was unreadable\n' >&2
    exit 1
fi
awk -F'\t' '$1 == "d1-b1-ub1" && $9 == "unavailable" { found = 1 }
            END { exit !found }' "$wedge_output/wedge-summary.tsv"
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $19 == "unverified" { found = 1 }
                 END { exit !found }' "$wedge_output/wedge-summary.tsv"; then
    printf 'depth wedge did not mark unavailable kernel telemetry non-promotable\n' >&2
    cat "$wedge_output/wedge-summary.tsv" >&2
    exit 1
fi

# wedge-identity.tsv names the tool and driver versions the invocation ran
# under: the bench, the runner script, and the sampler are all hashed, and a
# probe with no --version support or no build-tree .git still records "-"
# rather than failing.
identity_file=$wedge_output/wedge-identity.tsv
if [ ! -s "$identity_file" ]; then
    printf 'depth wedge did not write an identity record\n' >&2
    exit 1
fi
if [ "$(sed -n '1p' "$identity_file")" != \
'run_utc	llama_bench_sha256	llama_cpp_commit	runner_sha256	sampler_sha256	kernel_release	mesa_radv_version	amdgpu_module_version	argv	environment' ]; then
    printf 'depth wedge identity record header does not match\n' >&2
    cat "$identity_file" >&2
    exit 1
fi
identity_bench_sha256=$(sha256sum "$fake_bench")
identity_bench_sha256=${identity_bench_sha256%% *}
if ! awk -F'\t' -v want="$identity_bench_sha256" \
    'NR > 1 && $2 == want { found = 1 } END { exit !found }' "$identity_file"; then
    printf 'depth wedge identity record did not carry the bench digest\n' >&2
    cat "$identity_file" >&2
    exit 1
fi
if awk -F'\t' 'NR > 1 && (NF != 10 || $3 == "" || $6 == "" || $7 == "" || $8 == "") {
                    found = 1
                }
                END { exit !found }' "$identity_file"; then
    printf 'depth wedge identity record left a field empty rather than "-"\n' >&2
    cat "$identity_file" >&2
    exit 1
fi

# A fault line with no reset line names a hazard the ring never recovered from
# on its own. arm_healthy must read gpu_faults as well as ring_resets, so this
# arm stays unhealthy even though status, control status, and reset count are
# all clean.
# kernel_line_count calls dmesg twice (an existence probe, then the count), so
# the fault must not appear until the third call: the delta read after the
# arm ends. A counter file tracks the call ordinal across both the health
# probe and the count read that precede every arm.
fault_bin=$temporary_directory/fault-bin
fault_counter=$temporary_directory/fault-dmesg-counter
fault_log=$temporary_directory/fault-dmesg-log
: >"$fault_log"
mkdir -p "$fault_bin"
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "counter=$fault_counter" \
    "log=$fault_log" \
    'printf x >>"$counter"' \
    'count=$(wc -c <"$counter")' \
    'if [ "$count" -eq 4 ]; then' \
    '    printf "amdgpu: VM_L2_PROTECTION_FAULT detected\\n" >>"$log"' \
    'fi' \
    'cat "$log"' \
    >"$fault_bin/dmesg"
chmod +x "$fault_bin/dmesg"
fault_output=$temporary_directory/wedge-fault-no-reset
active_fixture=depth-wedge-fault-without-reset
diagnostic_file=$temporary_directory/wedge-fault.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_CONDITIONAL_DEPTHS=1 QWEN_WEDGE_GEOMETRIES='1:1 2:2' \
PATH="$fault_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$fault_output" \
    >"$temporary_directory/wedge-fault.stdout" \
    2>"$temporary_directory/wedge-fault.stderr"
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $8 == 0 && $9 == 0 && $10 > 0 {
                     found = 1
                 }
                 END { exit !found }' "$fault_output/wedge-summary.tsv"; then
    printf 'depth wedge did not record a clean-reset fault as a fault row\n' >&2
    cat "$fault_output/wedge-summary.tsv" >&2
    exit 1
fi
if [ "$(awk -F'\t' 'NR > 1' "$fault_output/wedge-summary.tsv" | wc -l)" -ne 2 ]; then
    printf 'depth wedge suppressed rescue geometry despite an unhealthy fault arm\n' >&2
    cat "$fault_output/wedge-summary.tsv" >&2
    exit 1
fi
if grep -F 'arm_skipped label=d1-b2-ub2' \
    "$temporary_directory/wedge-fault.stdout" >/dev/null; then
    printf 'depth wedge skipped the second geometry despite an unhealthy fault arm\n' >&2
    exit 1
fi
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $20 == "VM-protection-fault" {
                     found = 1
                 }
                 END { exit !found }' "$fault_output/wedge-summary.tsv"; then
    printf 'depth wedge did not classify the protection fault by name\n' >&2
    cat "$fault_output/wedge-summary.tsv" >&2
    exit 1
fi

# A GFXHUB-tagged page fault is a distinct class from the generic protection
# fault above, named by the same line carrying both "gfxhub" and "page fault".
gfxhub_bin=$temporary_directory/gfxhub-bin
gfxhub_counter=$temporary_directory/gfxhub-dmesg-counter
gfxhub_log=$temporary_directory/gfxhub-dmesg-log
: >"$gfxhub_log"
mkdir -p "$gfxhub_bin"
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "counter=$gfxhub_counter" \
    "log=$gfxhub_log" \
    'printf x >>"$counter"' \
    'count=$(wc -c <"$counter")' \
    'if [ "$count" -eq 4 ]; then' \
    '    printf "amdgpu: [gfxhub0] page fault detected\\n" >>"$log"' \
    'fi' \
    'cat "$log"' \
    >"$gfxhub_bin/dmesg"
chmod +x "$gfxhub_bin/dmesg"
gfxhub_output=$temporary_directory/wedge-gfxhub
active_fixture=depth-wedge-gfxhub-page-fault
diagnostic_file=$temporary_directory/wedge-gfxhub.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 PATH="$gfxhub_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$gfxhub_output" \
    >"$temporary_directory/wedge-gfxhub.stdout" \
    2>"$temporary_directory/wedge-gfxhub.stderr"
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $20 == "gfxhub-page-fault" {
                     found = 1
                 }
                 END { exit !found }' "$gfxhub_output/wedge-summary.tsv"; then
    printf 'depth wedge did not classify the GFXHUB page fault by name\n' >&2
    cat "$gfxhub_output/wedge-summary.tsv" >&2
    exit 1
fi

# A page fault and an unrelated GFXHUB line describe two events. The taxonomy
# requires both markers on one kernel line before naming a GFXHUB page fault.
separate_gfxhub_bin=$temporary_directory/separate-gfxhub-bin
separate_gfxhub_counter=$temporary_directory/separate-gfxhub-counter
separate_gfxhub_log=$temporary_directory/separate-gfxhub-log
: >"$separate_gfxhub_log"
mkdir -p "$separate_gfxhub_bin"
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "counter=$separate_gfxhub_counter" \
    "log=$separate_gfxhub_log" \
    'printf x >>"$counter"' \
    'count=$(wc -c <"$counter")' \
    'if [ "$count" -eq 4 ]; then' \
    '    printf "amdgpu: page fault detected\\namdgpu: GFXHUB status clean\\n" >>"$log"' \
    'fi' \
    'cat "$log"' >"$separate_gfxhub_bin/dmesg"
chmod +x "$separate_gfxhub_bin/dmesg"
separate_gfxhub_output=$temporary_directory/wedge-separate-gfxhub
active_fixture=depth-wedge-gfxhub-same-line
diagnostic_file=$temporary_directory/wedge-separate-gfxhub.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 PATH="$separate_gfxhub_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$separate_gfxhub_output" >"$temporary_directory/wedge-separate-gfxhub.stdout" \
    2>"$temporary_directory/wedge-separate-gfxhub.stderr"
if grep -F 'gfxhub-page-fault' \
    "$separate_gfxhub_output/wedge-summary.tsv" >/dev/null; then
    printf 'depth wedge joined GFXHUB and page-fault markers from separate lines\n' >&2
    exit 1
fi

# A reset line with no page-fault line is ring-timeout-only. Its control then
# fails, which is what post-reset-control-failure names: a confirmed reset
# whose recovery control did not pass. A call-counting bench succeeds on the
# arm and fails on the control that follows it.
reset_bin=$temporary_directory/reset-bin
reset_counter=$temporary_directory/reset-dmesg-counter
reset_log=$temporary_directory/reset-dmesg-log
: >"$reset_log"
mkdir -p "$reset_bin"
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "counter=$reset_counter" \
    "log=$reset_log" \
    'printf x >>"$counter"' \
    'count=$(wc -c <"$counter")' \
    'if [ "$count" -eq 4 ]; then' \
    '    printf "amdgpu: GPU reset begin\\n" >>"$log"' \
    'fi' \
    'cat "$log"' \
    >"$reset_bin/dmesg"
chmod +x "$reset_bin/dmesg"
# The probe now runs one `--version` identity call before the first arm, so
# the arm is the second bench invocation and its control is the third.
reset_control_bench=$temporary_directory/reset-control-bench
reset_control_counter=$temporary_directory/reset-control-counter
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "counter=$reset_control_counter" \
    'printf x >>"$counter"' \
    'count=$(wc -c <"$counter")' \
    'if [ "$count" -ge 3 ]; then exit 7; fi' \
    'printf "| fake | tg64 | 3.00 +/- 0.10 |\\n"' >"$reset_control_bench"
chmod +x "$reset_control_bench"
reset_output=$temporary_directory/wedge-post-reset-control-failure
active_fixture=depth-wedge-post-reset-control-failure
diagnostic_file=$temporary_directory/wedge-post-reset.stderr
if QWEN_LLAMA_BENCH=$reset_control_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 PATH="$reset_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$reset_output" \
    >"$temporary_directory/wedge-post-reset.stdout" \
    2>"$temporary_directory/wedge-post-reset.stderr"; then
    printf 'depth wedge accepted a post-reset control failure as recoverable\n' >&2
    exit 1
fi
if ! awk -F'\t' '$1 == "d1-b1-ub1" &&
                 $20 ~ /ring-timeout-only/ &&
                 $20 ~ /post-reset-control-failure/ {
                     found = 1
                 }
                 END { exit !found }' "$reset_output/wedge-summary.tsv"; then
    printf 'depth wedge did not record both the reset and the post-reset control-failure class\n' >&2
    cat "$reset_output/wedge-summary.tsv" >&2
    exit 1
fi

# A reset emitted while the recovery control runs belongs to that control's
# kernel window. A control-side device loss with that reset must never claim
# that the kernel recorded nothing.
control_kernel_bin=$temporary_directory/control-kernel-bin
control_kernel_counter=$temporary_directory/control-kernel-counter
control_kernel_log=$temporary_directory/control-kernel-log
: >"$control_kernel_log"
mkdir -p "$control_kernel_bin"
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "counter=$control_kernel_counter" \
    "log=$control_kernel_log" \
    'printf x >>"$counter"' \
    'count=$(wc -c <"$counter")' \
    'if [ "$count" -eq 8 ]; then' \
    '    printf "amdgpu: GPU reset during recovery control\\n" >>"$log"' \
    'fi' \
    'cat "$log"' >"$control_kernel_bin/dmesg"
chmod +x "$control_kernel_bin/dmesg"
control_device_lost_bench=$temporary_directory/control-device-lost-bench
control_device_lost_counter=$temporary_directory/control-device-lost-counter
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "counter=$control_device_lost_counter" \
    'printf x >>"$counter"' \
    'count=$(wc -c <"$counter")' \
    'if [ "$count" -ge 3 ]; then' \
    '    printf "VK_ERROR_DEVICE_LOST\\n" >&2; exit 7' \
    'fi' \
    'printf "| fake | tg64 | 3.00 +/- 0.10 |\\n"' \
    >"$control_device_lost_bench"
chmod +x "$control_device_lost_bench"
control_kernel_output=$temporary_directory/wedge-control-kernel
active_fixture=depth-wedge-control-kernel-capture
diagnostic_file=$temporary_directory/wedge-control-kernel.stderr
if QWEN_LLAMA_BENCH=$control_device_lost_bench \
    QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 PATH="$control_kernel_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$control_kernel_output" >"$temporary_directory/wedge-control-kernel.stdout" \
    2>"$temporary_directory/wedge-control-kernel.stderr"; then
    printf 'depth wedge accepted a control-side device loss\n' >&2
    exit 1
fi
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $9 == 1 &&
        $20 ~ /post-reset-control-failure/ &&
        $20 !~ /device-lost-without-kernel-record/ { found = 1 }
        END { exit !found }' "$control_kernel_output/wedge-summary.tsv"; then
    printf 'depth wedge failed to attribute the recovery-control kernel reset\n' >&2
    cat "$control_kernel_output/wedge-summary.tsv" >&2
    exit 1
fi

# A sampler that writes nothing leaves the arm without device covariates, which
# this probe records as `unavailable` alongside every other absent device
# reading rather than ending the sweep. It exists to find a wedge, not to
# compare rates, so a missing covariate names itself.
# A sampler that sleeps past the arm reproduces a loaded scheduler on a fast
# arm: the probe kills it before its first row, and the retained-artifact
# check on resume must still find the file the probe created ahead of it.
delayed_sampler=$temporary_directory/delayed-clock-sampler.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'printf "%s\\n" "$$" >"${QWEN_TEST_SAMPLER_PID_FILE:?}"' \
    'exec sleep 30' >"$delayed_sampler"
chmod +x "$delayed_sampler"
delayed_output=$temporary_directory/wedge-delayed-sampler
active_fixture=depth-wedge-delayed-clock-sampler
diagnostic_file=$temporary_directory/wedge-delayed.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$delayed_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$delayed_output" \
    >"$temporary_directory/wedge-delayed.stdout" \
    2>"$temporary_directory/wedge-delayed.stderr"
if [ ! -f "$delayed_output/d1-b1-ub1.clocks.tsv" ]; then
    printf 'depth wedge left no clock file for a sampler killed before its first row\n' >&2
    exit 1
fi
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$delayed_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 QWEN_TEST_BENCH_MODE=failure PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$delayed_output" \
    >"$temporary_directory/wedge-delayed-resume.stdout" \
    2>"$temporary_directory/wedge-delayed-resume.stderr"
grep -F 'arm_resume_skip label=d1-b1-ub1 status=0' \
    "$temporary_directory/wedge-delayed-resume.stdout" >/dev/null

silent_output=$temporary_directory/wedge-silent-sampler
active_fixture=depth-wedge-silent-clock-sampler
diagnostic_file=$temporary_directory/wedge-silent.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$silent_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$silent_output" \
    >"$temporary_directory/wedge-silent.stdout" \
    2>"$temporary_directory/wedge-silent.stderr"
# Columns 13 and 14 are the memory peaks and 17 and 18 the clock and
# temperature, so naming all four checks both readers of the sampler file.
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $13 == "unavailable" && $14 == "unavailable" &&
        $17 == "unavailable" && $18 == "unavailable" {
        found = 1 } END { exit !found }' \
        "$silent_output/wedge-summary.tsv"; then
    printf 'depth wedge did not record unavailable clocks for a silent sampler\n' >&2
    cat "$silent_output/wedge-summary.tsv" >&2
    exit 1
fi

# Reusing a completed output directory resumes from retained arm identity. The
# row remains unique and the failing bench mode proves no recorded arm reruns or
# overwrites the logs that support it.
active_fixture=depth-wedge-retained-arm-resume
diagnostic_file=$temporary_directory/wedge-resume.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 QWEN_TEST_BENCH_MODE=failure PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$wedge_output" \
    >"$temporary_directory/wedge-resume.stdout" \
    2>"$temporary_directory/wedge-resume.stderr"
grep -F 'arm_resume_skip label=d1-b1-ub1 status=0' \
    "$temporary_directory/wedge-resume.stdout" >/dev/null
if [ "$(awk -F'\t' '$1 == "d1-b1-ub1" { count++ }
        END { print count + 0 }' "$wedge_output/wedge-summary.tsv")" -ne 1 ]; then
    printf 'depth wedge duplicated a recorded arm on resume\n' >&2
    exit 1
fi

active_fixture=depth-wedge-cache-policy-identity
diagnostic_file=$temporary_directory/wedge-cache-mismatch.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 QWEN_CACHE_TYPE_K=f16 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$wedge_output" \
    >"$temporary_directory/wedge-cache-mismatch.stdout" \
    2>"$temporary_directory/wedge-cache-mismatch.stderr"; then
    printf 'depth wedge resumed an arm from a different cache policy\n' >&2
    exit 1
fi
grep -F 'recorded arm d1-b1-ub1 belongs to cache policy q8_0/q4_0/on, not f16/q4_0/on' \
    "$temporary_directory/wedge-cache-mismatch.stderr" >/dev/null

disjoint_policy_output=$temporary_directory/wedge-disjoint-policy
mkdir -p "$disjoint_policy_output"
cp "$wedge_output/wedge-metadata.tsv" \
    "$disjoint_policy_output/wedge-metadata.tsv"
cp "$wedge_output/wedge-summary.tsv" \
    "$disjoint_policy_output/wedge-summary.tsv"
for retained_suffix in log clocks.tsv control.log; do
    cp "$wedge_output/d1-b1-ub1.$retained_suffix" \
        "$disjoint_policy_output/d1-b1-ub1.$retained_suffix"
done
active_fixture=depth-wedge-disjoint-cache-policy
diagnostic_file=$temporary_directory/wedge-disjoint-policy.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=2 \
    QWEN_WEDGE_GEOMETRIES=1:1 QWEN_CACHE_TYPE_K=f16 \
    QWEN_TEST_BENCH_MODE=failure PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$disjoint_policy_output" \
    >"$temporary_directory/wedge-disjoint-policy.stdout" \
    2>"$temporary_directory/wedge-disjoint-policy.stderr"; then
    printf 'depth wedge mixed cache policies across disjoint arm labels\n' >&2
    exit 1
fi
grep -F 'recorded arm d1-b1-ub1 belongs to cache policy q8_0/q4_0/on, not f16/q4_0/on' \
    "$temporary_directory/wedge-disjoint-policy.stderr" >/dev/null
if [ -e "$disjoint_policy_output/d2-b1-ub1.log" ]; then
    printf 'depth wedge created an arm artifact before cache-policy admission\n' >&2
    exit 1
fi

active_fixture=depth-wedge-same-policy-extension
diagnostic_file=$temporary_directory/wedge-same-policy-extension.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=2 \
QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$disjoint_policy_output" \
    >"$temporary_directory/wedge-same-policy-extension.stdout" \
    2>"$temporary_directory/wedge-same-policy-extension.stderr"
if [ "$(awk -F'\t' 'NR > 1 { count++ } END { print count + 0 }' \
        "$disjoint_policy_output/wedge-summary.tsv")" -ne 2 ]; then
    printf 'depth wedge refused a same-policy disjoint arm extension\n' >&2
    exit 1
fi

different_model_path=$temporary_directory/different-model.gguf
printf 'different model bytes\n' >"$different_model_path"
active_fixture=depth-wedge-model-identity
diagnostic_file=$temporary_directory/wedge-model-mismatch.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$different_model_path" \
    "$wedge_output" >"$temporary_directory/wedge-model-mismatch.stdout" \
    2>"$temporary_directory/wedge-model-mismatch.stderr"; then
    printf 'depth wedge resumed an arm from a different model\n' >&2
    exit 1
fi
grep -F 'wedge metadata does not match the model or recovery control:' \
    "$temporary_directory/wedge-model-mismatch.stderr" >/dev/null

legacy_metadata_output=$temporary_directory/wedge-legacy-metadata
mkdir -p "$legacy_metadata_output"
printf 'model_sha256\tmodel_bytes\tcontrol_tokens\n' \
    >"$legacy_metadata_output/wedge-metadata.tsv"
active_fixture=depth-wedge-legacy-metadata
diagnostic_file=$temporary_directory/wedge-legacy-metadata.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$legacy_metadata_output" \
    >"$temporary_directory/wedge-legacy-metadata.stdout" \
    2>"$temporary_directory/wedge-legacy-metadata.stderr"; then
    printf 'depth wedge accepted a pre-versioning legacy metadata ledger\n' >&2
    exit 1
fi
grep -F 'wedge metadata predates ledger versioning (legacy ledger, no ledger_version field):' \
    "$temporary_directory/wedge-legacy-metadata.stderr" >/dev/null

kernel_gap_output=$temporary_directory/wedge-kernel-gap
mkdir -p "$kernel_gap_output"
cp "$wedge_output/wedge-metadata.tsv" "$kernel_gap_output/wedge-metadata.tsv"
sed 's/\tunavailable\tunavailable\t/\t0\t0\t/' \
    "$wedge_output/wedge-summary.tsv" >"$kernel_gap_output/wedge-summary.tsv"
for retained_suffix in log clocks.tsv control.log; do
    cp "$wedge_output/d1-b1-ub1.$retained_suffix" \
        "$kernel_gap_output/d1-b1-ub1.$retained_suffix"
done
active_fixture=depth-wedge-kernel-evidence-retention
diagnostic_file=$temporary_directory/wedge-kernel-gap.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$kernel_gap_output" >"$temporary_directory/wedge-kernel-gap.stdout" \
    2>"$temporary_directory/wedge-kernel-gap.stderr"; then
    printf 'depth wedge resumed a numeric kernel row without its delta\n' >&2
    exit 1
fi
grep -F 'recorded arm d1-b1-ub1 is missing retained artifact:' \
    "$temporary_directory/wedge-kernel-gap.stderr" >/dev/null

duplicate_wedge_output=$temporary_directory/wedge-duplicate
mkdir -p "$duplicate_wedge_output"
cp "$wedge_output/wedge-metadata.tsv" \
    "$duplicate_wedge_output/wedge-metadata.tsv"
cp "$wedge_output/wedge-summary.tsv" \
    "$duplicate_wedge_output/wedge-summary.tsv"
sed -n '2p' "$wedge_output/wedge-summary.tsv" \
    >>"$duplicate_wedge_output/wedge-summary.tsv"
active_fixture=depth-wedge-unique-arm-identity
diagnostic_file=$temporary_directory/wedge-duplicate.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$duplicate_wedge_output" >"$temporary_directory/wedge-duplicate.stdout" \
    2>"$temporary_directory/wedge-duplicate.stderr"; then
    printf 'depth wedge accepted duplicate retained arm identities\n' >&2
    exit 1
fi
grep -F 'wedge summary carries duplicate arm identity: d1-b1-ub1' \
    "$temporary_directory/wedge-duplicate.stderr" >/dev/null

unparseable_output=$temporary_directory/wedge-unparseable
active_fixture=depth-wedge-parser-status
diagnostic_file=$temporary_directory/unparseable.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=unparseable QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$unparseable_output" >"$temporary_directory/unparseable.stdout" \
    2>"$temporary_directory/unparseable.stderr"; then
    printf 'depth wedge accepted an unparseable recovery control\n' >&2
    exit 1
fi
grep -F 'control_failed label=d1-b1-ub1' \
    "$temporary_directory/unparseable.stderr" >/dev/null
awk -F'\t' '$1 == "d1-b1-ub1" && $8 == 65 && $15 == 65 { found = 1 }
            END { exit !found }' "$unparseable_output/wedge-summary.tsv"

active_fixture=depth-wedge-positive-timeout-validation
diagnostic_file=$temporary_directory/wedge-zero-timeout.stderr
if QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 QWEN_WEDGE_ARM_TIMEOUT_S=0 \
    PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$temporary_directory/wedge-zero-timeout" \
    >"$temporary_directory/wedge-zero-timeout.stdout" \
    2>"$temporary_directory/wedge-zero-timeout.stderr"; then
    printf 'depth wedge accepted a zero arm timeout\n' >&2
    exit 1
fi
grep -F 'QWEN_WEDGE_ARM_TIMEOUT_S must be a positive integer: 0' \
    "$temporary_directory/wedge-zero-timeout.stderr" >/dev/null

# Identity collection has the same finite boundary as an arm. A Vulkan loader
# that never returns leaves a dash in the identity row and cannot hold the
# harness before the first arm.
vulkan_timeout_bin=$temporary_directory/vulkan-timeout-bin
mkdir -p "$vulkan_timeout_bin"
printf '%s\n' '#!/bin/sh' 'exec sleep 30' >"$vulkan_timeout_bin/vulkaninfo"
chmod +x "$vulkan_timeout_bin/vulkaninfo"
active_fixture=depth-wedge-vulkan-identity-timeout
diagnostic_file=$temporary_directory/wedge-vulkan-timeout.stderr
if ! timeout 8s env QWEN_LLAMA_BENCH=$fake_bench \
    QWEN_CLOCK_SAMPLER=$fake_sampler QWEN_WEDGE_DEPTHS=' ' \
    PATH="$vulkan_timeout_bin:$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$temporary_directory/wedge-vulkan-timeout" \
    >"$temporary_directory/wedge-vulkan-timeout.stdout" \
    2>"$temporary_directory/wedge-vulkan-timeout.stderr"; then
    printf 'depth wedge did not bound a blocked vulkaninfo identity query\n' >&2
    exit 1
fi

# A bench that ignores SIGTERM reproduces a wedge parked in the driver: only
# the SIGKILL escalation after the kill-after grace period ends it, and the
# arm is recorded as a failure carrying that escalation's distinct status
# (128 + SIGKILL) rather than hanging the probe.
hanging_bench=$temporary_directory/hanging-llama-bench
printf '%s\n' '#!/bin/sh' "trap '' TERM" 'sleep 30' >"$hanging_bench"
chmod +x "$hanging_bench"
timeout_output=$temporary_directory/wedge-timeout
active_fixture=depth-wedge-timeout-kill-after
diagnostic_file=$temporary_directory/wedge-timeout.stderr
if QWEN_LLAMA_BENCH=$hanging_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
    QWEN_WEDGE_GEOMETRIES=1:1 QWEN_WEDGE_ARM_TIMEOUT_S=1 \
    QWEN_WEDGE_ARM_KILL_AFTER_S=1 PATH="$fake_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" \
    "$timeout_output" >"$temporary_directory/wedge-timeout.stdout" \
    2>"$temporary_directory/wedge-timeout.stderr"; then
    printf 'depth wedge accepted a timed-out arm as successful\n' >&2
    exit 1
fi
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $8 == 137 { found = 1 }
                 END { exit !found }' "$timeout_output/wedge-summary.tsv"; then
    printf 'depth wedge did not record the kill-after escalation status\n' >&2
    cat "$timeout_output/wedge-summary.tsv" >&2
    exit 1
fi

# A dmesg that follows the buffer stays attached after --follow, so the probe
# reads the arm's kernel delta straight off the streaming file rather than
# subtracting a before count from an after snapshot, and never calls plain
# dmesg for this arm at all.
follow_bin=$temporary_directory/follow-bin
follow_pid_marker=$temporary_directory/follow-pid
follow_plain_call_marker=$temporary_directory/follow-plain-call
follow_start_counter=$temporary_directory/follow-start-counter
mkdir -p "$follow_bin"
printf '%s\n' '#!/bin/sh' 'set -eu' \
    "case \" \$* \" in" \
    '  *" --follow-new "*) ;;' \
    "  *) : >\"$follow_plain_call_marker\"; exit 0 ;;" \
    'esac' \
    "printf x >>\"$follow_start_counter\"" \
    "count=\$(wc -c <\"$follow_start_counter\")" \
    "printf '%s\\n' \"\$\$\" >\"$follow_pid_marker\"" \
    'if [ "$count" -eq 1 ]; then printf "amdgpu: GPU reset via follow-new\\n"; fi' \
    "trap 'exit 0' TERM" \
    'while :; do sleep 1; done' >"$follow_bin/dmesg"
chmod +x "$follow_bin/dmesg"
follow_output=$temporary_directory/wedge-follow
active_fixture=depth-wedge-kernel-follow-capture
diagnostic_file=$temporary_directory/wedge-follow.stderr
QWEN_LLAMA_BENCH=$fake_bench QWEN_CLOCK_SAMPLER=$fake_sampler \
QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file QWEN_WEDGE_DEPTHS=1 \
QWEN_WEDGE_GEOMETRIES=1:1 PATH="$follow_bin:$PATH" \
    "$script_directory/probe-depth-wedge.sh" "$model_path" "$follow_output" \
    >"$temporary_directory/wedge-follow.stdout" \
    2>"$temporary_directory/wedge-follow.stderr"
if [ -e "$follow_plain_call_marker" ]; then
    printf 'depth wedge called plain dmesg despite a following dmesg being available\n' >&2
    exit 1
fi
if [ ! -f "$follow_output/d1-b1-ub1.dmesg-method.txt" ] ||
   [ "$(cat "$follow_output/d1-b1-ub1.dmesg-method.txt")" != follow ]; then
    printf 'depth wedge did not record the follow capture method\n' >&2
    exit 1
fi
if ! awk -F'\t' '$1 == "d1-b1-ub1" && $9 == 1 { found = 1 }
                 END { exit !found }' "$follow_output/wedge-summary.tsv"; then
    printf 'depth wedge did not count the reset the following dmesg streamed\n' >&2
    cat "$follow_output/wedge-summary.tsv" >&2
    exit 1
fi
if kill -0 "$(cat "$follow_pid_marker")" 2>/dev/null; then
    printf 'depth wedge left the following dmesg reader alive\n' >&2
    exit 1
fi

for invalid_rounds in 0 -1; do
    active_fixture=dpm-round-validation
    diagnostic_file=$temporary_directory/dpm-rounds-$invalid_rounds.stderr
    if QWEN_DPM_ROUNDS=$invalid_rounds QWEN_LLAMA_BENCH=$fake_bench \
        "$script_directory/measure-dpm-force.sh" "$model_path" \
        >"$temporary_directory/dpm-rounds-$invalid_rounds.stdout" \
        2>"$temporary_directory/dpm-rounds-$invalid_rounds.stderr"; then
        printf 'DPM harness accepted invalid rounds: %s\n' \
            "$invalid_rounds" >&2
        exit 1
    fi
    grep -F "DPM rounds must be a positive integer: $invalid_rounds" \
        "$temporary_directory/dpm-rounds-$invalid_rounds.stderr" >/dev/null
done

# Bash arrays preserve each model path through the reversed pass. The fixture
# uses spaces in both names and requires two arms per model.
fake_census=$temporary_directory/fake-census.py
printf '%s\n' '#!/usr/bin/env python3' \
    'print("streamed_bytes_per_token\t1000")' \
    >"$fake_census"
chmod +x "$fake_census"
first_spaced_model=$temporary_directory/'first model.gguf'
second_spaced_model=$temporary_directory/'second model.gguf'
: >"$first_spaced_model"
: >"$second_spaced_model"
bandwidth_output=$temporary_directory/bandwidth
active_fixture=bandwidth-niceness-policy
diagnostic_file=$temporary_directory/bandwidth-nice.stderr
if QWEN_BENCH_NICE_LEVELS=0 QWEN_BANDWIDTH_OUTPUT=$bandwidth_output \
    QWEN_LLAMA_BENCH=$fake_bench \
    "$script_directory/run-bandwidth-ladder.sh" \
    "$first_spaced_model" "$second_spaced_model" \
    >"$temporary_directory/bandwidth-nice.stdout" \
    2>"$temporary_directory/bandwidth-nice.stderr"; then
    printf 'bandwidth fixture accepted a priority other than nice 19\n' >&2
    exit 1
fi
grep -F 'bandwidth ladder requires nice 19: 0' \
    "$temporary_directory/bandwidth-nice.stderr" >/dev/null
active_fixture=bandwidth-model-path-order
diagnostic_file=$temporary_directory/bandwidth.stderr
if ! env \
    QWEN_BANDWIDTH_OUTPUT=$bandwidth_output QWEN_LLAMA_BENCH=$fake_bench \
    QWEN_TENSOR_CENSUS=$fake_census QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=delayed_success QWEN_BENCH_NICE_LEVELS=19 \
    "$script_directory/run-bandwidth-ladder.sh" \
    "$first_spaced_model" "$second_spaced_model" \
    >"$temporary_directory/bandwidth.stdout" \
    2>"$temporary_directory/bandwidth.stderr"; then
    printf 'bandwidth fixture failed before path-order verification\n' >&2
    sed -n '1,160p' "$temporary_directory/bandwidth.stderr" >&2
    exit 1
fi
for model_name in 'first model' 'second model'; do
    if [ "$(awk -F'\t' -v model="$model_name" '$3 == model { count++ }
                    END { print count + 0 }' \
                    "$bandwidth_output/bandwidth-summary.tsv")" -ne 2 ]; then
        printf 'reversed bandwidth ladder split or lost model path: %s\n' \
            "$model_name" >&2
        exit 1
    fi
done

# A paired prefill/decode arm is incomplete when llama-bench emits no pp row.
# The retained summary keeps the missing value, and the terminal state fails
# instead of presenting the decode half as a completed paired sweep.
missing_prefill_output=$temporary_directory/bandwidth-missing-prefill
active_fixture=bandwidth-required-prefill-output
diagnostic_file=$temporary_directory/missing-prefill.stderr
if env \
    QWEN_BANDWIDTH_OUTPUT=$missing_prefill_output QWEN_LLAMA_BENCH=$fake_bench \
    QWEN_TENSOR_CENSUS=$fake_census QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=delayed_success QWEN_BENCH_NICE_LEVELS=19 \
    QWEN_BENCH_PREFILL=32 \
    "$script_directory/run-bandwidth-ladder.sh" "$first_spaced_model" \
    >"$temporary_directory/missing-prefill.stdout" \
    2>"$temporary_directory/missing-prefill.stderr"; then
    printf 'bandwidth fixture accepted a missing requested prefill row\n' >&2
    exit 1
fi
grep -F 'arm_prefill_missing' \
    "$temporary_directory/missing-prefill.stderr" >/dev/null
grep -F 'bandwidth_ladder=failed' \
    "$temporary_directory/missing-prefill.stderr" >/dev/null
if grep -F 'bandwidth_ladder=completed' \
    "$temporary_directory/missing-prefill.stdout" >/dev/null; then
    printf 'missing prefill printed a completed terminal state\n' >&2
    exit 1
fi
awk -F'\t' 'NR > 1 && $6 == "n/a" { missing++ }
            END { exit missing == 2 ? 0 : 1 }' \
    "$missing_prefill_output/bandwidth-summary.tsv"

wrong_prefill_output=$temporary_directory/bandwidth-wrong-prefill
active_fixture=bandwidth-requested-prefill-identity
diagnostic_file=$temporary_directory/wrong-prefill.stderr
if env \
    QWEN_BANDWIDTH_OUTPUT=$wrong_prefill_output QWEN_LLAMA_BENCH=$fake_bench \
    QWEN_TENSOR_CENSUS=$fake_census QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=wrong_prefill QWEN_BENCH_NICE_LEVELS=19 \
    QWEN_BENCH_PREFILL=32 \
    "$script_directory/run-bandwidth-ladder.sh" "$first_spaced_model" \
    >"$temporary_directory/wrong-prefill.stdout" \
    2>"$temporary_directory/wrong-prefill.stderr"; then
    printf 'bandwidth fixture accepted pp512 as evidence for pp32\n' >&2
    exit 1
fi
awk -F'\t' 'NR > 1 && $5 == "3.00" && $6 == "n/a" { found++ }
            END { exit found == 2 ? 0 : 1 }' \
    "$wrong_prefill_output/bandwidth-summary.tsv"

wrong_decode_output=$temporary_directory/bandwidth-wrong-decode
active_fixture=bandwidth-requested-decode-identity
diagnostic_file=$temporary_directory/wrong-decode.stderr
if env \
    QWEN_BANDWIDTH_OUTPUT=$wrong_decode_output QWEN_LLAMA_BENCH=$fake_bench \
    QWEN_TENSOR_CENSUS=$fake_census QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=wrong_decode QWEN_BENCH_NICE_LEVELS=19 \
    "$script_directory/run-bandwidth-ladder.sh" "$first_spaced_model" \
    >"$temporary_directory/wrong-decode.stdout" \
    2>"$temporary_directory/wrong-decode.stderr"; then
    printf 'bandwidth fixture accepted tg128 as evidence for tg64\n' >&2
    exit 1
fi
awk -F'\t' 'NR > 1 && $5 == "n/a" { found++ }
            END { exit found == 2 ? 0 : 1 }' \
    "$wrong_decode_output/bandwidth-summary.tsv"

misleading_columns_output=$temporary_directory/bandwidth-misleading-columns
active_fixture=bandwidth-test-column-identity
diagnostic_file=$temporary_directory/misleading-columns.stderr
if env \
    QWEN_BANDWIDTH_OUTPUT=$misleading_columns_output \
    QWEN_LLAMA_BENCH=$fake_bench QWEN_TENSOR_CENSUS=$fake_census \
    QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=misleading_columns QWEN_BENCH_NICE_LEVELS=19 \
    QWEN_BENCH_PREFILL=32 \
    "$script_directory/run-bandwidth-ladder.sh" "$first_spaced_model" \
    >"$temporary_directory/misleading-columns.stdout" \
    2>"$temporary_directory/misleading-columns.stderr"; then
    printf 'bandwidth fixture treated a non-test column as row identity\n' >&2
    exit 1
fi
awk -F'\t' 'NR > 1 && $5 == "n/a" && $6 == "n/a" { found++ }
            END { exit found == 2 ? 0 : 1 }' \
    "$misleading_columns_output/bandwidth-summary.tsv"

exact_label_output=$temporary_directory/bandwidth-exact-labels
active_fixture=bandwidth-depth-qualified-label-identity
diagnostic_file=$temporary_directory/exact-labels.stderr
env QWEN_BANDWIDTH_OUTPUT=$exact_label_output QWEN_LLAMA_BENCH=$fake_bench \
    QWEN_TENSOR_CENSUS=$fake_census QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=exact_depth_labels QWEN_BENCH_NICE_LEVELS=19 \
    QWEN_BENCH_PREFILL=32 \
    "$script_directory/run-bandwidth-ladder.sh" "$first_spaced_model" \
    >"$temporary_directory/exact-labels.stdout" \
    2>"$temporary_directory/exact-labels.stderr"
awk -F'\t' 'NR > 1 && $5 == "3.00" && $6 == "12.00" { found++ }
            END { exit found == 2 ? 0 : 1 }' \
    "$exact_label_output/bandwidth-summary.tsv"

# The real llama-bench frames its table with lines that carry no pipe at all --
# a device banner above it, a blank line and a build line below -- while every
# fixture above emits pipe-bearing lines alone. mawk makes a negative field
# index a fatal run-time error, so an unguarded $(NF - 2) aborts on the banner,
# the extractor's END never runs, and the arm records an empty rate rather than
# the n/a a genuine miss produces. This fixture reproduces the real frame and
# requires both rates to survive it.
banner_output=$temporary_directory/bandwidth-device-banner
active_fixture=bandwidth-unpiped-frame-lines
diagnostic_file=$temporary_directory/device-banner.stderr
env QWEN_BANDWIDTH_OUTPUT=$banner_output QWEN_LLAMA_BENCH=$fake_bench \
    QWEN_TENSOR_CENSUS=$fake_census QWEN_CLOCK_SAMPLER=$fake_sampler \
    QWEN_TEST_SAMPLER_PID_FILE=$sampler_pid_file \
    QWEN_TEST_BENCH_MODE=device_banner QWEN_BENCH_NICE_LEVELS=19 \
    QWEN_BENCH_PREFILL=32 \
    "$script_directory/run-bandwidth-ladder.sh" "$first_spaced_model" \
    >"$temporary_directory/device-banner.stdout" \
    2>"$temporary_directory/device-banner.stderr"
awk -F'\t' 'NR > 1 && $5 == "3.00" && $6 == "12.00" { found++ }
            END { exit found == 2 ? 0 : 1 }' \
    "$banner_output/bandwidth-summary.tsv"
if grep -q 'negative field index' "$temporary_directory/device-banner.stderr"; then
    printf 'bandwidth extractor aborted on a line without pipes\n' >&2
    exit 1
fi

# run-depth-chain.sh waits between checkpoints for the previous summary to
# carry a complete row, its control to have passed, no llama process to be
# running, and the device's gpu_busy_percent sysfs node to read idle for
# several consecutive samples, rather than for the previous PID alone to
# exit.
active_fixture=depth-chain-usage
diagnostic_file=$temporary_directory/chain-usage.stderr
if "$script_directory/run-depth-chain.sh" \
    >"$temporary_directory/chain-usage.stdout" \
    2>"$temporary_directory/chain-usage.stderr"; then
    printf 'depth chain accepted zero checkpoint arguments\n' >&2
    exit 1
fi
grep -F 'usage:' "$temporary_directory/chain-usage.stderr" >/dev/null

chain_fake_probe=$temporary_directory/chain-fake-probe.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'chain_model_path=$1' \
    'chain_output_directory=$2' \
    'mkdir -p "$chain_output_directory"' \
    'printf "%s\\n" "$chain_model_path" >>"'"$temporary_directory"'/chain-probe-calls"' \
    'header="arm\tdepth\tbatch\tubatch\tcache_k\tcache_v\tflash_attn\tstatus\tring_resets\tgpu_faults\twall_s\tdecode_tok_s\tvram_peak_mib\tgtt_peak_mib\tcontrol_status\tcontrol_tok_s\tmclk_modal\ttemp_c_max\thealth\thazard_class"' \
    'row="d1-b1-ub1\t1\t1\t1\tq8_0\tq4_0\ton\t0\t0\t0\t1\t3.00\t0\t0\t0\t3.00\t933\t88.0\thealthy\tnone"' \
    'printf "%b\\n%b\\n" "$header" "$row" \
        >"$chain_output_directory/wedge-summary.tsv"' \
    >"$chain_fake_probe"
chmod +x "$chain_fake_probe"

chain_drm_device=$temporary_directory/chain-drm-device
mkdir -p "$chain_drm_device"
printf '0\n' >"$chain_drm_device/gpu_busy_percent"

chain_output_root=$temporary_directory/depth-chain
chain_home=$temporary_directory/chain-home
mkdir -p "$chain_home"
printf 'fake model bytes\n' >"$chain_home/first.gguf"
printf 'fake model bytes\n' >"$chain_home/second.gguf"
active_fixture=depth-chain-success
diagnostic_file=$temporary_directory/chain-success.stderr
HOME=$chain_home QWEN_DEPTH_CHAIN_PROBE=$chain_fake_probe \
QWEN_DEPTH_CHAIN_OUTPUT_ROOT=$chain_output_root \
QWEN_DRM_DEVICE=$chain_drm_device QWEN_DEPTH_CHAIN_IDLE_INTERVAL_S=1 \
    "$script_directory/run-depth-chain.sh" "first:$chain_home/first.gguf" \
    "second:second.gguf" \
    >"$temporary_directory/chain-success.stdout" \
    2>"$temporary_directory/chain-success.stderr"
if [ "$(wc -l <"$temporary_directory/chain-probe-calls")" -ne 2 ]; then
    printf 'depth chain did not run both checkpoints\n' >&2
    cat "$temporary_directory/chain-success.stderr" >&2
    exit 1
fi
grep -Fx "$chain_home/first.gguf" "$temporary_directory/chain-probe-calls" >/dev/null
grep -Fx "$chain_home/second.gguf" "$temporary_directory/chain-probe-calls" \
    >/dev/null
if grep -F 'chain_gpu_idle=unavailable' \
    "$temporary_directory/chain-success.stderr" >/dev/null; then
    printf 'depth chain reported the fake sysfs busy node unavailable\n' >&2
    exit 1
fi
grep -F 'depth_chain=completed' \
    "$temporary_directory/chain-success.stdout" >/dev/null

chain_failed_probe=$temporary_directory/chain-failed-probe.sh
printf '%s\n' '#!/bin/sh' 'set -eu' \
    'chain_output_directory=$2' \
    'mkdir -p "$chain_output_directory"' \
    'header="arm\tdepth\tbatch\tubatch\tcache_k\tcache_v\tflash_attn\tstatus\tring_resets\tgpu_faults\twall_s\tdecode_tok_s\tvram_peak_mib\tgtt_peak_mib\tcontrol_status\tcontrol_tok_s\tmclk_modal\ttemp_c_max\thealth\thazard_class"' \
    'row="d1-b1-ub1\t1\t1\t1\tq8_0\tq4_0\ton\t0\t0\t0\t1\t3.00\t0\t0\t7\t3.00\t933\t88.0\tunhealthy\tnone"' \
    'printf "%b\\n%b\\n" "$header" "$row" \
        >"$chain_output_directory/wedge-summary.tsv"' \
    >"$chain_failed_probe"
chmod +x "$chain_failed_probe"
chain_failed_output_root=$temporary_directory/depth-chain-failed-control
active_fixture=depth-chain-failed-control
diagnostic_file=$temporary_directory/chain-failed.stderr
if HOME=$chain_home QWEN_DEPTH_CHAIN_PROBE=$chain_failed_probe \
    QWEN_DEPTH_CHAIN_OUTPUT_ROOT=$chain_failed_output_root \
    QWEN_DRM_DEVICE=$chain_drm_device QWEN_DEPTH_CHAIN_IDLE_INTERVAL_S=1 \
    "$script_directory/run-depth-chain.sh" "first:$chain_home/first.gguf" \
    "second:second.gguf" \
    >"$temporary_directory/chain-failed.stdout" \
    2>"$temporary_directory/chain-failed.stderr"; then
    printf 'depth chain started a checkpoint after a failed recovery control\n' >&2
    exit 1
fi
grep -F 'the previous checkpoint left a failed recovery control' \
    "$temporary_directory/chain-failed.stderr" >/dev/null

# The complete argument set is validated before the first probe. A malformed
# later checkpoint therefore produces no probe call at all.
: >"$temporary_directory/chain-probe-calls"
active_fixture=depth-chain-preflight-all-checkpoints
diagnostic_file=$temporary_directory/chain-preflight.stderr
if HOME=$chain_home QWEN_DEPTH_CHAIN_PROBE=$chain_fake_probe \
    QWEN_DEPTH_CHAIN_OUTPUT_ROOT=$temporary_directory/depth-chain-preflight \
    QWEN_DRM_DEVICE=$chain_drm_device QWEN_DEPTH_CHAIN_IDLE_INTERVAL_S=1 \
    "$script_directory/run-depth-chain.sh" "first:$chain_home/first.gguf" \
    malformed-second-checkpoint >"$temporary_directory/chain-preflight.stdout" \
    2>"$temporary_directory/chain-preflight.stderr"; then
    printf 'depth chain accepted a malformed later checkpoint\n' >&2
    exit 1
fi
if [ -s "$temporary_directory/chain-probe-calls" ]; then
    printf 'depth chain ran the first checkpoint before rejecting a later argument\n' >&2
    exit 1
fi
grep -F 'checkpoint 2 is not MODEL_ID:REL_PATH' \
    "$temporary_directory/chain-preflight.stderr" >/dev/null

# The missing busy node is a failed safety observation. The first checkpoint
# may finish, but the chain must refuse the second rather than treating
# unavailable telemetry as idle.
: >"$temporary_directory/chain-probe-calls"
active_fixture=depth-chain-busy-node-required
diagnostic_file=$temporary_directory/chain-busy-unavailable.stderr
if HOME=$chain_home QWEN_DEPTH_CHAIN_PROBE=$chain_fake_probe \
    QWEN_DEPTH_CHAIN_OUTPUT_ROOT=$temporary_directory/depth-chain-busy-unavailable \
    QWEN_DRM_DEVICE=$temporary_directory/missing-drm-device \
    QWEN_DEPTH_CHAIN_IDLE_INTERVAL_S=1 \
    "$script_directory/run-depth-chain.sh" "first:$chain_home/first.gguf" \
    "second:second.gguf" >"$temporary_directory/chain-busy-unavailable.stdout" \
    2>"$temporary_directory/chain-busy-unavailable.stderr"; then
    printf 'depth chain accepted an unavailable GPU busy node\n' >&2
    exit 1
fi
if [ "$(wc -l <"$temporary_directory/chain-probe-calls")" -ne 1 ]; then
    printf 'depth chain ran a second checkpoint without GPU busy telemetry\n' >&2
    exit 1
fi
grep -F 'chain_gpu_idle=unavailable' \
    "$temporary_directory/chain-busy-unavailable.stderr" >/dev/null

active_fixture=completed
diagnostic_file=
printf 'measurement_harnesses=accepted\n'
