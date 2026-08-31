#!/bin/sh
set -eu

# Exercise scripts/run-quality-roster.sh against a fixture listener. The driver's
# own contribution over the suite runner is a set of refusals -- an endpoint that
# does not hold a registry row, and a response whose model id disagrees with the
# arm that asked for it -- and a refusal that never fires is a refusal that is
# not there.

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
driver=$script_directory/run-quality-roster.sh
work_directory=$(mktemp -d)
server_pid=

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$work_directory"
}
trap cleanup EXIT INT TERM

failures=0
report() {
    if [ "$1" = pass ]; then
        printf 'check=%s outcome=pass\n' "$2"
    else
        printf 'check=%s outcome=fail %s\n' "$2" "${3:-}" >&2
        failures=$((failures + 1))
    fi
}

cat > "$work_directory/fixture-server.py" <<'PYTHON'
"""Answer the two endpoints the driver reads, with a selectable disagreement.

QWEN_FIXTURE_SERVED_MODEL replaces the id in the response body while leaving the
routing itself alone, which is the shape the driver's assertion exists to catch:
a listener that answers from a preset other than the one named.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL_IDS = os.environ.get("QWEN_FIXTURE_MODELS", "alpha,beta").split(",")
FORCED_SERVED = os.environ.get("QWEN_FIXTURE_SERVED_MODEL", "")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def _send(self, document):
        payload = json.dumps(document).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path != "/v1/models":
            self.send_error(404)
            return
        self._send({"data": [{"id": name} for name in MODEL_IDS]})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        requested = request.get("model", "")
        if requested not in MODEL_IDS:
            self.send_error(400, f"model '{requested}' not found")
            return
        self._send({
            "model": FORCED_SERVED or requested,
            "choices": [{
                "finish_reason": "stop",
                "message": {"content": "408", "reasoning_content": ""},
            }],
            "timings": {"predicted_n": 3, "prompt_n": 11,
                        "predicted_per_second": 9.0},
        })


server = HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.serve_forever()
PYTHON

# The fixture suite carries the loader's own column order. Its first revision
# put the prompt third, so both rows reached grade() with the prompt text as
# their grader kind and scored `unknown grader` while the driver's row counts
# still passed.
cat > "$work_directory/suite.tsv" <<'TSV'
# id	category	grader	expectation	prompt	attachment
mul-1	arithmetic	numeric	408	What is 17 x 24?	-
mul-2	arithmetic	nonempty		What is 12 x 34?	-
TSV

cat > "$work_directory/registry.tsv" <<'TSV'
alpha	text	models/alpha.gguf	fetch-alpha.sh	8192	8192	32768	q8_0	q4_0	on	none	-	9.0	60.0	-	production	128	32	-	-	unmeasured	refused	0	off	-
beta	text	models/beta.gguf	fetch-beta.sh	8192	8192	32768	q8_0	q4_0	on	none	-	9.0	60.0	-	candidate	128	32	-	-	unmeasured	refused	0	off	-
gamma	text	models/gamma.gguf	fetch-gamma.sh	8192	8192	32768	q8_0	q4_0	on	none	-	9.0	60.0	-	quarantine	128	32	-	-	unmeasured	refused	0	off	-
TSV

port=$(python3 -c '
import socket

probe = socket.socket()
probe.bind(("127.0.0.1", 0))
print(probe.getsockname()[1])
probe.close()
')

start_fixture() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=
    fi
    python3 "$work_directory/fixture-server.py" "$port" &
    server_pid=$!
    waited=0
    while [ "$waited" -lt 50 ]; do
        if curl -s --max-time 2 "http://127.0.0.1:$port/v1/models" >/dev/null 2>&1; then
            return 0
        fi
        waited=$((waited + 1))
        sleep 0.1
    done
    printf 'the fixture listener never answered on port %s\n' "$port" >&2
    exit 1
}

run_driver() {
    QWEN_MODEL_REGISTRY=$work_directory/registry.tsv \
    QWEN_SERVER_PORT=$port \
    QWEN_QUALITY_CATEGORIES=arithmetic \
    QWEN_QUALITY_MAX_TOKENS=64 \
    QWEN_QUALITY_SUITE=$work_directory/suite.tsv \
        "$driver" "$1" 2>&1
}

start_fixture

# Grading two admitted rows writes one record and one summary line each, and
# leaves the quarantined row ungraded.
output_one=$work_directory/run-one
if run_driver "$output_one" >"$work_directory/one.log" 2>&1; then
    if [ -f "$output_one/alpha.json" ] && [ -f "$output_one/beta.json" ] &&
        [ ! -f "$output_one/gamma.json" ]; then
        report pass roster_covers_open_tiers
    else
        report fail roster_covers_open_tiers "per-model records are wrong"
    fi
    if [ "$(awk 'NR > 1' "$output_one/summary.tsv" | wc -l | tr -d ' ')" = 2 ]; then
        report pass summary_row_per_arm
    else
        report fail summary_row_per_arm "summary.tsv row count is wrong"
    fi
    if grep -q '"served_models"' "$output_one/alpha.json"; then
        report pass served_model_recorded
    else
        report fail served_model_recorded "the record omits the served id"
    fi
else
    report fail roster_covers_open_tiers "$(tail -3 "$work_directory/one.log")"
    report fail summary_row_per_arm skipped
    report fail served_model_recorded skipped
fi

# A listener answering from another preset than the one named fails the arm.
export QWEN_FIXTURE_SERVED_MODEL=beta
start_fixture
if run_driver "$work_directory/run-two" >"$work_directory/two.log" 2>&1; then
    report fail served_model_disagreement "the driver accepted a foreign served id"
else
    if grep -q 'served id disagrees' "$work_directory/two.log"; then
        report pass served_model_disagreement
    else
        report fail served_model_disagreement "the refusal named another reason"
    fi
fi
unset QWEN_FIXTURE_SERVED_MODEL

# A registry row the listener does not hold stops the run before any arm.
export QWEN_FIXTURE_MODELS=alpha
start_fixture
if run_driver "$work_directory/run-three" >"$work_directory/three.log" 2>&1; then
    report fail absent_row_refused "the driver graded an incomplete listener"
else
    if grep -q 'the listener does not hold registry row beta' \
        "$work_directory/three.log"; then
        report pass absent_row_refused
    else
        report fail absent_row_refused "the refusal named another reason"
    fi
fi
unset QWEN_FIXTURE_MODELS
start_fixture

# Argument errors exit 2 rather than running an arm.
set +e
QWEN_MODEL_REGISTRY=$work_directory/registry.tsv QWEN_SERVER_PORT=$port \
    QWEN_QUALITY_THINKING=maybe "$driver" "$work_directory/run-four" \
    >"$work_directory/four.log" 2>&1
thinking_status=$?
QWEN_MODEL_REGISTRY=$work_directory/registry.tsv QWEN_SERVER_PORT=$port \
    QWEN_QUALITY_MAX_TOKENS=0 "$driver" "$work_directory/run-five" \
    >"$work_directory/five.log" 2>&1
budget_status=$?
"$driver" one two >"$work_directory/six.log" 2>&1
argument_status=$?
set -e
if [ "$thinking_status" = 2 ] && [ "$budget_status" = 2 ] &&
    [ "$argument_status" = 2 ]; then
    report pass argument_errors_exit_two
else
    report fail argument_errors_exit_two \
        "statuses $thinking_status $budget_status $argument_status"
fi

if [ "$failures" -eq 0 ]; then
    printf 'quality_roster_driver=accepted checks=6\n'
    exit 0
fi
printf 'quality_roster_driver=refused failures=%s\n' "$failures" >&2
exit 1
