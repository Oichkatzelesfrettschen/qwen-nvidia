#!/usr/bin/env python3
"""Hold sidecar_grant.py to its claim: one lane, one operation, one argument set.

The arms: a physics request signs and verifies; the claim binds the lane's
operation, both profiles, the runtime digest, the scene, and a digest of the
normalized arguments; enforcement refuses a grant presented at the other
lane, under another profile, against another runtime or scene, with a count
over the ceiling, and with a count inside the ceiling that differs from the
approved one; a tampered token, an expired token, and a request carrying a
field outside the claim or a count over its ceiling each refuse by name.
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import server  # noqa: E402
import sidecar_grant as grant  # noqa: E402

RUNTIME = "ab" * 32


def request(**overrides):
    fields = {
        "context": grant.SIDECAR_CLAIM_CONTEXT,
        "service": "physics",
        "language_profile": "fast-text",
        "sidecar_profile": "physics-d6-chain-a",
        "runtime_sha256": RUNTIME,
        "scene": "d6-chain-4",
        "count": 600,
        "count_ceiling": 3600,
        "conversation_generation": 3,
    }
    fields.update(overrides)
    return fields


def expect(condition, message):
    if not condition:
        sys.exit("refused: " + message)
    print("accepted", message)


def refuses(callable_, exception, message):
    try:
        callable_()
    except exception:
        print("accepted", message)
        return
    sys.exit("refused: " + message + " (no refusal)")


def main():
    workspace = tempfile.mkdtemp(prefix="sidecar-grant-")
    key_path = os.path.join(workspace, "token.key")
    with open(key_path, "w") as handle:
        handle.write("k" * 48 + "\n")
    os.chmod(key_path, 0o600)
    signing_key = server.read_secret_file(key_path, "token signing")
    now = 1_700_000_000

    fields = grant.parse_sidecar_request(request())
    token = grant.issue_sidecar_grant(key_path, fields, 300, now=now)
    claim = grant.verify_sidecar_grant(signing_key, token, now + 10)
    expect(claim["operation"] == "physics_simulate_rigid" and claim["max_uses"] == 1, "a physics grant verifies with its operation")
    expect(claim["arguments_sha256"] == grant.arguments_digest("physics", "physics-d6-chain-a", 600),
           "the claim carries the normalized argument digest")

    def enforce(**kw):
        arguments = {"service": "physics", "language_profile": "fast-text", "sidecar_profile": "physics-d6-chain-a",
                     "runtime_sha256": RUNTIME, "scene": "d6-chain-4", "count": 600}
        arguments.update(kw)
        return grant.enforce_sidecar_authorization(claim, **arguments)

    expect(enforce() is claim, "the approved run passes enforcement")
    refuses(lambda: enforce(service="geometry"), server.AuthorizationDenied, "the other lane refuses the grant")
    refuses(lambda: enforce(language_profile="other"), server.AuthorizationDenied, "another language profile refuses")
    refuses(lambda: enforce(sidecar_profile="physics-d6-chain-b"), server.AuthorizationDenied, "another sidecar profile refuses")
    refuses(lambda: enforce(runtime_sha256="cd" * 32), server.AuthorizationDenied, "another runtime refuses")
    refuses(lambda: enforce(scene="cube-and-plane"), server.AuthorizationDenied, "another scene refuses")
    refuses(lambda: enforce(count=3601), server.AuthorizationDenied, "a count over the ceiling refuses")
    refuses(lambda: enforce(count=601), server.AuthorizationDenied, "a count inside the ceiling that differs refuses")

    geometry = grant.parse_sidecar_request(request(service="geometry", sidecar_profile="geometry-cube-orbit-a",
                                                   scene="cube-and-plane", count=4096, count_ceiling=1048576))
    geometry_token = grant.issue_sidecar_grant(key_path, geometry, 300, now=now)
    geometry_claim = grant.verify_sidecar_grant(signing_key, geometry_token, now + 10)
    expect(geometry_claim["operation"] == "geometry_ray_query", "a geometry grant names the ray query")
    refuses(lambda: grant.enforce_sidecar_authorization(geometry_claim, "physics", "fast-text", "geometry-cube-orbit-a",
                                                        RUNTIME, "cube-and-plane", 4096),
            server.AuthorizationDenied, "a geometry grant presented to physics refuses")

    tampered = token[:-2] + ("AA" if not token.endswith("AA") else "BB")
    refuses(lambda: grant.verify_sidecar_grant(signing_key, tampered, now + 10), server.AuthorizationDenied, "a tampered token refuses")
    refuses(lambda: grant.verify_sidecar_grant(signing_key, token, now + 301), server.ExpiredResult, "an expired token refuses")
    refuses(lambda: grant.parse_sidecar_request(request(seed=1)), server.InvalidArgument, "a field outside the claim refuses")
    refuses(lambda: grant.parse_sidecar_request(request(count=4000)), server.InvalidArgument, "a count over its ceiling refuses at parse")
    refuses(lambda: grant.parse_sidecar_request(request(service="image")), server.InvalidArgument, "an unknown service refuses")
    refuses(lambda: grant.issue_sidecar_grant(key_path, fields, 10, now=now), server.InvalidArgument, "a lifetime under the minimum refuses")
    print("sidecar_grant=accepted")


if __name__ == "__main__":
    main()
