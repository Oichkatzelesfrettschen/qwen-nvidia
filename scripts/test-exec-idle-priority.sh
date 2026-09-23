#!/bin/sh
set -eu

# Prove that the priority a generation runs at is established
# before the process it belongs to executes, and that it is absolute rather than
# an offset against whatever launched it.
#
# Every arm establishes absolute nice 5 in a SCHED_OTHER child and checks that
# precondition before calling the subject. Relative `nice -n 5` saturates at 19
# under an already-niced test runner and makes a removed renice look correct.
# SCHED_IDLE displays a dash in ps's NI column, so the child establishes the
# scheduler class whose numeric read-back the subject consumes. A host that
# refuses either fixture precondition reports that prerequisite explicitly.
# The arm that runs from a negative nice is unrun here;
# evidence/exec-idle-priority.md records that gap and what the remaining arms
# establish without it.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
wrapper=$script_directory/qwen-exec-idle-priority.sh
fake_runtime=$script_directory/test-fixtures/fake-image-runtime.sh

work_directory=$(mktemp -d)
trap 'rm -rf "$work_directory"' EXIT

cat >"$work_directory/caller.sh" <<'CALLER'
#!/bin/sh
set -eu
if ! /usr/bin/renice --priority 5 --pid "$$" >/dev/null 2>&1; then
    printf 'fixture prerequisite refused: establish absolute nice 5\n' >&2
    exit 124
fi
if ! /usr/bin/chrt --other --pid 0 "$$" 2>/dev/null; then
    printf 'fixture prerequisite refused: establish SCHED_OTHER\n' >&2
    exit 124
fi
observed_nice=$(LC_ALL=C /usr/bin/ps -o ni= -p "$$" | /usr/bin/awk '{print $1}')
if [ "$observed_nice" != 5 ]; then
    printf 'fixture prerequisite refused: expected nice=5 observed=%s\n' "$observed_nice" >&2
    exit 124
fi
exec "$@"
CALLER
chmod +x "$work_directory/caller.sh"

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
        "$work_directory/caller.sh" "$@" "$fake_runtime" \
        --output "$work_directory/arm.png" --width 8 --height 8 --seed 1 \
        >"$work_directory/arm.out" 2>"$work_directory/arm.err"
}

# A caller at nice 5 reaches the runtime's first instruction at nice 19 and in
# the idle I/O class.
if record_priority "$work_directory/plain.txt" "$wrapper"; then
    :
else
    initial_status=$?
    cat "$work_directory/arm.err" >&2
    exit "$initial_status"
fi
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
