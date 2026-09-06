#!/bin/sh
# Drive scripts/classify-page-arm.sh through every terminal shape a page arm
# reaches. Each case is a report file, a stderr file, and an exit status
# written here, so the classification is exercised without a browser, a router,
# a network, or the device, and a refusal that named nothing to triage becomes
# a case rather than a wait for the next unexplained run.
set -eu

if [ "$#" -ne 0 ]; then
    printf 'usage: %s\n' "$0" >&2
    exit 2
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
classifier=$script_directory/classify-page-arm.sh
temporary_directory=$(mktemp -d)
failures=0

cleanup() {
    rm -rf "$temporary_directory"
}
trap 'cleanup' EXIT
trap 'cleanup; exit 143' HUP INT TERM

fail() {
    printf 'FAIL %s\n' "$1" >&2
    failures=$((failures + 1))
}

pass() {
    printf 'ok %s\n' "$1"
}

# One case: a report, a stderr file, an exit status, and the fields the
# classification has to carry. Every field is required to be nonempty, since a
# refusal whose detail is blank names nothing.
run_case() {
    case_name=$1
    report_body=$2
    stderr_body=$3
    case_status=$4
    shift 4

    case_report=$temporary_directory/$case_name.json
    case_stderr=$temporary_directory/$case_name.err
    # A body of `absent` leaves no file, which is the shape a death before the
    # write leaves and a different failure from a truncated one.
    if [ "$report_body" = absent ]; then
        rm -f "$case_report"
    else
        printf '%s' "$report_body" >"$case_report"
    fi
    printf '%s' "$stderr_body" >"$case_stderr"

    if ! "$classifier" "$case_report" "$case_stderr" "$case_status" 4200 \
        >"$temporary_directory/$case_name.out" \
        2>"$temporary_directory/$case_name.classifier-err"; then
        fail "$case_name the classifier exited nonzero"
        return 0
    fi

    # The classifier's own stderr stays empty, since a shape it is built to
    # name should not also reach the log as an error.
    if [ -s "$temporary_directory/$case_name.classifier-err" ]; then
        fail "$case_name the classifier wrote to stderr: $(tr '\n' ' ' <"$temporary_directory/$case_name.classifier-err")"
        return 0
    fi

    for expectation in "$@"; do
        if ! grep -qx -- "$expectation" "$temporary_directory/$case_name.out"; then
            fail "$case_name expected=$expectation read=$(tr '\n' ' ' <"$temporary_directory/$case_name.out")"
            return 0
        fi
    done

    # Every emitted field carries a value, so a triage read finds a name rather
    # than an empty right-hand side.
    if awk -F= 'NF < 2 || $2 == "" { exit 1 }' "$temporary_directory/$case_name.out"; then
        pass "$case_name $(sed -n 's/^termination_reason=//p' "$temporary_directory/$case_name.out")"
    else
        fail "$case_name an emitted field carried no value"
    fi
}

never_loaded='{"error": {"type": "TimeoutError", "message": "waited 180s for the page to load"},
 "last_completed_phase": null, "pending_phase": "the page to load",
 "pending_phase_deadline_s": 180, "history": []}'

phase_never_arrived='{"error": {"type": "TimeoutError", "message": "waited 600s for the coding plan approval dialog"},
 "last_completed_phase": "the page to select a model",
 "pending_phase": "the coding plan approval dialog",
 "pending_phase_deadline_s": 600, "history": []}'

protocol_failure='{"error": {"type": "RuntimeError", "message": "page threw: {\"exceptionId\": 3}"},
 "last_completed_phase": "the page to load", "pending_phase": "the turn to end",
 "pending_phase_deadline_s": 900, "history": []}'

no_error_object='{"last_completed_phase": "the page to load", "pending_phase": "the turn to end",
 "pending_phase_deadline_s": 900, "history": []}'

completed_report='{"error": null, "last_completed_phase": "the turn to end",
 "pending_phase": null, "pending_phase_deadline_s": null, "history": []}'

# The page never loads. The pending phase names the wait rather than the
# exception, which is what tells this apart from the case below it.
run_case page_never_loads "$never_loaded" '' 1 \
    'termination_reason=timeout' \
    'pending_phase=the page to load' \
    'last_completed_phase=-' \
    'configured_deadline_s=180'

# The page loads and the expected phase never arrives. The same exception type
# reaches a different verdict because the timeline says how far it got.
run_case phase_never_arrives "$phase_never_arrived" '' 1 \
    'termination_reason=timeout' \
    'last_completed_phase=the page to select a model' \
    'pending_phase=the coding plan approval dialog' \
    'configured_deadline_s=600'

# The driver exits nonzero with empty stderr. The report is the authority, so
# an empty stderr changes nothing about what the classification names.
run_case empty_stderr "$protocol_failure" '' 1 \
    'termination_reason=protocol_error' \
    'stderr_bytes=0' \
    'last_completed_phase=the page to load'

# The driver receives a signal. The status names it before the report does,
# because a signal can arrive before anything is written.
run_case signalled absent '' 137 \
    'termination_reason=signal' \
    'signal=9' \
    'exit_status=137'

# The report is missing, and the shell reads that rather than a stale file.
run_case report_missing_case absent 'chromium: error while loading shared libraries
' 1 \
    'termination_reason=report_missing' \
    'exit_status=1'

# The report is malformed, which is a different verdict from a missing one
# because a truncated write and an absent file are different failures.
run_case report_malformed '{"error": {"type": "Timeout' '' 1 \
    'termination_reason=report_unreadable'

# The report parses and carries no error object, which is the shape a death
# after the write leaves.
run_case report_without_error "$no_error_object" '' 1 \
    'termination_reason=crash'

# The operation completes just before its deadline. A zero status is a
# completion whatever the report says about the phases it passed.
run_case completed_before_deadline "$completed_report" '' 0 \
    'termination_reason=completed' \
    'last_completed_phase=the turn to end' \
    'signal=-'

# A signal that arrived after the report was written still reads as a signal,
# since the status is the stronger evidence about how the process ended.
run_case signalled_with_report "$protocol_failure" '' 143 \
    'termination_reason=signal' \
    'signal=15'

# A phase name carrying a newline stays on one line. The driver builds one
# phase from its --model argument rather than from a literal, and the shell
# reads this output with sed, so an unflattened value would present its tail as
# another key and change the verdict.
newline_phase='{"error": {"type": "TimeoutError", "message": "waited 180s for the page to select --model a\nstate=report_missing"}, "last_completed_phase": null, "pending_phase": "the page to select --model a\nstate=report_missing", "pending_phase_deadline_s": 180, "history": []}'

run_case newline_in_phase "$newline_phase" '' 1 \
    'termination_reason=timeout' \
    'pending_phase=the page to select --model a state=report_missing' \
    'configured_deadline_s=180'

# The invariant is key identity rather than a frozen field count, so adding a
# field later leaves this arm measuring what it was written to measure: the
# injected suffix reaches no key of its own and every emitted key appears once.
if grep -q '^state=' "$temporary_directory/newline_in_phase.out"; then
    fail 'newline_in_phase the injected suffix became a key of its own'
elif [ "$(cut -d= -f1 <"$temporary_directory/newline_in_phase.out" | sort |
    uniq -d | wc -l)" -ne 0 ]; then
    fail "newline_in_phase a key repeats: $(cut -d= -f1 <"$temporary_directory/newline_in_phase.out" | sort | uniq -d | tr '\n' ' ')"
else
    pass 'newline_in_phase every key appears once and the suffix reaches none'
fi

# The classifier refuses an argument count and a non-numeric status rather than
# classifying something it cannot read.
if "$classifier" >/dev/null 2>&1; then
    fail 'usage the classifier accepted no arguments'
else
    [ "$?" = 2 ] && pass 'usage no arguments exits 2' || fail 'usage wrong status'
fi
if "$classifier" /dev/null /dev/null not-a-status 0 >/dev/null 2>&1; then
    fail 'usage the classifier accepted a non-numeric status'
else
    pass 'usage a non-numeric status is refused'
fi
if "$classifier" /dev/null /dev/null 1 "4200
state=report_missing" >/dev/null 2>&1; then
    fail 'usage the classifier accepted an elapsed count carrying a newline'
else
    pass 'usage an elapsed count carrying a newline is refused'
fi

if [ "$failures" -eq 0 ]; then
    printf 'page_arm_classification=accepted\n'
    exit 0
fi

printf 'page_arm_classification=refused failures=%s\n' "$failures"
exit 1
