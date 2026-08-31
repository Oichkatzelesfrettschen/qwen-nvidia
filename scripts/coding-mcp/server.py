#!/usr/bin/env python3
"""Expose the bounded coding operations as MCP tools over stdio.

llama-server spawns this child for a section whose MCP configuration names
it, one JSON-RPC request per line, the way it drives `web-mcp/server.py`
and `image-mcp/server.py`. The six tools are the whole browser-facing
surface: `code_plan` opens a job under the single-use grant a human
approved and returns the agent's plan, `code_inspect`, `code_apply_patch`,
`code_run_tests`, `code_review_diff`, and `code_finish` operate on that
job by id, and the generic shell the agent runtime uses stays inside the
coding-agent service's contained worktree. Every refusal reaches the model
as an `isError` result at JSON-RPC success, so the router's
`mcp_result_to_response` maps it onto an `error` key at HTTP 200.

The listing states the configured coding profile's own bounds -- maximum
files changed, patch bytes, and job seconds -- read from
`scripts/coding-profiles.tsv` at every list, so the model proposes inside
what the grant is signed over and the service enforces.
"""

import json
import os
import socket
import sys

SERVER_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
SCRIPTS_DIRECTORY = os.path.dirname(SERVER_DIRECTORY)
WEB_MCP_DIRECTORY = os.path.join(SCRIPTS_DIRECTORY, "web-mcp")
for candidate in (SERVER_DIRECTORY, WEB_MCP_DIRECTORY, SCRIPTS_DIRECTORY):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

import server as web_server  # noqa: E402

SERVER_NAME = "code"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = web_server.PROTOCOL_VERSION
SUPPORTED_PROTOCOL_VERSIONS = web_server.SUPPORTED_PROTOCOL_VERSIONS

SERVICE_TIMEOUT_SECONDS = 900.0


class ServiceUnavailable(web_server.ToolError):
    status = "service_unavailable"


class ServiceRefused(web_server.ToolError):
    status = "service_refused"


def settings_from_environment():
    return {
        "socket_path": os.environ.get("QWEN_CODING_SERVICE_SOCKET", ""),
        "profile": os.environ.get("QWEN_CODING_PROFILE", ""),
        "profiles_tsv": os.environ.get(
            "QWEN_CODING_PROFILES_TSV",
            os.path.join(SCRIPTS_DIRECTORY, "coding-profiles.tsv")),
    }


def profile_bounds(settings):
    if not settings["profile"]:
        raise web_server.InvalidArgument(
            "QWEN_CODING_PROFILE is unconfigured, so the tool states no "
            "bounds")
    header = None
    try:
        with open(settings["profiles_tsv"], encoding="utf-8") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    candidate = line.lstrip("#").strip()
                    if "\t" in candidate and candidate.split(
                            "\t")[0].isidentifier():
                        header = [c.strip() for c in candidate.split("\t")]
                    continue
                parts = [c.strip() for c in line.split("\t")]
                if header and len(parts) == len(header):
                    row = dict(zip(header, parts))
                    if row.get("profile_id") == settings["profile"]:
                        return row
    except OSError as error:
        raise web_server.InvalidArgument(
            "the coding profile ledger is unreadable: %s"
            % type(error).__name__) from None
    raise web_server.InvalidArgument(
        "coding profile %s is absent from the ledger"
        % settings["profile"])


def tool_definitions(bounds):
    job_argument = {
        "job_id": {"type": "string",
                   "description": "the job the open grant created"},
    }
    return [
        {
            "name": "code_plan",
            "description": (
                "Open one approved coding job on profile %s (at most %s "
                "changed files, %s patch bytes, %s seconds) and return the "
                "agent's plan for the approved instruction."
                % (bounds["profile_id"], bounds["maximum_files_changed"],
                   bounds["maximum_patch_bytes"],
                   bounds["maximum_job_seconds"])),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "instruction": {"type": "string"},
                    "workspace_id": {"type": "string"},
                    "profile_id": {"type": "string",
                                   "enum": [bounds["profile_id"]]},
                    "model_id": {"type": "string",
                                 "enum": [bounds["model_id"]]},
                    "base_commit": {"type": "string"},
                    "authorization": {"type": "object"},
                },
                "required": ["instruction", "workspace_id", "profile_id",
                             "model_id", "base_commit", "authorization"],
                "additionalProperties": False,
            },
        },
        {
            "name": "code_inspect",
            "description": "List a directory or read a file inside the "
                           "job worktree.",
            "inputSchema": {
                "type": "object",
                "properties": dict(job_argument,
                                   path={"type": "string"}),
                "required": ["job_id", "path"],
                "additionalProperties": False,
            },
        },
        {
            "name": "code_apply_patch",
            "description": "Run the agent on the approved instruction and "
                           "report the bounded diff.",
            "inputSchema": {"type": "object", "properties": job_argument,
                            "required": ["job_id"],
                            "additionalProperties": False},
        },
        {
            "name": "code_run_tests",
            "description": "Run the profile's allowed test command inside "
                           "the worktree.",
            "inputSchema": {"type": "object", "properties": job_argument,
                            "required": ["job_id"],
                            "additionalProperties": False},
        },
        {
            "name": "code_review_diff",
            "description": "Return the job's current patch, diffstat, and "
                           "changed files.",
            "inputSchema": {"type": "object", "properties": job_argument,
                            "required": ["job_id"],
                            "additionalProperties": False},
        },
        {
            "name": "code_finish",
            "description": "Export the patch, test log, and event stream, "
                           "then remove the worktree.",
            "inputSchema": {"type": "object", "properties": job_argument,
                            "required": ["job_id"],
                            "additionalProperties": False},
        },
    ]


def service_request(settings, payload):
    if not settings["socket_path"]:
        raise ServiceUnavailable(
            "QWEN_CODING_SERVICE_SOCKET is unconfigured")
    try:
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(SERVICE_TIMEOUT_SECONDS)
        connection.connect(settings["socket_path"])
        connection.sendall((json.dumps(payload) + "\n").encode())
        reply_line = connection.makefile().readline()
        connection.close()
    except OSError as error:
        raise ServiceUnavailable(
            "the coding-agent service is unreachable: %s"
            % type(error).__name__) from None
    try:
        reply = json.loads(reply_line)
    except ValueError:
        raise ServiceRefused("the service answered outside the protocol") \
            from None
    if not reply.get("ok"):
        raise ServiceRefused("the service refused: %s %s"
                             % (reply.get("error"), reply.get("detail")))
    return reply["result"]


def call_plan(settings, arguments):
    open_request = {
        "action": "open_job",
        "workspace_id": arguments["workspace_id"],
        "profile_id": arguments["profile_id"],
        "model_id": arguments["model_id"],
        "base_commit": arguments["base_commit"],
        "instruction": arguments["instruction"],
        "grant": arguments["authorization"],
    }
    opened = service_request(settings, open_request)
    planned = service_request(settings, {"action": "plan",
                                         "job_id": opened["job_id"]})
    return json.dumps({"job_id": opened["job_id"],
                       "base_commit": opened["base_commit"],
                       "plan": planned["plan"]}, sort_keys=True)


def job_action(action, result_keys):
    def call(settings, arguments):
        payload = dict(arguments)
        payload["action"] = action
        result = service_request(settings, payload)
        return json.dumps({key: result.get(key) for key in result_keys},
                          sort_keys=True)
    return call


TOOL_HANDLERS = {
    "code_plan": call_plan,
    "code_inspect": job_action("inspect",
                               ["kind", "entries", "content", "bytes"]),
    "code_apply_patch": job_action("apply_patch",
                                   ["returncode", "diffstat",
                                    "changed_files"]),
    "code_run_tests": job_action("run_tests", ["returncode", "log"]),
    "code_review_diff": job_action("review_diff",
                                   ["patch", "diffstat", "changed_files"]),
    "code_finish": job_action("finish", ["export", "result_tree"]),
}


def handle_request(settings, message):
    method = message["method"]
    identifier = message.get("id")
    if "id" not in message:
        return None
    params = message.get("params") or {}
    if method == "initialize":
        requested = params.get("protocolVersion")
        version = (requested if requested in SUPPORTED_PROTOCOL_VERSIONS
                   else PROTOCOL_VERSION)
        return {"jsonrpc": "2.0", "id": identifier, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME,
                           "version": SERVER_VERSION}}}
    if method == "ping":
        return {"jsonrpc": "2.0", "id": identifier, "result": {}}
    if method == "tools/list":
        try:
            bounds = profile_bounds(settings)
        except web_server.ToolError as error:
            return web_server.jsonrpc_error(identifier, -32603, str(error))
        return {"jsonrpc": "2.0", "id": identifier,
                "result": {"tools": tool_definitions(bounds)}}
    if method == "tools/call":
        handler = TOOL_HANDLERS.get(params.get("name"))
        if handler is None:
            return web_server.jsonrpc_error(
                identifier, -32602, "unknown tool: %s" % params.get("name"))
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict):
            return web_server.jsonrpc_error(
                identifier, -32602, "arguments must be a JSON object")
        schema = next(t for t in tool_definitions(
            {"profile_id": settings["profile"] or "-", "model_id": "-",
             "maximum_files_changed": "-", "maximum_patch_bytes": "-",
             "maximum_job_seconds": "-"})
            if t["name"] == params["name"])["inputSchema"]
        unknown = sorted(name for name in arguments
                         if name not in schema["properties"])
        if unknown:
            return web_server.tool_result(
                identifier,
                "the call carries an argument the tool does not read: "
                + ", ".join(unknown), True)
        missing = sorted(name for name in schema["required"]
                         if name not in arguments)
        if missing:
            return web_server.tool_result(
                identifier, "the call omits required arguments: "
                + ", ".join(missing), True)
        try:
            text = handler(settings, arguments)
        except web_server.ToolError as error:
            return web_server.tool_result(identifier, str(error), True)
        except Exception as error:  # noqa: BLE001
            sys.stderr.write(web_server.sanitized_traceback(error) + "\n")
            sys.stderr.flush()
            return web_server.jsonrpc_error(
                identifier, -32603, "internal error during tool execution")
        return web_server.tool_result(identifier, text, False)
    return web_server.jsonrpc_error(identifier, -32601,
                                    "unknown method: %s" % method)


def main(argv):
    settings = settings_from_environment()
    while True:
        line = web_server.read_request_line(sys.stdin)
        if line is None:
            break
        if line is web_server.OVERSIZED_LINE:
            response = web_server.jsonrpc_error(
                None, -32600,
                "the request exceeds the %d character line cap"
                % web_server.REQUEST_LINE_CHARACTER_CAP)
        else:
            line = line.strip()
            if not line:
                continue
            try:
                message = web_server.strict_json_loads(line)
            except (ValueError, RecursionError):
                response = web_server.jsonrpc_error(None, -32700,
                                                    "parse error")
            else:
                response = web_server.validate_message(message)
                if isinstance(message, dict) and "id" not in message:
                    response = None
                elif response is None:
                    response = handle_request(settings, message)
        if response is not None:
            sys.stdout.write(json.dumps(response, allow_nan=False) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
