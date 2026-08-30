#!/usr/bin/env python3
"""Frozen image job protocol, version 1.

scripts/image-protocol.md states the contract in prose and this module is the
checker every lane tests against, so the service, the MCP wrapper, and the UI
agree on one reading of a line rather than three. The Python standard library
carries no JSON Schema validator, so the schema lives here as code: importing
one module is what keeps a second reading from appearing.

A message is one UTF-8 JSON object on one line. The line is bounded at 65536
bytes excluding its terminating newline, and a longer line is refused before it
is parsed, because a peer that streams an unbounded line makes the reader's
memory the peer's choice.

The schema is closed. An unknown key is refused rather than ignored, so a field
added by a newer peer arrives as an explicit refusal at version 1 instead of
being silently dropped into a run that acts on fewer fields than the sender
believes it sent.
"""

import json

PROTOCOL_VERSION = 1
MAX_LINE_BYTES = 65536

ACTIONS = ("image_generate", "cancel", "status")
STATUSES = ("accepted", "completed", "refused", "cancelled", "failed")
ASPECTS = ("square", "portrait", "landscape")

MAX_IDENTIFIER_CHARACTERS = 64
MAX_PROMPT_CHARACTERS = 8192
MAX_AUTHORIZATION_CHARACTERS = 4096
MAX_ERROR_CHARACTERS = 1024

MIN_DIMENSION = 64
MAX_DIMENSION = 2048
DIMENSION_MULTIPLE = 64
MIN_STEPS = 1
MAX_STEPS = 100
MAX_SEED = 2**32 - 1

REQUEST_FIELDS = (
    "protocol_version",
    "request_id",
    "action",
    "profile_id",
    "prompt",
    "negative_prompt",
    "seed",
    "aspect",
    "width",
    "height",
    "steps",
    "authorization",
)
RESPONSE_FIELDS = (
    "protocol_version",
    "request_id",
    "status",
    "reason",
    "sha256",
    "provenance_url",
    "error",
)

# What a control reply reports beside the response frame. `status` and `cancel`
# answer with an observation of the service rather than with the outcome of a
# job, and a refusal names the artifact rule it broke, so the closed schema
# carries those keys as a second named set rather than admitting anything a
# sender adds. `validate_response` reads them only where the caller states that
# the line is a control reply.
OBSERVATION_FIELDS = (
    "state",
    "job_id",
    "job_request_id",
    "profile_id",
    "started_at",
    "elapsed_seconds",
    "cancel_requested",
    "cancelled",
    "lease_held",
    "lease_path",
    "artifact_directory",
    "artifact_url",
    "bytes",
    "seconds",
    "pid",
    "png_detail",
)

GENERATION_FIELDS = (
    "profile_id",
    "prompt",
    "negative_prompt",
    "seed",
    "aspect",
    "width",
    "height",
    "steps",
    "authorization",
)

IDENTIFIER_CHARACTERS = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
)
HEX_CHARACTERS = set("0123456789abcdef")


class ProtocolError(ValueError):
    """One message fails the version 1 contract."""


def _require_object(message, role):
    if not isinstance(message, dict):
        raise ProtocolError("%s is not a JSON object" % role)


def _require_closed_keys(message, allowed, role):
    unknown = sorted(set(message) - set(allowed))
    if unknown:
        raise ProtocolError(
            "%s carries fields outside protocol version %d: %s"
            % (role, PROTOCOL_VERSION, ", ".join(unknown))
        )


def _integer(message, key, role):
    value = message.get(key)
    # A JSON true is a Python int, and accepting it here would let a boolean
    # stand in for a seed or a dimension.
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProtocolError("%s: %s is not an integer" % (role, key))
    return value


def _string(message, key, role, maximum_characters):
    value = message.get(key)
    if not isinstance(value, str):
        raise ProtocolError("%s: %s is not a string" % (role, key))
    if len(value) > maximum_characters:
        raise ProtocolError(
            "%s: %s holds %d characters, above the %d the protocol admits"
            % (role, key, len(value), maximum_characters)
        )
    return value


def _identifier(message, key, role):
    value = _string(message, key, role, MAX_IDENTIFIER_CHARACTERS)
    if not value:
        raise ProtocolError("%s: %s is empty" % (role, key))
    if not set(value) <= IDENTIFIER_CHARACTERS:
        raise ProtocolError(
            "%s: %s carries characters outside the identifier set: %s"
            % (role, key, value)
        )
    return value


def _require_present(message, keys, role):
    absent = [key for key in keys if key not in message]
    if absent:
        raise ProtocolError(
            "%s omits required fields: %s" % (role, ", ".join(absent))
        )


def _require_absent(message, keys, role, reason):
    present = [key for key in keys if key in message]
    if present:
        raise ProtocolError(
            "%s carries %s, which %s" % (role, ", ".join(present), reason)
        )


def _protocol_version(message, role):
    version = _integer(message, "protocol_version", role)
    if version != PROTOCOL_VERSION:
        raise ProtocolError(
            "%s names protocol_version %d and this checker freezes %d"
            % (role, version, PROTOCOL_VERSION)
        )


def validate_request(message):
    """Return the request unchanged, or raise ProtocolError naming the breach."""
    role = "request"
    _require_object(message, role)
    _require_present(message, ("protocol_version", "request_id", "action"), role)
    _require_closed_keys(message, REQUEST_FIELDS, role)
    _protocol_version(message, role)
    _identifier(message, "request_id", role)

    action = message.get("action")
    if action not in ACTIONS:
        raise ProtocolError(
            "request: action %r is outside %s" % (action, list(ACTIONS))
        )

    # cancel and status name a job and carry nothing that could describe a
    # different one, so a control message can never smuggle a second geometry
    # past the authorization that admitted the first.
    if action in ("cancel", "status"):
        _require_absent(
            message,
            GENERATION_FIELDS,
            role,
            "a %s message names a job rather than describing one" % action,
        )
        return message

    _require_present(message, GENERATION_FIELDS, role)
    _identifier(message, "profile_id", role)
    _string(message, "prompt", role, MAX_PROMPT_CHARACTERS)
    _string(message, "negative_prompt", role, MAX_PROMPT_CHARACTERS)
    _string(message, "authorization", role, MAX_AUTHORIZATION_CHARACTERS)
    if not message["authorization"]:
        raise ProtocolError("request: authorization is empty")

    # The seed is required rather than defaulted. Where the model omits one the
    # trusted UI generates and displays it before approval, so the value the
    # grant was signed over is the value that reaches the runtime.
    seed = _integer(message, "seed", role)
    if not 0 <= seed <= MAX_SEED:
        raise ProtocolError(
            "request: seed %d is outside 0 to %d" % (seed, MAX_SEED)
        )

    for key in ("width", "height"):
        value = _integer(message, key, role)
        if not MIN_DIMENSION <= value <= MAX_DIMENSION:
            raise ProtocolError(
                "request: %s %d is outside %d to %d"
                % (key, value, MIN_DIMENSION, MAX_DIMENSION)
            )
        if value % DIMENSION_MULTIPLE:
            raise ProtocolError(
                "request: %s %d is not a multiple of %d"
                % (key, value, DIMENSION_MULTIPLE)
            )

    steps = _integer(message, "steps", role)
    if not MIN_STEPS <= steps <= MAX_STEPS:
        raise ProtocolError(
            "request: steps %d is outside %d to %d"
            % (steps, MIN_STEPS, MAX_STEPS)
        )

    aspect = message.get("aspect")
    if aspect not in ASPECTS:
        raise ProtocolError(
            "request: aspect %r is outside %s" % (aspect, list(ASPECTS))
        )
    # The label and the dimensions state one shape twice, so the checker
    # requires them to agree rather than choosing which one the runtime obeys.
    width, height = message["width"], message["height"]
    implied = (
        "square" if width == height else "landscape" if width > height else "portrait"
    )
    if aspect != implied:
        raise ProtocolError(
            "request: aspect %s disagrees with %dx%d, which is %s"
            % (aspect, width, height, implied)
        )

    # The protocol frame admits a shape; scripts/image-profiles.tsv admits the
    # served shape. A request inside these bounds still meets the profile's own
    # max_dimension and max_steps before anything runs.
    return message


def validate_response(message, control_reply=False):
    """Return the response unchanged, or raise ProtocolError naming the breach.

    `control_reply` admits OBSERVATION_FIELDS beside the frame, which is what a
    `status` or `cancel` answer reports. The outcome rules are the same either
    way: an artifact is named by a completed run alone and a failure names its
    cause alone.
    """
    role = "response"
    _require_object(message, role)
    _require_present(message, ("protocol_version", "request_id", "status"), role)
    _require_closed_keys(
        message,
        RESPONSE_FIELDS + OBSERVATION_FIELDS if control_reply else RESPONSE_FIELDS,
        role,
    )
    _protocol_version(message, role)
    _identifier(message, "request_id", role)

    status = message.get("status")
    if status not in STATUSES:
        raise ProtocolError(
            "response: status %r is outside %s" % (status, list(STATUSES))
        )

    # The reason is the machine-readable term a reader routes on, where the
    # error is the prose a human or a model reads. Each outcome that stops a
    # generation carries one, so a refusal is dispatched on a fixed word rather
    # than by matching a message that varies with its argument.
    if status == "completed":
        _require_absent(
            message,
            ("reason",),
            role,
            "names a refusal reason a completed run did not have",
        )
    elif status in ("refused", "failed", "cancelled"):
        _require_present(message, ("reason",), role)
        _identifier(message, "reason", role)
    elif "reason" in message:
        _identifier(message, "reason", role)

    if status == "completed":
        _require_present(message, ("sha256", "provenance_url"), role)
        _require_absent(
            message,
            ("error",),
            role,
            "states a failure a completed run did not have",
        )
        digest = _string(message, "sha256", role, 64)
        if len(digest) != 64 or not set(digest) <= HEX_CHARACTERS:
            raise ProtocolError(
                "response: sha256 is not 64 lowercase hex digits: %s" % digest
            )
        # The artifact is named by its own digest, so the provenance URL is
        # derived from the digest rather than chosen by the sender. A caller
        # therefore supplies no filesystem path at any layer.
        expected_url = "/artifacts/%s.json" % digest
        provenance_url = _string(message, "provenance_url", role, 128)
        if provenance_url != expected_url:
            raise ProtocolError(
                "response: provenance_url %s does not name the digest, expected %s"
                % (provenance_url, expected_url)
            )
        return message

    if status in ("refused", "failed"):
        _require_present(message, ("error",), role)
        _require_absent(
            message,
            ("sha256", "provenance_url"),
            role,
            "names an artifact a %s run did not produce" % status,
        )
        error = _string(message, "error", role, MAX_ERROR_CHARACTERS)
        if not error:
            raise ProtocolError("response: %s carries an empty error" % status)
        return message

    # accepted and cancelled report progress alone.
    _require_absent(
        message,
        ("sha256", "provenance_url", "error"),
        role,
        "reports an outcome an %s response has not reached" % status,
    )
    return message


def decode_line(line):
    """Parse one protocol line, refusing an oversized or malformed one.

    Accepts bytes or str. One trailing newline is stripped; the remainder is
    measured as UTF-8 against the 65536-byte line bound before it is parsed, so
    an oversized line is refused rather than decoded.
    """
    if isinstance(line, str):
        payload = line[:-1] if line.endswith("\n") else line
        encoded = payload.encode("utf-8")
    elif isinstance(line, (bytes, bytearray)):
        encoded = bytes(line)
        if encoded.endswith(b"\n"):
            encoded = encoded[:-1]
    else:
        raise ProtocolError("a protocol line is bytes or str")

    if len(encoded) > MAX_LINE_BYTES:
        raise ProtocolError(
            "line holds %d bytes, above the %d the protocol admits"
            % (len(encoded), MAX_LINE_BYTES)
        )
    if b"\n" in encoded:
        raise ProtocolError("one message is one line")
    try:
        text = encoded.decode("utf-8")
    except UnicodeDecodeError as decode_failure:
        raise ProtocolError("line is not UTF-8: %s" % decode_failure) from None
    try:
        return json.loads(text)
    except ValueError as parse_failure:
        raise ProtocolError("line is not JSON: %s" % parse_failure) from None


def encode_line(message):
    """Serialize one validated message as a bounded protocol line.

    The encoder writes compact separators and escapes non-ASCII, so the line
    the peer measures is the line this function bounded.
    """
    text = json.dumps(
        message, separators=(",", ":"), sort_keys=True, ensure_ascii=True
    )
    encoded = text.encode("utf-8")
    if len(encoded) > MAX_LINE_BYTES:
        raise ProtocolError(
            "encoded message holds %d bytes, above the %d the protocol admits"
            % (len(encoded), MAX_LINE_BYTES)
        )
    return text + "\n"


def read_request(line):
    """Decode and validate one request line."""
    return validate_request(decode_line(line))


def read_response(line):
    """Decode and validate one response line."""
    return validate_response(decode_line(line))
