#!/usr/bin/env python3
"""Drive the served fallback page through one image-generation turn.

The Image half of PR D is the same one-human-approval discipline as the web
search tool, with its own grant context (qwen-image-generate-v1) and its own
synchronous state line. This test stands up one stub HTTP server that plays
every route the page touches -- the model roster, the tool listing, a
streamed chat completion that proposes image_generate_image, the broker's session
and grant-image routes, the executor's POST /tools, and the artifact PNG --
and drives the served page in headless Chromium over the DevTools protocol,
the way drive-fallback-page.py drives the web search turn. It reuses that
script's DevToolsSocket, wait_for, and fetch-recording helpers rather than
reimplementing browser plumbing a second time.

Exit status is non-zero on any assertion failure; a human-readable summary
of what passed is printed on success.
"""

import base64
import hashlib
import http.server
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

THIS_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(THIS_DIRECTORY))
FALLBACK_UI_PATH = os.path.join(REPO_ROOT, "webui", "index.html")

# A well-known minimal 1x1 transparent PNG, used as the served artifact body.
ONE_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
ARTIFACT_SHA256 = hashlib.sha256(ONE_PIXEL_PNG).hexdigest()
ARTIFACT_PATH = "/artifacts/{}.png".format(ARTIFACT_SHA256)
# image-service.py derives both routes from the digest: artifact_url names
# the PNG and provenance_url names the retained record. The page reads the
# record's identity out of the result and composes the image route itself,
# so the stub answers with the provenance route the service answers with.
PROVENANCE_PATH = "/artifacts/{}.json".format(ARTIFACT_SHA256)
API_KEY = "test-image-key"
GRANT_TOKEN = "grant-token-abc"
SESSION_SECRET = "session-secret-xyz"
# llama-server serves an MCP tool as `<server>_<tool>`: server_mcp_tool sets
# name = server_name + "_" + tool_name (tools/server/server-tools.cpp:1814) and
# the listing composes the same string (:2046), so the section's `image` server
# serves `generate_image` as `image_generate_image` and the page addresses it by
# that name. The stub composes it here once, the way the router does.
# The section serves one image profile, and scripts/image-mcp/server.py states
# it as the enum of `profile_id` with the maxima that profile admits, so the
# stub listing carries the same shape the child builds from its parameter file.
SERVED_IMAGE_PROFILE = "sdxs-512-arm-a"
SCHEMA_MAX_DIMENSION = 512
SCHEMA_MAX_STEPS = 4
DEFAULT_PROPOSAL = {
    "prompt": "a fox in a snowy field",
    "negative_prompt": "blurry, low quality",
    "width": 512,
    "height": 512,
    "steps": 4,
    "profile_id": SERVED_IMAGE_PROFILE,
}
# The proposal the appliance answered with a 900 second hang: a model reading an
# unbounded schema proposed another profile at another geometry.
OUT_OF_BOUNDS_PROPOSAL = {
    "prompt": "a fox in a snowy field",
    "seed": 42,
    "width": 1024,
    "height": 768,
    "steps": 30,
    "profile_id": "product_photography",
}
FOREIGN_PROFILE_PROPOSAL = {
    "prompt": "a fox in a snowy field",
    "negative_prompt": "blurry, low quality",
    "seed": 42,
    "width": 512,
    "height": 512,
    "steps": 4,
    "profile_id": "product_photography",
}
BROKER_REFUSAL = (
    "the broker process serves language profile fast-text; the request named "
    "image-test-profile"
)

# The review lane (PR F): a second roster row whose props report a vision
# modality, and the verdicts the fake vision model answers with. The page
# declares one constraint per approved prompt field, so a verdict names
# prompt_subject and negative_prompt_absent in that order.
VISION_MODEL = "qwen35-2b"

# The paired image preset's own roster order: a router lists `/v1/models`
# sorted, and 'l' precedes 'w', so a review-only vision section sorts ahead of
# the language section the way lfm25-vl-16b sorts ahead of web-image-admission
# in evidence/web-admission-router-tools.md. The review section carries no MCP
# configuration and answers `GET /tools` with 403 the way an ordinary model
# does; the language section answers 200 and offers the image tool.
PAIRED_REVIEW_MODEL = "lfm25-vl-16b"
PAIRED_LANGUAGE_MODEL = "web-image-admission"
PASSING_REVIEW_VERDICT = {
    "hard_constraints": [
        {"name": "prompt_subject", "status": "pass", "observation": "A fox stands in snow."},
        {"name": "negative_prompt_absent", "status": "pass", "observation": "The frame is sharp."},
    ],
    "composition_change_required": False,
    "prompt_delta": "",
    "regenerate": False,
}
REVIEW_PROMPT_DELTA = "a single fox, centred, alone in the frame"
REGENERATE_REVIEW_VERDICT = {
    "hard_constraints": [
        {"name": "prompt_subject", "status": "fail", "observation": "Two foxes share the frame."},
        {"name": "negative_prompt_absent", "status": "pass", "observation": "The frame is sharp."},
    ],
    "composition_change_required": True,
    "prompt_delta": REVIEW_PROMPT_DELTA,
    "regenerate": True,
}
REVIEW_PROSE_REPLY = (
    "The image looks like one fox in a snowy field, and I would leave it as it is."
)

IMAGE_MCP_SERVER_NAME = "image"
IMAGE_MCP_TOOL_NAME = "generate_image"
IMAGE_TOOL_NAME = "{}_{}".format(IMAGE_MCP_SERVER_NAME, IMAGE_MCP_TOOL_NAME)

# Load drive-fallback-page.py by path: its filename carries a hyphen, so it
# is not importable as a normal module.
_spec = importlib.util.spec_from_file_location(
    "drive_fallback_page", os.path.join(THIS_DIRECTORY, "drive-fallback-page.py"))
drive_fallback_page = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drive_fallback_page)


class RecordingState:
    def __init__(self):
        self.lock = threading.Lock()
        self.grant_image_bodies = []
        self.tools_post_bodies = []
        self.artifact_auth_headers = []
        self.review_bodies = []


def image_tool_listing():
    """Return the `GET /tools` row the router serves for the image child.

    `profile_id` carries the one-value enum and `width`, `height`, and `steps`
    carry the profile's own maxima, which is what scripts/image-mcp/server.py
    builds from the parameter file image-service.py enforces against. The page
    reads both out of this listing.
    """
    return [{
        "tool": IMAGE_TOOL_NAME,
        "definition": {
            "type": "function",
            "function": {
                "name": IMAGE_TOOL_NAME,
                "description": (
                    "Generate one image under the {} image profile, which renders "
                    "512x512 and admits at most {} pixels a side and {} sampler "
                    "steps.".format(
                        SERVED_IMAGE_PROFILE, SCHEMA_MAX_DIMENSION, SCHEMA_MAX_STEPS)
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "prompt": {"type": "string"},
                        "negative_prompt": {"type": "string"},
                        "width": {"type": "integer", "maximum": SCHEMA_MAX_DIMENSION,
                                   "default": 512},
                        "height": {"type": "integer", "maximum": SCHEMA_MAX_DIMENSION,
                                    "default": 512},
                        "steps": {"type": "integer", "maximum": SCHEMA_MAX_STEPS,
                                   "default": 1},
                        "profile_id": {"type": "string",
                                        "enum": [SERVED_IMAGE_PROFILE]},
                        "seed": {"type": "integer"},
                        "authorization": {"type": "string"},
                    },
                    "required": ["prompt", "profile_id", "width", "height", "steps"],
                },
            },
        },
    }]


def make_handler(state, proposal=None, grant_status=200, grant_error=None,
                 vision_model=None, review_replies=None):
    """Play the router, the broker, and the artifact listener for one turn.

    `proposal` is what the fixture model emits as the tool call arguments, and
    `grant_status` with `grant_error` is what the broker answers, so an arm
    states the one condition it exercises and shares every other route.
    `vision_model` adds a second roster row whose `GET /props` reports a vision
    modality, which is what makes the page offer a review at all, and
    `review_replies` is the sequence of assistant messages the router answers
    each review request with, the last one repeating.
    """
    proposed_arguments = DEFAULT_PROPOSAL if proposal is None else proposal
    fallback_html = open(FALLBACK_UI_PATH, "rb").read()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _send_json(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _read_json_body(self):
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b""
            return json.loads(raw.decode("utf-8")) if raw else {}

        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Access-Control-Allow-Methods", "*")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):  # noqa: N802
            parsed_path = self.path.split("?", 1)[0]
            if parsed_path in ("/", "/index.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(fallback_html)))
                self.end_headers()
                self.wfile.write(fallback_html)
                return
            if parsed_path == "/v1/models":
                roster = [{"id": "image-test-profile"}]
                if vision_model:
                    roster.append({"id": vision_model})
                self._send_json(200, {"data": roster})
                return
            if parsed_path == "/props":
                # llama-server reports the vision modality per served row, which
                # is the field scripts/compare-model-candidate.sh reads and the
                # one the page asks about before it offers a review.
                query = urllib.parse.parse_qs(
                    self.path.split("?", 1)[1] if "?" in self.path else "")
                asked = (query.get("model") or [""])[0]
                props = {"default_generation_settings": {"n_ctx": 4096}}
                if vision_model and asked == vision_model:
                    props["modalities"] = {"vision": True, "audio": False}
                self._send_json(200, props)
                return
            if parsed_path == "/tools":
                self._send_json(200, image_tool_listing())
                return
            if parsed_path == "/session":
                self._send_json(200, {"session_secret": SESSION_SECRET})
                return
            if parsed_path == ARTIFACT_PATH:
                auth = self.headers.get("Authorization", "")
                with state.lock:
                    state.artifact_auth_headers.append(auth)
                if auth != "Bearer " + API_KEY:
                    self._send_json(401, {"error": "missing or wrong credential"})
                    return
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(ONE_PIXEL_PNG)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(ONE_PIXEL_PNG)
                return
            self._send_json(404, {"error": "no route: " + self.path})

        def do_POST(self):  # noqa: N802
            parsed_path = self.path.split("?", 1)[0]
            if parsed_path == "/v1/chat/completions":
                request_body = self._read_json_body()
                if request_body.get("stream") is not True:
                    # A review is the one non-streamed completion this page
                    # sends, so the stub answers it from the arm's own script
                    # rather than from the tool-proposal path.
                    with state.lock:
                        index = len(state.review_bodies)
                        state.review_bodies.append(request_body)
                    replies = review_replies or [
                        {"role": "assistant", "content": json.dumps(PASSING_REVIEW_VERDICT)}]
                    message = replies[min(index, len(replies) - 1)]
                    self._send_json(
                        200, {"choices": [{"message": message, "finish_reason": "stop"}]})
                    return
                already_ran = any(
                    message.get("role") == "tool"
                    for message in request_body.get("messages", []))
                if already_ran:
                    # The model proposes the image tool exactly once; the
                    # continuation round after the tool result reads plain
                    # text with no further calls, so the turn ends the way an
                    # ordinary model turn would rather than the fixture
                    # re-proposing the same call every round.
                    chunks = [
                        {"choices": [{"delta": {"content": "Here is your fox."}}]},
                        {"choices": [{"delta": {}, "finish_reason": "stop"}],
                         "usage": {"completion_tokens": 4}},
                    ]
                else:
                    arguments = json.dumps(proposed_arguments)
                    chunks = [
                        {"choices": [{"delta": {"tool_calls": [{
                            "index": 0,
                            "function": {"name": IMAGE_TOOL_NAME, "arguments": arguments},
                        }]}}]},
                        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}],
                         "usage": {"completion_tokens": 1}},
                    ]
                body = b""
                for chunk in chunks:
                    body += ("data: " + json.dumps(chunk) + "\n\n").encode("utf-8")
                body += b"data: [DONE]\n\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed_path == "/grant-image":
                payload = self._read_json_body()
                with state.lock:
                    state.grant_image_bodies.append(payload)
                if self.headers.get("X-Qwen-Web-Session") != SESSION_SECRET:
                    self._send_json(403, {"error": "bad session"})
                    return
                if payload.get("context") != "qwen-image-generate-v1":
                    self._send_json(400, {"error": "wrong grant context"})
                    return
                if grant_status != 200:
                    self._send_json(grant_status, {"error": grant_error})
                    return
                self._send_json(200, {"authorization": GRANT_TOKEN})
                return
            if parsed_path == "/tools":
                payload = self._read_json_body()
                with state.lock:
                    state.tools_post_bodies.append(payload)
                if payload.get("tool") != IMAGE_TOOL_NAME:
                    self._send_json(200, {"error": "unknown tool"})
                    return
                params = payload.get("params") or {}
                if params.get("authorization") != GRANT_TOKEN:
                    self._send_json(200, {"error": "grant did not verify"})
                    return
                result = {
                    "status": "completed",
                    "sha256": ARTIFACT_SHA256,
                    "provenance_url": PROVENANCE_PATH,
                }
                self._send_json(200, {"plain_text_response": json.dumps(result)})
                return
            self._send_json(404, {"error": "no route: " + self.path})

    return Handler


# The finding this scenario reproduces: against the real qwen38-4b-distill,
# the model sometimes spends its whole reply budget on prose and proposes no
# tool call, so the approval dialog never opens and drive-fallback-page.py's
# wait_for() raises TimeoutError. The prose text is asserted for verbatim so
# the test fails if a future edit stops retaining the model's reply on that
# path.
PROSE_REPLY = (
    "I can describe a fox in a snowy field for you, but I have not called "
    "any tool to draw one."
)


def make_prose_handler():
    """Plays a router whose model never proposes the image tool.

    Serves the same page, roster, and tool listing as make_handler(), and
    answers every /v1/chat/completions call with plain text and
    finish_reason: stop -- no tool_calls delta -- so the page's approval
    dialog for the image lane never opens.
    """
    fallback_html = open(FALLBACK_UI_PATH, "rb").read()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _send_json(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Access-Control-Allow-Methods", "*")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):  # noqa: N802
            parsed_path = self.path.split("?", 1)[0]
            if parsed_path in ("/", "/index.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(fallback_html)))
                self.end_headers()
                self.wfile.write(fallback_html)
                return
            if parsed_path == "/v1/models":
                self._send_json(200, {"data": [{"id": "image-test-profile"}]})
                return
            if parsed_path == "/props":
                self._send_json(200, {"default_generation_settings": {"n_ctx": 4096}})
                return
            if parsed_path == "/tools":
                self._send_json(200, [{
                    "tool": IMAGE_TOOL_NAME,
                    "definition": {
                        "type": "function",
                        "function": {
                            "name": IMAGE_TOOL_NAME,
                            "description": "Generate one image.",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "prompt": {"type": "string"},
                                    "profile_id": {"type": "string"},
                                    "width": {"type": "integer"},
                                    "height": {"type": "integer"},
                                    "steps": {"type": "integer"},
                                },
                                "required": ["prompt", "profile_id", "width", "height", "steps"],
                            },
                        },
                    },
                }])
                return
            self._send_json(404, {"error": "no route: " + self.path})

        def do_POST(self):  # noqa: N802
            parsed_path = self.path.split("?", 1)[0]
            if parsed_path == "/v1/chat/completions":
                chunks = [
                    {"choices": [{"delta": {"content": PROSE_REPLY}}]},
                    {"choices": [{"delta": {}, "finish_reason": "stop"}],
                     "usage": {"completion_tokens": 24}},
                ]
                body = b""
                for chunk in chunks:
                    body += ("data: " + json.dumps(chunk) + "\n\n").encode("utf-8")
                body += b"data: [DONE]\n\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self._send_json(404, {"error": "no route: " + self.path})

    return Handler


def test_timeout_without_proposal():
    """Runs drive-fallback-page.py as admit-image-router.sh does: as a

    subprocess against a router that answers prose without a proposal, so
    the approval dialog never opens. Asserts the process exits non-zero, still
    writes a parseable JSON report on stdout, names the TimeoutError, and
    retains the model's prose reply in `history` rather than losing it to an
    uncaught traceback.
    """
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_prose_handler())
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = "http://127.0.0.1:{}".format(port)
    chromium = os.environ.get("QWEN_CHROMIUM", "chromium")
    driver = os.path.join(THIS_DIRECTORY, "drive-fallback-page.py")
    try:
        result = subprocess.run(
            [sys.executable, driver, "--origin", origin, "--prompt", "draw a fox",
             "--lane", "image", "--chromium", chromium,
             "--load-timeout", "30", "--dialog-timeout", "3", "--turn-timeout", "10"],
            capture_output=True, text=True, timeout=90)
    finally:
        server.shutdown()
        thread.join(timeout=5)

    failures = []
    if result.returncode == 0:
        failures.append(
            "drive-fallback-page.py exited 0 against a router that proposed no tool call")

    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        sys.stderr.write("test-fallback-page-image (timeout-without-proposal) stdout: "
                          + result.stdout[:2000] + "\n")
        sys.stderr.write("test-fallback-page-image (timeout-without-proposal) stderr: "
                          + result.stderr[:2000] + "\n")
        failures.append(
            "drive-fallback-page.py wrote no parseable JSON report on the dialog timeout")
        return failures

    error = report.get("error") or {}
    if error.get("type") != "TimeoutError":
        failures.append("report[\"error\"][\"type\"] was not TimeoutError: " + repr(error))
    if "dialog" not in report or report["dialog"] is not None:
        failures.append("report[\"dialog\"] was not null: " + repr(report.get("dialog")))

    assistant_messages = [m for m in (report.get("history") or []) if m.get("role") == "assistant"]
    if not assistant_messages:
        failures.append("the report retained no assistant message from the model's prose reply")
    else:
        last = assistant_messages[-1]
        if PROSE_REPLY not in (last.get("content") or ""):
            failures.append(
                "the retained assistant message did not carry the model's prose: "
                + repr(last.get("content")))
        if last.get("tool_calls"):
            failures.append(
                "the retained assistant message carried a tool call the fixture never proposed")
    return failures


def serve(handler):
    """Return a started stub server, its thread, and its origin."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, "http://127.0.0.1:{}".format(server.server_address[1])


class PageSession:
    """One headless Chromium holding the served page with the image lane armed.

    Every arm drives the same page through the same three steps -- load it,
    give it the credential and the artifact origin, arm the Image toggle and
    send one prompt -- and differs in what the stub answers and what the arm
    reads back, so the plumbing lives here and each arm states its own
    condition.
    """

    def __init__(self, origin):
        import urllib.parse

        self.origin = origin
        self.profile_directory = tempfile.mkdtemp(prefix="qwen-image-page-drive.")
        chromium = os.environ.get("QWEN_CHROMIUM", "chromium")
        command = [
            chromium, "--headless=new", "--no-sandbox", "--disable-gpu",
            "--no-first-run", "--remote-debugging-port=0",
            "--user-data-dir=" + self.profile_directory, "about:blank",
        ]
        self.browser_log = open(
            os.path.join(self.profile_directory, "chromium.log"), "w+b")
        self.browser = subprocess.Popen(
            command, stdout=subprocess.DEVNULL, stderr=self.browser_log)
        devtools = None
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and self.browser.poll() is None:
            self.browser_log.seek(0)
            match = re.search(
                r"DevTools listening on (ws://\S+)",
                self.browser_log.read().decode("utf-8", "replace"))
            if match:
                devtools = match.group(1)
                break
            time.sleep(0.2)
        if devtools is None:
            self.close()
            raise RuntimeError("Chromium printed no DevTools address")
        http_origin = re.match(r"ws://([^/]+)/", devtools).group(1)
        # The stub plays the router and the broker on one origin, so the page is
        # told to use it through ?broker=, the override qwen-webui-session.sh's
        # own operator uses.
        page_url = origin + "/?broker=" + urllib.parse.quote(origin, safe="")
        request = urllib.request.Request(
            "http://{}/json/new?{}".format(http_origin, page_url), method="PUT")
        with urllib.request.urlopen(request, timeout=30) as response:
            target = json.load(response)
        self.page = drive_fallback_page.DevToolsSocket(target["webSocketDebuggerUrl"])
        self.page.call("Page.enable")
        self.page.call("Runtime.enable")
        drive_fallback_page.wait_for(
            self.page,
            "document.readyState === 'complete' && typeof requestModel !== 'undefined'",
            30, "the page to load")
        self.evaluate(
            "(() => { document.querySelector('#api-key').value = " + json.dumps(API_KEY) +
            "; document.querySelector('#set-key').click(); return true; })()")
        # The stub serves the artifact routes on its own origin, and the real
        # listener binds an ephemeral port, so the page is told where it is the
        # way an operator tells it: through the field.
        self.evaluate(
            "(() => { document.querySelector('#artifact-origin').value = "
            + json.dumps(origin) + "; return true; })()")
        drive_fallback_page.wait_for(
            self.page, "requestModel", 30, "the page to select a model")
        self.evaluate(drive_fallback_page.FETCH_RECORDER)

    def evaluate(self, expression):
        return self.page.evaluate(expression)

    def wait_for(self, expression, seconds, what):
        return drive_fallback_page.wait_for(self.page, expression, seconds, what)

    def send(self, prompt):
        self.evaluate(
            "(() => { document.querySelector('#image-tools').checked = true; return true; })()")
        self.evaluate(
            "(() => { document.querySelector('#input').value = " + json.dumps(prompt) +
            "; document.querySelector('#send').click(); return true; })()")

    def dialog_fields(self):
        return self.evaluate(
            "(() => { const args = {}; document.querySelectorAll('#image-approval-args dt')"
            ".forEach(dt => { args[dt.textContent.trim()] = "
            "(dt.nextElementSibling || {}).textContent; }); return args; })()")

    def dialog_note(self):
        return self.evaluate(
            "(() => { const note = document.querySelector('#image-approval-note');"
            " return note.hidden ? null : note.textContent; })()")

    def approve(self):
        self.evaluate(
            "(() => { document.querySelector('#image-approve-once').click(); return true; })()")

    def image_state(self):
        return self.evaluate(
            "(() => (document.querySelector('.image-state') || {}).textContent || null)()")

    def cards(self):
        return self.evaluate(
            "document.querySelectorAll('figure.image-artifact').length")

    # The expressions below hold JavaScript braces, so they are composed by
    # concatenation: str.format would read `{ const` as a field.
    def card_expression(self, index):
        return "document.querySelectorAll('figure.image-artifact')[" + str(index) + "]"

    def wait_for_review_button(self, index):
        self.wait_for(
            "(() => { const card = " + self.card_expression(index) + "; "
            "return Boolean(card) && Boolean(card.querySelector('.image-review-button')) && "
            "!card.querySelector('.image-review-button').hidden; })()",
            30, "the review button on card " + str(index))

    def click_review(self, index):
        self.evaluate(
            "(() => { " + self.card_expression(index)
            + ".querySelector('.image-review-button').click(); return true; })()")

    def review_items(self, index):
        return self.evaluate(
            "(() => { const card = " + self.card_expression(index) + "; "
            "return [...card.querySelectorAll('.image-review li')].map(li => li.textContent); "
            "})()")

    def review_notes(self, index):
        return self.evaluate(
            "(() => { const card = " + self.card_expression(index) + "; "
            "return [...card.querySelectorAll('.image-review-note')].map(n => n.textContent); "
            "})()")

    def report(self):
        return json.loads(self.evaluate(
            "JSON.stringify({ history, requests: window.__qwenRequests, busy, "
            "imgSrc: (document.querySelector('.image-artifact img') || {}).src || null, "
            "caption: (document.querySelector('.image-artifact figcaption') || {}).textContent "
            "|| null, imageState: (document.querySelector('.image-state') || {}).textContent "
            "|| null })"))

    def close(self):
        self.browser_log.close()
        self.browser.terminate()
        try:
            self.browser.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.browser.kill()
        # Chromium's helper processes outlive the browser process by a few
        # hundred milliseconds and write into the profile while they exit, so
        # a single-pass removal races them and fails on a directory that is
        # empty a moment later. The removal retries until the tree is gone or
        # the bound is spent, and the last failure is the one raised.
        deadline = time.monotonic() + 10
        while True:
            shutil.rmtree(self.profile_directory, ignore_errors=True)
            if not os.path.exists(self.profile_directory):
                return
            if time.monotonic() > deadline:
                shutil.rmtree(self.profile_directory)
                return
            time.sleep(0.2)


def image_tool_messages(report):
    return [message for message in report.get("history", [])
            if message.get("role") == "tool" and message.get("name") == IMAGE_TOOL_NAME]


def test_full_authorization():
    state = RecordingState()
    server, thread, origin = serve(make_handler(state))
    session = None
    try:
        session = PageSession(origin)
        session.send("draw a fox")
        session.wait_for(
            "document.querySelector('#image-approval').open", 30,
            "the image approval dialog")
        dialog_fields = session.dialog_fields()
        state_after_approval = session.image_state()
        if state_after_approval is not None:
            raise AssertionError(
                "an image-state element exists before approval: "
                + repr(state_after_approval))
        session.approve()
        session.wait_for(
            "(() => { const el = document.querySelector('.image-state'); "
            "return el && el.textContent === 'Image complete'; })()",
            60, "the image generation to complete")
        session.wait_for("busy === false", 60, "the turn to end")
        report = session.report()
    finally:
        if session is not None:
            session.close()
        server.shutdown()
        thread.join(timeout=5)

    # ---- Assertions -------------------------------------------------------
    failures = []

    if "generated by this page" not in (dialog_fields.get("seed") or ""):
        failures.append("dialog did not name the generated seed: " + repr(dialog_fields.get("seed")))
    if dialog_fields.get("prompt") != "a fox in a snowy field":
        failures.append("dialog prompt field mismatch: " + repr(dialog_fields.get("prompt")))
    if dialog_fields.get("profile") != SERVED_IMAGE_PROFILE:
        failures.append("dialog profile field mismatch: " + repr(dialog_fields.get("profile")))

    with state.lock:
        grant_bodies = list(state.grant_image_bodies)
        tools_bodies = list(state.tools_post_bodies)
        artifact_headers = list(state.artifact_auth_headers)

    if len(grant_bodies) != 1:
        failures.append("expected exactly one POST /grant-image, saw {}".format(len(grant_bodies)))
    else:
        grant = grant_bodies[0]
        if grant.get("context") != "qwen-image-generate-v1":
            failures.append("grant did not carry the qwen-image-generate-v1 context: " + repr(grant))
        if not isinstance(grant.get("prompt_hash"), str) or len(grant["prompt_hash"]) != 64:
            failures.append("grant did not carry a SHA-256 prompt hash: " + repr(grant.get("prompt_hash")))
        if grant.get("aspect") != "1:1":
            failures.append("grant aspect was not derived from width and height: " + repr(grant))
        if grant.get("max_dimension") != 512:
            failures.append("grant max_dimension was not the larger side: " + repr(grant))
        if not isinstance(grant.get("seed"), int):
            failures.append("grant did not carry an integer seed: " + repr(grant.get("seed")))

    image_tool_calls = [body for body in tools_bodies if body.get("tool") == IMAGE_TOOL_NAME]
    if len(image_tool_calls) != 1:
        failures.append("expected exactly one POST /tools for " + IMAGE_TOOL_NAME + ", saw {}"
                         .format(len(image_tool_calls)))
    else:
        params = image_tool_calls[0].get("params") or {}
        if params.get("authorization") != GRANT_TOKEN:
            failures.append("the " + IMAGE_TOOL_NAME + " call did not carry the issued grant")
        if "prompt" not in params:
            failures.append("the " + IMAGE_TOOL_NAME + " call carried no prompt")
        # scripts/image-mcp/server.py names this argument profile_id, requires
        # it, and refuses any name outside its schema, so the page's own wire
        # spelling is checked here rather than only against a stub that would
        # accept either.
        if params.get("profile_id") != SERVED_IMAGE_PROFILE:
            failures.append("the " + IMAGE_TOOL_NAME + " call named no profile_id: " + repr(params.get("profile_id")))
        if "profile" in params:
            failures.append("the " + IMAGE_TOOL_NAME + " call carries a profile key the tool refuses by name")

    if "Bearer " + API_KEY not in artifact_headers:
        failures.append("the artifact fetch never carried the page's credential header")

    if not (report.get("imgSrc") or "").startswith("blob:"):
        failures.append("the artifact <img> did not resolve to a blob: URL: " + repr(report.get("imgSrc")))

    caption = report.get("caption") or ""
    if ARTIFACT_SHA256 not in caption:
        failures.append("the artifact card caption does not name the sha256")
    if "512x512" not in caption:
        failures.append("the artifact card caption does not name the dimensions")

    tool_messages = image_tool_messages(report)
    if len(tool_messages) != 1:
        failures.append("expected exactly one retained " + IMAGE_TOOL_NAME + " tool message, saw {}"
                         .format(len(tool_messages)))
    else:
        content = tool_messages[0].get("content", "")
        if ARTIFACT_SHA256 not in content:
            failures.append("the retained tool message does not name the sha256")
        if PROVENANCE_PATH not in content:
            failures.append("the retained tool message does not name the provenance URL")
        if GRANT_TOKEN in content:
            failures.append("the retained tool message carries the spent grant")
        if base64.b64encode(ONE_PIXEL_PNG).decode("ascii")[:16] in content:
            failures.append("the retained tool message carries image bytes")

    history_text = json.dumps(report.get("history", []))
    if GRANT_TOKEN in history_text:
        failures.append("the grant token reached the transcript somewhere")

    requests_to_grant_image = [r for r in report.get("requests", [])
                                if r.get("url", "").endswith("/grant-image")]
    if len(requests_to_grant_image) != 1:
        failures.append("expected exactly one browser fetch to /grant-image, saw {}"
                         .format(len(requests_to_grant_image)))

    if failures:
        sys.stderr.write("test-fallback-page-image failures (full-authorization):\n")
        for failure in failures:
            sys.stderr.write("  - " + failure + "\n")
        sys.stderr.write("report: " + json.dumps(report, indent=1) + "\n")
        return failures, []

    success_lines = [
        "fallback_page_image_authorization=accepted",
        "dialog_fields=" + json.dumps(dialog_fields),
        "grant_context=" + grant_bodies[0]["context"],
        "artifact_sha256=" + ARTIFACT_SHA256,
        "history_tool_message=" + tool_messages[0]["content"],
    ]
    return [], success_lines


def report_failures(label, failures):
    if failures:
        sys.stderr.write("test-fallback-page-image failures ({}):\n".format(label))
        for failure in failures:
            sys.stderr.write("  - " + failure + "\n")
    return failures


def test_out_of_bounds_proposal_refused_before_the_dialog():
    """A proposal above the schema's maxima is answered rather than approved.

    The dialog stays shut, the broker sees no request, and the model reads the
    bound it exceeded, so it may propose again inside the turn's remaining
    continuation rounds.
    """
    state = RecordingState()
    server, thread, origin = serve(
        make_handler(state, proposal=OUT_OF_BOUNDS_PROPOSAL))
    session = None
    try:
        session = PageSession(origin)
        session.send("draw a fox")
        session.wait_for("busy === false", 60, "the turn to end")
        dialog_open = session.evaluate(
            "document.querySelector('#image-approval').open")
        report = session.report()
    finally:
        if session is not None:
            session.close()
        server.shutdown()
        thread.join(timeout=5)

    failures = []
    if dialog_open:
        failures.append("the approval dialog opened for an out-of-bounds proposal")
    with state.lock:
        if state.grant_image_bodies:
            failures.append("a grant was requested for an out-of-bounds proposal")
        if state.tools_post_bodies:
            failures.append("a generation ran for an out-of-bounds proposal")
    tool_messages = image_tool_messages(report)
    if len(tool_messages) != 1:
        failures.append("expected one tool message naming the bound, saw {}".format(
            len(tool_messages)))
    else:
        content = tool_messages[0].get("content", "")
        if "width" not in content or str(SCHEMA_MAX_DIMENSION) not in content:
            failures.append("the tool message named no argument and no bound: " + repr(content))
    if report.get("busy") is not False:
        failures.append("the turn did not end: busy=" + repr(report.get("busy")))
    return report_failures("out-of-bounds-proposal", failures), [
        "out_of_bounds_refused_before_dialog=accepted",
        "out_of_bounds_tool_message=" + (
            image_tool_messages(report)[0]["content"] if image_tool_messages(report) else ""),
    ]


def test_foreign_profile_replaced_by_the_served_one():
    """The dialog and the grant name the profile the section serves.

    A model proposing another profile is shown its own value on the note line
    and the served value on the profile row, and the grant the broker signs
    carries the served profile, which is the one the broker is bound to.
    """
    state = RecordingState()
    server, thread, origin = serve(
        make_handler(state, proposal=FOREIGN_PROFILE_PROPOSAL))
    session = None
    try:
        session = PageSession(origin)
        session.send("draw a fox")
        session.wait_for(
            "document.querySelector('#image-approval').open", 30,
            "the image approval dialog")
        dialog_fields = session.dialog_fields()
        dialog_note = session.dialog_note()
        session.approve()
        session.wait_for("busy === false", 60, "the turn to end")
        report = session.report()
    finally:
        if session is not None:
            session.close()
        server.shutdown()
        thread.join(timeout=5)

    failures = []
    if dialog_fields.get("profile") != SERVED_IMAGE_PROFILE:
        failures.append("the dialog named a profile other than the served one: "
                         + repr(dialog_fields.get("profile")))
    if not dialog_note or "product_photography" not in dialog_note:
        failures.append("the dialog note did not name the proposed profile: " + repr(dialog_note))
    if not dialog_note or SERVED_IMAGE_PROFILE not in dialog_note:
        failures.append("the dialog note did not name the served profile: " + repr(dialog_note))
    with state.lock:
        grants = list(state.grant_image_bodies)
        tools_bodies = list(state.tools_post_bodies)
    if len(grants) != 1 or grants[0].get("image_profile") != SERVED_IMAGE_PROFILE:
        failures.append("the grant did not name the served image profile: " + repr(grants))
    calls = [body for body in tools_bodies if body.get("tool") == IMAGE_TOOL_NAME]
    if len(calls) != 1 or (calls[0].get("params") or {}).get("profile_id") != SERVED_IMAGE_PROFILE:
        failures.append("the generation did not name the served profile_id: " + repr(calls))
    if report.get("busy") is not False:
        failures.append("the turn did not end: busy=" + repr(report.get("busy")))
    return report_failures("foreign-profile", failures), [
        "foreign_profile_replaced=accepted",
        "dialog_note=" + repr(dialog_note),
    ]


def test_refused_grant_ends_the_turn():
    """A broker refusal after the approval reaches the model and ends the turn.

    The appliance held `busy` for 900 seconds here: the dialog caught the
    refusal, re-enabled its button, and settled nothing, so the model waited on
    a tool message that never arrived.
    """
    state = RecordingState()
    server, thread, origin = serve(
        make_handler(state, grant_status=400, grant_error=BROKER_REFUSAL))
    session = None
    try:
        session = PageSession(origin)
        session.send("draw a fox")
        session.wait_for(
            "document.querySelector('#image-approval').open", 30,
            "the image approval dialog")
        session.approve()
        session.wait_for("busy === false", 60, "the turn to end")
        dialog_open = session.evaluate("document.querySelector('#image-approval').open")
        report = session.report()
    finally:
        if session is not None:
            session.close()
        server.shutdown()
        thread.join(timeout=5)

    failures = []
    if dialog_open:
        failures.append("the approval dialog stayed open after the broker refused")
    if report.get("busy") is not False:
        failures.append("the turn did not end: busy=" + repr(report.get("busy")))
    tool_messages = image_tool_messages(report)
    if len(tool_messages) != 1:
        failures.append("expected one tool message naming the refusal, saw {}".format(
            len(tool_messages)))
    elif BROKER_REFUSAL not in tool_messages[0].get("content", ""):
        failures.append("the tool message did not carry the broker's reason: "
                         + repr(tool_messages[0].get("content")))
    image_state = report.get("imageState") or ""
    if not image_state.startswith("Image failed:"):
        failures.append("the image state did not read failed: " + repr(image_state))
    with state.lock:
        if state.tools_post_bodies:
            failures.append("a generation ran without a grant")
    return report_failures("refused-grant", failures), [
        "refused_grant_ends_turn=accepted",
        "refused_grant_tool_message=" + (
            tool_messages[0]["content"] if tool_messages else ""),
    ]


def prompt_digest(text):
    return hashlib.sha256(text.strip().encode("utf-8")).hexdigest()


def test_review_and_bounded_corrections():
    """One review, two approved corrections, and a third that proposes none.

    The verdict is rendered as a checklist on the card, each correction carries
    the first approval's seed with the review's delta appended to the prompt,
    and the third review reads the cap rather than opening a dialog. The
    counter travels on the card, so a correction's own review inherits it.
    """
    state = RecordingState()
    server, thread, origin = serve(make_handler(
        state, vision_model=VISION_MODEL,
        review_replies=[{"role": "assistant",
                         "content": json.dumps(REGENERATE_REVIEW_VERDICT)}]))
    session = None
    notes = []
    checklists = []
    try:
        session = PageSession(origin)
        session.send("draw a fox")
        session.wait_for(
            "document.querySelector('#image-approval').open", 30,
            "the image approval dialog")
        session.approve()
        session.wait_for(
            "(() => { const el = document.querySelector('.image-state'); "
            "return el && el.textContent === 'Image complete'; })()",
            60, "the image generation to complete")
        session.wait_for("busy === false", 60, "the turn to end")

        for correction in (1, 2):
            card_index = correction - 1
            session.wait_for_review_button(card_index)
            session.click_review(card_index)
            session.wait_for(
                "document.querySelector('#image-approval').open", 60,
                "the correction {} approval dialog".format(correction))
            checklists.append(session.review_items(card_index))
            notes.append(session.dialog_note())
            fields = session.dialog_fields()
            if "generated by this page" in (fields.get("seed") or ""):
                notes.append("correction {} regenerated the seed".format(correction))
            session.approve()
            session.wait_for(
                "document.querySelectorAll('figure.image-artifact').length === {}".format(
                    correction + 1),
                60, "the corrected artifact card {}".format(correction + 1))
            session.wait_for("busy === false", 60, "the review to return the page to idle")

        session.wait_for_review_button(2)
        session.click_review(2)
        session.wait_for(
            "(() => { const card = document.querySelectorAll('figure.image-artifact')[2]; "
            "return card.querySelectorAll('.image-review-note').length > 0; })()",
            60, "the capped review to report its reason")
        session.wait_for("busy === false", 60, "the third review to end")
        capped_notes = session.review_notes(2)
        capped_checklist = session.review_items(2)
        dialog_open_after_cap = session.evaluate(
            "document.querySelector('#image-approval').open")
        card_count = session.cards()
        report = session.report()
    finally:
        if session is not None:
            session.close()
        server.shutdown()
        thread.join(timeout=5)

    failures = []
    with state.lock:
        grants = list(state.grant_image_bodies)
        reviews = list(state.review_bodies)
        tool_calls = [body for body in state.tools_post_bodies
                      if body.get("tool") == IMAGE_TOOL_NAME]

    for index, checklist in enumerate(checklists):
        if len(checklist) != 2:
            failures.append("review {} rendered {} checklist rows".format(
                index + 1, len(checklist)))
        elif not checklist[0].startswith("fail prompt_subject"):
            failures.append("review {} did not render the failed constraint: {}".format(
                index + 1, checklist[0]))
    for correction, note in enumerate(notes, start=1):
        if "regenerated the seed" in (note or ""):
            failures.append(note)
        elif "correction {} of 2".format(correction) not in (note or ""):
            failures.append("correction {} dialog note reads {}".format(correction, note))

    if len(grants) != 3:
        failures.append("expected three grants, saw {}".format(len(grants)))
    else:
        seeds = {grant.get("seed") for grant in grants}
        if len(seeds) != 1:
            failures.append("the corrections did not carry the first seed: " + repr(seeds))
        expected_first = prompt_digest(DEFAULT_PROPOSAL["prompt"])
        if grants[0].get("prompt_hash") != expected_first:
            failures.append("the first grant hashed something other than the prompt")
        # Each correction composes on the prompt that produced the image it
        # reviewed, so the second correction carries the delta twice: the
        # review reads a corrected artifact and appends to the prompt behind
        # it rather than to the original.
        for index in (1, 2):
            expected = prompt_digest(
                DEFAULT_PROPOSAL["prompt"] + (" " + REVIEW_PROMPT_DELTA) * index)
            if grants[index].get("prompt_hash") != expected:
                failures.append(
                    "correction {} did not hash the prompt with the delta appended".format(index))

    if len(tool_calls) != 3:
        failures.append("expected three generations, saw {}".format(len(tool_calls)))
    else:
        for index in (1, 2):
            params = tool_calls[index].get("params") or {}
            composed = DEFAULT_PROPOSAL["prompt"] + (" " + REVIEW_PROMPT_DELTA) * index
            if params.get("prompt") != composed:
                failures.append("correction {} did not carry the composed prompt: {}".format(
                    index, params.get("prompt")))
            if params.get("seed") != (tool_calls[0].get("params") or {}).get("seed"):
                failures.append("correction {} did not carry the first seed".format(index))

    if len(reviews) != 3:
        failures.append("expected three review requests, saw {}".format(len(reviews)))
    for index, body in enumerate(reviews):
        if "tools" in body:
            failures.append("review {} carried a tools key".format(index + 1))
        if body.get("model") != VISION_MODEL:
            failures.append("review {} named model {}".format(index + 1, body.get("model")))
        if body.get("max_tokens") != 400:
            failures.append("review {} did not bound the reply at 400 tokens".format(index + 1))
        if (body.get("chat_template_kwargs") or {}).get("enable_thinking") is not False:
            failures.append("review {} did not turn thinking off".format(index + 1))
        parts = (body.get("messages") or [{}, {}])[1].get("content") or []
        images = [part for part in parts if part.get("type") == "image_url"]
        if len(images) != 1:
            failures.append("review {} carried {} image parts".format(index + 1, len(images)))
        elif not images[0]["image_url"]["url"].startswith("data:image/png;base64,"):
            failures.append("review {} sent no data URI".format(index + 1))

    if card_count != 3:
        failures.append("the run left {} artifact cards".format(card_count))
    if len(capped_checklist) != 2:
        failures.append("the capped review rendered no checklist")
    if not any("corrections for this request are spent" in note for note in capped_notes):
        failures.append("the capped review did not report the cap: " + repr(capped_notes))
    if dialog_open_after_cap:
        failures.append("the capped review opened an approval dialog")

    tool_messages = image_tool_messages(report)
    if len(tool_messages) != 1:
        failures.append("the reviews reached the transcript: {} tool messages".format(
            len(tool_messages)))
    history_text = json.dumps(report.get("history", []))
    if REVIEW_PROMPT_DELTA in history_text:
        failures.append("the review's prompt delta reached the transcript")
    if "Two foxes share the frame" in history_text:
        failures.append("a review observation reached the transcript")

    if failures:
        return report_failures("review-and-corrections", failures), []
    return [], [
        "review_checklist_rows=" + json.dumps(checklists[0]),
        "correction_notes=" + json.dumps(notes),
        "carried_seed=" + str(grants[0].get("seed")),
        "capped_note=" + json.dumps(capped_notes),
    ]


def test_review_refuses_a_prose_reply():
    """A vision model that answers prose leaves the card without a verdict.

    The page refuses the reply rather than reading a verdict out of it, so no
    correction is proposed and no dialog opens.
    """
    state = RecordingState()
    server, thread, origin = serve(make_handler(
        state, vision_model=VISION_MODEL,
        review_replies=[{"role": "assistant", "content": REVIEW_PROSE_REPLY}]))
    session = None
    try:
        session = PageSession(origin)
        session.send("draw a fox")
        session.wait_for(
            "document.querySelector('#image-approval').open", 30,
            "the image approval dialog")
        session.approve()
        session.wait_for(
            "(() => { const el = document.querySelector('.image-state'); "
            "return el && el.textContent === 'Image complete'; })()",
            60, "the image generation to complete")
        session.wait_for("busy === false", 60, "the turn to end")
        session.wait_for_review_button(0)
        session.click_review(0)
        session.wait_for(
            "(() => { const card = document.querySelector('figure.image-artifact'); "
            "return card.querySelectorAll('.image-review-note').length > 0; })()",
            60, "the refused review to report its reason")
        session.wait_for("busy === false", 60, "the review to return the page to idle")
        notes = session.review_notes(0)
        checklist = session.review_items(0)
        dialog_open = session.evaluate("document.querySelector('#image-approval').open")
        cards = session.cards()
    finally:
        if session is not None:
            session.close()
        server.shutdown()
        thread.join(timeout=5)

    failures = []
    if checklist:
        failures.append("a prose reply rendered a checklist: " + repr(checklist))
    if not any("did not complete" in note for note in notes):
        failures.append("the refusal was not reported on the card: " + repr(notes))
    if not any("not one JSON object" in note for note in notes):
        failures.append("the refusal did not name the rule: " + repr(notes))
    if dialog_open:
        failures.append("a refused review opened an approval dialog")
    if cards != 1:
        failures.append("a refused review produced {} cards".format(cards))
    with state.lock:
        grants = len(state.grant_image_bodies)
    if grants != 1:
        failures.append("a refused review signed {} grants".format(grants))
    if failures:
        return report_failures("review-prose-refusal", failures), []
    return [], ["review_prose_refusal=" + json.dumps(notes)]


def make_paired_roster_handler():
    """Play a router whose roster sorts the review row ahead of the language row.

    `GET /v1/models` returns [PAIRED_REVIEW_MODEL, PAIRED_LANGUAGE_MODEL], the
    order the real router's sort produces for the paired image preset. `GET
    /tools?model=` answers 403 for the review row and 200 for the language
    row, and `GET /props?model=` reports a vision modality for the review row
    alone, so the fixture states the same three facts
    evidence/web-admission-router-tools.md records for the paired preset. The
    language row's chat, grant, and tool-execution routes reuse the same
    proposal and credentials make_handler() plays, so a run that lands on it
    completes a whole generation.
    """
    fallback_html = open(FALLBACK_UI_PATH, "rb").read()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _send_json(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _read_json_body(self):
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b""
            return json.loads(raw.decode("utf-8")) if raw else {}

        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Access-Control-Allow-Methods", "*")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):  # noqa: N802
            parsed_path = self.path.split("?", 1)[0]
            if parsed_path in ("/", "/index.html"):
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(fallback_html)))
                self.end_headers()
                self.wfile.write(fallback_html)
                return
            if parsed_path == "/v1/models":
                self._send_json(200, {"data": [
                    {"id": PAIRED_REVIEW_MODEL}, {"id": PAIRED_LANGUAGE_MODEL}]})
                return
            query = urllib.parse.parse_qs(
                self.path.split("?", 1)[1] if "?" in self.path else "")
            asked = (query.get("model") or [""])[0]
            if parsed_path == "/props":
                props = {"default_generation_settings": {"n_ctx": 4096}}
                if asked == PAIRED_REVIEW_MODEL:
                    props["modalities"] = {"vision": True, "audio": False}
                self._send_json(200, props)
                return
            if parsed_path == "/tools":
                if asked == PAIRED_REVIEW_MODEL:
                    self._send_json(403, {"error": "feature_disabled"})
                else:
                    self._send_json(200, image_tool_listing())
                return
            if parsed_path == "/session":
                self._send_json(200, {"session_secret": SESSION_SECRET})
                return
            if parsed_path == ARTIFACT_PATH:
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(ONE_PIXEL_PNG)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(ONE_PIXEL_PNG)
                return
            self._send_json(404, {"error": "no route: " + self.path})

        def do_POST(self):  # noqa: N802
            parsed_path = self.path.split("?", 1)[0]
            if parsed_path == "/v1/chat/completions":
                request_body = self._read_json_body()
                already_ran = any(
                    message.get("role") == "tool"
                    for message in request_body.get("messages", []))
                # The review row's `GET /tools` answers 403, so the page's
                # own resolveImageTools() reads no image tool and composes
                # `body.tools` empty; a real router proposes no call outside
                # a schema it was never given, and this stub matches that
                # rather than proposing unconditionally the way make_handler()
                # does for a fixture with one servable row.
                if already_ran or not request_body.get("tools"):
                    chunks = [
                        {"choices": [{"delta": {"content": "Here is your fox."}}]},
                        {"choices": [{"delta": {}, "finish_reason": "stop"}],
                         "usage": {"completion_tokens": 4}},
                    ]
                else:
                    arguments = json.dumps(DEFAULT_PROPOSAL)
                    chunks = [
                        {"choices": [{"delta": {"tool_calls": [{
                            "index": 0,
                            "function": {"name": IMAGE_TOOL_NAME, "arguments": arguments},
                        }]}}]},
                        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}],
                         "usage": {"completion_tokens": 1}},
                    ]
                body = b""
                for chunk in chunks:
                    body += ("data: " + json.dumps(chunk) + "\n\n").encode("utf-8")
                body += b"data: [DONE]\n\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed_path == "/grant-image":
                payload = self._read_json_body()
                if self.headers.get("X-Qwen-Web-Session") != SESSION_SECRET:
                    self._send_json(403, {"error": "bad session"})
                    return
                self._send_json(200, {"authorization": GRANT_TOKEN})
                return
            if parsed_path == "/tools":
                payload = self._read_json_body()
                params = payload.get("params") or {}
                if params.get("authorization") != GRANT_TOKEN:
                    self._send_json(200, {"error": "grant did not verify"})
                    return
                result = {
                    "status": "completed",
                    "sha256": ARTIFACT_SHA256,
                    "provenance_url": PROVENANCE_PATH,
                }
                self._send_json(200, {"plain_text_response": json.dumps(result)})
                return
            self._send_json(404, {"error": "no route: " + self.path})

    return Handler


def test_paired_roster_default_and_explicit_selection():
    """Against a roster that sorts the review row first, prove two facts:

    the page's own default lands on the language row (webui/index.html's
    `boot()` probes `GET /tools` per roster row and prefers the first one that
    answers 200 over the first one in sort order), and drive-fallback-page.py's
    `--model` argument selects a named row through the picker regardless of
    which one the page would have defaulted to -- the mechanism
    scripts/admit-image-router.sh relies on to send its turn to the language
    profile it already knows by id. A third arm names a roster id the picker
    carries no option for and requires the driver to refuse the step by name
    rather than silently sending the turn to whatever the page selected.
    """
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_paired_roster_handler())
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = "http://127.0.0.1:{}".format(port)
    chromium = os.environ.get("QWEN_CHROMIUM", "chromium")
    driver = os.path.join(THIS_DIRECTORY, "drive-fallback-page.py")
    failures = []
    try:
        default_run = subprocess.run(
            [sys.executable, driver, "--origin", origin, "--prompt", "draw a fox",
             "--lane", "image", "--chromium", chromium, "--artifacts", origin,
             "--load-timeout", "30", "--dialog-timeout", "30", "--turn-timeout", "60"],
            capture_output=True, text=True, timeout=120)
        try:
            default_report = json.loads(default_run.stdout)
        except json.JSONDecodeError:
            sys.stderr.write("test-fallback-page-image (paired-roster-default) stdout: "
                              + default_run.stdout[:2000] + "\n")
            sys.stderr.write("test-fallback-page-image (paired-roster-default) stderr: "
                              + default_run.stderr[:2000] + "\n")
            return ["drive-fallback-page.py wrote no parseable JSON report on the default run"]
        if default_report.get("selected_model_at_load") != PAIRED_LANGUAGE_MODEL:
            failures.append(
                "the page's own default selected {} rather than the language row {}".format(
                    default_report.get("selected_model_at_load"), PAIRED_LANGUAGE_MODEL))
        if default_run.returncode != 0:
            failures.append(
                "drive-fallback-page.py exited {} against the paired roster's own default: {}"
                .format(default_run.returncode, default_report.get("error")))

        explicit_run = subprocess.run(
            [sys.executable, driver, "--origin", origin, "--prompt", "draw a fox",
             "--lane", "image", "--chromium", chromium, "--artifacts", origin,
             "--model", PAIRED_REVIEW_MODEL,
             "--load-timeout", "30", "--dialog-timeout", "5", "--turn-timeout", "10"],
            capture_output=True, text=True, timeout=60)
        try:
            explicit_report = json.loads(explicit_run.stdout)
        except json.JSONDecodeError:
            sys.stderr.write("test-fallback-page-image (paired-roster-explicit) stdout: "
                              + explicit_run.stdout[:2000] + "\n")
            sys.stderr.write("test-fallback-page-image (paired-roster-explicit) stderr: "
                              + explicit_run.stderr[:2000] + "\n")
            failures.append(
                "drive-fallback-page.py wrote no parseable JSON report on the explicit run")
        else:
            if explicit_report.get("selected_model_at_load") != PAIRED_REVIEW_MODEL:
                failures.append(
                    "--model {} did not hold: selected_model_at_load reads {}".format(
                        PAIRED_REVIEW_MODEL, explicit_report.get("selected_model_at_load")))
            # The review row offers no tool, so the toggle and send leave no
            # dialog to open; the driver's own dialog-timeout ends the turn,
            # which proves the selection reached the page rather than the run
            # completing a generation through it.
            if (explicit_report.get("error") or {}).get("type") != "TimeoutError":
                failures.append(
                    "the review row unexpectedly completed a turn: " +
                    repr(explicit_report.get("error")))

        refused_run = subprocess.run(
            [sys.executable, driver, "--origin", origin, "--prompt", "draw a fox",
             "--lane", "image", "--chromium", chromium, "--artifacts", origin,
             "--model", "not-a-roster-id",
             "--load-timeout", "30", "--dialog-timeout", "5", "--turn-timeout", "10"],
            capture_output=True, text=True, timeout=60)
        try:
            refused_report = json.loads(refused_run.stdout)
        except json.JSONDecodeError:
            sys.stderr.write("test-fallback-page-image (paired-roster-refused) stdout: "
                              + refused_run.stdout[:2000] + "\n")
            sys.stderr.write("test-fallback-page-image (paired-roster-refused) stderr: "
                              + refused_run.stderr[:2000] + "\n")
            failures.append(
                "drive-fallback-page.py wrote no parseable JSON report on the refused run")
        else:
            if refused_run.returncode == 0:
                failures.append(
                    "drive-fallback-page.py exited 0 selecting a roster id its picker carries "
                    "no option for")
            error = refused_report.get("error") or {}
            if error.get("type") != "RuntimeError" or "no option for --model" not in (
                    error.get("message") or ""):
                failures.append(
                    "the missing-option refusal did not name itself: " + repr(error))
    finally:
        server.shutdown()
        thread.join(timeout=5)

    return failures


def main():
    failures = []

    authorization_failures, success_lines = test_full_authorization()
    failures.extend(authorization_failures)

    for arm in (test_out_of_bounds_proposal_refused_before_the_dialog,
                test_foreign_profile_replaced_by_the_served_one,
                test_refused_grant_ends_the_turn,
                test_review_and_bounded_corrections,
                test_review_refuses_a_prose_reply):
        arm_failures, arm_lines = arm()
        failures.extend(arm_failures)
        if not arm_failures:
            success_lines.extend(arm_lines)

    timeout_failures = test_timeout_without_proposal()
    failures.extend(timeout_failures)
    if timeout_failures:
        sys.stderr.write("test-fallback-page-image failures (timeout-without-proposal):\n")
        for failure in timeout_failures:
            sys.stderr.write("  - " + failure + "\n")

    paired_roster_failures = test_paired_roster_default_and_explicit_selection()
    failures.extend(paired_roster_failures)
    if paired_roster_failures:
        sys.stderr.write("test-fallback-page-image failures (paired-roster-selection):\n")
        for failure in paired_roster_failures:
            sys.stderr.write("  - " + failure + "\n")

    if failures:
        return 1

    for line in success_lines:
        print(line)
    print("browser_turn_timeout_retains_prose=accepted")
    print("paired_roster_default_and_explicit_selection=accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
