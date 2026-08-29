"""Sign and verify the single generation one approval authorizes.

The image grant is a second claim context beside `search-authorization`:
`qwen-image-generate-v1` binds the language profile that ran the turn, the
image profile that executes it, the SHA-256 of the prompt and of the negative
prompt, the seed, the aspect ratio, the maximum pixel dimension and step count,
the conversation generation the approval belongs to, an expiry, and a
single-use nonce. `server.sign_claim` and `server.verify_claim` carry the HMAC
over that context string, so a search grant never verifies as a generation
grant and a generation grant never verifies as a search.

Both sides of the boundary reach the canonical claim through `image_claim`
here: `authorize-broker.py` builds it from the fields a human approved and
`image-mcp/server.py` rebuilds it from the arguments the model emitted. One
implementation of the normalization is what makes the field-by-field
comparison meaningful, the way `server.authorization_claim` serves the search
path; a second implementation would admit a spelling the serving path refuses.

The prompt reaches the claim as a digest the approving page computes, so the
grant travels through a model transcript and a broker audit row while the
approved text stays in the browser that displayed it. The comparison at
execution time is exact because both sides hash the stripped UTF-8 string:
`prompt_digest` here is the one normalization, and a page that hashed an
unstripped copy reaches a digest mismatch rather than a generation.
"""

import hashlib
import math
import os
import re
import sys
import time

MODULE_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
if MODULE_DIRECTORY not in sys.path:
    sys.path.insert(0, MODULE_DIRECTORY)

import server  # noqa: E402

IMAGE_CLAIM_CONTEXT = "qwen-image-generate-v1"
IMAGE_GRANT_MAX_USES = 1

PROFILE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
ASPECT_PATTERN = re.compile(r"^([1-9][0-9]{0,3}):([1-9][0-9]{0,3})$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")

PROMPT_CHARACTER_CAP = 2000
SEED_MAXIMUM = 2**64 - 1
DIMENSION_MINIMUM = 64
DIMENSION_MAXIMUM = 4096
STEP_MINIMUM = 1
STEP_MAXIMUM = 200
GENERATION_MAXIMUM = 2**31 - 1
IMAGE_GRANT_CHARACTER_CAP = 4096
IMAGE_GRANT_LIFETIME_DEFAULT_SECONDS = 900
IMAGE_GRANT_LIFETIME_MINIMUM_SECONDS = 60
IMAGE_GRANT_LIFETIME_MAXIMUM_SECONDS = 3600

REQUEST_FIELDS = (
    "context",
    "language_profile",
    "image_profile",
    "prompt_hash",
    "negative_prompt_hash",
    "seed",
    "aspect",
    "max_dimension",
    "max_steps",
    "conversation_generation",
)


def prompt_digest(text):
    """Return the SHA-256 of a prompt under the one spelling both sides hash.

    The string is stripped before hashing because a dialog renders trailing
    whitespace invisibly, so the human approves the stripped text and the
    execution path reaches the same digest from the model's own copy.
    """
    return hashlib.sha256(text.strip().encode("utf-8")).hexdigest()


def require_text(payload, key, required):
    value = payload.get(key)
    if value is None:
        value = ""
    if not isinstance(value, str):
        raise server.InvalidArgument(f"{key} must be a string")
    value = value.strip()
    if required and not value:
        raise server.InvalidArgument(f"{key} is required")
    if len(value) > PROMPT_CHARACTER_CAP:
        raise server.InvalidArgument(
            f"{key} exceeds the {PROMPT_CHARACTER_CAP} character cap"
        )
    return value


def require_digest(payload, key):
    """Return a SHA-256 hex digest a request states rather than a text it holds.

    The approving page hashes the prompt it displayed and posts the digest, so
    the approved text stays in the browser and the broker signs an identity.
    The execution path hashes the model's own copy through `prompt_digest` and
    compares, which requires both sides to hash the stripped UTF-8 string.
    """
    value = payload.get(key)
    if not isinstance(value, str) or not DIGEST_PATTERN.match(value.strip().lower()):
        raise server.InvalidArgument(
            f"{key} must be a SHA-256 digest in lowercase hexadecimal"
        )
    return value.strip().lower()


def require_context(payload, key):
    """Return the claim context a request names, refusing any other."""
    value = payload.get(key)
    if value != IMAGE_CLAIM_CONTEXT:
        raise server.InvalidArgument(
            f"{key} must name the {IMAGE_CLAIM_CONTEXT} claim"
        )
    return value


def require_profile_id(payload, key):
    value = payload.get(key)
    if not isinstance(value, str) or not PROFILE_ID_PATTERN.match(value):
        raise server.InvalidArgument(
            f"{key} must name a profile in [A-Za-z0-9][A-Za-z0-9._-]*"
        )
    return value


def require_bounded_integer(payload, key, minimum, maximum):
    """Return an integer field, refusing an absent one and refusing a bool.

    `bool` subclasses `int`, so `True` passes an `isinstance` test and reaches
    the claim as 1. The seed is where that matters: a caller sending `true`
    where a seed belongs would authorize generation 1 while the dialog
    displayed nothing. An explicit `is None` test rather than a truth test
    admits a seed of 0, which is a value a user picks.
    """
    value = payload.get(key)
    if value is None:
        raise server.InvalidArgument(f"{key} is required")
    if isinstance(value, bool) or not isinstance(value, int):
        raise server.InvalidArgument(f"{key} must be an integer")
    if value < minimum or value > maximum:
        raise server.InvalidArgument(
            f"{key} must lie between {minimum} and {maximum}"
        )
    return value


def canonical_aspect(width, height):
    """Return the reduced `W:H` form of one pixel geometry."""
    divisor = math.gcd(int(width), int(height))
    return f"{int(width) // divisor}:{int(height) // divisor}"


def require_aspect(payload, key):
    """Return an aspect ratio in its reduced form.

    `1024:1024` and `1:1` name one geometry, so the claim carries the reduced
    spelling and the execution path reduces the emitted width and height the
    same way before comparing. Without the reduction a grant approved as `1:1`
    would refuse the square image the model then requested in pixels.
    """
    value = payload.get(key)
    if not isinstance(value, str):
        raise server.InvalidArgument(f"{key} must be a string of the form W:H")
    matched = ASPECT_PATTERN.match(value.strip())
    if matched is None:
        raise server.InvalidArgument(
            f"{key} must be a string of the form W:H with positive terms"
        )
    return canonical_aspect(int(matched.group(1)), int(matched.group(2)))


def resolve_lifetime(lifetime):
    """Return an admitted grant lifetime in seconds.

    The range matches the search grant's: below 60 seconds an approval expires
    inside the turn that spends it, and above 3600 a token outlives the
    appliance session that issued it. A value outside the range refuses the
    request, since a clamp hides an operator's mistake behind a working grant.
    """
    try:
        seconds = int(lifetime)
    except (TypeError, ValueError):
        raise server.InvalidArgument(
            "the image grant lifetime is not an integer"
        ) from None
    if not (
        IMAGE_GRANT_LIFETIME_MINIMUM_SECONDS
        <= seconds
        <= IMAGE_GRANT_LIFETIME_MAXIMUM_SECONDS
    ):
        raise server.InvalidArgument(
            "the image grant lifetime lies outside "
            f"[{IMAGE_GRANT_LIFETIME_MINIMUM_SECONDS}, "
            f"{IMAGE_GRANT_LIFETIME_MAXIMUM_SECONDS}]: {seconds}"
        )
    return seconds


def parse_image_request(payload):
    """Return the exact fields an image grant request names.

    The seed is required and the broker generates none, so a request omitting
    it is refused here rather than completed with a value no human read. The
    field allowlist refuses an unknown key by name for the same reason the MCP
    schema does: a field the broker would drop silently is a field the dialog
    displayed and the grant then failed to bind.
    """
    if not isinstance(payload, dict):
        raise server.InvalidArgument("the request body is not an object")
    unknown = sorted(name for name in payload if name not in REQUEST_FIELDS)
    if unknown:
        raise server.InvalidArgument(
            "the grant request carries a field outside the image claim: "
            + ", ".join(unknown)
        )
    return {
        "context": require_context(payload, "context"),
        "language_profile": require_profile_id(payload, "language_profile"),
        "image_profile": require_profile_id(payload, "image_profile"),
        "prompt_hash": require_digest(payload, "prompt_hash"),
        "negative_prompt_hash": require_digest(payload, "negative_prompt_hash"),
        "seed": require_bounded_integer(payload, "seed", 0, SEED_MAXIMUM),
        "aspect": require_aspect(payload, "aspect"),
        "max_dimension": require_bounded_integer(
            payload, "max_dimension", DIMENSION_MINIMUM, DIMENSION_MAXIMUM
        ),
        "max_steps": require_bounded_integer(
            payload, "max_steps", STEP_MINIMUM, STEP_MAXIMUM
        ),
        "conversation_generation": require_bounded_integer(
            payload, "conversation_generation", 0, GENERATION_MAXIMUM
        ),
    }


def image_claim(fields, issued_at, expiry, grant_id):
    """Return the canonical claim one approval signs.

    The digests replace the prompt text, so the claim states which prompt was
    approved while the text stays out of every later request that re-sends the
    grant.

    `conversation_generation` is signed and compared by the user interface that
    approved it, since the MCP child reads a tool call and sees no conversation.
    The single-use nonce is what stops a replay inside the appliance; the
    generation states which conversation the approval belongs to, so a page
    that reset its transcript asks for a new approval rather than reusing the
    one on screen.
    """
    return {
        "language_profile": fields["language_profile"],
        "image_profile": fields["image_profile"],
        "prompt_hash": fields["prompt_hash"],
        "negative_prompt_hash": fields["negative_prompt_hash"],
        "seed": fields["seed"],
        "aspect": fields["aspect"],
        "max_dimension": fields["max_dimension"],
        "max_steps": fields["max_steps"],
        "conversation_generation": fields["conversation_generation"],
        "issued_at": issued_at,
        "expiry": expiry,
        "grant_id": grant_id,
        "max_uses": IMAGE_GRANT_MAX_USES,
    }


def issue_image_grant(token_key_file, fields, lifetime, now=None):
    """Return the signed grant for one exact generation.

    The signing key reaches `server.sign_claim` through
    `server.read_secret_file`, which applies the descriptor rules the search
    path applies, so the key stays out of every message and every return value.
    """
    issued_at = int(time.time() if now is None else now)
    claim = image_claim(
        fields,
        issued_at,
        issued_at + resolve_lifetime(lifetime),
        server.base64url_encode(os.urandom(server.GRANT_ID_BYTES)),
    )
    signing_key = server.read_secret_file(token_key_file, "token signing")
    token = server.sign_claim(signing_key, IMAGE_CLAIM_CONTEXT, claim)
    if len(token) > IMAGE_GRANT_CHARACTER_CAP:
        # A grant the tool argument refuses on length buys nothing, so the cap
        # is enforced where the grant is issued. The message states the cap
        # alone, which keeps the oversized token out of the broker response
        # and out of the audit row.
        raise server.InvalidArgument(
            f"the image grant exceeds the {IMAGE_GRANT_CHARACTER_CAP} "
            "character cap the tool argument admits"
        )
    return token


def verify_image_grant(signing_key, token, now):
    """Return the claim of a grant this key signed under the image context.

    `server.verify_claim` raises `AuthorizationDenied` on a tampered payload
    and `ExpiredResult` once the term runs out. The structural checks here are
    what a valid signature leaves open: a grant admitting a use count other
    than one, or carrying no ledger key, spends nothing the ledger enforces.
    """
    if not isinstance(token, str) or len(token) > IMAGE_GRANT_CHARACTER_CAP:
        raise server.AuthorizationDenied("the grant is malformed")
    claim = server.verify_claim(
        signing_key, IMAGE_CLAIM_CONTEXT, token, now, "grant"
    )
    if claim.get("max_uses") != IMAGE_GRANT_MAX_USES:
        raise server.AuthorizationDenied(
            f"the grant admits a use count other than {IMAGE_GRANT_MAX_USES}"
        )
    grant_id = claim.get("grant_id")
    if not isinstance(grant_id, str) or not server.GRANT_ID_PATTERN.match(grant_id):
        raise server.AuthorizationDenied("the grant carries no usable grant_id")
    for key in ("prompt_hash", "negative_prompt_hash"):
        digest = claim.get(key)
        if not isinstance(digest, str) or not DIGEST_PATTERN.match(digest):
            raise server.AuthorizationDenied(f"the grant carries no usable {key}")
    expiry = claim.get("expiry")
    if not isinstance(expiry, int) or isinstance(expiry, bool):
        raise server.AuthorizationDenied("the grant carries no integer expiry")
    return claim


def enforce_image_authorization(
    claim, language_profile, image_profile, arguments
):
    """Refuse a generation whose arguments leave the grant.

    The split follows `server.enforce_search_authorization`: the fields a human
    read are compared for equality and the fields a human capped are compared
    as bounds. Prompt, negative prompt, seed, and aspect form the equality
    half, so a note inside the conversation that rewrites the prompt after
    approval reaches a digest mismatch rather than the runtime. Width, height,
    and steps form the bound half at `<=`, so a request at exactly the approved
    maximum runs.
    """
    if claim.get("image_profile") != image_profile:
        raise server.AuthorizationDenied(
            "the grant names another image profile than the serving one"
        )
    if claim.get("language_profile") != language_profile:
        raise server.AuthorizationDenied(
            "the grant names another language profile than the serving one"
        )
    if arguments["profile_id"] != image_profile:
        raise server.AuthorizationDenied(
            "the call names another image profile than the serving one"
        )
    if claim.get("prompt_hash") != prompt_digest(arguments["prompt"]):
        raise server.AuthorizationDenied(
            "the generation arguments leave the grant: prompt differs"
        )
    if claim.get("negative_prompt_hash") != prompt_digest(
        arguments["negative_prompt"]
    ):
        raise server.AuthorizationDenied(
            "the generation arguments leave the grant: negative_prompt differs"
        )
    if claim.get("seed") != arguments["seed"]:
        raise server.AuthorizationDenied(
            "the generation arguments leave the grant: seed differs"
        )
    if claim.get("aspect") != canonical_aspect(
        arguments["width"], arguments["height"]
    ):
        raise server.AuthorizationDenied(
            "the generation arguments leave the grant: aspect differs"
        )
    for argument_key, claim_key in (
        ("width", "max_dimension"),
        ("height", "max_dimension"),
        ("steps", "max_steps"),
    ):
        bound = claim.get(claim_key)
        if not isinstance(bound, int) or isinstance(bound, bool):
            raise server.AuthorizationDenied(
                f"the grant carries no integer {claim_key}"
            )
        if arguments[argument_key] > bound:
            raise server.AuthorizationDenied(
                f"the generation arguments leave the grant: {argument_key} "
                f"exceeds {claim_key}"
            )
    return claim
