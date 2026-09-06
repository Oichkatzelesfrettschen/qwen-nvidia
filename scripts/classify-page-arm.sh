#!/bin/sh
# Classify one page-arm run from what it left behind. drive-fallback-page.py
# catches its own exceptions, writes the report to stdout carrying an `error`
# object, and returns 1, so the cause of a refusal lives in the report rather
# than in stderr; reading the stderr tail alone produced refusals whose detail
# was empty and which named nothing to triage. The report is the authority and
# stderr is the fallback for a death before it is written.
#
# The classification runs here rather than inside the admission so a fixture
# can drive every terminal shape without a browser, a router, or a device.
set -eu

if [ "$#" -ne 4 ]; then
    printf 'usage: %s REPORT_JSON STDERR_FILE EXIT_STATUS ELAPSED_MS\n' "$0" >&2
    exit 2
fi

report_file=$1
stderr_file=$2
exit_status=$3
elapsed_ms=$4

# Both numbers are validated rather than printed as given, because the output
# is line oriented and a newline in either would present its tail as another
# key to the sed that reads this.
case $exit_status in
''|*[!0-9]*)
    printf 'usage: %s REPORT_JSON STDERR_FILE EXIT_STATUS ELAPSED_MS\n' "$0" >&2
    printf '  EXIT_STATUS reads %s rather than a decimal status\n' "$exit_status" >&2
    exit 2
    ;;
esac

case $elapsed_ms in
''|*[!0-9]*)
    printf 'usage: %s REPORT_JSON STDERR_FILE EXIT_STATUS ELAPSED_MS\n' "$0" >&2
    printf '  ELAPSED_MS reads %s rather than a decimal count\n' \
        "$(printf '%s' "$elapsed_ms" | tr -d '\n\t')" >&2
    exit 2
    ;;
esac

# The redirect itself fails on an absent path before wc runs, so the file is
# tested rather than the command's status: an absent report is one of the
# shapes this classifies rather than an error it prints.
report_bytes=0
[ -f "$report_file" ] && report_bytes=$(wc -c <"$report_file")
stderr_bytes=0
[ -f "$stderr_file" ] && stderr_bytes=$(wc -c <"$stderr_file")

# The report carries the error object, the phase timeline, and the budget the
# pending phase was given, so one read answers what failed and how far the run
# got before it did.
read_state=$(python3 - "$report_file" <<'PYTHON'
import json, sys

def emit(**fields):
    # The output is line oriented and the shell reads it with sed, so a value
    # carrying a newline would present its tail as another key. One phase name
    # is built from the driver's --model argument rather than from a literal,
    # so every value is flattened before it is written.
    def flat(value):
        if value in (None, ""):
            return "-"
        return " ".join(str(value).split())

    for name in ("state", "error", "last_completed_phase", "pending_phase",
                 "configured_deadline_s"):
        print("%s=%s" % (name, flat(fields.get(name))))
    raise SystemExit(0)

try:
    with open(sys.argv[1]) as handle:
        report = json.load(handle)
except FileNotFoundError:
    emit(state="report_missing")
except Exception as exc:
    emit(state="report_unreadable", error=type(exc).__name__)

if not isinstance(report, dict):
    emit(state="report_unreadable", error="not_an_object")

last_completed = report.get("last_completed_phase")
pending = report.get("pending_phase")
deadline = report.get("pending_phase_deadline_s")

error = report.get("error")
if not isinstance(error, dict):
    emit(state="report_carries_no_error",
         last_completed_phase=last_completed, pending_phase=pending,
         configured_deadline_s=deadline)

emit(state=str(error.get("type") or "unnamed"),
     error=str(error.get("message") or "")[:200],
     last_completed_phase=last_completed, pending_phase=pending,
     configured_deadline_s=deadline)
PYTHON
)

report_state=$(printf '%s\n' "$read_state" | sed -n 's/^state=//p')
report_error=$(printf '%s\n' "$read_state" | sed -n 's/^error=//p')
last_completed_phase=$(printf '%s\n' "$read_state" | sed -n 's/^last_completed_phase=//p')
pending_phase=$(printf '%s\n' "$read_state" | sed -n 's/^pending_phase=//p')
configured_deadline=$(printf '%s\n' "$read_state" | sed -n 's/^configured_deadline_s=//p')

# A status above 128 names the signal that ended the driver, and the shell
# reports it that way whether or not the report was ever written, so the signal
# is read before the report's own account of the run.
signal_number='-'
if [ "$exit_status" -gt 128 ]; then
    termination_reason=signal
    signal_number=$((exit_status - 128))
elif [ "$exit_status" -eq 0 ]; then
    termination_reason=completed
else
    case $report_state in
    report_missing) termination_reason=report_missing ;;
    report_unreadable) termination_reason=report_unreadable ;;
    report_carries_no_error) termination_reason=crash ;;
    TimeoutError) termination_reason=timeout ;;
    *) termination_reason=protocol_error ;;
    esac
fi

printf 'termination_reason=%s\n' "$termination_reason"
printf 'exit_status=%s\n' "$exit_status"
printf 'signal=%s\n' "$signal_number"
printf 'elapsed_ms=%s\n' "$elapsed_ms"
printf 'configured_deadline_s=%s\n' "${configured_deadline:--}"
printf 'last_completed_phase=%s\n' "${last_completed_phase:--}"
printf 'pending_phase=%s\n' "${pending_phase:--}"
printf 'report_bytes=%s\n' "$report_bytes"
printf 'stderr_bytes=%s\n' "$stderr_bytes"
printf 'error=%s: %s\n' "$report_state" "${report_error:--}"
stderr_tail=$(tail -3 "$stderr_file" 2>/dev/null | tr '\n\t' '; ' || true)
printf 'stderr_tail=%s\n' "${stderr_tail:--}"
