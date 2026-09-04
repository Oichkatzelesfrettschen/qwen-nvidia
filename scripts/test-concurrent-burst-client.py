#!/usr/bin/env python3
"""Hold concurrent-burst-client.py to a fake /completion route.

The fake server answers the shape the client validates -- `timings`,
`tokens`, and the request's own `id_slot` -- and misbehaves on command: one
slot short a token, one slot answering an `error` key, one slot reporting
the wrong `prompt_n`. The assertions are that a clean burst is accepted with
every reply and one window, that priming reaches every slot once ahead of the
burst under `primed`, that the barrier releases every request inside one
short interval, and that each defect fails the burst by name.
"""

import http.server
import json
import pathlib
import subprocess
import sys
import tempfile
import threading
import time

CLIENT = pathlib.Path(__file__).resolve().parent / "concurrent-burst-client.py"


class State:
    defect = None
    requests = []
    lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with State.lock:
            State.requests.append((time.time(), body))
        slot = body["id_slot"]
        predict = body["n_predict"]
        prompt_n = 1 if body.get("cache_prompt") else len(body["prompt"])
        tokens = [100 + slot] * predict
        reply = {"tokens": tokens, "timings": {
            "prompt_n": prompt_n, "predicted_n": predict,
            "prompt_ms": 1.0, "predicted_ms": 10.0 * predict}}
        if State.defect == "short" and slot == 1 and predict > 1:
            reply["tokens"] = tokens[:-1]
        if State.defect == "error" and slot == 2 and predict > 1:
            reply = {"error": {"code": 500, "message": "fixture"}}
        if State.defect == "prompt" and slot == 0 and predict > 1:
            reply["timings"]["prompt_n"] = 7
        payload = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def run_client(port, directory, admission, predict=4, level=3):
    prompt = pathlib.Path(directory) / "prompt.json"
    prompt.write_text(json.dumps([1, 2, 3, 4, 5]))
    output = pathlib.Path(directory) / ("burst-" + admission + "-" + str(State.defect))
    return subprocess.run(
        [sys.executable, str(CLIENT), "--port", str(port), "--level", str(level),
         "--predict", str(predict), "--prompt-tokens", str(prompt),
         "--output", str(output), "--admission", admission],
        capture_output=True, text=True), output


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    failures = []

    def check(condition, description):
        print(("ok " if condition else "FAIL ") + description)
        if not condition:
            failures.append(description)

    with tempfile.TemporaryDirectory() as directory:
        State.defect = None
        State.requests = []
        result, output = run_client(port, directory, "primed")
        check(result.returncode == 0, "a clean primed burst is accepted")
        primes = [body for _t, body in State.requests if body["n_predict"] == 1]
        check([body["id_slot"] for body in primes] == [0, 1, 2],
              "priming reaches each slot once, in order, ahead of the burst")
        burst = [(t, body) for t, body in State.requests if body["n_predict"] == 4]
        check(len(burst) == 3 and all(body["cache_prompt"] for _t, body in burst),
              "the primed burst reuses every slot's cache")
        spread = max(t for t, _b in burst) - min(t for t, _b in burst)
        check(spread < 0.2, "the barrier releases the burst inside 200 ms (spread %.4f s)" % spread)
        check((output / "window.txt").exists() and
              all((output / ("request-%d.json" % slot)).exists() for slot in range(3)),
              "one window and every reply are retained")
        check("burst=accepted" in (output / "validation.txt").read_text(),
              "the validation record states acceptance")

        State.defect = None
        State.requests = []
        result, _output = run_client(port, directory, "cold")
        check(result.returncode == 0, "a clean cold burst is accepted")
        check(all(body["cache_prompt"] is False for _t, body in State.requests),
              "a cold burst sends no cached prompt")
        check(not any(body["n_predict"] == 1 for _t, body in State.requests),
              "a cold burst primes nothing")

        for defect, phrase in (("short", "tokens holds 3 ids"),
                               ("error", "server error"),
                               ("prompt", "prompt_n 7 where the uncached prompt holds 5")):
            State.defect = defect
            State.requests = []
            result, output = run_client(port, directory, "cold")
            check(result.returncode != 0 and phrase in result.stderr,
                  "defect %s fails the burst naming it" % defect)
            check("burst=rejected" in (output / "validation.txt").read_text(),
                  "defect %s is recorded as a rejection" % defect)
    server.shutdown()
    if failures:
        print("concurrent_burst_client=rejected failures=%d" % len(failures), file=sys.stderr)
        sys.exit(1)
    print("concurrent_burst_client=accepted")


if __name__ == "__main__":
    main()
