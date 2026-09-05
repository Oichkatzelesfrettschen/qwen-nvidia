#!/usr/bin/env python3
"""One MCP child for the two device sidecars: a PhysX simulation or an OptiX query.

`QWEN_SIDECAR_SERVICE` names the lane, `physics` or `geometry`, and the child
serves that lane's one tool: `simulate_rigid` over `profile_id` and `steps`,
or `ray_query` over `profile_id` and `rays`, each with the single-use
`authorization` a human approval issued. The order of a call is the boundary:
the arguments are validated against the ledger row, the grant is verified
against the signing key and enforced field by field, the service socket is
opened, the single use is spent under the SQLite ledger's primary key, and
only then does the job line reach the service, which revalidates the same
token ahead of the compute lease. Spending after the connect keeps an absent
service from consuming an approval; spending before the send keeps one
approval from reaching a runtime twice.

The reply the model reads is a summary of what the service proved: the
status, the GPU proof block, the runtime and scene digests, the step or ray
count, the timings, and one lane-specific figure (the chain's joint count or
the device-to-reference agreement), and never the runtime's full state,
which the audit trail names by digest.
"""

import hashlib
import json
import os
import secrets
import socket
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SCRIPTS, "web-mcp"))
sys.path.insert(0, SCRIPTS)
import server as web_server  # noqa: E402
import sidecar_grant  # noqa: E402

LANES = {
    "physics": {
        "protocol": "physics_protocol",
        "tool": "simulate_rigid",
        "count_key": "steps",
        "ceiling_column": "max_steps",
        "scene_column": "scene",
        "columns": ("profile_id", "scene", "timestep_s", "max_steps", "gravity_y", "gpu_dynamics",
                    "gpu_broadphase", "timeout_s", "execution_policy", "device_index"),
        "description": "Simulate one bounded rigid-body scene on the GPU through PhysX and return the proof that it ran there.",
    },
    "geometry": {
        "protocol": "geometry_protocol",
        "tool": "ray_query",
        "count_key": "rays",
        "ceiling_column": "max_rays",
        "scene_column": "scene",
        "columns": ("profile_id", "scene", "query_set", "max_rays", "timeout_s", "execution_policy", "device_index"),
        "description": "Trace one bounded ray query against a fixture scene on the GPU through OptiX and return the proof that it ran there.",
    },
}
MCP_TIMEOUT_DEFAULT_SECONDS = 360.0
MCP_TIMEOUT_MAXIMUM_SECONDS = 3600.0
REQUEST_ID_BYTES = 12
TOOL_ARGUMENT_NAMES = ("profile_id", "count", "authorization")


class ServiceRefused(web_server.ToolError):
    status = "service_refused"


class ServiceUnavailable(web_server.ToolError):
    status = "service_unavailable"


def settings_from_environment():
    return {
        "service": os.environ.get("QWEN_SIDECAR_SERVICE", ""),
        "profile": os.environ.get("QWEN_SIDECAR_PROFILE", ""),
        "language_profile": os.environ.get("QWEN_SIDECAR_LANGUAGE_PROFILE", ""),
        "token_key_file": os.environ.get("QWEN_SIDECAR_TOKEN_KEY_FILE", ""),
        "state_dir": os.environ.get("QWEN_SIDECAR_STATE_DIR", ""),
        "socket_path": os.environ.get("QWEN_SIDECAR_SERVICE_SOCKET", ""),
        "profiles": os.environ.get("QWEN_SIDECAR_PROFILES", ""),
        "runtime_sha256": os.environ.get("QWEN_SIDECAR_RUNTIME_SHA256", ""),
        "timeout": os.environ.get("QWEN_SIDECAR_MCP_TIMEOUT_S", ""),
    }


def require_configuration(settings):
    if settings["service"] not in LANES:
        raise web_server.InvalidArgument("QWEN_SIDECAR_SERVICE names no lane, so the call reaches no runtime")
    for key, name in (("profile", "QWEN_SIDECAR_PROFILE"), ("language_profile", "QWEN_SIDECAR_LANGUAGE_PROFILE"),
                      ("token_key_file", "QWEN_SIDECAR_TOKEN_KEY_FILE"), ("state_dir", "QWEN_SIDECAR_STATE_DIR"),
                      ("socket_path", "QWEN_SIDECAR_SERVICE_SOCKET"), ("profiles", "QWEN_SIDECAR_PROFILES"),
                      ("runtime_sha256", "QWEN_SIDECAR_RUNTIME_SHA256")):
        if not settings.get(key):
            raise web_server.InvalidArgument(f"{name} is unconfigured, so the call reaches no runtime")
    if not sidecar_grant.DIGEST_PATTERN.match(settings["runtime_sha256"]):
        raise web_server.InvalidArgument("QWEN_SIDECAR_RUNTIME_SHA256 is no SHA-256")


def resolve_timeout(raw):
    if not raw:
        return MCP_TIMEOUT_DEFAULT_SECONDS
    try:
        seconds = float(raw)
    except ValueError:
        raise web_server.InvalidArgument("QWEN_SIDECAR_MCP_TIMEOUT_S is not a number") from None
    if not 0 < seconds <= MCP_TIMEOUT_MAXIMUM_SECONDS:
        raise web_server.InvalidArgument(
            f"QWEN_SIDECAR_MCP_TIMEOUT_S lies outside (0, {MCP_TIMEOUT_MAXIMUM_SECONDS:g}]: {seconds:g}")
    return seconds


def profile_row(settings):
    """Return the ledger row the child serves, read from the same TSV the service reads."""
    lane = LANES[settings["service"]]
    try:
        with open(settings["profiles"], encoding="utf-8") as handle:
            lines = [line.rstrip("\n") for line in handle if line.strip() and not line.startswith("#")]
    except OSError as error:
        raise web_server.InvalidArgument(f"the profile ledger is unreadable: {error.__class__.__name__}") from None
    for line in lines:
        fields = line.split("\t")
        if len(fields) != len(lane["columns"]):
            raise web_server.InvalidArgument("the profile ledger carries a row of the wrong width")
        row = dict(zip(lane["columns"], fields))
        if row["profile_id"] == settings["profile"]:
            try:
                ceiling = int(row[lane["ceiling_column"]])
            except ValueError:
                raise web_server.InvalidArgument("the profile ledger carries no integer ceiling") from None
            if ceiling < 1:
                raise web_server.InvalidArgument("the profile ledger carries a ceiling under one")
            if row["execution_policy"] != "validator-gated":
                raise web_server.InvalidArgument(
                    f"profile {settings['profile']} reads {row['execution_policy']}, so nothing runs")
            return row, ceiling
    raise web_server.InvalidArgument(f"profile {settings['profile']} is not in the ledger")


def tool_definitions(settings, row, ceiling):
    lane = LANES[settings["service"]]
    return [{
        "name": lane["tool"],
        "description": lane["description"] + " The call runs only under a grant the user approved for exactly these arguments.",
        "inputSchema": {
            "type": "object",
            "properties": {
                # The grant binds the runtime digest and the scene, and the page
                # that requests the grant reads both out of this listing; a
                # page that stated other values would meet the child's own
                # refusal, since the child enforces them against its
                # configuration and the ledger rather than against the call.
                "profile_id": {"type": "string", "enum": [settings["profile"]],
                               "description": f"The one {settings['service']} profile this section serves; scene {row[lane['scene_column']]}.",
                               "x_scene": row[lane["scene_column"]],
                               "x_runtime_sha256": settings["runtime_sha256"]},
                "count": {"type": "integer", "minimum": 1, "maximum": ceiling,
                          "description": f"The {lane['count_key']} to run, at most {ceiling} for this profile."},
                "authorization": {"type": "string", "maxLength": sidecar_grant.SIDECAR_GRANT_CHARACTER_CAP,
                                  "description": "The single-use grant the user's approval issued for this exact call."},
            },
            "required": list(TOOL_ARGUMENT_NAMES),
            "additionalProperties": False,
        },
    }]


def parse_arguments(raw, settings, ceiling):
    profile = raw.get("profile_id")
    if profile != settings["profile"]:
        raise web_server.InvalidArgument("the call names another profile than the one this section serves")
    count = raw.get("count")
    if not isinstance(count, int) or isinstance(count, bool) or not 1 <= count <= ceiling:
        raise web_server.InvalidArgument(f"count is no integer in [1, {ceiling}]")
    grant = raw.get("authorization")
    if not isinstance(grant, str) or not grant.strip():
        raise web_server.InvalidArgument("authorization names no grant")
    if len(grant) > sidecar_grant.SIDECAR_GRANT_CHARACTER_CAP:
        raise web_server.InvalidArgument("authorization exceeds the grant character cap")
    return {"profile_id": profile, "count": count, "authorization": grant.strip()}


def connect_service(settings, timeout):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    try:
        connection.connect(settings["socket_path"])
    except (OSError, socket.timeout) as error:
        connection.close()
        raise ServiceUnavailable(f"the {settings['service']} service socket is unreachable: {error.__class__.__name__}") from None
    return connection


def exchange(connection, protocol, payload, timeout):
    try:
        protocol.validate_request(payload)
    except protocol.ProtocolError as breach:
        raise web_server.InvalidArgument(f"the job leaves the {payload['action']} protocol: {breach}") from None
    line = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
    connection.settimeout(timeout)
    try:
        connection.sendall(line)
        stream = connection.makefile("rb")
        reply = stream.readline(protocol.MAX_LINE_BYTES + 1)
    except (OSError, socket.timeout) as error:
        raise ServiceUnavailable("the service answered no reply inside the deadline: " + error.__class__.__name__) from None
    if not reply:
        raise ServiceUnavailable("the service closed the connection without a reply")
    try:
        return protocol.parse_reply(reply.decode("utf-8", "replace"))
    except protocol.ProtocolError as breach:
        raise ServiceRefused(f"the service reply leaves the protocol: {breach}") from None


def clip(value):
    text = value if isinstance(value, str) else json.dumps(value)
    return "".join(ch for ch in text[:300] if ch.isprintable())


def summarize(settings, reply, request_id):
    if reply.get("request_id") != request_id:
        raise ServiceRefused("the service reply names another request")
    status = reply.get("status")
    if status != "completed":
        raise ServiceRefused(f"the {settings['service']} service {status} the run: " + clip(reply.get("error") or reply.get("reason") or "-"))
    result = reply.get("result") or {}
    summary = {
        "status": "completed",
        "service": settings["service"],
        "profile_id": reply.get("profile_id"),
        "gpu": result.get("gpu"),
        "runtime_sha256": result.get("runtime_sha256"),
        "scene_sha256": result.get("scene_sha256"),
        "result_sha256": hashlib.sha256(json.dumps(result, sort_keys=True).encode("utf-8")).hexdigest(),
    }
    lane = LANES[settings["service"]]
    summary[lane["count_key"]] = result.get(lane["count_key"])
    # the protocol's own figures, by their protocol names: the physics
    # timings, and the geometry counts including the device-to-reference
    # agreement the reply carries
    for key in ("wall_ms", "simulate_ms", "launch_ms", "hits", "misses", "reference_agreement", "reference_disagreement"):
        if key in result:
            summary[key] = result[key]
    if settings["service"] == "physics":
        summary["joints"] = len(result.get("joints") or [])
        summary["bodies"] = len(result.get("bodies") or [])
    return summary


def audit_row(settings, arguments, status, started_at, result_sha256=""):
    now = time.time()
    return {
        "recorded_at": web_server.utc_timestamp(now),
        "profile": settings["language_profile"],
        "operation": f"{settings['service']}-run",
        "query_sha256": result_sha256 or sidecar_grant.arguments_digest(settings["service"], arguments["profile_id"], arguments["count"]),
        "domains": f"{settings['language_profile']}>{settings['profile']}",
        "result_count": arguments["count"],
        "fetched_host": "",
        "provider_bytes": 0,
        "returned_characters": 0,
        "latency_ms": int((now - started_at) * 1000),
        "status": status,
        "recorded_epoch": int(now),
    }


def call_run(settings, raw):
    started_at = time.time()
    require_configuration(settings)
    lane = LANES[settings["service"]]
    protocol = __import__(lane["protocol"])
    row, ceiling = profile_row(settings)
    arguments = parse_arguments(raw, settings, ceiling)
    signing_key = web_server.read_secret_file(settings["token_key_file"], "token signing")
    claim = sidecar_grant.verify_sidecar_grant(signing_key, arguments["authorization"], started_at)
    sidecar_grant.enforce_sidecar_authorization(
        claim, settings["service"], settings["language_profile"], settings["profile"],
        settings["runtime_sha256"], row[lane["scene_column"]], arguments["count"])
    request_id = web_server.base64url_encode(secrets.token_bytes(REQUEST_ID_BYTES))
    ledger = web_server.Ledger(settings["state_dir"])
    connection = None
    result_sha256 = ""
    try:
        connection = connect_service(settings, settings["timeout_seconds"])
        ledger.consume_grant(claim["grant_id"], settings["profile"], settings["service"], claim["expiry"], started_at)
        payload = {
            "protocol": protocol.PROTOCOL_VERSION, "action": sidecar_grant.LANES[settings["service"]]["operation"],
            "request_id": request_id, "profile_id": arguments["profile_id"], lane["count_key"]: arguments["count"],
            "authorization": arguments["authorization"],
        }
        reply = exchange(connection, protocol, payload, settings["timeout_seconds"])
        summary = summarize(settings, reply, request_id)
        result_sha256 = summary["result_sha256"]
    except web_server.ToolError as error:
        ledger.record(audit_row(settings, arguments, error.status, started_at))
        raise
    else:
        ledger.record(audit_row(settings, arguments, "success", started_at, result_sha256))
    finally:
        if connection is not None:
            connection.close()
        ledger.close()
    return json.dumps(summary, sort_keys=True)


def handle_request(settings, message):
    identifier = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": identifier, "result": {
            "protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
            "serverInfo": {"name": f"qwen-{settings['service'] or 'sidecar'}", "version": "1"}}}
    if method == "tools/list":
        try:
            require_configuration(settings)
            row, ceiling = profile_row(settings)
        except web_server.ToolError as error:
            return web_server.jsonrpc_error(identifier, -32603, str(error))
        return {"jsonrpc": "2.0", "id": identifier, "result": {"tools": tool_definitions(settings, row, ceiling)}}
    if method == "tools/call":
        lane = LANES.get(settings["service"])
        if lane is None or params.get("name") != lane["tool"]:
            return web_server.jsonrpc_error(identifier, -32602, f"unknown tool: {params.get('name')}")
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            return web_server.jsonrpc_error(identifier, -32602, "arguments must be a JSON object")
        unknown = sorted(name for name in arguments if name not in TOOL_ARGUMENT_NAMES)
        if unknown:
            return web_server.tool_result(identifier, "the call carries an argument the tool does not read: " + ", ".join(unknown), True)
        try:
            text = call_run(settings, arguments)
        except web_server.ToolError as error:
            return web_server.tool_result(identifier, str(error), True)
        except Exception as error:  # noqa: BLE001 -- the trail names frames alone
            sys.stderr.write(web_server.sanitized_traceback(error) + "\n")
            sys.stderr.flush()
            return web_server.jsonrpc_error(identifier, -32603, "internal error during tool execution")
        return web_server.tool_result(identifier, text, False)
    return web_server.jsonrpc_error(identifier, -32601, f"unknown method: {method}")


def main(argv):
    settings = settings_from_environment()
    try:
        settings["timeout_seconds"] = resolve_timeout(settings["timeout"])
    except web_server.ToolError as error:
        sys.stderr.write(f"{error}\n")
        return 2
    sys.stderr.write(f"timeouts mcp={settings['timeout_seconds']:g} service={settings['service'] or '-'}\n")
    sys.stderr.flush()
    while True:
        line = web_server.read_request_line(sys.stdin)
        if line is None:
            break
        if line is web_server.OVERSIZED_LINE:
            response = web_server.jsonrpc_error(None, -32600, f"the request exceeds the {web_server.REQUEST_LINE_CHARACTER_CAP} character line cap")
        else:
            line = line.strip()
            if not line:
                continue
            try:
                message = web_server.strict_json_loads(line)
            except (ValueError, RecursionError):
                response = web_server.jsonrpc_error(None, -32700, "parse error")
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
