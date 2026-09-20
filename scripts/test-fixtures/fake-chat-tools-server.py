#!/usr/bin/env python3
"""Serve /health and /v1/chat/completions the way llama-server answers a
forced tool call with and without --jinja, plus the answer shapes a consumer
must refuse: a call to another function, no call at all, arguments that do
not parse, ok recorded as false, a reply cut at the token cap, an HTTP
error, and prose that quotes the field name.

usage: fake-chat-tools-server.py PORT API_KEY MODE
MODE: jinja | prose | wrong_function | empty_calls | bad_arguments |
      ok_false | truncated | http_error | quoted_field
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
        if self.mode == "http_error":
            self._send(500, {"error": {"message": "slot unavailable", "tool_calls": []}})
            return
        # tools/server/server-common.cpp reads tool_choice through
        # json_value(body, "tool_choice", std::string("auto")), which catches
        # the type error an object raises and returns "auto". A caller sending
        # the OpenAI named-function object therefore forces nothing, and the
        # model answers or does not on its own. The fixture models that, so a
        # probe that regresses to the object form fails here rather than in a
        # campaign that reads voluntary calls as forced ones.
        forced = isinstance(request.get("tool_choice"), str) and \
            request.get("tool_choice") in ("required", "any")
        finish = "stop"
        if self.mode == "jinja" and request.get("tools") and forced:
            message = call("record_probe", "{\"ok\":true}")
        elif self.mode == "wrong_function":
            message = call("record_graph", "{\"ok\":true}")
        elif self.mode == "empty_calls":
            message = {"role": "assistant", "content": None, "tool_calls": []}
        elif self.mode == "bad_arguments":
            message = call("record_probe", "{\"ok\":")
        elif self.mode == "ok_false":
            message = call("record_probe", "{\"ok\":false}")
        elif self.mode == "truncated":
            message = call("record_probe", "{\"ok\":true}")
            finish = "length"
        elif self.mode == "quoted_field":
            message = {"role": "assistant", "content": "I would put \"tool_calls\" here."}
        else:
            message = {"role": "assistant", "content": "The probe is ok."}
        self._send(200, {"choices": [{"index": 0, "finish_reason": finish, "message": message}]})


def call(name, arguments):
    return {
        "role": "assistant",
        "content": None,
        "tool_calls": [{"id": "call_0", "type": "function",
                        "function": {"name": name, "arguments": arguments}}],
    }


MODES = ("jinja", "prose", "wrong_function", "empty_calls", "bad_arguments",
         "ok_false", "truncated", "http_error", "quoted_field")


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in MODES:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(2)
    Handler.api_key = sys.argv[2]
    Handler.mode = sys.argv[3]
    http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()


if __name__ == "__main__":
    main()
