#!/usr/bin/env python3
"""Serve telemetry-shaped health and model endpoints without CUDA."""

import argparse
import http.server
import json
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if time.monotonic() < self.server.ready_at:
            self.send_error(503)
            return
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
parser.add_argument("--health-delay", type=float, default=0.0)
settings = parser.parse_args()
server = http.server.ThreadingHTTPServer(("127.0.0.1", settings.port), Handler)
server.model_id = settings.model_id
server.ready_at = time.monotonic() + settings.health_delay
server.serve_forever()
