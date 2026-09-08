#!/usr/bin/env python3
"""Stand in for one router child without loading a model or device backend."""

import http.server
import json
import os
import sys
import threading
import time


def argument(name: str) -> str:
    index = sys.argv.index(name)
    return sys.argv[index + 1]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        event("request_start")
        size = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(size)) if size else {}
        delay = float(self.headers.get("X-Fixture-Delay", "0"))
        if delay:
            time.sleep(delay)
        attribution = body.get("attribution")
        payload = json.dumps({
            "model": MODEL,
            "approval": self.headers.get("X-Approval-Id", ""),
            "artifact": self.headers.get("X-Artifact-Id", ""),
            "tool_result": self.headers.get("X-Tool-Result-Id", ""),
            "attribution": attribution,
            "messages": body.get("messages", []),
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        event("request_terminal")

    do_GET = do_POST

    def log_message(self, _format, *_args):
        return


PORT = int(argument("--port"))
MODEL = argument("--alias")
SERVER = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
EVENTS = os.environ.get("QWEN_FAKE_CHILD_EVENTS", "")


def event(name):
    if EVENTS:
        with open(EVENTS, "a", encoding="utf-8") as stream:
            stream.write("%d\t%s\t%s\n" % (time.monotonic_ns(), MODEL, name))


def watch_stdin():
    for line in sys.stdin:
        if line.strip() == "cmd_router_to_child:exit":
            SERVER.shutdown()
            return


threading.Thread(target=watch_stdin, daemon=True).start()
event("generation_ready")
print('cmd_child_to_router:state:{"state":"ready","payload":{"model":"%s"}}' % MODEL, flush=True)
SERVER.serve_forever()
event("generation_exit")
proof = os.environ.get("QWEN_FAKE_TEARDOWN_PROOF", "yes")
if proof != "absent":
    print("workload lease teardown: held=%s" % proof, flush=True)
