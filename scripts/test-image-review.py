#!/usr/bin/env python3
"""Run scripts/image-review.py against a fake vision router and artifact listener.

One stub plays both listeners: `GET /artifacts/<sha256>.png` answers the PNG the
test hashed, and `POST /v1/chat/completions` answers whichever reply variant an
arm selected. The stub also enforces the property the design rests on rather
than describing it: a request carrying a `tools` key at all is answered with a
reply proposing a tool call, so the arm that would break the zero-tool rule
fails through the parser instead of passing unnoticed.

The control arms run here too: `--image-mode withheld` is read from the request
the stub recorded rather than from the module's own report, `--image-mode
swapped` is read from the base64 the second artifact's bytes encode to, and
`scripts/run-vision-review-control.sh` drives all four arms through this same
stub, so the arm order is proved by the image-part counts of four recorded
requests.

Exit status is non-zero on any failed assertion, and the passing arms print what
they proved.
"""

import base64
import csv
import hashlib
import http.server
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading

THIS_DIRECTORY = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "image_review", os.path.join(THIS_DIRECTORY, "image-review.py"))
image_review = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(image_review)

ONE_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
# A second artifact the swapped control sends in place of the reviewed one.
SWAP_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMB"
    "AQDJ/pLvAAAAAElFTkSuQmCC"
)
ARTIFACT_SHA256 = hashlib.sha256(ONE_PIXEL_PNG).hexdigest()
SWAP_SHA256 = hashlib.sha256(SWAP_PIXEL_PNG).hexdigest()
PROMPT_HASH = hashlib.sha256(b"a fox in a snowy field").hexdigest()
API_KEY = "test-review-key"
VISION_MODEL = "lfm25-vl-16b"
CONSTRAINTS = [
    ("subject_count", "exactly one fox is visible"),
    ("background_color", "the background is snow, and reads white"),
]
CONSTRAINT_NAMES = [name for name, _description in CONSTRAINTS]

PASSING_VERDICT = {
    "hard_constraints": [
        {"name": "subject_count", "status": "pass", "observation": "One fox stands in frame."},
        {"name": "background_color", "status": "pass", "observation": "The field reads white."},
    ],
    "composition_change_required": False,
    "prompt_delta": "",
    "regenerate": False,
}
REGENERATE_VERDICT = {
    "hard_constraints": [
        {"name": "subject_count", "status": "fail", "observation": "Two foxes stand in frame."},
        {"name": "background_color", "status": "pass", "observation": "The field reads white."},
    ],
    "composition_change_required": True,
    "prompt_delta": "a single fox, alone in the frame",
    "regenerate": True,
}
REGENERATE_WITHOUT_FAILURE = {
    "hard_constraints": PASSING_VERDICT["hard_constraints"],
    "composition_change_required": False,
    "prompt_delta": "a single fox",
    "regenerate": True,
}
PROSE_REPLY = (
    "The image shows one fox in a snowy field, and every hard constraint "
    "looks satisfied to me."
)


def verdict_text(verdict):
    return json.dumps(verdict)


def make_handler(state, reply, artifact_bytes=ONE_PIXEL_PNG, artifact_digest=None,
                 artifacts=None):
    """Play the artifact listener and the router for one arm.

    `reply` is either the assistant message dictionary the router answers with
    or a callable taking the request body, so an arm states the one reply shape
    it exercises. `artifacts` maps a route digest onto the bytes served there,
    which is what a swapped arm needs: two artifacts answer on one listener and
    each route still returns whichever bytes the arm placed behind it.
    """
    served = dict(artifacts or {})
    served.setdefault(artifact_digest or ARTIFACT_SHA256, artifact_bytes)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _send_json(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self):
            return self.headers.get("Authorization") == "Bearer " + API_KEY

        def do_GET(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
            if not self._authorized():
                with state["lock"]:
                    state["unauthorized_reads"] += 1
                self._send_json(401, {"error": "missing credential"})
                return
            for route_digest, route_bytes in served.items():
                if self.path == "/artifacts/{}.png".format(route_digest):
                    self.send_response(200)
                    self.send_header("Content-Type", "image/png")
                    self.send_header("Content-Length", str(len(route_bytes)))
                    self.end_headers()
                    self.wfile.write(route_bytes)
                    return
            self._send_json(404, {"error": "no such artifact"})

        def do_POST(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw.decode("utf-8"))
            with state["lock"]:
                state["chat_bodies"].append(body)
            if not self._authorized():
                self._send_json(401, {"error": "missing credential"})
                return
            if "tools" in body:
                # The review offers no executable surface. A request that
                # carried one would be answered by a model free to propose a
                # call, so the stub answers exactly that and the parser refuses.
                message = {"role": "assistant", "content": None, "tool_calls": [
                    {"id": "call_1", "type": "function",
                     "function": {"name": "web_search_exa", "arguments": "{}"}}]}
            else:
                message = reply(body) if callable(reply) else reply
            self._send_json(200, {"choices": [{"message": message, "finish_reason": "stop"}]})

    return Handler


def serve(handler):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, "http://127.0.0.1:{}".format(server.server_address[1])


def run_review(reply, constraints=None, artifact_bytes=ONE_PIXEL_PNG,
               artifact_digest=None, digest=None, prompt_hash=PROMPT_HASH,
               artifacts=None, image_mode="real", swap_digest=None, bindings=None):
    """Run one review against a stub answering `reply`, returning (record, error, state)."""
    state = {"lock": threading.Lock(), "chat_bodies": [], "unauthorized_reads": 0}
    server, thread, origin = serve(
        make_handler(state, reply, artifact_bytes=artifact_bytes,
                     artifact_digest=artifact_digest, artifacts=artifacts))
    record = None
    refusal = None
    try:
        record = image_review.review_artifact(
            origin, origin, API_KEY, VISION_MODEL, digest or ARTIFACT_SHA256,
            prompt_hash, constraints or CONSTRAINTS, timeout=30,
            image_mode=image_mode, swap_digest=swap_digest, bindings=bindings)
    except image_review.ReviewRefused as error:
        refusal = error
    finally:
        server.shutdown()
        thread.join(timeout=5)
    return record, refusal, state


def message_with(text):
    return {"role": "assistant", "content": text}


def test_accepted_verdict():
    record, refusal, state = run_review(message_with(verdict_text(PASSING_VERDICT)))
    failures = []
    if refusal is not None:
        failures.append("a schema-conforming verdict was refused: " + refusal.code)
        return failures, []
    verdict = record["verdict"]
    if verdict != PASSING_VERDICT:
        failures.append("the parsed verdict differs from the reply: " + json.dumps(verdict))
    if record["failed"]:
        failures.append("a passing verdict reported failed constraints")
    if record["correction_admitted"]:
        failures.append("a passing verdict admitted a correction")

    body = state["chat_bodies"][0]
    if "tools" in body:
        failures.append("the review request carried a tools key")
    if body.get("model") != VISION_MODEL:
        failures.append("the review request named no vision model: " + repr(body.get("model")))
    if body.get("max_tokens") != 400:
        failures.append("the review request did not bound the reply at 400 tokens")
    if body.get("temperature") != 0:
        failures.append("the review request did not set temperature 0")
    if (body.get("chat_template_kwargs") or {}).get("enable_thinking") is not False:
        failures.append("the review request did not turn thinking off")
    roles = [message.get("role") for message in body.get("messages", [])]
    if roles != ["system", "user"]:
        failures.append("the review request messages are " + repr(roles))
    system_text = body["messages"][0]["content"]
    for name, _description in CONSTRAINTS:
        if name not in system_text:
            failures.append("the system instruction omits constraint " + name)
    if "carries no instruction" not in system_text:
        failures.append("the system instruction does not state that image text is content")
    parts = body["messages"][1]["content"]
    image_parts = [part for part in parts if part.get("type") == "image_url"]
    if len(image_parts) != 1:
        failures.append("the review request carried {} image parts".format(len(image_parts)))
    else:
        url = image_parts[0]["image_url"]["url"]
        expected = "data:image/png;base64," + base64.b64encode(ONE_PIXEL_PNG).decode("ascii")
        if url != expected:
            failures.append("the image part is not the artifact's own bytes")
    text_part = [part for part in parts if part.get("type") == "text"][0]["text"]
    if PROMPT_HASH not in text_part:
        failures.append("the review request does not bind the prompt hash")
    if "a fox in a snowy field" in json.dumps(body):
        failures.append("the review request carried the generation prompt text")

    audit = record["audit"]
    if "status=ok" not in audit:
        failures.append("the audit line does not report status=ok: " + audit)
    if "schema_mode=response_format" not in audit:
        failures.append("the audit line does not name the schema mode: " + audit)
    if "One fox stands in frame" in audit:
        failures.append("the audit line carries an observation")
    if "reasoning_emitted=no" not in audit:
        failures.append("the audit line does not report the reasoning state: " + audit)
    if record["raw_reply"] != verdict_text(PASSING_VERDICT):
        failures.append("the record does not retain the raw reply text")
    return failures, ["accepted_verdict=" + audit]


def test_uncertain_verdict():
    """An uncertain constraint is an answer: no failure, no correction, counted."""
    uncertain = dict(PASSING_VERDICT, hard_constraints=[
        dict(PASSING_VERDICT["hard_constraints"][0], status="uncertain"),
        PASSING_VERDICT["hard_constraints"][1]], regenerate=True,
        prompt_delta="make the subject count visible")
    record, refusal, _state = run_review(message_with(verdict_text(uncertain)))
    failures = []
    if refusal is not None:
        return ["an uncertain verdict was refused: " + refusal.code], []
    if record["failed"]:
        failures.append("an uncertain constraint was reported as failed")
    if record["uncertain"] != ["subject_count"]:
        failures.append("the uncertain names are " + repr(record["uncertain"]))
    if record["correction_admitted"]:
        failures.append("an uncertain verdict admitted a correction")
    audit = record["audit"]
    for expected in ("uncertain=1", "uncertain_names=subject_count", "failed=0", "passed=1",
                     "correction_admitted=no"):
        if expected not in audit:
            failures.append("the audit line lacks " + expected + ": " + audit)
    return failures, ["uncertain_verdict=" + audit]


def test_bindings_are_recorded():
    """Every binding and the constraints digest reach the record and the audit line."""
    bindings = {"projector_sha256": "ab" * 32, "tuple_id": "lfm25-vl-450m-cuda-d65536-b2048-ub512"}
    record, refusal, _state = run_review(message_with(verdict_text(PASSING_VERDICT)), bindings=bindings)
    failures = []
    if refusal is not None:
        return ["a bound review was refused: " + refusal.code], []
    if record["bindings"] != bindings:
        failures.append("the record does not carry the bindings: " + json.dumps(record["bindings"]))
    expected_digest = hashlib.sha256(json.dumps(
        [[name, description] for name, description in CONSTRAINTS],
        separators=(",", ":")).encode("utf-8")).hexdigest()
    if record["constraints_sha256"] != expected_digest:
        failures.append("the constraints digest differs from the declaration's")
    audit = record["audit"]
    for expected in ("binding_projector_sha256=" + "ab" * 32, "binding_tuple_id=lfm25-vl-450m-cuda-d65536-b2048-ub512",
                     "constraints_sha256=" + expected_digest):
        if expected not in audit:
            failures.append("the audit line lacks " + expected)
    record, refusal, _state = run_review(message_with(PROSE_REPLY), bindings=bindings)
    if refusal is None or "binding_tuple_id=" not in getattr(refusal, "audit", ""):
        failures.append("a refused review's audit line drops the bindings")
    return failures, ["bindings=" + ",".join(sorted(bindings))]


def test_response_format_carries_bounded_schema():
    """The request bounds the reply through `response_format`, not `grammar`.

    `tools/server/server-common.cpp:1158-1160` refuses a request naming both
    `json_schema` and `grammar`, so a caller sends the constraint through one
    mechanism. `response_format.json_schema.schema` is the one this module
    reads at c2c62855c (containing f280b269), and the array bounds and the
    name enum come from the two declared constraints.
    """
    record, refusal, state = run_review(message_with(verdict_text(PASSING_VERDICT)))
    failures = []
    if refusal is not None:
        failures.append("a schema-bound request was refused: " + refusal.code)
        return failures, []
    body = state["chat_bodies"][0]
    if "grammar" in body:
        failures.append("the request named grammar beside response_format")
    if "json_schema" in body:
        failures.append("the request named a top-level json_schema beside response_format")
    response_format = body.get("response_format")
    if not isinstance(response_format, dict) or response_format.get("type") != "json_schema":
        failures.append("response_format.type is not json_schema: " + repr(response_format))
        return failures, []
    wrapper = response_format.get("json_schema")
    if not isinstance(wrapper, dict) or wrapper.get("name") != "image_review":
        failures.append("json_schema.name is not image_review: " + repr(wrapper))
        return failures, []
    schema = wrapper.get("schema")
    if not isinstance(schema, dict):
        failures.append("json_schema.schema is not an object")
        return failures, []
    if schema.get("additionalProperties") is not False:
        failures.append("the top-level schema admits additional properties")
    if sorted(schema.get("required", [])) != sorted(image_review.VERDICT_KEYS):
        failures.append("the top-level schema does not require the four verdict keys")
    constraints_schema = schema.get("properties", {}).get("hard_constraints", {})
    if constraints_schema.get("minItems") != len(CONSTRAINT_NAMES):
        failures.append("hard_constraints.minItems is not " + str(len(CONSTRAINT_NAMES)))
    if constraints_schema.get("maxItems") != len(CONSTRAINT_NAMES):
        failures.append("hard_constraints.maxItems is not " + str(len(CONSTRAINT_NAMES)))
    item_schema = constraints_schema.get("items", {})
    name_enum = item_schema.get("properties", {}).get("name", {}).get("enum")
    if name_enum != CONSTRAINT_NAMES:
        failures.append("the constraint name enum is " + repr(name_enum))
    if item_schema.get("additionalProperties") is not False:
        failures.append("a constraint entry schema admits additional properties")
    if sorted(item_schema.get("required", [])) != sorted(image_review.CONSTRAINT_KEYS):
        failures.append("a constraint entry schema does not require name, passed, observation")
    return failures, ["response_format_schema=bound"]


def test_regenerate_verdict_admits_one_correction():
    record, refusal, _state = run_review(message_with(verdict_text(REGENERATE_VERDICT)))
    failures = []
    if refusal is not None:
        failures.append("the regenerate verdict was refused: " + refusal.code)
        return failures, []
    if record["failed"] != ["subject_count"]:
        failures.append("the failed constraint list is " + repr(record["failed"]))
    if not record["correction_admitted"]:
        failures.append("a named failure with a delta admitted no correction")
    if record["verdict"]["prompt_delta"] != REGENERATE_VERDICT["prompt_delta"]:
        failures.append("the prompt delta did not survive the parse")
    audit = record["audit"]
    if "correction_admitted=yes" not in audit or "failed_names=subject_count" not in audit:
        failures.append("the audit line does not report the admitted correction: " + audit)
    if REGENERATE_VERDICT["prompt_delta"] in audit:
        failures.append("the audit line carries the prompt delta text")
    delta_digest = hashlib.sha256(
        REGENERATE_VERDICT["prompt_delta"].encode("utf-8")).hexdigest()
    if "delta_sha256=" + delta_digest not in audit:
        failures.append("the audit line does not carry the delta digest: " + audit)
    return failures, ["regenerate_verdict=" + audit]


def test_regenerate_without_a_named_failure_is_not_admitted():
    record, refusal, _state = run_review(message_with(verdict_text(REGENERATE_WITHOUT_FAILURE)))
    failures = []
    if refusal is not None:
        failures.append("the verdict was refused rather than parsed: " + refusal.code)
        return failures, []
    if record["correction_admitted"]:
        failures.append("a regenerate flag with every constraint passing admitted a correction")
    if "every hard constraint passed" not in record["correction_reason"]:
        failures.append("the reason does not name the missing failure: "
                        + record["correction_reason"])
    return failures, ["regenerate_without_failure=" + record["correction_reason"]]


def refusal_arm(label, reply, expected_code, **kwargs):
    record, refusal, _state = run_review(reply, **kwargs)
    if refusal is None:
        return ["{} was accepted, verdict {}".format(label, json.dumps(record["verdict"]))], []
    if refusal.code != expected_code:
        return ["{} refused as {} rather than {}".format(label, refusal.code, expected_code)], []
    audit = getattr(refusal, "audit", "")
    if audit and "status=refused:" + expected_code not in audit:
        return ["{} audit line does not name the code: {}".format(label, audit)], []
    return [], ["{}={}".format(label, refusal.code)]


def test_refusals():
    failures = []
    lines = []
    arms = [
        ("prose_reply", message_with(PROSE_REPLY), "not_json", {}),
        ("fenced_reply",
         message_with("```json\n" + verdict_text(PASSING_VERDICT) + "\n```"),
         "not_json", {}),
        ("extra_key",
         message_with(verdict_text(dict(PASSING_VERDICT, confidence=0.9))),
         "extra_keys", {}),
        ("missing_key",
         message_with(verdict_text(
             {key: value for key, value in PASSING_VERDICT.items() if key != "regenerate"})),
         "missing_keys", {}),
        ("status_not_enum",
         message_with(verdict_text(dict(
             PASSING_VERDICT,
             hard_constraints=[
                 {"name": "subject_count", "status": "maybe", "observation": "One fox."},
                 {"name": "background_color", "status": "pass", "observation": "White."}]))),
         "status_not_enum", {}),
        ("status_boolean",
         message_with(verdict_text(dict(
             PASSING_VERDICT,
             hard_constraints=[
                 {"name": "subject_count", "status": True, "observation": "One fox."},
                 {"name": "background_color", "status": "pass", "observation": "White."}]))),
         "status_not_enum", {}),
        ("unnamed_constraint",
         message_with(verdict_text(dict(
             PASSING_VERDICT,
             hard_constraints=[
                 {"name": "subject_count", "status": "pass", "observation": "One fox."},
                 {"name": "lighting", "status": "pass", "observation": "Bright."}]))),
         "constraint_names", {}),
        ("duplicated_name",
         message_with(verdict_text(dict(
             PASSING_VERDICT,
             hard_constraints=[
                 {"name": "subject_count", "status": "pass", "observation": "One fox."},
                 {"name": "subject_count", "status": "pass", "observation": "Still one fox."}]))),
         "constraint_names", {}),
        ("constraint_count",
         message_with(verdict_text(dict(
             PASSING_VERDICT,
             hard_constraints=PASSING_VERDICT["hard_constraints"][:1]))),
         "constraint_count", {}),
        ("tool_calls_present",
         {"role": "assistant", "content": verdict_text(PASSING_VERDICT),
          "tool_calls": [{"id": "call_1", "type": "function",
                          "function": {"name": "generate_image", "arguments": "{}"}}]},
         "tool_calls_present", {}),
        ("empty_content", {"role": "assistant", "content": ""}, "empty_content", {}),
        ("artifact_digest_mismatch", message_with(verdict_text(PASSING_VERDICT)),
         "artifact_digest_mismatch",
         {"artifact_bytes": ONE_PIXEL_PNG + b"\x00", "artifact_digest": ARTIFACT_SHA256}),
        ("artifact_absent", message_with(verdict_text(PASSING_VERDICT)),
         "artifact_http_error", {"digest": "0" * 64}),
        ("bad_prompt_hash", message_with(verdict_text(PASSING_VERDICT)),
         "bad_prompt_hash", {"prompt_hash": "not-a-hash"}),
    ]
    for label, reply, code, kwargs in arms:
        arm_failures, arm_lines = refusal_arm(label, reply, code, **kwargs)
        failures.extend(arm_failures)
        lines.extend(arm_lines)
    return failures, lines


def test_raw_reply_retained_on_refusal():
    """A reply that fails the parser still leaves its raw text on the refusal.

    The grammar bounds a compliant model's tokens; a reply that reaches the
    parser malformed anyway -- prose, a duplicate name, an out-of-schema
    key -- is a finding about the served row, and `raw_reply` is what a later
    reader rereads to tell a fenced answer from a genuinely unbound one.
    """
    _record, refusal, _state = run_review(message_with(PROSE_REPLY))
    failures = []
    if refusal is None:
        failures.append("the prose reply was accepted rather than refused")
        return failures, []
    if getattr(refusal, "raw_reply", None) != PROSE_REPLY:
        failures.append("the refusal does not retain the raw reply text")
    return failures, ["raw_reply_on_refusal=retained"]


def test_a_tools_key_is_refused_through_the_reply():
    """The stub answers a tools-carrying request with a proposal the parser refuses.

    The module builds its own body, so this arm reaches the condition by calling
    post_review with a body the module would never compose, which proves the
    refusal path rather than the composer.
    """
    state = {"lock": threading.Lock(), "chat_bodies": [], "unauthorized_reads": 0}
    server, thread, origin = serve(
        make_handler(state, message_with(verdict_text(PASSING_VERDICT))))
    failures = []
    try:
        payload = image_review.build_review_request(
            VISION_MODEL, ONE_PIXEL_PNG, PROMPT_HASH, CONSTRAINTS)
        payload["tools"] = [{"type": "function", "function": {"name": "web_search_exa"}}]
        document = image_review.post_review(origin, API_KEY, payload, timeout=30)
        try:
            image_review.parse_verdict(document, CONSTRAINT_NAMES)
            failures.append("a reply proposing a tool call was accepted")
        except image_review.ReviewRefused as refusal:
            if refusal.code != "tool_calls_present":
                failures.append("the tool-call reply refused as " + refusal.code)
    finally:
        server.shutdown()
        thread.join(timeout=5)
    return failures, ["tools_key_reply=tool_calls_present"]


def test_the_artifact_read_carries_the_credential():
    state = {"lock": threading.Lock(), "chat_bodies": [], "unauthorized_reads": 0}
    server, thread, origin = serve(
        make_handler(state, message_with(verdict_text(PASSING_VERDICT))))
    failures = []
    try:
        try:
            image_review.fetch_artifact_png(origin, ARTIFACT_SHA256, "wrong-key", timeout=30)
            failures.append("an artifact read with the wrong credential succeeded")
        except image_review.ReviewRefused as refusal:
            if refusal.code != "artifact_http_error":
                failures.append("the uncredentialed read refused as " + refusal.code)
        body = image_review.fetch_artifact_png(origin, ARTIFACT_SHA256, API_KEY, timeout=30)
        if body != ONE_PIXEL_PNG:
            failures.append("the credentialed read returned other bytes")
    finally:
        server.shutdown()
        thread.join(timeout=5)
    if state["unauthorized_reads"] < 1:
        failures.append("the listener never saw an uncredentialed read")
    return failures, ["artifact_credential=required"]


BOTH_ARTIFACTS = {ARTIFACT_SHA256: ONE_PIXEL_PNG, SWAP_SHA256: SWAP_PIXEL_PNG}


def user_content(body):
    return body["messages"][1]["content"]


def test_withheld_control_drops_the_image_part_alone():
    """The withheld arm keeps the multipart text part and sends no image part.

    Image presence is the single changed request dimension, so the content stays
    a list and every other field of the request reads the same as the real arm's.
    """
    record, refusal, state = run_review(
        message_with(verdict_text(PASSING_VERDICT)), image_mode="withheld")
    failures = []
    if refusal is not None:
        failures.append("the withheld arm was refused: " + refusal.code)
        return failures, []
    body = state["chat_bodies"][0]
    content = user_content(body)
    if not isinstance(content, list):
        failures.append("the withheld arm collapsed the content to " + repr(type(content)))
        return failures, []
    if [part.get("type") for part in content] != ["text"]:
        failures.append("the withheld arm sent parts " + repr(
            [part.get("type") for part in content]))
    if PROMPT_HASH not in content[0]["text"]:
        failures.append("the withheld arm dropped the prompt hash with the image")
    if "tools" in body:
        failures.append("the withheld arm carried a tools key")
    if body.get("max_tokens") != 400 or body.get("temperature") != 0:
        failures.append("the withheld arm moved the reply budget or the temperature")
    if (body.get("chat_template_kwargs") or {}).get("enable_thinking") is not False:
        failures.append("the withheld arm did not turn thinking off")
    if record["image_mode"] != "withheld":
        failures.append("the record names image mode " + repr(record["image_mode"]))
    if "image_mode=withheld" not in record["audit"]:
        failures.append("the audit line does not name the image mode: " + record["audit"])
    if "swap_sha256=-" not in record["audit"]:
        failures.append("the withheld audit line names a swap artifact: " + record["audit"])
    return failures, ["withheld_control=" + record["audit"]]


def test_withheld_control_still_reads_the_reviewed_artifact():
    """A control arm meets `fetch_artifact_png`'s refusals the way a real arm does.

    The withheld request sends no pixels and the reviewed artifact is still read
    and hashed, so `artifact_sha256` stays a verified claim and a listener
    answering other bytes refuses the control rather than passing it.
    """
    return refusal_arm(
        "withheld_digest_mismatch", message_with(verdict_text(PASSING_VERDICT)),
        "artifact_digest_mismatch", image_mode="withheld",
        artifact_bytes=ONE_PIXEL_PNG + b"\x00", artifact_digest=ARTIFACT_SHA256)


def test_swapped_control_sends_the_second_artifact():
    record, refusal, state = run_review(
        message_with(verdict_text(PASSING_VERDICT)), artifacts=BOTH_ARTIFACTS,
        image_mode="swapped", swap_digest=SWAP_SHA256)
    failures = []
    if refusal is not None:
        failures.append("the swapped arm was refused: " + refusal.code)
        return failures, []
    content = user_content(state["chat_bodies"][0])
    image_parts = [part for part in content if part.get("type") == "image_url"]
    if len(image_parts) != 1:
        failures.append("the swapped arm sent {} image parts".format(len(image_parts)))
        return failures, []
    expected = "data:image/png;base64," + base64.b64encode(SWAP_PIXEL_PNG).decode("ascii")
    if image_parts[0]["image_url"]["url"] != expected:
        failures.append("the swapped arm sent bytes other than the swap artifact's")
    if record["artifact_sha256"] != ARTIFACT_SHA256:
        failures.append("the swapped record names artifact " + record["artifact_sha256"])
    if record["swap_sha256"] != SWAP_SHA256:
        failures.append("the swapped record names swap " + repr(record["swap_sha256"]))
    if "image_mode=swapped" not in record["audit"]:
        failures.append("the audit line does not name the image mode: " + record["audit"])
    if "swap_sha256=" + SWAP_SHA256 not in record["audit"]:
        failures.append("the audit line does not name the swap artifact: " + record["audit"])
    return failures, ["swapped_control=" + record["audit"]]


def test_a_failed_swap_read_names_the_swap_artifact():
    """A listener serving A and refusing B refuses under a `swap_` code.

    Falsifier 4 of the control design reserves "a control arm refused where the
    real arm parsed" for the model, so a listener fault reaches the audit line
    under a code that names which artifact failed its read.
    """
    _record, refusal, _state = run_review(
        message_with(verdict_text(PASSING_VERDICT)),
        artifacts={ARTIFACT_SHA256: ONE_PIXEL_PNG}, image_mode="swapped",
        swap_digest=SWAP_SHA256)
    failures = []
    if refusal is None:
        failures.append("an absent swap artifact was accepted")
        return failures, []
    if refusal.code != "swap_artifact_http_error":
        failures.append("the absent swap artifact refused as " + refusal.code)
    if SWAP_SHA256 not in refusal.message:
        failures.append("the refusal does not name the swap artifact: " + refusal.message)
    return failures, ["swap_read_failure=" + refusal.code]


def test_prompt_cache_is_stated_by_the_caller():
    """`cache_prompt` is a request field rather than the server's default.

    A control run sends it false on every arm, because the four requests share
    the text part ahead of the image part and a warm prefix moves an answer on
    this backend rather than only its timing.
    """
    failures = []
    default_payload = image_review.build_review_request(
        VISION_MODEL, ONE_PIXEL_PNG, PROMPT_HASH, CONSTRAINTS)
    if default_payload.get("cache_prompt") is not True:
        failures.append("a single review does not keep the server's caching: "
                        + repr(default_payload.get("cache_prompt")))
    control_payload = image_review.build_review_request(
        VISION_MODEL, ONE_PIXEL_PNG, PROMPT_HASH, CONSTRAINTS, cache_prompt=False)
    if control_payload.get("cache_prompt") is not False:
        failures.append("a control arm does not turn the prompt cache off")
    return failures, ["prompt_cache=stated"]


def test_image_mode_argument_refusals():
    """`--image-mode swapped` and `--swap-sha256` name each other, or argparse exits 2."""
    base = ["--router-origin", "http://127.0.0.1:1", "--artifact-origin",
            "http://127.0.0.1:1", "--model", VISION_MODEL, "--sha256", ARTIFACT_SHA256,
            "--prompt-hash", PROMPT_HASH, "--constraint", "subject_count=one fox"]
    arms = [
        ("swapped_without_swap_digest", base + ["--image-mode", "swapped"]),
        ("swap_digest_without_swapped_mode", base + ["--swap-sha256", SWAP_SHA256]),
        ("swap_digest_equals_reviewed",
         base + ["--image-mode", "swapped", "--swap-sha256", ARTIFACT_SHA256]),
        ("swap_digest_malformed",
         base + ["--image-mode", "swapped", "--swap-sha256", "not-a-digest"]),
        ("image_mode_unknown", base + ["--image-mode", "shuffled"]),
    ]
    failures = []
    lines = []
    stderr = sys.stderr
    for label, argv in arms:
        sys.stderr = open(os.devnull, "w")
        try:
            image_review.main(argv)
            failures.append(label + " was admitted rather than refused")
        except SystemExit as exit_status:
            if exit_status.code != 2:
                failures.append("{} exited {} rather than 2".format(label, exit_status.code))
            else:
                lines.append(label + "=exit_2")
        finally:
            sys.stderr.close()
            sys.stderr = stderr
    return failures, lines


def test_control_runner_drives_the_four_arms():
    """`scripts/run-vision-review-control.sh` runs real, withheld, swapped, real.

    The stub records every chat body, so the arm order is read from the image
    part counts the four requests carried rather than from the script's own
    report.
    """
    state = {"lock": threading.Lock(), "chat_bodies": [], "unauthorized_reads": 0}
    server, thread, origin = serve(
        make_handler(state, message_with(verdict_text(PASSING_VERDICT)),
                     artifacts=BOTH_ARTIFACTS))
    output_directory = tempfile.mkdtemp(prefix="vision-review-control-")
    failures = []
    lines = []
    try:
        completed = subprocess.run(
            ["sh", os.path.join(THIS_DIRECTORY, "run-vision-review-control.sh"),
             origin, origin, VISION_MODEL, ARTIFACT_SHA256, SWAP_SHA256, PROMPT_HASH,
             output_directory,
             "--constraint", "subject_count=exactly one fox is visible",
             "--constraint", "background_color=the background is snow, and reads white"],
            env=dict(os.environ, QWEN_API_KEY=API_KEY),
            capture_output=True, text=True, timeout=180)
        if completed.returncode != 0:
            failures.append("the runner exited {}: {}".format(
                completed.returncode, completed.stderr.strip()))
        image_part_counts = [
            len([part for part in user_content(body) if part.get("type") == "image_url"])
            for body in state["chat_bodies"]]
        if image_part_counts != [1, 0, 1, 1]:
            failures.append("the arm image part counts are " + repr(image_part_counts))
        if len(state["chat_bodies"]) == 4:
            swapped_url = [part for part in user_content(state["chat_bodies"][2])
                           if part.get("type") == "image_url"][0]["image_url"]["url"]
            expected = "data:image/png;base64," + base64.b64encode(
                SWAP_PIXEL_PNG).decode("ascii")
            if swapped_url != expected:
                failures.append("the swapped arm did not send the swap artifact's bytes")
        with open(os.path.join(output_directory, "summary.tsv")) as handle:
            rows = list(csv.DictReader(handle, delimiter="\t"))
        if [row["arm"] for row in rows] != ["01-real", "02-withheld", "03-swapped",
                                            "04-real-closing"]:
            failures.append("the summary names arms " + repr([row["arm"] for row in rows]))
        if any(body.get("cache_prompt") is not False for body in state["chat_bodies"]):
            failures.append("an arm left the prompt cache on: " + repr(
                [body.get("cache_prompt") for body in state["chat_bodies"]]))
        if [row["image_mode"] for row in rows] != ["real", "withheld", "swapped", "real"]:
            failures.append("the summary names modes " + repr(
                [row["image_mode"] for row in rows]))
        if any(row["passed"] != "2" for row in rows):
            failures.append("a summary row reports passed " + repr(
                [row["passed"] for row in rows]))
        if any(row["regenerate"] != "no" for row in rows):
            failures.append("a summary row reports regenerate " + repr(
                [row["regenerate"] for row in rows]))
        if len(rows) != 4:
            failures.append("the summary holds {} arm rows".format(len(rows)))
        elif rows[2]["swap_sha256"] != SWAP_SHA256:
            failures.append("the swapped summary row names swap " + rows[2]["swap_sha256"])
        for row in rows:
            if row["exit_status"] != "0":
                failures.append("arm {} exited {}".format(row["arm"], row["exit_status"]))
        for arm in ("01-real", "02-withheld", "03-swapped", "04-real-closing"):
            verdict_path = os.path.join(output_directory, arm + ".verdict.json")
            if not os.path.exists(verdict_path):
                failures.append("arm {} wrote no verdict record".format(arm))
                continue
            with open(verdict_path) as handle:
                verdict_record = json.load(handle)
            if verdict_record["verdict"] != PASSING_VERDICT:
                failures.append("arm {} retained another verdict".format(arm))
        with open(os.path.join(output_directory, "audit.log")) as handle:
            audit_text = handle.read()
        if audit_text.count("status=ok") != 4:
            failures.append("the audit log holds " + repr(audit_text))
        lines.append("control_runner=four_arms")
    finally:
        server.shutdown()
        thread.join(timeout=5)
        shutil.rmtree(output_directory, ignore_errors=True)
    return failures, lines


def test_calibration_runner_reads_six_arms():
    """`scripts/run-vision-review-calibration.sh` reads pass, fail, and uncertain per arm.

    The stub answers from the pixels the request carried: A passes, B fails
    one constraint, and a request without an image is uncertain, so the six
    readings follow the arm design rather than a fixed verdict.
    """
    b_url = "data:image/png;base64," + base64.b64encode(SWAP_PIXEL_PNG).decode("ascii")

    def reply(body):
        images = [part["image_url"]["url"] for part in user_content(body) if part.get("type") == "image_url"]
        if not images:
            status = ["uncertain", "uncertain"]
        elif images[0] == b_url:
            status = ["fail", "pass"]
        else:
            status = ["pass", "pass"]
        verdict = dict(PASSING_VERDICT, hard_constraints=[
            dict(PASSING_VERDICT["hard_constraints"][0], status=status[0]),
            dict(PASSING_VERDICT["hard_constraints"][1], status=status[1])])
        return message_with(verdict_text(verdict))

    state = {"lock": threading.Lock(), "chat_bodies": [], "unauthorized_reads": 0}
    server, thread, origin = serve(make_handler(state, reply, artifacts=BOTH_ARTIFACTS))
    output_directory = tempfile.mkdtemp(prefix="vision-review-calibration-")
    failures = []
    lines = []
    try:
        completed = subprocess.run(
            ["sh", os.path.join(THIS_DIRECTORY, "run-vision-review-calibration.sh"),
             origin, origin, VISION_MODEL, ARTIFACT_SHA256, SWAP_SHA256, "0" * 64, PROMPT_HASH,
             output_directory, "--repeat", "2", "--binding", "tuple_id=fixture-tuple",
             "--constraint", "subject_count=exactly one fox is visible",
             "--constraint", "background_color=the background is snow, and reads white"],
            env=dict(os.environ, QWEN_API_KEY=API_KEY), capture_output=True, text=True, timeout=300)
        if completed.returncode != 0:
            failures.append("the runner exited {}: {}".format(completed.returncode, completed.stderr.strip()))
        with open(os.path.join(output_directory, "summary.tsv")) as handle:
            rows = list(csv.DictReader(handle, delimiter="\t"))
        readings = [(row["arm"], row["reading"]) for row in rows]
        expected = [("01-correct", "grounded_pass"), ("02-violating", "discriminated"),
                    ("03-withheld", "withheld_declined"), ("04-swapped", "follows_pixels"),
                    ("05-absent", "refused_as_expected"), ("06-correct-closing", "grounded_pass")] * 2
        if readings != expected:
            failures.append("the readings are " + repr(readings))
        if [row["uncertain"] for row in rows if row["arm"] == "03-withheld"] != ["2", "2"]:
            failures.append("the withheld arm did not count two uncertain constraints")
        if len(state["chat_bodies"]) != 10:
            failures.append("the stub saw {} chat bodies where ten arms reach the model".format(len(state["chat_bodies"])))
        summary_line = completed.stdout.strip().splitlines()[-1] if completed.stdout.strip() else ""
        for expected_field in ("vision_review_calibration=complete", "grounded_pass=2/2", "discriminated=2/2",
                               "ungrounded_pass=0/2", "follows_text=0/2", "refused_reads=2/2", "malformed_replies=0"):
            if expected_field not in summary_line:
                failures.append("the summary line lacks " + expected_field + ": " + summary_line)
        with open(os.path.join(output_directory, "1-01-correct.verdict.json")) as handle:
            record = json.load(handle)
        if record.get("bindings") != {"tuple_id": "fixture-tuple"}:
            failures.append("the arm record does not carry the binding")
        lines.append("calibration_runner=six_arms")
    finally:
        server.shutdown()
        thread.join(timeout=5)
        shutil.rmtree(output_directory, ignore_errors=True)
    return failures, lines


def test_declared_bounds():
    failures = []
    if image_review.REVIEW_TIMEOUT_SECONDS != 300:
        failures.append("the review timeout is not 300 s")
    if image_review.REVIEW_MAX_TOKENS != 400:
        failures.append("the review reply budget is not 400 tokens")
    if image_review.IMAGE_MODES != ("real", "withheld", "swapped"):
        failures.append("the image modes are " + repr(image_review.IMAGE_MODES))
    try:
        image_review.validate_constraints([])
        failures.append("a review with no declared constraint was admitted")
    except SystemExit:
        pass
    try:
        image_review.parse_constraint("Subject Count=one fox")
        failures.append("a constraint name outside the pattern was admitted")
    except SystemExit:
        pass
    name, description = image_review.parse_constraint("subject_count=exactly one fox")
    if (name, description) != ("subject_count", "exactly one fox"):
        failures.append("a constraint declaration parsed to " + repr((name, description)))
    return failures, ["declared_bounds=timeout_300s,max_tokens_400,image_modes_3"]


def main():
    arms = [
        ("accepted_verdict", test_accepted_verdict),
        ("uncertain_verdict", test_uncertain_verdict),
        ("bindings", test_bindings_are_recorded),
        ("response_format_schema", test_response_format_carries_bounded_schema),
        ("regenerate_verdict", test_regenerate_verdict_admits_one_correction),
        ("regenerate_without_failure", test_regenerate_without_a_named_failure_is_not_admitted),
        ("refusals", test_refusals),
        ("withheld_control", test_withheld_control_drops_the_image_part_alone),
        ("withheld_artifact_read", test_withheld_control_still_reads_the_reviewed_artifact),
        ("swapped_control", test_swapped_control_sends_the_second_artifact),
        ("swap_read_failure", test_a_failed_swap_read_names_the_swap_artifact),
        ("prompt_cache", test_prompt_cache_is_stated_by_the_caller),
        ("image_mode_arguments", test_image_mode_argument_refusals),
        ("control_runner", test_control_runner_drives_the_four_arms),
        ("calibration_runner", test_calibration_runner_reads_six_arms),
        ("raw_reply_on_refusal", test_raw_reply_retained_on_refusal),
        ("tools_key", test_a_tools_key_is_refused_through_the_reply),
        ("artifact_credential", test_the_artifact_read_carries_the_credential),
        ("declared_bounds", test_declared_bounds),
    ]
    all_failures = []
    all_lines = []
    for label, arm in arms:
        failures, lines = arm()
        if failures:
            sys.stderr.write("test-image-review failures ({}):\n".format(label))
            for failure in failures:
                sys.stderr.write("  - " + failure + "\n")
        all_failures.extend(failures)
        all_lines.extend(lines)
    if all_failures:
        return 1
    for line in all_lines:
        sys.stdout.write(line + "\n")
    sys.stdout.write("image_review_tests=accepted\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
