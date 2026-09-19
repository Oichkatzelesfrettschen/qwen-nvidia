#!/usr/bin/env python3
"""Serve /health and /v1/chat/completions the way llama-server answers a
forced tool call with and without --jinja, for a test.

usage: fake-chat-tools-server.py PORT API_KEY jinja|prose
"""

import http.server
import json
import sys

REQUEST_BODY_BYTE_CAP = 65536


class Handler(http.server.BaseHTTPRequestHandler):
    api_key = ""
    mode = "prose"

    def log_message(self, *_args):
        return

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
            return
        self._send(404, {"error": "no route"})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self._send(404, {"error": "no route"})
            return
        if self.headers.get("Authorization") != "Bearer " + self.api_key:
            self._send(401, {"error": "invalid api key"})
            return
        length = min(int(self.headers.get("Content-Length", "0")), REQUEST_BODY_BYTE_CAP)
        request = json.loads(self.rfile.read(length) or b"{}")
        if self.mode == "jinja" and request.get("tools"):
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "call_0",
                        "type": "function",
                        "function": {"name": "record_probe", "arguments": "{\"ok\":true}"},
                    }
                ],
            }
        else:
            message = {"role": "assistant", "content": "The probe is ok."}
        self._send(200, {"choices": [{"index": 0, "finish_reason": "stop", "message": message}]})


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in ("jinja", "prose"):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(2)
    Handler.api_key = sys.argv[2]
    Handler.mode = sys.argv[3]
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()


if __name__ == "__main__":
    main()
