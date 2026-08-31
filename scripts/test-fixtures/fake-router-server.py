#!/usr/bin/env python3
"""Stand in for the patched router llama-server so an admission runs without a GPU.

`scripts/test-fixtures/fake-llama-server.sh` answers `/health`, `/tokenize`, and
`/completion` for the policy, projector, and graph-alias lanes, and the image
admission needs a different surface: the roster and `/props` a page selects a
model from, `GET /tools` and `POST /tools` in the shape
`patches/llama-router-tools-proxy.patch` puts on the router port, a streaming
chat completion that proposes one `image_generate_image` call, and the fallback
page itself at `/`. Adding those to the shell fixture would change what three
other lanes measure, so this is a second fixture rather than a mode of the
first.

What it reproduces of the router is the routing rule the admission tests. `GET
/tools` resolves the model from `?model=`, `POST /tools` resolves it from the
body's top-level `model` key, and the request reaches the MCP child the named
section's `LLAMA_ARG_MCP_SERVERS_CONFIG` configures. `tool`, `params`, and
`stream` are the only body keys forwarded, so the routing key provably stays
out of the tool arguments and the child's own schema refuses one that appears
there. An `isError` result becomes an `error` key at HTTP 200, which is what
`mcp_result_to_response` does and what the page reads a refusal from.

What it stands in for is the device. There is no model: the chat completion is
a fixed script, and `QWEN_FAKE_ROUTER_IMAGE_ARGUMENTS` names the JSON the one
proposed `image_generate_image` call carries. A turn that carries a tool message
already reads the closing plain-text answer, so the fixture proposes once per
turn the way a model that read its own result would.

A preset carrying a review-only vision section beside the language one serves
two roster ids. `GET /props` reports `modalities.vision` from the section's own
`LLAMA_ARG_MMPROJ`, which is what makes the page's Review button appear, and a
completion naming the review section answers the verdict object
`QWEN_FAKE_ROUTER_REVIEW_VERDICT` holds. A review request that arrived carrying
a `tools` key is answered with an object outside the schema, so the page's own
parser reports it rather than the fixture asserting it. The verdict names the
constraints the request declared, since the page requires one entry per name in
the order it gave.

The child is spawned per call over stdio, the way llama-server spawns an MCP
server for one invocation, and its stderr reaches this process's stderr so a
child that refused startup names its reason in the server log.

usage: fake-router-server.py --models-preset FILE --host HOST --port PORT
                             [--path STATIC] [--api-key-file FILE] [--ui]
"""

import http.server
import json
import os
import re
import shlex
import socketserver
import subprocess
import sys
import threading
import urllib.parse

MCP_PROTOCOL_VERSION = "2024-11-05"

# The section configures the image MCP server under this key, so the router
# serves its one tool under the composed name and the fixture proposes that
# name rather than the child's own.
IMAGE_MCP_SERVER_NAME = "image"
IMAGE_MCP_TOOL_NAME = "generate_image"


def parse_arguments(argv):
    """Return the router settings out of the argv the capacity policy builds.

    An unknown flag is skipped rather than refused: the policy adds submission
    geometry, cache, and profile arguments this fixture has no use for, and a
    strict parser would turn every policy change into a fixture failure.
    """
    settings = {
        "preset": "",
        "host": "127.0.0.1",
        "port": 0,
        "static": "",
        "api_key_file": "",
    }
    named = {
        "--models-preset": "preset",
        "--host": "host",
        "--port": "port",
        "--path": "static",
        "--api-key-file": "api_key_file",
    }
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in named and index + 1 < len(argv):
            settings[named[token]] = argv[index + 1]
            index += 2
            continue
        index += 1
    settings["port"] = int(settings["port"])
    return settings


def read_preset(path):
    """Return the sections this preset names, in file order.

    `qwen-web-launch.sh` admits one language section, and one review-only
    vision section beside it where an image row pairs a review_model, so the
    fixture serves one or two. A third is a preset no launch produces.
    """
    sections = {}
    order = []
    current = None
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if stripped.startswith("[") and stripped.endswith("]"):
                current = stripped[1:-1]
                sections[current] = {}
                order.append(current)
                continue
            if current is None or "=" not in stripped:
                continue
            name, value = stripped.split("=", 1)
            sections[current][name.strip()] = value.strip()
    if not 1 <= len(order) <= 2:
        raise SystemExit(
            f"the fixture router serves one or two preset sections; {path} names {len(order)}"
        )
    return [(name, sections[name]) for name in order]


class MissingTools(Exception):
    """The section configures no MCP server, so the route answers as the binary does."""


class UnknownTool(Exception):
    """No served name matches, which `find_tool` raises and the route answers at 404."""


class ToolChild:
    """One spawned MCP server, driven over stdio for the life of one call."""

    def __init__(self, configuration_path):
        with open(configuration_path, encoding="utf-8") as handle:
            configuration = json.load(handle)
        servers = configuration.get("mcpServers") or {}
        if not servers:
            raise MissingTools("the configuration names no server")
        self.servers = servers

    def call(self, method, params):
        """Return the result of one JSON-RPC method against every named server.

        Each server is spawned, initialized, driven once, and closed, so a
        crashed child costs one call rather than the route. The results are
        concatenated in the configuration's own key order.
        """
        results = []
        for name, definition in self.servers.items():
            results.append((name, self._one(definition, method, params)))
        return results

    @staticmethod
    def _one(definition, method, params):
        command = [definition.get("command", "python3")] + list(definition.get("args") or [])
        environment = dict(os.environ)
        environment.update({
            str(key): str(value) for key, value in (definition.get("env") or {}).items()
        })
        child = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=sys.stderr,
            env=environment,
            text=True,
        )
        try:
            # The child bounds its own call at QWEN_IMAGE_MCP_TIMEOUT_S and
            # answers a stalled service itself, so the read here waits on that
            # deadline rather than adding a second one above it.
            def exchange(payload):
                child.stdin.write(json.dumps(payload) + "\n")
                child.stdin.flush()
                line = child.stdout.readline()
                if not line:
                    raise RuntimeError("the MCP child closed its output")
                return json.loads(line)

            exchange({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": MCP_PROTOCOL_VERSION},
            })
            return exchange(
                {"jsonrpc": "2.0", "id": 2, "method": method, "params": params}
            )
        finally:
            try:
                child.stdin.close()
            except OSError:
                pass
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()


def served_tool_name(server_name, tool_name):
    """Return the name llama-server serves one MCP tool under.

    `server_mcp_tool` sets `name = server_name + "_" + tool_name`
    (tools/server/server-tools.cpp:1814) and the listing composes the same
    string (:2046), so the configured `mcpServers` key decides what `GET
    /tools` lists and what `POST /tools` must name. A server configured as
    `image` serves `generate_image` as `image_generate_image`.
    """
    return f"{server_name}_{tool_name}"


def tool_listing(child):
    """Return the `[{tool, definition}]` shape the page composes body.tools from."""
    listing = []
    for server_name, reply in child.call("tools/list", {}):
        for tool in (reply.get("result") or {}).get("tools") or []:
            name = served_tool_name(server_name, tool["name"])
            listing.append({
                "tool": name,
                "definition": {
                    "type": "function",
                    "function": {
                        "name": name,
                        "description": tool.get("description", ""),
                        "parameters": tool.get("inputSchema") or {"type": "object"},
                    },
                },
            })
    return listing


def call_tool(child, name, params):
    """Return the HTTP body one tool call produces.

    `find_tool` matches the composed `<server>_<tool>` name and raises for any
    other string (tools/server/server-tools.cpp:1935), which the route answers
    at 404 (:2163), and `server_mcp_tool::invoke` hands the child the bare tool
    name (:1838). The owning server is found by its own key rather than by
    splitting on the first underscore, so a configured name containing one
    still resolves.

    `mcp_result_to_response` maps an `isError` result onto an `error` key at
    HTTP 200, so a refusal is read from the body rather than from the status,
    and the page and the shell harness both read it there.
    """
    for server_name, definition in child.servers.items():
        prefix = server_name + "_"
        if not name.startswith(prefix):
            continue
        reply = ToolChild._one(
            definition, "tools/call", {"name": name[len(prefix):], "arguments": params}
        )
        if "error" in reply:
            return {"error": reply["error"].get("message", "the tool call failed")}
        result = reply.get("result") or {}
        text = "".join(
            part.get("text", "") for part in (result.get("content") or [])
            if part.get("type") == "text"
        )
        if result.get("isError"):
            return {"error": text or f"{server_name} refused the call"}
        return {"plain_text_response": text}
    raise UnknownTool(f'unknown tool "{name}"')


CONSTRAINT_NAMES = re.compile(r"Constraint names, in order:\s*(.+)")


def review_verdict(body):
    """Compose a passing verdict over the constraints the request declared.

    `buildReviewRequestBody` writes `Constraint names, in order: a, b` into the
    user turn's text part, and `parseReviewVerdict` requires one entry per
    declared name in that order, so a fixture answering a fixed list would fail
    the page's own parser whenever the approval carried a negative prompt. The
    names are read back out of the request for that reason: the fixture stands
    in for a model that read the instruction, not for one that guessed it.
    """
    declared = []
    for message in body.get("messages") or []:
        content = message.get("content")
        parts = content if isinstance(content, list) else [{"text": content}]
        for part in parts:
            text = part.get("text") if isinstance(part, dict) else None
            if not isinstance(text, str):
                continue
            found = CONSTRAINT_NAMES.search(text)
            if found:
                declared = [
                    name.strip() for name in found.group(1).split(",") if name.strip()
                ]
    return json.dumps({
        "hard_constraints": [
            {"name": name, "passed": True,
             "observation": "The frame meets this constraint."}
            for name in declared
        ],
        "composition_change_required": False,
        "prompt_delta": "",
        "regenerate": False,
    })


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "qwen-fake-router/1"
    sys_version = ""

    def log_message(self, fmt, *args):
        """Drop the access log; the admission reads the page's own request log."""

    @property
    def settings(self):
        return self.server.router_settings

    def authorized(self):
        expected = self.settings["api_key"]
        if not expected:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {expected}"

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_error_object(self, status, message, kind="invalid_request_error"):
        self.send_json(status, {"error": {"code": status, "message": message, "type": kind}})

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except ValueError:
            return {}

    def resolve_model(self, named):
        """Return the named row of the roster, or refuse and return None.

        The router resolves `/tools` the way it resolves `/props`, so an absent
        and an unknown name are separate refusals and neither reaches a child.
        """
        if not named:
            self.send_error_object(400, "a model must be named")
            return None
        row = self.settings["rows"].get(named)
        if row is None:
            self.send_error_object(404, f"no model named {named}", "not_found_error")
            return None
        return row

    def tools_child(self, row):
        configuration = row["mcp_configuration"]
        if not configuration:
            raise MissingTools("the section carries no MCP configuration")
        return ToolChild(configuration)

    def do_OPTIONS(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path in ("/", "/index.html"):
            # llama-server serves --path without the API key, which is how the
            # page loads before a human types one into its own field.
            self.serve_page()
            return
        if parsed.path == "/health":
            self.send_json(200, {"status": "ok"})
            return
        if not self.authorized():
            self.send_error_object(401, "an API key is required", "authentication_error")
            return
        if parsed.path in ("/v1/models", "/models"):
            self.send_json(200, {"object": "list", "data": [{
                "id": row_id,
                "object": "model",
                "status": {"value": "loaded"},
            } for row_id in self.settings["roster"]]})
            return
        if parsed.path == "/props":
            row = self.resolve_model((query.get("model") or [""])[0])
            if row is None:
                return
            # The page asks each roster row which modality it reads, and
            # llama-server reports vision for a child holding a projector. The
            # review section is the one carrying LLAMA_ARG_MMPROJ, so that key
            # rather than a name decides the answer here too.
            self.send_json(200, {
                "default_generation_settings": {"n_ctx": row["context"]},
                "model_path": row["model_path"],
                "modalities": {"vision": bool(row["projector"])},
            })
            return
        if parsed.path == "/tools":
            row = self.resolve_model((query.get("model") or [""])[0])
            if row is None:
                return
            try:
                self.send_json(200, tool_listing(self.tools_child(row)))
            except MissingTools:
                self.send_error_object(403, "tools are disabled", "feature_disabled")
            except (OSError, ValueError, RuntimeError) as error:
                self.send_error_object(500, f"the tool listing failed: {error}", "server_error")
            return
        self.send_error_object(404, f"no route: {parsed.path}", "not_found_error")

    def serve_page(self):
        path = os.path.join(self.settings["static"], "index.html")
        try:
            with open(path, "rb") as handle:
                body = handle.read()
        except OSError:
            self.send_error_object(404, "no page is served", "not_found_error")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802 -- BaseHTTPRequestHandler names the verb
        parsed = urllib.parse.urlparse(self.path)
        if not self.authorized():
            self.send_error_object(401, "an API key is required", "authentication_error")
            return
        body = self.read_body()
        if parsed.path == "/tools":
            row = self.resolve_model(body.get("model") or "")
            if row is None:
                return
            name = body.get("tool")
            if not isinstance(name, str) or not name:
                self.send_error_object(400, "a tool must be named")
                return
            params = body.get("params")
            if not isinstance(params, dict):
                params = {}
            try:
                self.send_json(200, call_tool(self.tools_child(row), name, params))
            except MissingTools:
                self.send_error_object(403, "tools are disabled", "feature_disabled")
            except UnknownTool as error:
                self.send_error_object(404, str(error), "not_found_error")
            except (OSError, ValueError, RuntimeError) as error:
                self.send_error_object(500, f"the tool call failed: {error}", "server_error")
            return
        if parsed.path == "/v1/chat/completions":
            self.chat_completion(body)
            return
        self.send_error_object(404, f"no route: {parsed.path}", "not_found_error")

    def coding_calls(self, body, offered):
        """Return this round's coding proposals, or None outside the lane.

        The turn shape scripts the chain the way the image branch scripts one
        proposal: with code tools offered and no code tool message yet, the
        model proposes `code_plan` over the fixture instruction; with a plan
        answered, it proposes the apply; with the apply answered, it proposes
        the tests and the diff review together in one round, which is what
        keeps the whole chain inside the page's continuation cap; and with
        all four answered it closes the turn in prose. The job id is read
        back out of the plan's own tool message, so the fixture stands in
        for a model that read its results rather than one that guessed.
        """
        code_offered = any(
            isinstance(name, str) and name.startswith("code_")
            for name in offered
        )
        tool_messages = [
            message for message in body.get("messages") or []
            if message.get("role") == "tool"
            and str(message.get("name", "")).startswith("code_")
        ]
        if not code_offered and not tool_messages:
            return None
        instruction = os.environ.get(
            "QWEN_FAKE_ROUTER_CODE_INSTRUCTION",
            "set VALUE to 42 in declared-value.txt and update check-value.sh",
        )
        answered = [str(message.get("name")) for message in tool_messages]
        if not answered:
            return [("code_plan", json.dumps({"instruction": instruction}))]
        job_match = re.search(
            r"job (job-\d+-[0-9a-f]+)",
            "".join(str(message.get("content", ""))
                    for message in tool_messages),
        )
        if job_match is None:
            return []
        job_id = job_match.group(1)
        if "code_apply_patch" not in answered:
            return [("code_apply_patch", json.dumps({"job_id": job_id}))]
        if "code_run_tests" not in answered:
            return [
                ("code_run_tests", json.dumps({"job_id": job_id})),
                ("code_review_diff", json.dumps({"job_id": job_id})),
            ]
        return []

    def chat_completion(self, body):
        """Answer one turn, proposing the image call while no tool message exists.

        The turn shape rather than a model decides the branch: a request whose
        messages already carry a `role: tool` entry is the continuation round,
        which reads plain text and ends the turn.

        QWEN_FAKE_ROUTER_PROSE_FIRST_COMPLETIONS reproduces the variability
        `evidence/image-appliance/served-turn-admission/README.md` and a later
        appliance run both recorded on the same prompt: the 4B answers with a
        schema-valid call in most runs and with prose in some. Each opening
        completion -- one per browser attempt, since a fresh page resends the
        turn from empty history -- increments the shared counter the server
        holds, and a completion whose count falls at or below the configured
        threshold answers prose instead of proposing, so a caller can script
        "prose on attempt 1, a proposal on attempt 2" without touching the
        continuation branch a real second round would take.

        A request naming the review section is the vision review, and the page
        posts it non-streamed with the body carrying no `tools` key at all. The
        fixture answers the verdict object QWEN_FAKE_ROUTER_REVIEW_VERDICT
        names, so the admission reads the checklist the page rendered rather
        than a device's opinion of an image.
        """
        review_row = self.settings["review_section"]
        if review_row and body.get("model") == review_row:
            verdict = self.settings["review_verdict"] or review_verdict(body)
            if "tools" in body:
                verdict = json.dumps({
                    "note": "the review request carried a tools key",
                })
            self.send_json(200, {
                "id": "chatcmpl-review",
                "object": "chat.completion",
                "model": review_row,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": verdict},
                    "finish_reason": "stop",
                }],
            })
            return
        continuation = any(
            message.get("role") == "tool" for message in body.get("messages") or []
        )
        offered = {
            tool.get("function", {}).get("name")
            for tool in body.get("tools") or []
            if isinstance(tool, dict)
        }
        coding = self.coding_calls(body, offered)
        if coding is not None:
            if coding:
                calls = [{
                    "index": position,
                    "id": f"call_code_admission_{position}",
                    "type": "function",
                    "function": {"name": name, "arguments": arguments_text},
                } for position, (name, arguments_text) in enumerate(coding)]
                chunks = [
                    {"choices": [{"index": 0,
                                  "delta": {"tool_calls": calls}}]},
                    {"choices": [{"index": 0, "delta": {},
                                  "finish_reason": "tool_calls"}]},
                ]
                message = {"role": "assistant", "content": "",
                           "tool_calls": calls}
                finish = "tool_calls"
            else:
                closing = "The change is applied and the tests pass."
                chunks = [
                    {"choices": [{"index": 0,
                                  "delta": {"content": closing}}]},
                    {"choices": [{"index": 0, "delta": {},
                                  "finish_reason": "stop"}]},
                ]
                message = {"role": "assistant", "content": closing}
                finish = "stop"
            self.send_completion(body, chunks, message, finish)
            return
        image_tool = served_tool_name(IMAGE_MCP_SERVER_NAME, IMAGE_MCP_TOOL_NAME)
        answer_prose = continuation or image_tool not in offered
        if not continuation and image_tool in offered:
            with self.server.opening_completion_lock:
                self.server.opening_completion_count += 1
                opening_count = self.server.opening_completion_count
            if opening_count <= self.settings["prose_first_completions"]:
                answer_prose = True
        if answer_prose:
            chunks = [
                {"choices": [{"index": 0, "delta": {"content": self.settings["answer"]}}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ]
            message = {"role": "assistant", "content": self.settings["answer"]}
            finish = "stop"
        else:
            call = {
                "index": 0,
                "id": "call_image_admission",
                "type": "function",
                "function": {
                    "name": image_tool,
                    "arguments": self.settings["image_arguments"],
                },
            }
            chunks = [
                {"choices": [{"index": 0, "delta": {"tool_calls": [call]}}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
            ]
            message = {"role": "assistant", "content": "", "tool_calls": [call]}
            finish = "tool_calls"
        self.send_completion(body, chunks, message, finish)

    def send_completion(self, body, chunks, message, finish):
        if body.get("stream"):
            payload = b""
            for chunk in chunks:
                chunk = dict(chunk, model=self.settings["section"], object="chat.completion.chunk")
                payload += b"data: " + json.dumps(chunk).encode("utf-8") + b"\n\n"
            payload += b"data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_json(200, {
            "id": "chatcmpl-admission",
            "object": "chat.completion",
            "model": self.settings["section"],
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
        })


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv):
    settings = parse_arguments(argv)
    if not settings["preset"]:
        sys.stderr.write("--models-preset names the section this fixture serves\n")
        return 2
    preset_sections = read_preset(settings["preset"])
    api_key = ""
    if settings["api_key_file"]:
        with open(settings["api_key_file"], encoding="utf-8") as handle:
            api_key = handle.readline().strip()
    rows = {}
    roster = []
    language_section = ""
    review_section = ""
    for section, keys in preset_sections:
        served = keys.get("LLAMA_ARG_ALIAS", section)
        rows[served] = {
            "mcp_configuration": keys.get("LLAMA_ARG_MCP_SERVERS_CONFIG", ""),
            "model_path": keys.get("LLAMA_ARG_MODEL", ""),
            "context": int(keys.get("LLAMA_ARG_CTX_SIZE", "4096")),
            "projector": keys.get("LLAMA_ARG_MMPROJ", ""),
        }
        roster.append(served)
        # The review section is the one tagged review-only, which is also the
        # one carrying a projector and no MCP configuration; the tag is read
        # because it is what the generator writes and the launch checks.
        if "review-only" in keys.get("LLAMA_ARG_TAGS", "").split(","):
            review_section = served
        else:
            language_section = served
    # The real router reports `/v1/models` sorted, which is what put a
    # review-only vision section ahead of the language section by id alone --
    # evidence/web-admission-router-tools.md records lfm25-vl-16b sorting
    # ahead of web-image-admission -- so this fixture sorts the same way
    # rather than reporting preset section order, which a page's own default
    # selection or a driver's --model argument cannot be proven against
    # otherwise.
    roster = sorted(roster)
    router_settings = {
        "rows": rows,
        "roster": roster,
        "section": language_section or roster[0],
        "review_section": review_section,
        "mcp_configuration": rows[language_section or roster[0]]["mcp_configuration"],
        "model_path": rows[language_section or roster[0]]["model_path"],
        "context": rows[language_section or roster[0]]["context"],
        "static": settings["static"],
        "api_key": api_key,
        # An unset override leaves the verdict composed from the constraints
        # the request declared, which is the only reply the page's parser
        # admits whatever the approval carried.
        "review_verdict": os.environ.get("QWEN_FAKE_ROUTER_REVIEW_VERDICT", ""),
        "image_arguments": os.environ.get(
            "QWEN_FAKE_ROUTER_IMAGE_ARGUMENTS",
            json.dumps({
                "prompt": "a fox in a snowy field",
                "negative_prompt": "blurry",
                "width": 512,
                "height": 512,
                "steps": 1,
                "profile_id": "image-sdxs-512-a",
            }),
        ),
        "answer": os.environ.get(
            "QWEN_FAKE_ROUTER_ANSWER", "The image is ready."
        ),
        # Zero reproduces the tree's ordinary fixture behavior: every opening
        # completion proposes, so the single-attempt admission path is
        # unchanged. A positive count answers prose for that many opening
        # completions before it proposes.
        "prose_first_completions": int(
            os.environ.get("QWEN_FAKE_ROUTER_PROSE_FIRST_COMPLETIONS", "0")
        ),
    }
    server = Server((settings["host"], settings["port"]), Handler)
    server.router_settings = router_settings
    server.opening_completion_count = 0
    server.opening_completion_lock = threading.Lock()
    # qwen-webui-session.sh waits for llama.cpp's own router banner before it
    # arms the watchdogs, so the fixture prints the marker that readiness loop
    # greps for.
    sys.stderr.write("starting server in router mode\n")
    sys.stderr.write(
        "fake_router listening {} {} section={} review={} tools={}\n".format(
            settings["host"],
            server.server_address[1],
            router_settings["section"],
            router_settings["review_section"] or "none",
            shlex.quote(router_settings["mcp_configuration"] or "none"),
        )
    )
    sys.stderr.flush()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        while thread.is_alive():
            thread.join(1.0)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
