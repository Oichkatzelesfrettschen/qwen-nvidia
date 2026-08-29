#!/usr/bin/env python3
"""Expose one authorized image generation as an MCP tool over stdio.

llama-server spawns this child for a section whose MCP configuration names it,
writes one JSON-RPC request per line, and reads one response per line, the way
it drives `web-mcp/server.py`. The single tool `generate_image` carries the
grant a human approved beside the arguments the model emitted, and every
refusal reaches the model as an `isError` result at JSON-RPC success, so the
router's `mcp_result_to_response` maps it onto an `error` key at HTTP 200 and
the page reads what refused from the body.

Three boundaries meet here. The grant decides what runs: `image_grant`
verifies the HMAC under the `qwen-image-generate-v1` context, compares the
prompt, negative prompt, seed, and aspect for equality, bounds width, height,
and steps by the approved maxima, and the SQLite ledger spends the single use
under the grant identifier, so a replayed token meets a primary-key violation
rather than a second generation. The Unix socket decides where it runs: the
validated job travels to `image-service.py`, which owns the Vulkan workload
lease and the pinned runtime, and this child holds no device state. The result
decides what the transcript carries: the result is a JSON object naming the
status, the artifact SHA-256, and its provenance URL, so the model and the page
read an identity and a location rather than image bytes.

The listing states the served profile rather than the lane. `tools/list` reads
`QWEN_IMAGE_PROFILES_JSON` -- the parameter file `image-service.py` runs a job
under and `qwen-image-launch.sh` validates against the ledger row -- and builds
`profile_id` as an enum of the one served profile with the dimension and step
maxima that profile admits, so a model proposing from the schema proposes what
the broker signs and the service executes.

The tool bounds its own call at `QWEN_IMAGE_MCP_TIMEOUT_S`, 360 seconds by
default, and applies it as the socket deadline, so a stalled service is
answered by this child's own timer rather than abandoned by the router.
"""

import json
import os
import re
import secrets
import socket
import sys
import time

SERVER_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
REMOTE_DIRECTORY = os.path.dirname(SERVER_DIRECTORY)
WEB_MCP_DIRECTORY = os.path.join(REMOTE_DIRECTORY, "web-mcp")
for candidate in (SERVER_DIRECTORY, WEB_MCP_DIRECTORY, REMOTE_DIRECTORY):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

import server as web_server  # noqa: E402
import image_grant  # noqa: E402
import image_protocol  # noqa: E402

SERVER_NAME = "image"
SERVER_VERSION = "1.0.0"
PROTOCOL_VERSION = web_server.PROTOCOL_VERSION
SUPPORTED_PROTOCOL_VERSIONS = web_server.SUPPORTED_PROTOCOL_VERSIONS

# The job frame is `image_protocol`'s, so this wrapper and the service read one
# closed schema rather than two agreeing copies of it.
SERVICE_PROTOCOL_VERSION = image_protocol.PROTOCOL_VERSION
SERVICE_LINE_BYTE_CAP = image_protocol.MAX_LINE_BYTES
SERVICE_ACTION = "image_generate"
SERVICE_STATUSES = image_protocol.STATUSES
SERVICE_TERMINAL_SUCCESS = "completed"
SERVICE_ERROR_CHARACTER_CAP = 500

MCP_TIMEOUT_DEFAULT_SECONDS = 360.0
MCP_TIMEOUT_MAXIMUM_SECONDS = 3600.0
REQUEST_ID_BYTES = 12
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")


class ServiceRefused(web_server.ToolError):
    """The image service answered, and the answer is not a finished artifact.

    A refusal, a failure, a cancellation, and a reply outside the protocol all
    reach the audit trail as `service_refused`, because each states that the
    service read the job and produced no image. The web vocabulary's
    `provider_http_error` names a remote HTTP provider, which the image lane
    reaches none of.
    """

    status = "service_refused"


class ServiceUnavailable(web_server.ToolError):
    """The image service took no job: the socket, the write, or the read failed.

    The trail separates this from a refusal because the remedies differ: an
    unreachable or silent service is a launch state, where a refusal is a
    policy or a runtime outcome the operator reads in the service's own log.
    """

    status = "service_unavailable"


def resolve_timeout(raw):
    """Return the wall-clock bound this tool applies to one generation.

    The value bounds the socket read, so the child answers a stalled service
    itself. A malformed or out-of-range setting refuses startup rather than
    falling back to the default, since a silently defaulted deadline reports a
    bound the operator did not configure.
    """
    if not raw:
        return MCP_TIMEOUT_DEFAULT_SECONDS
    try:
        seconds = float(raw)
    except ValueError:
        raise web_server.InvalidArgument(
            "QWEN_IMAGE_MCP_TIMEOUT_S is not a number"
        ) from None
    if not 0 < seconds <= MCP_TIMEOUT_MAXIMUM_SECONDS:
        raise web_server.InvalidArgument(
            "QWEN_IMAGE_MCP_TIMEOUT_S lies outside "
            f"(0, {MCP_TIMEOUT_MAXIMUM_SECONDS:g}]: {seconds:g}"
        )
    return seconds


def settings_from_environment():
    return {
        "profile": os.environ.get("QWEN_IMAGE_PROFILE", ""),
        "language_profile": os.environ.get("QWEN_IMAGE_LANGUAGE_PROFILE", ""),
        "token_key_file": os.environ.get("QWEN_IMAGE_TOKEN_KEY_FILE", ""),
        "state_dir": os.environ.get("QWEN_IMAGE_STATE_DIR", ""),
        "socket_path": os.environ.get("QWEN_IMAGE_SERVICE_SOCKET", ""),
        "profiles_json": os.environ.get("QWEN_IMAGE_PROFILES_JSON", ""),
        "timeout": os.environ.get("QWEN_IMAGE_MCP_TIMEOUT_S", ""),
    }


def require_configuration(settings):
    """Refuse a call whose configuration names no profile, key, or socket.

    The check runs per call rather than at startup because llama-server
    respawns the child for each invocation and because a missing value is a
    refusal the model can read, where a startup exit reaches it as a transport
    failure with no cause.
    """
    for key, name in (
        ("profile", "QWEN_IMAGE_PROFILE"),
        ("language_profile", "QWEN_IMAGE_LANGUAGE_PROFILE"),
        ("token_key_file", "QWEN_IMAGE_TOKEN_KEY_FILE"),
        ("state_dir", "QWEN_IMAGE_STATE_DIR"),
        ("socket_path", "QWEN_IMAGE_SERVICE_SOCKET"),
        ("profiles_json", "QWEN_IMAGE_PROFILES_JSON"),
    ):
        if not settings.get(key):
            raise web_server.InvalidArgument(
                f"{name} is unconfigured, so the call reaches no runtime"
            )


PROFILE_INTEGER_FIELDS = ("width", "height", "steps", "max_dimension", "max_steps")

# Every argument the tool reads, named once. `additionalProperties` is false and
# `handle_request` refuses a name outside this set, so the schema and that
# refusal read one tuple rather than two lists that drift apart.
TOOL_ARGUMENT_NAMES = (
    "prompt",
    "negative_prompt",
    "seed",
    "width",
    "height",
    "steps",
    "profile_id",
    "authorization",
)


def profile_parameters(settings):
    """Return the served profile's geometry and ceilings from the parameter file.

    `QWEN_IMAGE_PROFILES_JSON` is the file `image-service.py` runs a job under
    and `qwen-image-launch.sh` validates against the `remote/image-profiles.tsv`
    row before anything starts, so the maximum this schema advertises and the
    maximum the service enforces at `request["width"] > profile["max_dimension"]`
    are one number read from one file. A preset persists across a registry edit
    where this file is read again at every child start, which is why the bounds
    live here rather than in the section's environment.

    An absent file, an absent profile, or a non-positive field raises. A schema
    falling back to `image_grant`'s own 4096 pixel ceiling would advertise a
    geometry the profile refuses, which is the state the bounds exist to end.
    """
    parameter_path = settings["profiles_json"]
    if not parameter_path:
        raise web_server.InvalidArgument(
            "QWEN_IMAGE_PROFILES_JSON is unconfigured, so the tool states no "
            "profile bounds"
        )
    try:
        with open(parameter_path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as error:
        raise web_server.InvalidArgument(
            "the image parameter file is unreadable or is not JSON: "
            f"{error.__class__.__name__}"
        ) from None
    profile = payload.get(settings["profile"]) if isinstance(payload, dict) else None
    if not isinstance(profile, dict):
        raise web_server.InvalidArgument(
            "the image parameter file holds no object for profile "
            f"{settings['profile']!r}"
        )
    bounds = {"profile_id": settings["profile"]}
    for field in PROFILE_INTEGER_FIELDS:
        value = profile.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise web_server.InvalidArgument(
                f"the parameters for profile {settings['profile']!r} carry no "
                f"positive integer {field}"
            )
        bounds[field] = value
    return bounds


def tool_definitions(bounds):
    """Return the one tool this server exposes, bounded by the served profile.

    The schema states what this section serves rather than what the lane could
    serve: `profile_id` is an enum of the one admitted profile, the dimension
    and step maxima are that profile's own ceilings, and each description names
    its native geometry. A model reading the listing proposes inside the bounds
    the broker signs and the service enforces, where a schema stating the
    helper's widest ceilings invites a proposal every later layer refuses.

    `image_grant` bounds a dimension at `DIMENSION_MAXIMUM` and a step count at
    `STEP_MAXIMUM`, and `parse_arguments` applies both to what arrives, so an
    advertised ceiling is clamped to them: a profile admitting more would
    otherwise advertise a geometry this file refuses.

    `authorization` is an argument rather than an ambient setting because one
    approval authorizes one call, and it takes the name the service protocol
    gives the same field, so one word names the grant along its whole path.
    """
    profile = bounds["profile_id"]
    dimension_ceiling = min(bounds["max_dimension"], image_grant.DIMENSION_MAXIMUM)
    step_ceiling = min(bounds["max_steps"], image_grant.STEP_MAXIMUM)
    return [
        {
            "name": "generate_image",
            "description": (
                f"Generate one image under the {profile} image profile, which "
                f"renders {bounds['width']}x{bounds['height']} and admits at "
                f"most {dimension_ceiling} pixels a side and {step_ceiling} "
                "sampler steps. The call runs only under a grant the user "
                "approved for these exact arguments, and the reply names the "
                "artifact digest and its provenance URL."
            ),
            "inputSchema": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": (
                            "The approved prompt, at most "
                            f"{image_grant.PROMPT_CHARACTER_CAP} characters."
                        ),
                    },
                    "negative_prompt": {
                        "type": "string",
                        "description": (
                            "The approved negative prompt, empty when the "
                            "approval named none."
                        ),
                    },
                    "seed": {
                        "type": "integer",
                        "minimum": 0,
                        "maximum": image_grant.SEED_MAXIMUM,
                        "description": (
                            "The seed the approval displayed. The runtime "
                            "chooses none."
                        ),
                    },
                    "width": {
                        "type": "integer",
                        "minimum": image_grant.DIMENSION_MINIMUM,
                        "maximum": dimension_ceiling,
                        "default": bounds["width"],
                        "description": (
                            f"Pixel width. The {profile} profile renders "
                            f"{bounds['width']} natively and admits at most "
                            f"{dimension_ceiling}."
                        ),
                    },
                    "height": {
                        "type": "integer",
                        "minimum": image_grant.DIMENSION_MINIMUM,
                        "maximum": dimension_ceiling,
                        "default": bounds["height"],
                        "description": (
                            f"Pixel height. The {profile} profile renders "
                            f"{bounds['height']} natively and admits at most "
                            f"{dimension_ceiling}."
                        ),
                    },
                    "steps": {
                        "type": "integer",
                        "minimum": image_grant.STEP_MINIMUM,
                        "maximum": step_ceiling,
                        "default": bounds["steps"],
                        "description": (
                            f"Sampler steps. The {profile} profile runs "
                            f"{bounds['steps']} and admits at most "
                            f"{step_ceiling}."
                        ),
                    },
                    "profile_id": {
                        "type": "string",
                        "enum": [profile],
                        "description": (
                            f"The image profile this server serves. {profile} "
                            "is the one profile it admits, and the grant names "
                            "the same one."
                        ),
                    },
                    "authorization": {
                        "type": "string",
                        "description": (
                            "The single-use grant the user's approval issued "
                            "for these exact arguments."
                        ),
                    },
                },
                "required": [
                    "prompt",
                    "seed",
                    "width",
                    "height",
                    "steps",
                    "profile_id",
                    "authorization",
                ],
            },
        }
    ]


def parse_arguments(raw):
    """Return the generation arguments under the same helpers the grant used.

    The claim was built through `image_grant`, so the arguments are rebuilt
    through it too and the comparison runs over one spelling of each field.
    """
    grant = raw.get("authorization")
    if not isinstance(grant, str) or not grant.strip():
        raise web_server.InvalidArgument("authorization is required")
    if len(grant) > image_grant.IMAGE_GRANT_CHARACTER_CAP:
        raise web_server.InvalidArgument(
            f"authorization exceeds the "
            f"{image_grant.IMAGE_GRANT_CHARACTER_CAP} character cap"
        )
    return {
        "prompt": image_grant.require_text(raw, "prompt", True),
        "negative_prompt": image_grant.require_text(raw, "negative_prompt", False),
        "seed": image_grant.require_bounded_integer(
            raw, "seed", 0, image_grant.SEED_MAXIMUM
        ),
        "width": image_grant.require_bounded_integer(
            raw,
            "width",
            image_grant.DIMENSION_MINIMUM,
            image_grant.DIMENSION_MAXIMUM,
        ),
        "height": image_grant.require_bounded_integer(
            raw,
            "height",
            image_grant.DIMENSION_MINIMUM,
            image_grant.DIMENSION_MAXIMUM,
        ),
        "steps": image_grant.require_bounded_integer(
            raw, "steps", image_grant.STEP_MINIMUM, image_grant.STEP_MAXIMUM
        ),
        "profile_id": image_grant.require_profile_id(raw, "profile_id"),
        "authorization": grant.strip(),
    }


def service_request(settings, arguments, request_id):
    """Return the job line the image service reads.

    The grant travels to the service as an opaque string under
    `authorization`: this child verified it and spent its single use, and the
    service revalidates against the same key file, so neither side takes the
    other's word for what a human approved.

    Two schemas spell the shape differently and each keeps its own spelling.
    The grant binds the reduced ratio `image_grant.canonical_aspect` produces,
    which is what the approval displayed; the job line carries the protocol's
    coarse label, which the frame requires to agree with the dimensions beside
    it. Both are derived from the same width and height, so the two readings
    cannot diverge.
    """
    return {
        "protocol_version": SERVICE_PROTOCOL_VERSION,
        "request_id": request_id,
        "action": SERVICE_ACTION,
        "profile_id": arguments["profile_id"],
        "prompt": arguments["prompt"],
        "negative_prompt": arguments["negative_prompt"],
        "seed": arguments["seed"],
        "aspect": protocol_aspect(arguments["width"], arguments["height"]),
        "width": arguments["width"],
        "height": arguments["height"],
        "steps": arguments["steps"],
        "authorization": arguments["authorization"],
    }


def protocol_aspect(width, height):
    """Return the label `image_protocol` admits for one geometry."""
    if width == height:
        return "square"
    return "landscape" if width > height else "portrait"


def connect_service(settings, timeout):
    """Return a connected socket to the image service, or refuse the call.

    The connection opens before the ledger spends the grant, so a socket no
    process listens on refuses without consuming an approval a human would have
    to give again. A connect that succeeds proves a listener took the
    connection into its backlog rather than that the service will read the
    line, so an approval is spent by a service that accepts and then dies: one
    approval buys one attempt, and a retry needs a second approval.
    """
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    try:
        connection.connect(settings["socket_path"])
    except (OSError, socket.timeout) as error:
        connection.close()
        raise ServiceUnavailable(
            f"the image service socket is unreachable: {error.__class__.__name__}"
        ) from None
    return connection


def exchange(connection, payload, timeout):
    """Write one job line and read one reply line inside the tool deadline.

    The job is validated against the frozen frame before it is encoded, so a
    grant whose approved ceilings exceed the protocol's own -- `image_grant`
    admits a 4096 pixel side and a 2**64 seed where the frame admits 2048 and
    2**32 -- is refused here rather than sent for the service to refuse.
    """
    try:
        image_protocol.validate_request(payload)
        line = image_protocol.encode_line(payload).encode("utf-8")
    except image_protocol.ProtocolError as breach:
        raise web_server.InvalidArgument(
            f"the job leaves the image protocol: {breach}"
        ) from None
    connection.settimeout(timeout)
    try:
        connection.sendall(line)
        # The reader takes the cap plus one byte, so a service that writes
        # bytes and no newline meets the cap rather than growing a buffer
        # until the child dies.
        stream = connection.makefile("rb")
        reply = stream.readline(SERVICE_LINE_BYTE_CAP + 1)
    except (OSError, socket.timeout) as error:
        raise ServiceUnavailable(
            "the image service answered no reply inside the "
            f"{timeout:g} second tool deadline: {error.__class__.__name__}"
        ) from None
    if not reply:
        raise ServiceUnavailable(
            "the image service closed the connection unanswered"
        )
    try:
        decoded = image_protocol.decode_line(reply)
    except image_protocol.ProtocolError:
        raise ServiceRefused(
            "the image service reply is not UTF-8 JSON inside the line bound"
        ) from None
    if not isinstance(decoded, dict):
        raise ServiceRefused("the image service reply is not an object")
    return decoded


def clip_service_error(value):
    """Return the service's own message, bounded and free of control bytes.

    The text reaches the model, so a reply that carried a newline or an escape
    sequence would rewrite the surrounding result rather than describe a
    failure.
    """
    if not isinstance(value, str) or not value.strip():
        return "the image service named no reason"
    return CONTROL_CHARACTERS.sub(" ", value.strip())[
        :SERVICE_ERROR_CHARACTER_CAP
    ]


def require_provenance(reply):
    """Return the digest and provenance route of a completed artifact.

    `image_protocol.validate_response` derives the route from the digest and
    admits one spelling of it, so the identity in the transcript and the
    location the page resolves are the same value read twice. The reply carries
    no origin, so the page resolves the route against the artifact listener it
    already holds a credential for.
    """
    try:
        image_protocol.validate_response(reply, control_reply=True)
    except image_protocol.ProtocolError as breach:
        raise ServiceRefused(
            f"the completed reply leaves the image protocol: {breach}"
        ) from None
    return reply["sha256"], reply["provenance_url"]


def read_reply(reply, request_id):
    """Return the completed artifact of one reply, or refuse it by status.

    The admitted vocabulary is the service protocol's own five terms and
    `completed` alone is success. `accepted` is refused here because the
    generation path is synchronous: a reply that opened a job and returned
    reaches the model as a failure rather than as an image that never arrived.
    A status outside the vocabulary is refused for the same reason a schema
    refuses an unknown argument -- an unrecognized term read as success is the
    failure that matters. A stopped generation carries `reason` as its fixed
    term and `error` as its prose, and the model reads whichever the service
    sent.
    """
    if reply.get("protocol_version") != SERVICE_PROTOCOL_VERSION:
        raise ServiceRefused(
            "the image service answered under another protocol version"
        )
    if reply.get("request_id") != request_id:
        raise ServiceRefused("the image service reply names another request")
    status = reply.get("status")
    if status not in SERVICE_STATUSES:
        named = clip_service_error(status) if isinstance(status, str) else "none"
        raise ServiceRefused(
            f"the image service answered a status outside the protocol: {named}"
        )
    if status != SERVICE_TERMINAL_SUCCESS:
        raise ServiceRefused(
            f"the image service {status} the generation: "
            + clip_service_error(reply.get("error") or reply.get("reason"))
        )
    return require_provenance(reply)


def audit_row(settings, arguments, status, started_at):
    """Return the trail row one generation writes.

    The row carries the prompt digest rather than the prompt and the artifact
    identity rather than the artifact, which is the same reduction the search
    trail applies, so the ledger states what ran without retaining the text a
    human approved or the bytes the runtime produced.
    """
    now = time.time()
    return {
        "recorded_at": web_server.utc_timestamp(now),
        "profile": settings["profile"],
        "operation": "generate-image",
        "query_sha256": (
            image_grant.prompt_digest(arguments["prompt"])
            if arguments is not None
            else ""
        ),
        "domains": "",
        "result_count": 1,
        "fetched_host": "",
        "provider_bytes": 0,
        "returned_characters": 0,
        "latency_ms": int((now - started_at) * 1000),
        "status": status,
        "recorded_epoch": int(now),
    }


def call_generate(settings, raw):
    """Run one authorized generation and return what the transcript carries.

    The order is what the boundary rests on. The arguments are validated, the
    grant is verified against the signing key and compared field by field with
    them, the socket is opened, the single use is spent under the ledger's
    primary key, and only then does the job reach the runtime. Spending after
    the connect keeps an absent service from consuming an approval, and
    spending before the send keeps one approval from reaching the runtime
    twice.
    """
    started_at = time.time()
    require_configuration(settings)
    arguments = parse_arguments(raw)
    signing_key = web_server.read_secret_file(
        settings["token_key_file"], "token signing"
    )
    claim = image_grant.verify_image_grant(
        signing_key, arguments["authorization"], started_at
    )
    image_grant.enforce_image_authorization(
        claim, settings["language_profile"], settings["profile"], arguments
    )
    request_id = web_server.base64url_encode(secrets.token_bytes(REQUEST_ID_BYTES))
    ledger = web_server.Ledger(settings["state_dir"])
    connection = None
    try:
        connection = connect_service(settings, settings["timeout_seconds"])
        ledger.consume_grant(
            claim["grant_id"],
            settings["profile"],
            "image",
            claim["expiry"],
            started_at,
        )
        reply = exchange(
            connection,
            service_request(settings, arguments, request_id),
            settings["timeout_seconds"],
        )
        digest, url = read_reply(reply, request_id)
    except web_server.ToolError as error:
        ledger.record(audit_row(settings, arguments, error.status, started_at))
        raise
    else:
        ledger.record(audit_row(settings, arguments, "success", started_at))
    finally:
        if connection is not None:
            connection.close()
        ledger.close()
    return json.dumps(
        {
            "status": SERVICE_TERMINAL_SUCCESS,
            "sha256": digest,
            "provenance_url": url,
        },
        sort_keys=True,
    )


TOOL_HANDLERS = {"generate_image": call_generate}


def handle_request(settings, message):
    """Return a JSON-RPC response object, or None for a notification.

    A protocol fault answers with a JSON-RPC error and a refused tool call
    answers with a successful result carrying `isError`, which is the shape the
    router maps onto an `error` key at HTTP 200.
    """
    method = message["method"]
    identifier = message.get("id")
    if "id" not in message:
        return None
    params = message.get("params") or {}
    if method == "initialize":
        requested = params.get("protocolVersion")
        version = (
            requested
            if requested in SUPPORTED_PROTOCOL_VERSIONS
            else PROTOCOL_VERSION
        )
        return {
            "jsonrpc": "2.0",
            "id": identifier,
            "result": {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": identifier, "result": {}}
    if method == "tools/list":
        # The listing states the served profile's own bounds, so an unreadable
        # parameter file answers with an error rather than with a schema whose
        # maxima nothing measured. A model offered no tool proposes no
        # generation, where a model offered unbounded arguments proposes a
        # geometry the broker and the service both refuse.
        try:
            bounds = profile_parameters(settings)
        except web_server.ToolError as error:
            return web_server.jsonrpc_error(identifier, -32603, str(error))
        return {
            "jsonrpc": "2.0",
            "id": identifier,
            "result": {"tools": tool_definitions(bounds)},
        }
    if method == "tools/call":
        handler = TOOL_HANDLERS.get(params.get("name"))
        if handler is None:
            return web_server.jsonrpc_error(
                identifier, -32602, f"unknown tool: {params.get('name')}"
            )
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            return web_server.jsonrpc_error(
                identifier, -32602, "arguments must be a JSON object"
            )
        # The schema names every argument the tool reads, so a name outside it
        # is a request the tool would silently drop. Refusing it by name makes
        # the executor's boundary observable: llama-server forwards the
        # `params` object of POST /tools and keeps its own routing keys out of
        # it, and a parser that started forwarding one surfaces here as a
        # refusal rather than as a generation that ran anyway.
        unknown = sorted(
            name for name in arguments if name not in TOOL_ARGUMENT_NAMES
        )
        if unknown:
            return web_server.tool_result(
                identifier,
                "the call carries an argument the tool does not read: "
                + ", ".join(unknown),
                True,
            )
        try:
            text = handler(settings, arguments)
        except web_server.ToolError as error:
            return web_server.tool_result(identifier, str(error), True)
        except Exception as error:  # noqa: BLE001 -- the trail names frames alone
            sys.stderr.write(web_server.sanitized_traceback(error) + "\n")
            sys.stderr.flush()
            return web_server.jsonrpc_error(
                identifier, -32603, "internal error during tool execution"
            )
        return web_server.tool_result(identifier, text, False)
    return web_server.jsonrpc_error(identifier, -32601, f"unknown method: {method}")


def main(argv):
    settings = settings_from_environment()
    try:
        settings["timeout_seconds"] = resolve_timeout(settings["timeout"])
    except web_server.ToolError as error:
        sys.stderr.write(f"{error}\n")
        return 2
    # The banner names the bound this child enforces and reaches stderr,
    # because stdout carries the JSON-RPC responses llama-server reads. The
    # ordering of the runtime, service, proxy, and browser deadlines around it
    # is verified by the launch script that configures all five.
    sys.stderr.write(f"timeouts mcp={settings['timeout_seconds']:g}\n")
    sys.stderr.flush()
    while True:
        line = web_server.read_request_line(sys.stdin)
        if line is None:
            break
        if line is web_server.OVERSIZED_LINE:
            response = web_server.jsonrpc_error(
                None,
                -32600,
                f"the request exceeds the {web_server.REQUEST_LINE_CHARACTER_CAP} "
                "character line cap",
            )
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
                    # A JSON-RPC notification receives no response, including a
                    # malformed one, so an unsolicited id:null error is never
                    # mistaken for a request reply.
                    response = None
                elif response is None:
                    response = handle_request(settings, message)
        if response is not None:
            sys.stdout.write(json.dumps(response, allow_nan=False) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
