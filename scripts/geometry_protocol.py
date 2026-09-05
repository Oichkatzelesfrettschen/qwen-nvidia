#!/usr/bin/env python3
"""Frozen geometry job protocol, version 1.

The geometry service, its tests, and any wrapper import this module, so one
reading of a request and a reply exists. A message is one UTF-8 JSON object
on one line, bounded at 65536 bytes excluding the newline, and a longer line
is refused before it is parsed. The schema is closed: an unknown key is
refused rather than ignored.

A request names a profile and a ray count and nothing else the query reads.
The profile row in scripts/geometry-profiles.tsv carries the fixture scene,
the query set, the ray ceiling, and the device, so a caller chooses among
fixtures and never supplies geometry, native code, a filesystem path, or an
OptiX or CUDA flag. The ray count is the one free parameter, bounded by the
profile's own ceiling, because it changes how long the device is held and
nothing about what runs.

A completed reply carries the structured summary the runtime printed: hit
and miss counts, the distance range, the per-primitive hit counts, the
agreement between the device answer and the host reference for every ray, a
digest of the packed per-ray results, the timings, and the GPU proof block
the service requires before it reports `completed` at all.
"""

import json

PROTOCOL_VERSION = 1
MAX_LINE_BYTES = 65536
ACTIONS = ("geometry_ray_query", "status")
STATUSES = ("accepted", "completed", "refused", "failed")
MAX_IDENTIFIER_CHARACTERS = 64
MAX_ERROR_CHARACTERS = 1024
MIN_RAYS = 1
MAX_RAYS = 1048576
GPU_PROOF_KEYS = (
    "context_created",
    "gas_built",
    "pipeline_created",
    "launch_completed",
    "optix_version",
    "gas_bytes",
    "device_name",
    "device_index",
)
REQUEST_KEYS = {"protocol", "action", "request_id", "profile_id", "rays"}
STATUS_REQUEST_KEYS = {"protocol", "action", "request_id"}
REPLY_KEYS = {"protocol", "request_id", "status", "profile_id", "result", "error", "reason"}
RESULT_KEYS = {
    "scene", "query_set", "rays", "hits", "misses", "t_min", "t_max", "t_mean",
    "primitive_hits", "reference_agreement", "reference_disagreement",
    "results_fnv1a64", "wall_ms", "launch_ms", "gpu", "runtime_sha256", "scene_sha256",
}


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
    """Return (action, request_id, profile_id, rays) or raise ProtocolError."""
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
    rays = message["rays"]
    if isinstance(rays, bool) or not isinstance(rays, int) or not MIN_RAYS <= rays <= MAX_RAYS:
        raise ProtocolError("rays is not an integer in [%d, %d]" % (MIN_RAYS, MAX_RAYS))
    return action, request_id, profile_id, rays


def _count(value, name):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProtocolError("%s is not a non-negative integer" % name)
    return value


def _number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProtocolError("%s is not a number" % name)
    return value


def validate_result(result):
    """Validate the structured summary a completed reply carries."""
    if not isinstance(result, dict):
        raise ProtocolError("result is not an object")
    if set(result) != RESULT_KEYS:
        raise ProtocolError("result keys differ from the schema: %s"
                            % ", ".join(sorted(set(result) ^ RESULT_KEYS)))
    _identifier(result["scene"], "scene")
    _identifier(result["query_set"], "query_set")
    rays = result["rays"]
    if isinstance(rays, bool) or not isinstance(rays, int) or not MIN_RAYS <= rays <= MAX_RAYS:
        raise ProtocolError("result rays is outside [%d, %d]" % (MIN_RAYS, MAX_RAYS))
    hits = _count(result["hits"], "hits")
    misses = _count(result["misses"], "misses")
    if hits + misses != rays:
        raise ProtocolError("hits and misses do not sum to rays")
    for key in ("t_min", "t_max", "t_mean"):
        if _number(result[key], key) < 0:
            raise ProtocolError("%s is negative" % key)
    primitive_hits = result["primitive_hits"]
    if not isinstance(primitive_hits, list) or not primitive_hits:
        raise ProtocolError("primitive_hits holds no primitive")
    for index, count in enumerate(primitive_hits):
        _count(count, "primitive_hits[%d]" % index)
    if sum(primitive_hits) != hits:
        raise ProtocolError("primitive_hits do not sum to hits")
    agreement = _count(result["reference_agreement"], "reference_agreement")
    disagreement = _count(result["reference_disagreement"], "reference_disagreement")
    if agreement + disagreement != rays:
        raise ProtocolError("reference agreement and disagreement do not sum to rays")
    digest = result["results_fnv1a64"]
    if not isinstance(digest, str) or len(digest) != 16 or any(c not in "0123456789abcdef" for c in digest):
        raise ProtocolError("results_fnv1a64 is not 16 hex")
    for key in ("wall_ms", "launch_ms"):
        if _number(result[key], key) < 0:
            raise ProtocolError("%s is negative" % key)
    gpu = result["gpu"]
    if not isinstance(gpu, dict) or set(gpu) != set(GPU_PROOF_KEYS):
        raise ProtocolError("gpu proof keys differ from the schema")
    for key in ("context_created", "gas_built", "pipeline_created", "launch_completed"):
        if not isinstance(gpu[key], bool):
            raise ProtocolError("gpu.%s is not a boolean" % key)
    for key in ("optix_version", "gas_bytes"):
        _count(gpu[key], "gpu.%s" % key)
    if not isinstance(gpu["device_name"], str) or not gpu["device_name"]:
        raise ProtocolError("gpu.device_name is empty")
    if isinstance(gpu["device_index"], bool) or not isinstance(gpu["device_index"], int):
        raise ProtocolError("gpu.device_index is not an integer")
    for key in ("runtime_sha256", "scene_sha256"):
        value = result[key]
        if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise ProtocolError("%s is not 64 hex" % key)
    return result


def gpu_proof_holds(gpu):
    """Every proof the service requires before a reply reads completed."""
    return all(gpu[key] is True for key in ("context_created", "gas_built", "pipeline_created",
                                             "launch_completed")) and gpu["gas_bytes"] > 0


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
        if message["result"]["reference_disagreement"] != 0:
            raise ProtocolError("a completed reply carries a reference disagreement")
    return message
