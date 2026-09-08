#!/usr/bin/env python3
"""Serve telemetry-shaped health and model endpoints without CUDA."""

import argparse
import http.server
import json


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            payload = {"status": "ok"}
        elif self.path == "/v1/models":
            payload = {"data": [{"id": self.server.model_id}]}
        else:
            self.send_error(404)
            return
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_arguments):
        return


parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--model-id", required=True)
parser.add_argument("--config", required=True)
parser.add_argument("--boundary", required=True)
settings = parser.parse_args()
server = http.server.ThreadingHTTPServer(("127.0.0.1", settings.port), Handler)
server.model_id = settings.model_id
server.serve_forever()
