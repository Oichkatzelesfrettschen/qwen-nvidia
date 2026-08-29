#!/usr/bin/env python3
"""Serve llama-server's two tool routes over one MCP child, for a test.

The appliance's executor is llama-server: `GET /tools` renders each wrapped MCP
tool as `{tool, definition}` and `POST /tools` invokes the named tool with the
`params` object taken verbatim from the request body. Building that binary
needs the appliance, so this fixture speaks the same two routes over a
`server.py` child on stdio and reproduces the one response shape the front end
reads from: `mcp_result_to_response` turns an MCP `isError` result into an
`error` key at HTTP 200 and a successful result into `plain_text_response`, so
a refused grant arrives with a 200 status and a browser that reads the status
first would call it a success.

The MCP server name is `web`, which is what composes `search_exa` into
`web_search_exa` the way `--mcp-servers-config` composes it on the appliance.

usage: fake-llama-tools-server.py PORT MCP_SERVER_PATH
"""

import http.server
import json
import os
import subprocess
import sys

SERVER_LABEL = "web"
PROTOCOL_VERSION = "2024-11-05"
REQUEST_BODY_BYTE_CAP = 65536


class McpChild:
    """One `server.py` process and the JSON-RPC line protocol over its pipes."""

    def __init__(self, server_path):
        self.process = subprocess.Popen(
            [sys.executable, server_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.next_id = 0
        self.call(
            "initialize", {"protocolVersion": PROTOCOL_VERSION}
        )

    def call(self, method, params):
        self.next_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": self.next_id,
            "method": method,
            "params": params,
        }
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("the MCP child closed its output")
        return json.loads(line)

    def close(self):
        try:
            self.process.stdin.close()
        finally:
            self.process.wait(timeout=10)


def mcp_result_to_response(result):
    """Return the body llama-server sends for one MCP result.

    Every text part joins into one string, and `isError` decides which key
    carries it. The status stays 200 in both cases, which is the property the
    front end's body-before-status reading exists for.
    """
    text_parts = []
    for part in result.get("content", []):
        if isinstance(part, dict) and part.get("type") == "text":
            text_parts.append(part.get("text", ""))
    text = "\n".join(text_parts)
    if result.get("isError", False):
        return {"error": text or "MCP tool returned an error"}
    return {"plain_text_response": text}


class ToolsHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        """Drop the access log so the test's output carries its own lines."""

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/tools":
            self.send_json(404, {"error": "no such endpoint"})
            return
        listed = self.server.mcp_child.call("tools/list", {})
        rendered = []
        for definition in listed["result"]["tools"]:
            name = f"{SERVER_LABEL}_{definition['name']}"
            rendered.append(
                {
                    "display_name": name,
                    "tool": name,
                    "type": "mcp",
                    "permissions": {"write": False},
                    "uses_cwd": False,
                    "definition": {
                        "type": "function",
                        "function": {
                            "name": name,
                            "description": definition.get("description", ""),
                            "parameters": definition.get("inputSchema", {}),
                        },
                    },
                }
            )
        self.send_json(200, rendered)

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/tools":
            self.send_json(404, {"error": "no such endpoint"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length > REQUEST_BODY_BYTE_CAP:
            self.send_json(413, {"error": "the request body exceeds the cap"})
            return
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            tool_name = body["tool"]
            params = body.get("params", {})
        except (ValueError, KeyError, TypeError):
            self.send_json(400, {"error": "the request body names no tool"})
            return
        prefix = f"{SERVER_LABEL}_"
        if not tool_name.startswith(prefix):
            self.send_json(404, {"error": f"unknown tool: {tool_name}"})
            return
        answer = self.server.mcp_child.call(
            "tools/call",
            {"name": tool_name[len(prefix):], "arguments": params},
        )
        if "result" not in answer:
            self.send_json(500, {"error": "the MCP child returned no result"})
            return
        self.send_json(200, mcp_result_to_response(answer["result"]))


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: fake-llama-tools-server.py PORT MCP_SERVER_PATH\n")
        return 2
    service = http.server.HTTPServer(("127.0.0.1", int(argv[0])), ToolsHandler)
    service.mcp_child = McpChild(argv[1])
    sys.stdout.write(f"listening 127.0.0.1 {service.server_address[1]}\n")
    sys.stdout.flush()
    try:
        service.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        service.server_close()
        service.mcp_child.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
