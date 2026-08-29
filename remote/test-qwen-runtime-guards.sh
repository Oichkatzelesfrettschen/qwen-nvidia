#!/bin/sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
temporary_directory=$(mktemp -d)
fake_gpu_directory=$temporary_directory/fake-gpu
export QWEN_GUARD_CPU_ACTIVE=1
test_pid=""
watchdog_pid=""
kernel_watchdog_pid=""

cleanup() {
    if [ -n "$test_pid" ]; then
        kill "$test_pid" 2>/dev/null || true
        wait "$test_pid" 2>/dev/null || true
    fi
    if [ -n "$watchdog_pid" ]; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$kernel_watchdog_pid" ]; then
        kill "$kernel_watchdog_pid" 2>/dev/null || true
        wait "$kernel_watchdog_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fake_gpu_directory"
printf '0\n' >"$fake_gpu_directory/gpu_busy_percent"
printf '0\n' >"$fake_gpu_directory/mem_info_gtt_used"
printf '0\n' >"$fake_gpu_directory/mem_info_vram_used"
printf '0: 200Mhz *\n' >"$fake_gpu_directory/pp_dpm_sclk"
printf '0: 400Mhz *\n' >"$fake_gpu_directory/pp_dpm_mclk"

start_test_process() {
    target_nice_value=$1
    duration_seconds=$2
    taskset -c 0 sleep "$duration_seconds" &
    test_pid=$!
    renice -n "$target_nice_value" -p "$test_pid" >/dev/null
}

start_persistent_test_process() {
    target_nice_value=$1
    taskset -c 0 sh -c 'while :; do sleep 1; done' &
    test_pid=$!
    renice -n "$target_nice_value" -p "$test_pid" >/dev/null
}

start_term_ignoring_process() {
    taskset -c 0 sh -c 'trap "" TERM; while :; do sleep 1; done' &
    test_pid=$!
    renice -n 19 -p "$test_pid" >/dev/null
}

start_watchdog_process() {
    taskset -c 0 sleep 60 &
    watchdog_pid=$!
    renice -n 19 -p "$watchdog_pid" >/dev/null
}

start_kernel_watchdog_process() {
    taskset -c 0 sleep 60 &
    kernel_watchdog_pid=$!
    renice -n 19 -p "$kernel_watchdog_pid" >/dev/null
}

start_test_process 19 5
start_watchdog_process
start_kernel_watchdog_process
QWEN_GUARD_TEST_MODE=1 QWEN_GPU_DEVICE_DIRECTORY=$fake_gpu_directory \
    "$script_directory/monitor-qwen-runtime.sh" \
    "$test_pid" "$temporary_directory/positive-telemetry.log" \
    paced-60 "$watchdog_pid" "$kernel_watchdog_pid"
wait "$test_pid" 2>/dev/null || true
test_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
kill "$kernel_watchdog_pid" 2>/dev/null || true
wait "$kernel_watchdog_pid" 2>/dev/null || true
kernel_watchdog_pid=""
grep -F 'reason=server_exited' "$temporary_directory/positive-telemetry.log" >/dev/null
grep -F 'guard_affinity=1 guard_nice=0' \
    "$temporary_directory/positive-telemetry.log" >/dev/null

start_persistent_test_process 18
start_watchdog_process
start_kernel_watchdog_process
set +e
QWEN_GUARD_TEST_MODE=1 QWEN_GPU_DEVICE_DIRECTORY=$fake_gpu_directory \
    "$script_directory/monitor-qwen-runtime.sh" \
    "$test_pid" "$temporary_directory/negative-telemetry.log" \
    paced-60 "$watchdog_pid" "$kernel_watchdog_pid"
monitor_status=$?
set -e
if [ "$monitor_status" -ne 3 ]; then
    printf 'runtime monitor negative test returned %s instead of 3\n' \
        "$monitor_status" >&2
    exit 1
fi
wait "$test_pid" 2>/dev/null || true
test_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
kill "$kernel_watchdog_pid" 2>/dev/null || true
wait "$kernel_watchdog_pid" 2>/dev/null || true
kernel_watchdog_pid=""
grep -F 'reason=process_nice_changed' \
    "$temporary_directory/negative-telemetry.log" >/dev/null

printf '76\n' >"$fake_gpu_directory/gpu_busy_percent"
start_term_ignoring_process
start_watchdog_process
start_kernel_watchdog_process
set +e
QWEN_GUARD_TEST_MODE=1 QWEN_GPU_DEVICE_DIRECTORY=$fake_gpu_directory \
    "$script_directory/monitor-qwen-runtime.sh" \
    "$test_pid" "$temporary_directory/gpu-busy-telemetry.log" \
    paced-60 "$watchdog_pid" "$kernel_watchdog_pid"
monitor_status=$?
set -e
if [ "$monitor_status" -ne 3 ]; then
    printf 'GPU busy monitor test returned %s instead of 3\n' \
        "$monitor_status" >&2
    exit 1
fi
wait "$test_pid" 2>/dev/null || true
test_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
kill "$kernel_watchdog_pid" 2>/dev/null || true
wait "$kernel_watchdog_pid" 2>/dev/null || true
kernel_watchdog_pid=""
grep -F 'reason=gpu_busy_percent_breached' \
    "$temporary_directory/gpu-busy-telemetry.log" >/dev/null
grep -F 'action=SIGKILL grace_milliseconds=2000' \
    "$temporary_directory/gpu-busy-telemetry.log" >/dev/null

printf '100\n' >"$fake_gpu_directory/gpu_busy_percent"
start_test_process 19 5
start_watchdog_process
start_kernel_watchdog_process
QWEN_GUARD_TEST_MODE=1 QWEN_GPU_DEVICE_DIRECTORY=$fake_gpu_directory \
    "$script_directory/monitor-qwen-runtime.sh" \
    "$test_pid" "$temporary_directory/priority-first-telemetry.log" \
    low-serialized "$watchdog_pid" "$kernel_watchdog_pid"
wait "$test_pid" 2>/dev/null || true
test_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
kill "$kernel_watchdog_pid" 2>/dev/null || true
wait "$kernel_watchdog_pid" 2>/dev/null || true
kernel_watchdog_pid=""
grep -F 'threshold_maximum_gpu_busy_percent=100' \
    "$temporary_directory/priority-first-telemetry.log" >/dev/null

start_test_process 19 5
start_watchdog_process
start_kernel_watchdog_process
QWEN_GUARD_TEST_MODE=1 QWEN_GPU_DEVICE_DIRECTORY=$fake_gpu_directory \
    "$script_directory/monitor-qwen-runtime.sh" \
    "$test_pid" "$temporary_directory/async-priority-first-telemetry.log" \
    low-async "$watchdog_pid" "$kernel_watchdog_pid"
wait "$test_pid" 2>/dev/null || true
test_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
kill "$kernel_watchdog_pid" 2>/dev/null || true
wait "$kernel_watchdog_pid" 2>/dev/null || true
kernel_watchdog_pid=""
grep -F 'threshold_maximum_gpu_busy_percent=100' \
    "$temporary_directory/async-priority-first-telemetry.log" >/dev/null

printf '0\n' >"$fake_gpu_directory/gpu_busy_percent"
start_persistent_test_process 19
start_watchdog_process
kill "$watchdog_pid"
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
set +e
QWEN_GUARD_TEST_MODE=1 QWEN_GPU_DEVICE_DIRECTORY=$fake_gpu_directory \
    "$script_directory/monitor-qwen-runtime.sh" \
    "$test_pid" "$temporary_directory/watchdog-telemetry.log" \
    low-serialized 999999999 999999998
monitor_status=$?
set -e
if [ "$monitor_status" -ne 3 ]; then
    printf 'watchdog monitor test returned %s instead of 3\n' \
        "$monitor_status" >&2
    exit 1
fi
wait "$test_pid" 2>/dev/null || true
test_pid=""
grep -F 'reason=graphics_latency_watchdog_unavailable' \
    "$temporary_directory/watchdog-telemetry.log" >/dev/null

start_persistent_test_process 19
start_watchdog_process
set +e
QWEN_GUARD_TEST_MODE=1 QWEN_GPU_DEVICE_DIRECTORY=$fake_gpu_directory \
    "$script_directory/monitor-qwen-runtime.sh" \
    "$test_pid" "$temporary_directory/kernel-watchdog-telemetry.log" \
    low-serialized "$watchdog_pid" 999999997
monitor_status=$?
set -e
if [ "$monitor_status" -ne 3 ]; then
    printf 'kernel watchdog monitor test returned %s instead of 3\n' \
        "$monitor_status" >&2
    exit 1
fi
wait "$test_pid" 2>/dev/null || true
test_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
grep -F 'reason=kernel_hazard_watchdog_unavailable' \
    "$temporary_directory/kernel-watchdog-telemetry.log" >/dev/null

start_persistent_test_process 19
printf '%s\n' 'amdgpu: ring gfx timeout, signaled seq=1' \
    >"$temporary_directory/synthetic-kernel.log"
set +e
"$script_directory/watch-qwen-kernel-hazards.sh" "$test_pid" \
    "$temporary_directory/hazard-watch.log" \
    "$temporary_directory/synthetic-kernel.log"
hazard_status=$?
set -e
if [ "$hazard_status" -ne 3 ]; then
    printf 'kernel hazard negative test returned %s instead of 3\n' \
        "$hazard_status" >&2
    exit 1
fi
wait "$test_pid" 2>/dev/null || true
test_pid=""
grep -F 'action=SIGTERM' "$temporary_directory/hazard-watch.log" >/dev/null
grep -F 'guard_affinity=1 guard_nice=0' \
    "$temporary_directory/hazard-watch.log" >/dev/null

printf 'runtime_monitor=accepted gpu_busy_ceiling=accepted kernel_hazard_watcher=accepted\n'
