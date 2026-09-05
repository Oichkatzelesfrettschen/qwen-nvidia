"""The single-use grant one sidecar run spends: PhysX and OptiX under one claim.

A physics simulation and a geometry query reach the device the same way an
image generation does: one human approval signs one grant, the MCP child
verifies it against the signing key and compares it field by field with the
arguments the model emitted, the SQLite ledger spends its single use under
the grant identifier, and the service revalidates the same token against the
same key ahead of the compute lease. This module carries the claim both
lanes share, so a token signed for one service, one operation, one profile,
and one argument set verifies as nothing else.

The claim binds:

- `service` and `operation`: `physics` with `physics_simulate_rigid`, or
  `geometry` with `geometry_ray_query`; a claim for one lane meets a
  refusal at the other lane's child and service alike.
- `language_profile` and `sidecar_profile`: the section that executed the
  call and the ledger row it may run, compared against separate settings
  the way `image_grant.enforce_image_authorization` compares its pair.
- `runtime_sha256` and `scene`: the identity of the binary and the fixture
  the profile names, read from the ledger at approval time; a service whose
  runtime digest differs from the approved one refuses the run.
- `arguments_sha256`: the SHA-256 of the normalized argument object (the
  bounded count under its protocol name and the profile id), so a rewritten
  step or ray count reaches a digest mismatch rather than the runtime.
- `count_ceiling`: the profile's own ceiling the human read, compared at
  `<=` against the count the call carries.
- `conversation_generation`, `issued_at`, `expiry`, `grant_id`, `max_uses`.

The claim carries no argument text beyond the profile id and the count; a
service that logs the claim logs identities and digests.
"""

import hashlib
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

SIDECAR_CLAIM_CONTEXT = "qwen-sidecar-run-v1"
SIDECAR_GRANT_MAX_USES = 1
SIDECAR_GRANT_CHARACTER_CAP = 4096
SIDECAR_GRANT_LIFETIME_MINIMUM_SECONDS = 60
SIDECAR_GRANT_LIFETIME_MAXIMUM_SECONDS = 3600
GENERATION_MAXIMUM = 2**31 - 1
COUNT_MAXIMUM = 2**31 - 1
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
PROFILE_ID_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
SCENE_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,63}$")

# The lanes this claim admits, keyed by service: the operation the protocol
# names, the count argument's protocol name, and the ledger's ceiling column.
LANES = {
    "physics": {"operation": "physics_simulate_rigid", "count_key": "steps", "ceiling_key": "max_steps"},
    "geometry": {"operation": "geometry_ray_query", "count_key": "rays", "ceiling_key": "max_rays"},
}

REQUEST_FIELDS = (
    "context",
    "service",
    "language_profile",
    "sidecar_profile",
    "runtime_sha256",
    "scene",
    "count",
    "count_ceiling",
    "conversation_generation",
)


def require_text(payload, key, pattern, label):
    value = payload.get(key)
    if not isinstance(value, str) or not pattern.match(value):
        raise server.InvalidArgument(f"{key} is no {label}")
    return value


def require_bounded_integer(payload, key, minimum, maximum):
    value = payload.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or not minimum <= value <= maximum:
        raise server.InvalidArgument(f"{key} is no integer in [{minimum}, {maximum}]")
    return value


def require_service(payload):
    value = payload.get("service")
    if value not in LANES:
        raise server.InvalidArgument("service is none of " + ", ".join(sorted(LANES)))
    return value


def arguments_digest(service, sidecar_profile, count):
    """One digest over the normalized argument object both sides rebuild."""
    lane = LANES[service]
    canonical = json.dumps(
        {"profile_id": sidecar_profile, lane["count_key"]: count, "operation": lane["operation"]},
        sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def parse_sidecar_request(payload):
    """Return the approved fields of one grant request, or refuse by name."""
    if not isinstance(payload, dict):
        raise server.InvalidArgument("the request body is not an object")
    unknown = sorted(name for name in payload if name not in REQUEST_FIELDS)
    if unknown:
        raise server.InvalidArgument(
            "the grant request carries a field outside the sidecar claim: " + ", ".join(unknown))
    if payload.get("context") != SIDECAR_CLAIM_CONTEXT:
        raise server.InvalidArgument(f"context is not {SIDECAR_CLAIM_CONTEXT}")
    service = require_service(payload)
    fields = {
        "context": SIDECAR_CLAIM_CONTEXT,
        "service": service,
        "language_profile": require_text(payload, "language_profile", PROFILE_ID_PATTERN, "profile id"),
        "sidecar_profile": require_text(payload, "sidecar_profile", PROFILE_ID_PATTERN, "profile id"),
        "runtime_sha256": require_text(payload, "runtime_sha256", DIGEST_PATTERN, "SHA-256"),
        "scene": require_text(payload, "scene", SCENE_PATTERN, "scene name"),
        "count": require_bounded_integer(payload, "count", 1, COUNT_MAXIMUM),
        "count_ceiling": require_bounded_integer(payload, "count_ceiling", 1, COUNT_MAXIMUM),
        "conversation_generation": require_bounded_integer(payload, "conversation_generation", 0, GENERATION_MAXIMUM),
    }
    if fields["count"] > fields["count_ceiling"]:
        raise server.InvalidArgument("count exceeds count_ceiling")
    return fields


def sidecar_claim(fields, issued_at, expiry, grant_id):
    lane = LANES[fields["service"]]
    return {
        "service": fields["service"],
        "operation": lane["operation"],
        "language_profile": fields["language_profile"],
        "sidecar_profile": fields["sidecar_profile"],
        "runtime_sha256": fields["runtime_sha256"],
        "scene": fields["scene"],
        "arguments_sha256": arguments_digest(fields["service"], fields["sidecar_profile"], fields["count"]),
        "count_ceiling": fields["count_ceiling"],
        "conversation_generation": fields["conversation_generation"],
        "issued_at": issued_at,
        "expiry": expiry,
        "grant_id": grant_id,
        "max_uses": SIDECAR_GRANT_MAX_USES,
    }


def resolve_lifetime(lifetime):
    try:
        seconds = int(lifetime)
    except (TypeError, ValueError):
        raise server.InvalidArgument("the sidecar grant lifetime is not an integer") from None
    if not SIDECAR_GRANT_LIFETIME_MINIMUM_SECONDS <= seconds <= SIDECAR_GRANT_LIFETIME_MAXIMUM_SECONDS:
        raise server.InvalidArgument(
            "the sidecar grant lifetime lies outside "
            f"[{SIDECAR_GRANT_LIFETIME_MINIMUM_SECONDS}, {SIDECAR_GRANT_LIFETIME_MAXIMUM_SECONDS}]: {seconds}")
    return seconds


def issue_sidecar_grant(token_key_file, fields, lifetime, now=None):
    issued_at = int(time.time() if now is None else now)
    claim = sidecar_claim(fields, issued_at, issued_at + resolve_lifetime(lifetime),
                          server.base64url_encode(os.urandom(server.GRANT_ID_BYTES)))
    signing_key = server.read_secret_file(token_key_file, "token signing")
    token = server.sign_claim(signing_key, SIDECAR_CLAIM_CONTEXT, claim)
    if len(token) > SIDECAR_GRANT_CHARACTER_CAP:
        raise server.InvalidArgument(
            f"the sidecar grant exceeds the {SIDECAR_GRANT_CHARACTER_CAP} character cap the tool argument admits")
    return token


def verify_sidecar_grant(signing_key, token, now):
    """Return the claim of a token whose signature verifies and whose term runs."""
    if not isinstance(token, str) or len(token) > SIDECAR_GRANT_CHARACTER_CAP:
        raise server.AuthorizationDenied("the grant is malformed")
    claim = server.verify_claim(signing_key, SIDECAR_CLAIM_CONTEXT, token, now, "grant")
    if claim.get("max_uses") != SIDECAR_GRANT_MAX_USES:
        raise server.AuthorizationDenied(f"the grant admits a use count other than {SIDECAR_GRANT_MAX_USES}")
    grant_id = claim.get("grant_id")
    if not isinstance(grant_id, str) or not server.GRANT_ID_PATTERN.match(grant_id):
        raise server.AuthorizationDenied("the grant carries no usable grant_id")
    if claim.get("service") not in LANES:
        raise server.AuthorizationDenied("the grant names no sidecar service")
    for key in ("runtime_sha256", "arguments_sha256"):
        digest = claim.get(key)
        if not isinstance(digest, str) or not DIGEST_PATTERN.match(digest):
            raise server.AuthorizationDenied(f"the grant carries no usable {key}")
    expiry = claim.get("expiry")
    if not isinstance(expiry, int) or isinstance(expiry, bool):
        raise server.AuthorizationDenied("the grant carries no integer expiry")
    return claim


def enforce_sidecar_authorization(claim, service, language_profile, sidecar_profile, runtime_sha256,
                                  scene, count):
    """Refuse a run whose arguments or executor leave the grant.

    Every identity field is compared for equality: the lane, the operation
    the lane names, both profiles, the runtime digest, and the scene. The
    count is compared twice, as a digest of the normalized arguments and as
    a bound against the ceiling the human read, so a count inside the
    ceiling with a rewritten profile still meets the digest mismatch.
    """
    if claim.get("service") != service:
        raise server.AuthorizationDenied("the grant names another sidecar service than the executing one")
    if claim.get("operation") != LANES[service]["operation"]:
        raise server.AuthorizationDenied("the grant names another operation than the lane runs")
    if claim.get("language_profile") != language_profile:
        raise server.AuthorizationDenied("the grant names another language profile than the serving one")
    if claim.get("sidecar_profile") != sidecar_profile:
        raise server.AuthorizationDenied("the grant names another sidecar profile than the serving one")
    if claim.get("runtime_sha256") != runtime_sha256:
        raise server.AuthorizationDenied("the grant names another runtime than the one that would run")
    if claim.get("scene") != scene:
        raise server.AuthorizationDenied("the grant names another scene than the profile runs")
    ceiling = claim.get("count_ceiling")
    if not isinstance(ceiling, int) or isinstance(ceiling, bool):
        raise server.AuthorizationDenied("the grant carries no integer count_ceiling")
    if not isinstance(count, int) or isinstance(count, bool) or count < 1:
        raise server.AuthorizationDenied("the run names no positive count")
    if count > ceiling:
        raise server.AuthorizationDenied("the run arguments leave the grant: count exceeds count_ceiling")
    if claim.get("arguments_sha256") != arguments_digest(service, sidecar_profile, count):
        raise server.AuthorizationDenied("the run arguments leave the grant: arguments differ")
    return claim
