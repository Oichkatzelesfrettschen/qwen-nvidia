"""Sign and validate the two coding-lane grants.

The coding lane spends two single-use approvals per job: a plan grant
(`qwen-code-plan-v1`) opens one job read-only over the exact instruction,
repository, and base commit a human saw, and an apply grant
(`qwen-code-apply-v1`) admits the one edit phase over the exact plan hash
that human reviewed, so the edit cannot silently depart from the reviewed
plan. Both claims are signed with the broker's token key over the same
`field=value` newline join `scripts/coding-agent-service.py` verifies, and
the service's spent-nonce ledger spends each once. The module lives beside
`image_grant` because `authorize-broker.py` imports both and the coding
MCP child never sees the key.
"""

import hashlib
import hmac
import pathlib
import secrets
import time

import server

PLAN_GRANT_FIELDS = [
    "action", "workspace_id", "repository_identity", "base_commit",
    "model_id", "profile_id", "instruction_sha256", "allowed_test_profile",
    "maximum_files_changed", "maximum_patch_bytes", "maximum_job_seconds",
    "conversation_generation", "expiry_epoch", "nonce",
]

APPLY_GRANT_FIELDS = [
    "action", "job_id", "plan_sha256", "instruction_sha256", "model_id",
    "profile_id", "conversation_generation", "expiry_epoch", "nonce",
]

COMMIT_HEX_LENGTH = 40
SHA256_HEX_LENGTH = 64


def require_field(payload, key):
    value = payload.get(key)
    if not isinstance(value, str) or not value:
        raise server.InvalidArgument(f"{key} must be a nonempty string")
    return value


def require_hex(payload, key, length):
    value = require_field(payload, key)
    if len(value) != length or any(c not in "0123456789abcdef"
                                   for c in value):
        raise server.InvalidArgument(
            f"{key} must be {length} lowercase hex characters")
    return value


def require_decimal(payload, key):
    value = require_field(payload, key)
    if not value.isdigit():
        raise server.InvalidArgument(f"{key} must be a decimal integer")
    return value


def parse_plan_request(payload):
    """Return the exact plan-grant fields a request names."""
    if not isinstance(payload, dict):
        raise server.InvalidArgument("the request body is not an object")
    fields = {}
    for key in ("workspace_id", "repository_identity", "model_id",
                "profile_id", "allowed_test_profile"):
        fields[key] = require_field(payload, key)
    fields["base_commit"] = require_hex(payload, "base_commit",
                                        COMMIT_HEX_LENGTH)
    fields["instruction_sha256"] = require_hex(payload, "instruction_sha256",
                                               SHA256_HEX_LENGTH)
    for key in ("maximum_files_changed", "maximum_patch_bytes",
                "maximum_job_seconds", "conversation_generation"):
        fields[key] = require_decimal(payload, key)
    return fields


def parse_apply_request(payload):
    """Return the exact apply-grant fields a request names."""
    if not isinstance(payload, dict):
        raise server.InvalidArgument("the request body is not an object")
    fields = {}
    for key in ("job_id", "model_id", "profile_id"):
        fields[key] = require_field(payload, key)
    fields["plan_sha256"] = require_hex(payload, "plan_sha256",
                                        SHA256_HEX_LENGTH)
    fields["instruction_sha256"] = require_hex(payload, "instruction_sha256",
                                               SHA256_HEX_LENGTH)
    fields["conversation_generation"] = require_decimal(
        payload, "conversation_generation")
    return fields


def sign_claim(token_key_file, claim, grant_fields):
    """Return the signature the coding-agent service verifies.

    The key bytes are stripped the way the service strips them, so one key
    file yields one signature on both sides.
    """
    key = pathlib.Path(token_key_file).read_bytes().strip()
    message = "\n".join("%s=%s" % (field, claim[field])
                        for field in grant_fields)
    return hmac.new(key, message.encode(), hashlib.sha256).hexdigest()


def issue_grant(token_key_file, action, fields, grant_fields, lifetime):
    claim = dict(fields)
    claim["action"] = action
    claim["expiry_epoch"] = str(time.time() + lifetime)
    claim["nonce"] = secrets.token_hex(16)
    signature = sign_claim(token_key_file, claim, grant_fields)
    return {"claim": claim, "signature": signature}


def issue_plan_grant(token_key_file, fields, lifetime):
    return issue_grant(token_key_file, "open_job", fields,
                       PLAN_GRANT_FIELDS, lifetime)


def issue_apply_grant(token_key_file, fields, lifetime):
    return issue_grant(token_key_file, "apply_patch", fields,
                       APPLY_GRANT_FIELDS, lifetime)
