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

PROTOCOL_VERSION = 4
# The columns of scripts/geometry-profiles.tsv, in order. The service and the
# MCP child both read that ledger, so the shape lives here beside the version
# rather than in each reader, where a column added to one reader leaves the
# other rejecting every row as the wrong width.
PROFILE_COLUMNS = (
    "profile_id", "scene", "query_set", "max_rays", "timeout_s", "execution_policy",
    "device_index", "module_cache", "residency", "session_requests", "session_seconds",
    "idle_timeout_s", "residency_budget_mib",
)
# Whether the runtime a profile names exits with its answer or keeps its device
# state between requests. execution_policy admits the compute one request runs;
# these five columns admit the device memory a process holds while it runs no
# request, which is the separate permission a resident worker needs. A one-shot
# row releases every allocation with the process that held the compute lease,
# so it carries a session of one request and n-a for the three bounds only a
# session has. A bounded-resident row names the request count and the wall
# seconds its session ends at, the idle interval that ends it earlier, and the
# device memory ceiling it fails at rather than enlarges.
RESIDENCY_MODES = ("one-shot", "bounded-resident")
RESIDENCY_UNSET = "n-a"
SESSION_REQUESTS_MAX = 64
SESSION_SECONDS_MAX = 3600
IDLE_TIMEOUT_SECONDS_MAX = 300
RESIDENCY_BUDGET_MIB_MAX = 4096
# Whether the OptiX disk cache is available to optixModuleCreate. optix_host.h
# states there is no in-memory cache, so the module stage either compiles the
# PTX or reads a compiled module back, and a timing taken without pinning this
# measures run history. OPTIX_CACHE_MAXSIZE=0 in the environment takes
# precedence over the API and can disable a cache the row asked for, which is
# why the reply carries the request and the readback separately.
MODULE_CACHES = ("enabled", "disabled")
# One number per stage of a launch. A resident worker would keep the optix
# context, the module, the pipeline and the acceleration structure; every query
# would still pay upload, launch, download and validate. Separating them is
# what makes that claim measurable rather than argued.
STAGE_KEYS = {
    "scene_ms", "cuda_context_ms", "optix_context_ms", "accel_ms", "module_ms",
    "pipeline_ms", "sbt_ms", "upload_ms", "launch_ms", "download_ms",
    "reference_ms", "compare_ms", "teardown_ms",
}
# The runtime serializes every stage and the wall time with three decimal
# places, so each carries up to half a millisecond-thousandth of rounding. The
# stages can each round up while the total rounds down, which puts their sum
# legitimately above it by (stages + 1) * half a step. A tolerance finer than
# the precision it checks rejects correct runs, so the bound is derived from
# the format rather than written as an epsilon.
STAGE_PRECISION_MS = 0.001


def stage_sum_tolerance_ms(stage_count):
    """The rounding a sum of stage_count stages and one wall time can carry."""
    return (stage_count + 1) * STAGE_PRECISION_MS / 2


STAGE_SUM_TOLERANCE_MS = stage_sum_tolerance_ms(len(STAGE_KEYS))
# A resident worker pays the setup stages once for a session and the per-request
# stages on every request, so its replies name the stages that request paid
# rather than zeroing the stages the session paid before it. The three sets
# partition STAGE_KEYS exactly, which is what makes a session's stage total
# comparable against a one-shot run's: a stage that reaches the one-shot table
# and none of these leaves the partition short and is refused at import.
RESIDENT_STARTUP_STAGE_KEYS = frozenset({
    "cuda_context_ms", "optix_context_ms", "accel_ms", "module_ms", "pipeline_ms", "sbt_ms",
})
RESIDENT_REQUEST_STAGE_KEYS = frozenset({
    "scene_ms", "upload_ms", "launch_ms", "download_ms", "reference_ms", "compare_ms",
})
RESIDENT_RETIRE_STAGE_KEYS = frozenset({"teardown_ms"})
_RESIDENT_PARTITION = (RESIDENT_STARTUP_STAGE_KEYS, RESIDENT_REQUEST_STAGE_KEYS,
                       RESIDENT_RETIRE_STAGE_KEYS)
if set().union(*_RESIDENT_PARTITION) != STAGE_KEYS or sum(
        len(part) for part in _RESIDENT_PARTITION) != len(STAGE_KEYS):
    raise ImportError("the resident stage sets do not partition STAGE_KEYS")
# What ends a session. A supervisor stopping the worker gives shutdown; the
# worker itself ends on the request count, the wall seconds, or the idle
# interval its profile row declared, and on the memory ceiling it refuses to
# enlarge.
RETIREMENT_REASONS = ("shutdown", "request_limit", "session_limit", "idle_timeout",
                      "budget_exceeded")
# The four a worker reaches by itself. Destroying device resources is compute,
# so a worker that reaches one announces it and waits for the supervisor's
# shutdown line rather than destroying at the moment its own bound expires;
# only `shutdown` is the supervisor's own word.
SELF_RETIREMENT_REASONS = tuple(reason for reason in RETIREMENT_REASONS if reason != "shutdown")
# How long a worker that has announced its retirement waits for that
# authorization before destroying unauthorized. The bound exists because a
# supervisor that died holding no lease would otherwise leave device memory
# held by a process nothing drives. The build passes it to the runtime and
# geometry-resident-driver.py refuses a lease wait that could outlast it, so
# the two ends read one number.
RETIREMENT_AUTHORIZATION_S = 30
RESIDENT_EVENTS = ("ready", "result", "refused", "retiring", "retired")
# The ready line proves the device state the session retains. It carries no
# launch, because no request has run; every request reply carries the full
# proof block including its own completed launch.
RESIDENT_READY_GPU_KEYS = tuple(key for key in (
    "context_created", "gas_built", "pipeline_created", "optix_version", "gas_bytes",
    "device_name", "device_index"))
RESIDENT_READY_KEYS = {"event", "scene", "query_set", "module_cache", "gpu", "timings",
                       "startup_ms", "device_allocated_bytes", "session_requests",
                       "session_seconds", "idle_timeout_s", "residency_budget_mib"}
RESIDENT_RESULT_KEYS = {"event", "request_id", "residency", "result"}
RESIDENT_RESIDENCY_KEYS = {"request_index", "session_age_s", "device_allocated_bytes",
                           "requests_remaining"}
RESIDENT_REFUSED_KEYS = {"event", "request_id", "reason", "detail"}
RESIDENT_RETIRING_KEYS = {"event", "reason", "requests_served", "session_age_s"}
RESIDENT_RETIRED_KEYS = {"event", "reason", "requests_served", "session_age_s", "timings",
                         "device_allocated_bytes", "authorized"}
MODULE_CACHE_KEYS = {"requested", "enabled", "location"}
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
REQUEST_KEYS = {"protocol", "action", "request_id", "profile_id", "rays", "authorization"}
# The grant a run spends travels as an opaque string the service revalidates
# against the same signing key the MCP child used; it is optional at the
# protocol level and required by a service launched with a key file.
AUTHORIZATION_CHARACTER_CAP = 4096
STATUS_REQUEST_KEYS = {"protocol", "action", "request_id"}
REPLY_KEYS = {"protocol", "request_id", "status", "profile_id", "result", "error", "reason"}
RESULT_KEYS = {
    "scene", "query_set", "rays", "hits", "misses", "t_min", "t_max", "t_mean",
    "primitive_hits", "reference_agreement", "reference_disagreement",
    "results_fnv1a64", "wall_ms", "launch_ms", "timings", "module_cache", "gpu",
    "runtime_sha256", "scene_sha256",
}


# The worker names the problem it solved; the binary's digest and the digest of
# the inputs are the supervisor's to add, the way geometry-service.py adds them
# to a one-shot reply. A worker that named its own digest would be attesting to
# the file it was read from.
RESIDENT_WORKER_RESULT_KEYS = RESULT_KEYS - {"runtime_sha256", "scene_sha256"}


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
    missing = (REQUEST_KEYS - {"authorization"}) - set(message)
    if missing:
        raise ProtocolError("request lacks keys: %s" % ", ".join(sorted(missing)))
    authorization = message.get("authorization")
    if authorization is not None and (not isinstance(authorization, str) or not authorization
                                      or len(authorization) > AUTHORIZATION_CHARACTER_CAP):
        raise ProtocolError("authorization is not a string of 1 to %d characters" % AUTHORIZATION_CHARACTER_CAP)
    profile_id = _identifier(message["profile_id"], "profile_id")
    rays = message["rays"]
    if isinstance(rays, bool) or not isinstance(rays, int) or not MIN_RAYS <= rays <= MAX_RAYS:
        raise ProtocolError("rays is not an integer in [%d, %d]" % (MIN_RAYS, MAX_RAYS))
    return action, request_id, profile_id, rays


def residency_bounds(row):
    """Read a profile row's residency columns, or raise ProtocolError.

    Returns None for a one-shot row and a dict of the four bounds for a
    bounded-resident one. Both readers of the ledger call this, so a row that
    admits retained device memory is read the same way by the service that
    refuses it and by the supervisor that acts on it.
    """
    mode = row["residency"]
    if mode not in RESIDENCY_MODES:
        raise ProtocolError("residency is not one of %s" % ", ".join(RESIDENCY_MODES))
    optional = ("session_seconds", "idle_timeout_s", "residency_budget_mib")
    if mode == "one-shot":
        if row["session_requests"] != "1":
            raise ProtocolError("a one-shot row serves one request and reads session_requests %s"
                                % row["session_requests"])
        for column in optional:
            if row[column] != RESIDENCY_UNSET:
                raise ProtocolError("a one-shot row holds no session, so %s reads %s rather than %s"
                                    % (column, row[column], RESIDENCY_UNSET))
        return None
    bounds = {}
    for column, ceiling in (("session_requests", SESSION_REQUESTS_MAX),
                            ("session_seconds", SESSION_SECONDS_MAX),
                            ("idle_timeout_s", IDLE_TIMEOUT_SECONDS_MAX),
                            ("residency_budget_mib", RESIDENCY_BUDGET_MIB_MAX)):
        try:
            value = int(row[column])
        except (TypeError, ValueError):
            raise ProtocolError("%s is not an integer" % column) from None
        if not 1 <= value <= ceiling:
            raise ProtocolError("%s is outside [1, %d]" % (column, ceiling))
        bounds[column] = value
    # An idle interval at or past the session's own wall bound never fires, so
    # a row reading that way declares a bound it does not have.
    if bounds["idle_timeout_s"] >= bounds["session_seconds"]:
        raise ProtocolError("idle_timeout_s %d never fires inside a session of %d s"
                            % (bounds["idle_timeout_s"], bounds["session_seconds"]))
    return bounds


def _count(value, name):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProtocolError("%s is not a non-negative integer" % name)
    return value


def _number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProtocolError("%s is not a number" % name)
    return value


def validate_result(result, timings_keys=None, result_keys=None):
    """Validate the structured summary a completed reply carries.

    A resident worker's per-request reply is the same summary over the stages
    that request paid, so it passes RESIDENT_REQUEST_STAGE_KEYS and the key set
    its residency block adds. Every other rule -- the hit arithmetic, the
    reference agreement, the GPU proof, the stage sum against the wall -- is
    the one a one-shot reply meets.
    """
    expected_keys = RESULT_KEYS if result_keys is None else result_keys
    expected_stages = STAGE_KEYS if timings_keys is None else set(timings_keys)
    if not isinstance(result, dict):
        raise ProtocolError("result is not an object")
    if set(result) != expected_keys:
        raise ProtocolError("result keys differ from the schema: %s"
                            % ", ".join(sorted(set(result) ^ expected_keys)))
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
    timings = result["timings"]
    if not isinstance(timings, dict) or set(timings) != expected_stages:
        raise ProtocolError("timings keys differ from the schema")
    for key in sorted(expected_stages):
        if _number(timings[key], "timings.%s" % key) < 0:
            raise ProtocolError("timings.%s is negative" % key)
    # The stages partition the run, so their sum cannot exceed the wall time
    # they were taken inside; a stage double-counted or a mark left behind
    # shows up here rather than in a plausible-looking table.
    tolerance = stage_sum_tolerance_ms(len(expected_stages))
    if sum(timings.values()) > result["wall_ms"] + tolerance:
        raise ProtocolError("the stage timings sum %.3f ms past wall_ms, beyond the %.4f ms "
                            "the serialization can account for"
                            % (sum(timings.values()) - result["wall_ms"], tolerance))
    if abs(timings["launch_ms"] - result["launch_ms"]) > 1e-6:
        raise ProtocolError("timings.launch_ms disagrees with launch_ms")

    cache = result["module_cache"]
    if not isinstance(cache, dict) or set(cache) != MODULE_CACHE_KEYS:
        raise ProtocolError("module_cache keys differ from the schema")
    if cache["requested"] not in MODULE_CACHES:
        raise ProtocolError("module_cache.requested is not one of %s" % ", ".join(MODULE_CACHES))
    if not isinstance(cache["enabled"], bool):
        raise ProtocolError("module_cache.enabled is not a boolean")
    if not isinstance(cache["location"], str):
        raise ProtocolError("module_cache.location is not a string")
    # The environment can disable a cache this run asked for but cannot enable
    # one it refused, so a disabled request reading back enabled is the reply
    # disagreeing with itself.
    if cache["requested"] == "disabled" and cache["enabled"]:
        raise ProtocolError("module_cache reads enabled where the run disabled it")
    if not cache["enabled"] and cache["location"]:
        raise ProtocolError("module_cache names a location with the cache disabled")

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
        if key not in expected_keys:
            continue
        value = result[key]
        if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
            raise ProtocolError("%s is not 64 hex" % key)
    return result


def gpu_proof_holds(gpu):
    """Every proof the service requires before a reply reads completed."""
    return all(gpu[key] is True for key in ("context_created", "gas_built", "pipeline_created",
                                             "launch_completed")) and gpu["gas_bytes"] > 0


def parse_resident_line(raw):
    """Return (event, message) for one line the resident worker printed.

    The worker outlives the supervisor's own start, so every line it prints
    carries the protocol version: a binary built against another version of
    this module is the failure a long-lived channel has, and it reads here
    rather than as a key set that happens to differ.
    """
    message = parse_line(raw)
    event = message.get("event")
    if event not in RESIDENT_EVENTS:
        raise ProtocolError("event is not one of %s" % ", ".join(RESIDENT_EVENTS))
    return event, message


def _resident_keys(message, expected, name):
    keys = set(message) - {"protocol"}
    if keys != expected:
        raise ProtocolError("%s keys differ from the schema: %s"
                            % (name, ", ".join(sorted(keys ^ expected))))


def _validate_module_cache(cache):
    if not isinstance(cache, dict) or set(cache) != MODULE_CACHE_KEYS:
        raise ProtocolError("module_cache keys differ from the schema")
    if cache["requested"] not in MODULE_CACHES:
        raise ProtocolError("module_cache.requested is not one of %s" % ", ".join(MODULE_CACHES))
    if not isinstance(cache["enabled"], bool):
        raise ProtocolError("module_cache.enabled is not a boolean")
    if not isinstance(cache["location"], str):
        raise ProtocolError("module_cache.location is not a string")
    if cache["requested"] == "disabled" and cache["enabled"]:
        raise ProtocolError("module_cache reads enabled where the run disabled it")
    if not cache["enabled"] and cache["location"]:
        raise ProtocolError("module_cache names a location with the cache disabled")


def validate_resident_ready(message, bounds):
    """The line that says a session holds device state and has served nothing."""
    _resident_keys(message, RESIDENT_READY_KEYS, "ready")
    _identifier(message["scene"], "scene")
    _identifier(message["query_set"], "query_set")
    _validate_module_cache(message["module_cache"])
    gpu = message["gpu"]
    if not isinstance(gpu, dict) or set(gpu) != set(RESIDENT_READY_GPU_KEYS):
        raise ProtocolError("ready gpu keys differ from the schema")
    for key in ("context_created", "gas_built", "pipeline_created"):
        if gpu[key] is not True:
            raise ProtocolError("ready reports gpu.%s false, so the session holds no such state" % key)
    for key in ("optix_version", "gas_bytes"):
        _count(gpu[key], "gpu.%s" % key)
    if gpu["gas_bytes"] <= 0:
        raise ProtocolError("ready reports an acceleration structure of no bytes")
    if not isinstance(gpu["device_name"], str) or not gpu["device_name"]:
        raise ProtocolError("gpu.device_name is empty")
    if isinstance(gpu["device_index"], bool) or not isinstance(gpu["device_index"], int):
        raise ProtocolError("gpu.device_index is not an integer")
    timings = message["timings"]
    if not isinstance(timings, dict) or set(timings) != set(RESIDENT_STARTUP_STAGE_KEYS):
        raise ProtocolError("ready timings differ from the startup stages")
    for key in sorted(RESIDENT_STARTUP_STAGE_KEYS):
        if _number(timings[key], "timings.%s" % key) < 0:
            raise ProtocolError("timings.%s is negative" % key)
    startup_ms = _number(message["startup_ms"], "startup_ms")
    tolerance = stage_sum_tolerance_ms(len(RESIDENT_STARTUP_STAGE_KEYS))
    if sum(timings.values()) > startup_ms + tolerance:
        raise ProtocolError("the startup stages sum %.3f ms past startup_ms, beyond the %.4f ms "
                            "the serialization can account for"
                            % (sum(timings.values()) - startup_ms, tolerance))
    allocated = _count(message["device_allocated_bytes"], "device_allocated_bytes")
    if allocated <= 0:
        raise ProtocolError("ready reports no device allocation, so it retains nothing")
    # The supervisor hands the bounds on argv and the worker reads them back.
    # A disagreement means the two hold different sessions, which is the one
    # thing neither can detect alone.
    for column, value in sorted(bounds.items()):
        if message[column] != value:
            raise ProtocolError("ready reads %s as %r where the ledger declares %r"
                                % (column, message[column], value))
    if allocated > bounds["residency_budget_mib"] * 1024 * 1024:
        raise ProtocolError("ready allocates %d bytes against a ceiling of %d MiB"
                            % (allocated, bounds["residency_budget_mib"]))
    return message


def validate_resident_result(message, bounds, request_id, rays):
    """One request's reply, over the stages a resident request pays."""
    _resident_keys(message, RESIDENT_RESULT_KEYS, "result")
    if message["request_id"] != request_id:
        raise ProtocolError("the worker answered request_id %r where %r was asked"
                            % (message["request_id"], request_id))
    residency = message["residency"]
    if not isinstance(residency, dict) or set(residency) != RESIDENT_RESIDENCY_KEYS:
        raise ProtocolError("residency keys differ from the schema")
    index = _count(residency["request_index"], "residency.request_index")
    if not 1 <= index <= bounds["session_requests"]:
        raise ProtocolError("residency.request_index %d is outside the session's %d requests"
                            % (index, bounds["session_requests"]))
    age = _number(residency["session_age_s"], "residency.session_age_s")
    if age < 0 or age > bounds["session_seconds"]:
        raise ProtocolError("residency.session_age_s %.3f is outside [0, %d]"
                            % (age, bounds["session_seconds"]))
    remaining = _count(residency["requests_remaining"], "residency.requests_remaining")
    if remaining != bounds["session_requests"] - index:
        raise ProtocolError("residency.requests_remaining %d disagrees with %d served of %d"
                            % (remaining, index, bounds["session_requests"]))
    allocated = _count(residency["device_allocated_bytes"], "residency.device_allocated_bytes")
    if allocated > bounds["residency_budget_mib"] * 1024 * 1024:
        raise ProtocolError("the request holds %d bytes against a ceiling of %d MiB"
                            % (allocated, bounds["residency_budget_mib"]))
    result = message["result"]
    validate_result(result, timings_keys=RESIDENT_REQUEST_STAGE_KEYS,
                    result_keys=RESIDENT_WORKER_RESULT_KEYS)
    if result["rays"] != rays:
        raise ProtocolError("the worker traced %d rays where %d were asked" % (result["rays"], rays))
    return message


def validate_resident_refused(message, request_id):
    _resident_keys(message, RESIDENT_REFUSED_KEYS, "refused")
    if message["request_id"] != request_id:
        raise ProtocolError("the worker refused request_id %r where %r was asked"
                            % (message["request_id"], request_id))
    _identifier(message["reason"], "reason")
    detail = message["detail"]
    if not isinstance(detail, str) or len(detail) > MAX_ERROR_CHARACTERS:
        raise ProtocolError("detail is not a string of at most %d characters" % MAX_ERROR_CHARACTERS)
    return message


def validate_resident_retiring(message, requests_served):
    """The notice that a worker has reached one of its own bounds.

    It carries no timings and no allocation figure, because nothing has been
    destroyed: the worker is asking for the lease under which destruction may
    run. A supervisor reading this stops sending requests and authorizes.
    """
    _resident_keys(message, RESIDENT_RETIRING_KEYS, "retiring")
    if message["reason"] not in SELF_RETIREMENT_REASONS:
        raise ProtocolError("a retirement notice cites %r, which is not one of %s"
                            % (message["reason"], ", ".join(SELF_RETIREMENT_REASONS)))
    served = _count(message["requests_served"], "requests_served")
    if served != requests_served:
        raise ProtocolError("the worker announces retirement having served %d where the "
                            "supervisor sent %d" % (served, requests_served))
    _number(message["session_age_s"], "session_age_s")
    return message


def validate_resident_retired(message, bounds, requests_served):
    """The line that says every device resource the session held is released."""
    _resident_keys(message, RESIDENT_RETIRED_KEYS, "retired")
    # Whether the supervisor authorized this destruction, rather than the
    # worker reaching its authorization deadline with nothing answering. The
    # supervisor holds the compute lease when it authorizes, so an
    # unauthorized retirement is device state released under no ownership.
    if message["authorized"] is not True and message["authorized"] is not False:
        raise ProtocolError("authorized is not a boolean")
    if message["reason"] not in RETIREMENT_REASONS:
        raise ProtocolError("retirement reason is not one of %s" % ", ".join(RETIREMENT_REASONS))
    served = _count(message["requests_served"], "requests_served")
    if served != requests_served:
        raise ProtocolError("the worker retires having served %d where the supervisor sent %d"
                            % (served, requests_served))
    _number(message["session_age_s"], "session_age_s")
    timings = message["timings"]
    if not isinstance(timings, dict) or set(timings) != set(RESIDENT_RETIRE_STAGE_KEYS):
        raise ProtocolError("retired timings differ from the retirement stages")
    for key in sorted(RESIDENT_RETIRE_STAGE_KEYS):
        if _number(timings[key], "timings.%s" % key) < 0:
            raise ProtocolError("timings.%s is negative" % key)
    # Retirement is the claim that the device holds nothing of this session's,
    # so a non-zero allocation here is the claim failing rather than a number.
    if _count(message["device_allocated_bytes"], "device_allocated_bytes") != 0:
        raise ProtocolError("the worker retires holding %d device bytes"
                            % message["device_allocated_bytes"])
    if message["reason"] == "request_limit" and served != bounds["session_requests"]:
        raise ProtocolError("the worker cites the request limit having served %d of %d"
                            % (served, bounds["session_requests"]))
    return message


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
