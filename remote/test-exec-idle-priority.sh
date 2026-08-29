#!/bin/sh
set -eu

# Prove that the priority a measurement or a generation runs at is established
# before the process it belongs to executes, and that it is absolute rather than
# an offset against whatever launched it.
#
# Every arm calls the subject from nice 5, so a relative increment and an
# absolute value are distinguishable in the arms that can distinguish them. The
# arm that runs from a negative nice is unrun here, because lowering a nice
# value requires privilege this test declines to take;
# evidence/exec-idle-priority.md records that gap and what the remaining arms
# establish without it.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
wrapper=$script_directory/qwen-exec-idle-priority.sh
dpm_harness=$script_directory/measure-dpm-force.sh
fake_runtime=$script_directory/test-fixtures/fake-image-runtime.sh

work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT

failures=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: expected %s, observed %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

record_priority() {
    record=$1
    shift
    rm -f "$record"
    QWEN_FAKE_IMAGE_PRIORITY_RECORD=$record \
        nice -n 5 "$@" "$fake_runtime" \
        --output "$work_directory/arm.png" --width 8 --height 8 --seed 1 \
        >"$work_directory/arm.out" 2>"$work_directory/arm.err"
}

# A caller at nice 5 reaches the runtime's first instruction at nice 19 and in
# the idle I/O class.
record_priority "$work_directory/plain.txt" "$wrapper"
check 'runtime state under the wrapper' 'nice=19 ioclass=idle' \
    "$(cat "$work_directory/plain.txt" 2>/dev/null || printf unrecorded)"
check 'wrapper announces readiness' 1 \
    "$(grep -c 'qwen_priority_ready pid=[0-9]* nice=19 ioclass=idle' \
        "$work_directory/arm.err" || :)"

# POSIXLY_CORRECT is what turns `renice -n` relative; `renice --priority` names
# an absolute value under it.
POSIXLY_CORRECT=1 record_priority "$work_directory/posix.txt" "$wrapper"
check 'runtime state under POSIXLY_CORRECT' 'nice=19 ioclass=idle' \
    "$(cat "$work_directory/posix.txt" 2>/dev/null || printf unrecorded)"

# A wrapper whose priority call fails exits ahead of the runtime, so the marker
# is absent and the runtime records nothing.
mkdir -p "$work_directory/stub"
cat >"$work_directory/stub/renice" <<'STUB'
#!/bin/sh
printf 'renice refused\n' >&2
exit 1
STUB
chmod +x "$work_directory/stub/renice"
sed "s|/usr/bin/renice|$work_directory/stub/renice|" "$wrapper" \
    >"$work_directory/refusing-wrapper.sh"
chmod +x "$work_directory/refusing-wrapper.sh"
set +e
record_priority "$work_directory/refused.txt" "$work_directory/refusing-wrapper.sh"
refusal_status=$?
set -e
check 'a refused priority exits 125' 125 "$refusal_status"
check 'a refused priority never executes the runtime' absent \
    "$(if [ -e "$work_directory/refused.txt" ]; then printf present; else printf absent; fi)"
check 'a refused priority prints no readiness marker' 0 \
    "$(grep -c qwen_priority_ready "$work_directory/arm.err" || :)"

# Removing the absolute renice leaves the caller's own nice in force, which the
# wrapper's own read-back rejects. A mutation that drops the mechanism fails
# here rather than passing quietly.
sed '/renice --priority/,+1d' "$wrapper" >"$work_directory/mutant-wrapper.sh"
chmod +x "$work_directory/mutant-wrapper.sh"
set +e
record_priority "$work_directory/mutant.txt" "$work_directory/mutant-wrapper.sh"
mutant_status=$?
set -e
check 'a wrapper without the absolute renice is refused' 125 "$mutant_status"
check 'the mutant never executes the runtime' absent \
    "$(if [ -e "$work_directory/mutant.txt" ]; then printf present; else printf absent; fi)"

# The DPM harness establishes its own priority once and records it in every arm.
# Four stubs stand in for the device: the amdgpu governor node, its clock
# surface, the clock sampler, and llama-bench.
device_directory=$work_directory/drm-device
mkdir -p "$device_directory"
printf 'auto\n' >"$device_directory/power_dpm_force_performance_level"
printf '0: 400Mhz\n1: 800Mhz *\n' >"$device_directory/pp_dpm_mclk"
cat >"$work_directory/stub/sudo" <<'STUB'
#!/bin/sh
set -eu
[ "${1:-}" = -n ] && shift
case ${1:-} in
    true) exit 0 ;;
    tee) shift; cat >"$1" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$work_directory/stub/sudo"
cat >"$work_directory/stub/sampler.sh" <<'STUB'
#!/bin/sh
set -eu
printf 'timestamp\tsclk\tmclk\ttemp\n' >"$1"
printf '0\t1400\t800\t45000\n' >>"$1"
STUB
chmod +x "$work_directory/stub/sampler.sh"
# The stub bench records the priority it inherited and prints the one tg row the
# harness parses, so the summary's own claim and the bench's observation are two
# readings of the same value.
cat >"$work_directory/stub/bench.sh" <<'STUB'
#!/bin/sh
set -eu
LC_ALL=C /usr/bin/ps -o ni= -p "$$" |
    /usr/bin/awk 'NR == 1 { gsub(/[[:space:]]/, "", $0); print }' \
    >>"$QWEN_STUB_BENCH_NICE_RECORD"
printf '| model | size | params | backend | test | t/s |\n'
printf '| --- | --- | --- | --- | --- | --- |\n'
printf '| stub | 1 B | 1 | Stub | tg64 | 12.34 +/- 0.01 |\n'
STUB
chmod +x "$work_directory/stub/bench.sh"
printf 'model\n' >"$work_directory/model.gguf"

set +e
PATH=$work_directory/stub:$PATH \
QWEN_STUB_BENCH_NICE_RECORD=$work_directory/bench-nice.txt \
QWEN_LLAMA_BENCH=$work_directory/stub/bench.sh \
QWEN_CLOCK_SAMPLER=$work_directory/stub/sampler.sh \
QWEN_DRM_DEVICE=$device_directory \
QWEN_DPM_ROUNDS=1 \
    nice -n 5 "$dpm_harness" "$work_directory/model.gguf" \
    "$work_directory/dpm" >"$work_directory/dpm.out" 2>&1
dpm_status=$?
set -e
check 'the DPM harness completes against the stub device' 0 "$dpm_status"
check 'every DPM arm records nice 19 and the idle class' 2 \
    "$(awk -F'\t' 'NR > 1 && $9 == 19 && $10 == "idle"' \
        "$work_directory/dpm/dpm-summary.tsv" 2>/dev/null | wc -l)"
check 'the bench inherits nice 19 in every arm' 2 \
    "$(grep -c '^19$' "$work_directory/bench-nice.txt" 2>/dev/null || :)"

# A DPM harness whose priority call fails refuses before it touches the
# governor node, so the device is left where the run found it.
cat >"$work_directory/stub/renice-refusing" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$work_directory/stub/renice-refusing"
sed "s|/usr/bin/renice|$work_directory/stub/renice-refusing|" "$dpm_harness" \
    >"$work_directory/refusing-dpm.sh"
chmod +x "$work_directory/refusing-dpm.sh"
set +e
PATH=$work_directory/stub:$PATH \
QWEN_STUB_BENCH_NICE_RECORD=$work_directory/bench-nice-2.txt \
QWEN_LLAMA_BENCH=$work_directory/stub/bench.sh \
QWEN_CLOCK_SAMPLER=$work_directory/stub/sampler.sh \
QWEN_DRM_DEVICE=$device_directory \
QWEN_DPM_ROUNDS=1 \
    nice -n 5 "$work_directory/refusing-dpm.sh" "$work_directory/model.gguf" \
    "$work_directory/dpm-refused" >"$work_directory/dpm-refused.out" 2>&1
dpm_refusal_status=$?
set -e
check 'a DPM harness at a refused priority exits 2' 2 "$dpm_refusal_status"
check 'a refused DPM harness runs no arm' absent \
    "$(if [ -e "$work_directory/bench-nice-2.txt" ]; then printf present; else printf absent; fi)"

if [ "$failures" -ne 0 ]; then
    printf '\ntest-exec-idle-priority: %s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\ntest-exec-idle-priority: every check passed\n'
