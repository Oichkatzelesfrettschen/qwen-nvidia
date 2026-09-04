#!/usr/bin/env python3
"""Frozen physics job protocol, version 1.

The physics service, its MCP wrapper, and every test import this module, so
one reading of a request and a reply exists rather than three. A message is one
UTF-8 JSON object on one line, bounded at 65536 bytes excluding the newline,
and a longer line is refused before it is parsed. The schema is closed: an
unknown key is refused rather than ignored.

A request names a profile and nothing else the simulation reads. The profile
row in scripts/physics-profiles.tsv carries the scene, the timestep, the step
count, and the GPU flags, so a caller chooses among fixtures and never supplies
geometry, native code, a filesystem path, or a PhysX or CUDA flag. The one
free parameter is `steps`, bounded by the profile's own ceiling, because the
step count changes how long the device is held and nothing about what runs.

A completed reply carries the structured state the runtime printed: every
body's position, orientation, and velocities, every joint's state, a contact
summary, the step count, the timings, and the GPU proof block the service
requires before it reports `completed` at all.
"""

import json

PROTOCOL_VERSION = 1
MAX_LINE_BYTES = 65536
ACTIONS = ("physics_simulate_rigid", "status")
STATUSES = ("accepted", "completed", "refused", "failed")
MAX_IDENTIFIER_CHARACTERS = 64
MAX_ERROR_CHARACTERS = 1024
MIN_STEPS = 1
MAX_STEPS = 100000
GPU_PROOF_KEYS = (
    "cuda_context_valid",
    "gpu_dynamics_requested",
    "gpu_broadphase_requested",
    "gpu_dynamics_active",
    "device_name",
    "device_index",
)
REQUEST_KEYS = {"protocol", "action", "request_id", "profile_id", "steps"}
STATUS_REQUEST_KEYS = {"protocol", "action", "request_id"}
REPLY_KEYS = {"protocol", "request_id", "status", "profile_id", "result", "error", "reason"}
RESULT_KEYS = {
    "bodies", "joints", "contacts", "steps", "timestep_s", "wall_ms",
    "simulate_ms", "gpu", "runtime_sha256", "scene_sha256",
}
BODY_KEYS = {"id", "position", "orientation", "linear_velocity", "angular_velocity", "sleeping"}
JOINT_KEYS = {"id", "body0", "body1", "twist_rad", "swing_y_rad", "swing_z_rad", "broken"}
CONTACT_KEYS = {"pairs", "touching"}


class ProtocolError(ValueError):
    """A line that is not a valid version-1 message, with the rule it broke."""


def _identifier(value, name):
    if not isinstance(value, str) or not value or len(value) > MAX_IDENTIFIER_CHARACTERS:
        raise ProtocolError("%s is not a non-empty string of at most %d characters"
                            % (name, MAX_IDENTIFIER_CHARACTERS))
    for character in value:
        if not (character.isalnum() or character in "-_"):
            raise ProtocolError("%s carries a character outside [A-Za-z0-9_-]" % name)
    return value


def parse_line(raw):
    if isinstance(raw, str):
        raw = raw.encode("utf-8")
    if len(raw) > MAX_LINE_BYTES:
        raise ProtocolError("line exceeds %d bytes" % MAX_LINE_BYTES)
    try:
        message = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ProtocolError("line is not one UTF-8 JSON object") from None
    if not isinstance(message, dict):
        raise ProtocolError("message is not a JSON object")
    if message.get("protocol") != PROTOCOL_VERSION:
        raise ProtocolError("protocol is not %d" % PROTOCOL_VERSION)
    return message


def validate_request(message):
    """Return (action, request_id, profile_id, steps) or raise ProtocolError."""
    action = message.get("action")
    if action not in ACTIONS:
        raise ProtocolError("action is not one of %s" % ", ".join(ACTIONS))
    request_id = _identifier(message.get("request_id"), "request_id")
    if action == "status":
        unknown = set(message) - STATUS_REQUEST_KEYS
        if unknown:
            raise ProtocolError("status request carries unknown keys: %s" % ", ".join(sorted(unknown)))
        return action, request_id, None, None
    unknown = set(message) - REQUEST_KEYS
    if unknown:
        raise ProtocolError("request carries unknown keys: %s" % ", ".join(sorted(unknown)))
    missing = REQUEST_KEYS - set(message)
    if missing:
        raise ProtocolError("request lacks keys: %s" % ", ".join(sorted(missing)))
    profile_id = _identifier(message["profile_id"], "profile_id")
    steps = message["steps"]
    if isinstance(steps, bool) or not isinstance(steps, int) or not MIN_STEPS <= steps <= MAX_STEPS:
        raise ProtocolError("steps is not an integer in [%d, %d]" % (MIN_STEPS, MAX_STEPS))
    return action, request_id, profile_id, steps


def _number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProtocolError("%s is not a number" % name)
    return value


def _vector(value, name, length):
    if not isinstance(value, list) or len(value) != length:
        raise ProtocolError("%s is not a list of %d numbers" % (name, length))
    for index, component in enumerate(value):
        _number(component, "%s[%d]" % (name, index))
    return value


def validate_result(result):
    """Validate the structured state a completed reply carries."""
    if not isinstance(result, dict):
        raise ProtocolError("result is not an object")
    if set(result) != RESULT_KEYS:
        raise ProtocolError("result keys differ from the schema: %s"
                            % ", ".join(sorted(set(result) ^ RESULT_KEYS)))
    if not isinstance(result["bodies"], list) or not result["bodies"]:
        raise ProtocolError("result holds no body")
    for body in result["bodies"]:
        if not isinstance(body, dict) or set(body) != BODY_KEYS:
            raise ProtocolError("a body's keys differ from the schema")
        _identifier(body["id"], "body id")
        _vector(body["position"], "position", 3)
        _vector(body["orientation"], "orientation", 4)
        _vector(body["linear_velocity"], "linear_velocity", 3)
        _vector(body["angular_velocity"], "angular_velocity", 3)
        if not isinstance(body["sleeping"], bool):
            raise ProtocolError("sleeping is not a boolean")
    if not isinstance(result["joints"], list):
        raise ProtocolError("joints is not a list")
    for joint in result["joints"]:
        if not isinstance(joint, dict) or set(joint) != JOINT_KEYS:
            raise ProtocolError("a joint's keys differ from the schema")
        _identifier(joint["id"], "joint id")
        for axis in ("twist_rad", "swing_y_rad", "swing_z_rad"):
            _number(joint[axis], axis)
        if not isinstance(joint["broken"], bool):
            raise ProtocolError("broken is not a boolean")
    contacts = result["contacts"]
    if not isinstance(contacts, dict) or set(contacts) != CONTACT_KEYS:
        raise ProtocolError("contacts keys differ from the schema")
    for key in CONTACT_KEYS:
        if isinstance(contacts[key], bool) or not isinstance(contacts[key], int) or contacts[key] < 0:
            raise ProtocolError("contacts.%s is not a non-negative integer" % key)
    steps = result["steps"]
    if isinstance(steps, bool) or not isinstance(steps, int) or not MIN_STEPS <= steps <= MAX_STEPS:
        raise ProtocolError("result steps is outside [%d, %d]" % (MIN_STEPS, MAX_STEPS))
    for key in ("timestep_s", "wall_ms", "simulate_ms"):
        if _number(result[key], key) <= 0 and key == "timestep_s":
            raise ProtocolError("timestep_s is not positive")
    gpu = result["gpu"]
    if not isinstance(gpu, dict) or set(gpu) != set(GPU_PROOF_KEYS):
        raise ProtocolError("gpu proof keys differ from the schema")
    for key in ("cuda_context_valid", "gpu_dynamics_requested", "gpu_broadphase_requested",
                "gpu_dynamics_active"):
        if not isinstance(gpu[key], bool):
            raise ProtocolError("gpu.%s is not a boolean" % key)
    if not isinstance(gpu["device_name"], str) or not gpu["device_name"]:
        raise ProtocolError("gpu.device_name is empty")
    if isinstance(gpu["device_index"], bool) or not isinstance(gpu["device_index"], int):
        raise ProtocolError("gpu.device_index is not an integer")
    for key in ("runtime_sha256", "scene_sha256"):
        digest = result[key]
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ProtocolError("%s is not 64 hex" % key)
    return result


def gpu_proof_holds(gpu):
    """Every proof the service requires before a reply reads completed."""
    return all(gpu[key] is True for key in ("cuda_context_valid", "gpu_dynamics_requested",
                                             "gpu_broadphase_requested", "gpu_dynamics_active"))


def encode_reply(request_id, status, profile_id=None, result=None, error=None, reason=None):
    if status not in STATUSES:
        raise ProtocolError("status is not one of %s" % ", ".join(STATUSES))
    reply = {"protocol": PROTOCOL_VERSION, "request_id": request_id, "status": status}
    if profile_id is not None:
        reply["profile_id"] = profile_id
    if result is not None:
        reply["result"] = validate_result(result)
    if error is not None:
        if not isinstance(error, str) or len(error) > MAX_ERROR_CHARACTERS:
            raise ProtocolError("error is not a string of at most %d characters" % MAX_ERROR_CHARACTERS)
        reply["error"] = error
    if reason is not None:
        reply["reason"] = _identifier(reason, "reason")
    line = json.dumps(reply, separators=(",", ":"), sort_keys=True)
    if len(line.encode("utf-8")) > MAX_LINE_BYTES:
        raise ProtocolError("reply exceeds %d bytes" % MAX_LINE_BYTES)
    return line + "\n"


def parse_reply(raw):
    message = parse_line(raw)
    unknown = set(message) - REPLY_KEYS
    if unknown:
        raise ProtocolError("reply carries unknown keys: %s" % ", ".join(sorted(unknown)))
    _identifier(message.get("request_id"), "request_id")
    if message.get("status") not in STATUSES:
        raise ProtocolError("reply status is not one of %s" % ", ".join(STATUSES))
    if message["status"] == "completed":
        validate_result(message.get("result"))
        if not gpu_proof_holds(message["result"]["gpu"]):
            raise ProtocolError("a completed reply carries a failed GPU proof")
    return message
