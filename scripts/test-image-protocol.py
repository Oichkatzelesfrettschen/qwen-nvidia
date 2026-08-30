#!/usr/bin/env python3
"""Drive every refusal scripts/image_protocol.py states and the accepted shapes.

A checker that only ever meets correct messages passes on their correctness, so
each case below changes one field of a valid message and requires the named
refusal. The service and MCP lanes import the same module, so a rule proven here
is the rule those lanes obey.
"""

import sys

import image_protocol
from image_protocol import ProtocolError

FAILURES = []


def report(label, accepted, detail=""):
    print("%s=%s" % (label, "accepted" if accepted else "rejected"))
    if not accepted:
        FAILURES.append("%s %s" % (label, detail))


def expect_accepted(label, function, message):
    try:
        function(message)
    except ProtocolError as refusal:
        report(label, False, str(refusal))
        return
    report(label, True)


def expect_refused(label, function, message):
    try:
        function(message)
    except ProtocolError:
        report(label, True)
        return
    report(label, False, "the checker admitted a breaking message")


def generate_request(**overrides):
    message = {
        "protocol_version": 1,
        "request_id": "img-0001",
        "action": "image_generate",
        "profile_id": "image-sdxs-512-a",
        "prompt": "a red cube on a white table",
        "negative_prompt": "",
        "seed": 42,
        "aspect": "square",
        "width": 512,
        "height": 512,
        "steps": 1,
        "authorization": "grant-token-bytes",
    }
    message.update(overrides)
    for key, value in list(message.items()):
        if value is None:
            del message[key]
    return message


def completed_response(**overrides):
    digest = "a" * 64
    message = {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "completed",
        "sha256": digest,
        "provenance_url": "/artifacts/%s.json" % digest,
    }
    message.update(overrides)
    for key, value in list(message.items()):
        if value is None:
            del message[key]
    return message


validate_request = image_protocol.validate_request
validate_response = image_protocol.validate_response

expect_accepted("generate_request", validate_request, generate_request())
expect_accepted(
    "cancel_request",
    validate_request,
    {"protocol_version": 1, "request_id": "img-0001", "action": "cancel"},
)
expect_accepted(
    "status_request",
    validate_request,
    {"protocol_version": 1, "request_id": "img-0001", "action": "status"},
)

expect_refused("request_not_object", validate_request, ["image_generate"])
expect_refused(
    "request_wrong_version", validate_request, generate_request(protocol_version=2)
)
expect_refused(
    "request_boolean_version",
    validate_request,
    generate_request(protocol_version=True),
)
expect_refused(
    "request_unknown_field", validate_request, generate_request(model_path="/etc/passwd")
)
expect_refused("request_bad_action", validate_request, generate_request(action="render"))
expect_refused(
    "request_malformed_id", validate_request, generate_request(request_id="img 0001")
)
expect_refused(
    "request_empty_id", validate_request, generate_request(request_id="")
)
expect_refused("request_absent_seed", validate_request, generate_request(seed=None))
expect_refused("request_string_seed", validate_request, generate_request(seed="42"))
expect_refused("request_negative_seed", validate_request, generate_request(seed=-1))
expect_refused(
    "request_seed_above_range",
    validate_request,
    generate_request(seed=image_protocol.MAX_SEED + 1),
)
expect_refused(
    "request_absent_authorization",
    validate_request,
    generate_request(authorization=None),
)
expect_refused(
    "request_empty_authorization",
    validate_request,
    generate_request(authorization=""),
)
expect_refused(
    "request_absent_profile", validate_request, generate_request(profile_id=None)
)
expect_refused(
    "request_odd_dimension",
    validate_request,
    generate_request(width=500, height=500),
)
expect_refused(
    "request_dimension_above_range",
    validate_request,
    generate_request(width=4096, height=4096),
)
expect_refused(
    "request_steps_above_range", validate_request, generate_request(steps=1000)
)
expect_refused("request_zero_steps", validate_request, generate_request(steps=0))
expect_refused("request_bad_aspect", validate_request, generate_request(aspect="wide"))
expect_refused(
    "request_aspect_disagrees_with_dimensions",
    validate_request,
    generate_request(aspect="portrait"),
)
expect_accepted(
    "request_portrait_agrees",
    validate_request,
    generate_request(aspect="portrait", width=512, height=768),
)
expect_refused(
    "request_prompt_above_bound",
    validate_request,
    generate_request(prompt="x" * (image_protocol.MAX_PROMPT_CHARACTERS + 1)),
)
# A control message names a job. Carrying a geometry would let a cancel or a
# status arrive describing a run the grant never authorized.
expect_refused(
    "cancel_carries_geometry",
    validate_request,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "action": "cancel",
        "width": 512,
    },
)

expect_accepted("completed_response", validate_response, completed_response())
expect_accepted(
    "accepted_response",
    validate_response,
    {"protocol_version": 1, "request_id": "img-0001", "status": "accepted"},
)
# Every outcome that stops a generation names its term, so a reader routes on
# a fixed word where the message varies with the argument that produced it.
expect_accepted(
    "cancelled_response",
    validate_response,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "cancelled",
        "reason": "cancelled",
    },
)
expect_accepted(
    "refused_response",
    validate_response,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "refused",
        "reason": "profile_refused",
        "error": "the profile admits 512 and the grant named 1024",
    },
)
expect_accepted(
    "failed_response",
    validate_response,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "failed",
        "reason": "runtime_timeout",
        "error": "the runtime exceeded its 300 s bound",
    },
)
expect_refused(
    "refused_response_without_reason",
    validate_response,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "refused",
        "error": "the profile admits 512 and the grant named 1024",
    },
)
expect_refused(
    "completed_carries_reason",
    validate_response,
    completed_response(reason="profile_refused"),
)

# A status or cancel answer reports the service beside the frame, and those
# keys are a second named set rather than an opening for anything a sender
# adds: the same line is refused where the caller reads a plain response.
control_reply = {
    "protocol_version": 1,
    "request_id": "img-0001",
    "status": "accepted",
    "state": "running",
    "job_id": "0a1b2c3d",
    "job_request_id": "img-0001",
    "lease_held": True,
    "pid": 4321,
}
expect_accepted(
    "control_reply_carries_observations",
    lambda message: validate_response(message, control_reply=True),
    control_reply,
)
expect_refused(
    "control_observations_outside_a_control_reply",
    validate_response,
    control_reply,
)
expect_refused(
    "control_reply_unknown_observation",
    lambda message: validate_response(message, control_reply=True),
    dict(control_reply, artifact_path="/home/user/out.png"),
)

expect_refused(
    "response_bad_status", validate_response, completed_response(status="done")
)
expect_refused(
    "response_unknown_field",
    validate_response,
    completed_response(artifact_path="/home/user/out.png"),
)
expect_refused(
    "completed_without_digest", validate_response, completed_response(sha256=None)
)
expect_refused(
    "completed_short_digest", validate_response, completed_response(sha256="abc")
)
expect_refused(
    "completed_uppercase_digest",
    validate_response,
    completed_response(sha256="A" * 64, provenance_url="/artifacts/%s.json" % ("A" * 64)),
)
expect_refused(
    "completed_url_disagrees_with_digest",
    validate_response,
    completed_response(provenance_url="/artifacts/other.json"),
)
expect_refused(
    "completed_carries_error",
    validate_response,
    completed_response(error="it also failed"),
)
expect_refused(
    "failed_without_error",
    validate_response,
    {"protocol_version": 1, "request_id": "img-0001", "status": "failed"},
)
expect_refused(
    "failed_with_empty_error",
    validate_response,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "failed",
        "error": "",
    },
)
expect_refused(
    "failed_names_artifact",
    validate_response,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "failed",
        "error": "the runtime exited 1",
        "sha256": "b" * 64,
    },
)
expect_refused(
    "accepted_names_artifact",
    validate_response,
    {
        "protocol_version": 1,
        "request_id": "img-0001",
        "status": "accepted",
        "sha256": "b" * 64,
    },
)

# The line bound is measured in encoded bytes before the line is parsed, so an
# oversized line costs a length check rather than a parse.
line = image_protocol.encode_line(generate_request())
expect_accepted("round_trip_line", image_protocol.read_request, line)

oversized = '{"protocol_version":1,"pad":"' + "x" * image_protocol.MAX_LINE_BYTES + '"}'
try:
    image_protocol.decode_line(oversized)
    report("oversized_line", False, "the decoder admitted an oversized line")
except ProtocolError:
    report("oversized_line", True)

# A line exactly at the bound is admitted, which is what makes the refusal above
# a bound rather than an arbitrary limit.
padding = image_protocol.MAX_LINE_BYTES - len('{"pad":""}')
at_bound = '{"pad":"' + "x" * padding + '"}'
if len(at_bound.encode("utf-8")) != image_protocol.MAX_LINE_BYTES:
    report("line_bound_fixture", False, "the fixture is not exactly at the bound")
else:
    report("line_bound_fixture", True)
try:
    image_protocol.decode_line(at_bound)
    report("line_at_bound", True)
except ProtocolError as refusal:
    report("line_at_bound", False, str(refusal))

for label, payload in (
    ("embedded_newline", '{"a":1}\n{"b":2}'),
    ("not_json", "protocol_version=1"),
    ("not_an_object_line", "[1, 2, 3]"),
):
    if label == "not_an_object_line":
        try:
            image_protocol.validate_request(image_protocol.decode_line(payload))
            report(label, False, "the checker admitted a JSON array")
        except ProtocolError:
            report(label, True)
        continue
    try:
        image_protocol.decode_line(payload)
        report(label, False, "the decoder admitted a malformed line")
    except ProtocolError:
        report(label, True)

if FAILURES:
    print("image_protocol_checks=rejected failures=%d" % len(FAILURES), file=sys.stderr)
    for failure in FAILURES:
        print("  %s" % failure, file=sys.stderr)
    sys.exit(1)
print("image_protocol_checks=accepted")
