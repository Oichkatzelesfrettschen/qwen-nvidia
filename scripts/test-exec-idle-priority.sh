#!/bin/sh
set -eu

# Prove that the priority a generation runs at is established
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

if [ "$failures" -ne 0 ]; then
    printf '\ntest-exec-idle-priority: %s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\ntest-exec-idle-priority: every check passed\n'
