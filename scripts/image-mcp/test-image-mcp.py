#!/usr/bin/env python3
"""Drive the image MCP server over stdio against a stub image service.

The server is spawned the way llama-server spawns it and the approval broker
is spawned the way a session spawns it, so a grant travels from
`POST /grant-image` through a model-shaped `tools/call` and into a Unix socket
without any imported shortcut across the boundary. The stub service answers
each connection from a scripted reply, which puts the runtime, the device, and
the network outside every arm.

The refusals are the point of the suite: a replayed grant, a tampered payload,
an expired term, another profile, an argument outside the schema, an absent
seed, a dimension above the approved maximum, and a service that refuses all
reach the model as `isError` results at JSON-RPC success.
"""

import http.client
import importlib.util
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

TEST_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
IMAGE_SERVER_PATH = os.path.join(TEST_DIRECTORY, "server.py")
WEB_MCP_DIRECTORY = os.path.join(os.path.dirname(TEST_DIRECTORY), "web-mcp")
BROKER_PATH = os.path.join(WEB_MCP_DIRECTORY, "authorize-broker.py")
sys.path.insert(0, WEB_MCP_DIRECTORY)

import server as web_server  # noqa: E402
import image_grant  # noqa: E402


def load_broker_module():
    """Import the broker by path so the constants under test are its own."""
    specification = importlib.util.spec_from_file_location(
        "authorize_broker_module", BROKER_PATH
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


broker_module = load_broker_module()
SESSION_HEADER = broker_module.SESSION_HEADER
SESSION_SECRET_FILE_NAME = broker_module.SESSION_SECRET_FILE_NAME

TOKEN_SECRET = "image-token-secret-7QF2LD"
API_KEY = "web-ui-api-key-K3RM9T"
ORIGIN = "http://127.0.0.1:8080"
LANGUAGE_PROFILE = "fast-text"
IMAGE_PROFILE = "sdxs-512-a"
PROMPT = "a measured raven on a laptop lid"
NEGATIVE_PROMPT = "text, watermark"
SEED = 0
PROFILE_WIDTH = 512
PROFILE_HEIGHT = 512
PROFILE_STEPS = 4
PROFILE_MAX_DIMENSION = 512
PROFILE_MAX_STEPS = 4
ARTIFACT_SHA256 = "b" * 64
PROVENANCE_URL = f"/artifacts/{ARTIFACT_SHA256}.json"
START_WAIT_SECONDS = 15.0
STOP_WAIT_SECONDS = 5.0
CLOSE_WAIT_SECONDS = 10.0


def approved_fields(**overrides):
    """Return the body the approving page posts to POST /grant-image.

    The page hashes the prompt it displayed, so the request names digests and
    the broker signs an identity rather than the words.
    """
    fields = {
        "context": image_grant.IMAGE_CLAIM_CONTEXT,
        "language_profile": LANGUAGE_PROFILE,
        "image_profile": IMAGE_PROFILE,
        "prompt_hash": image_grant.prompt_digest(PROMPT),
        "negative_prompt_hash": image_grant.prompt_digest(NEGATIVE_PROMPT),
        "seed": SEED,
        "aspect": "1:1",
        "max_dimension": 512,
        "max_steps": 4,
        "conversation_generation": 3,
    }
    fields.update(overrides)
    return fields


def tool_arguments(grant, **overrides):
    arguments = {
        "prompt": PROMPT,
        "negative_prompt": NEGATIVE_PROMPT,
        "seed": SEED,
        "width": 512,
        "height": 512,
        "steps": 4,
        "profile_id": IMAGE_PROFILE,
        "authorization": grant,
    }
    arguments.update(overrides)
    return arguments


class StubService:
    """A Unix-socket image service that answers from a scripted reply.

    Each accepted connection reads one line and writes the next scripted
    reply, so an arm states what the service answers rather than what a
    runtime would produce. `requests` retains every job line the server sent,
    which is what proves the routing key stays out of the job and the grant
    reaches the service opaque.
    """

    def __init__(self, path, replies, delay_seconds=0.0, answer=True,
                 template=None):
        # Every field the serving thread reads is assigned before the thread
        # starts. Assigning one after it would let the first connection reach
        # an attribute that does not exist yet, which ends the thread and
        # leaves the client waiting out its whole deadline.
        self.path = path
        self.replies = list(replies)
        self.delay_seconds = delay_seconds
        self.answer = answer
        self.template = template or {}
        self.requests = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(4)
        self.listener.settimeout(0.2)
        self.running = True
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while self.running:
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                # `makefile` holds an I/O reference on the socket, so the
                # descriptor outlives `close` until the reader is released and
                # the client waits out its whole deadline rather than reading
                # end of file. The reader is closed where it was opened.
                stream = connection.makefile("rb")
                try:
                    line = stream.readline(1024 * 1024)
                    if line:
                        self.requests.append(json.loads(line.decode("utf-8")))
                    if self.delay_seconds:
                        time.sleep(self.delay_seconds)
                    if not self.answer:
                        # A service that holds the connection open and writes
                        # nothing is what the tool deadline exists for, so the
                        # stub keeps the socket until the arm ends rather than
                        # handing the client an end of file.
                        while self.running:
                            time.sleep(0.05)
                        continue
                    if self.replies:
                        reply = self.replies.pop(0)
                        connection.sendall(
                            (
                                reply
                                if isinstance(reply, (bytes, bytearray))
                                else json.dumps(reply).encode("utf-8") + b"\n"
                            )
                        )
                except OSError:
                    continue
                finally:
                    stream.close()

    def close(self):
        self.running = False
        self.thread.join(timeout=STOP_WAIT_SECONDS)
        self.listener.close()


def completed_reply(request_id, **overrides):
    """Return the reply a completed generation writes.

    `image_protocol` closes the response schema, so a completed reply names the
    digest and the route derived from it and carries no error key: a JSON null
    or an empty string there states a failure the run did not have.
    """
    reply = {
        "protocol_version": 1,
        "request_id": request_id,
        "status": "completed",
        "sha256": ARTIFACT_SHA256,
        "provenance_url": PROVENANCE_URL,
    }
    reply.update(overrides)
    # An override of None removes the key, which is how an arm states a reply
    # that names no artifact: the schema reads a present key as a claim.
    return {key: value for key, value in reply.items() if value is not None}


class EchoingService(StubService):
    """A stub that answers each job under the request identifier it carried."""

    def __init__(self, path, template=None):
        super().__init__(path, replies=[], template=template)

    def serve(self):
        while self.running:
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                stream = connection.makefile("rb")
                try:
                    line = stream.readline(1024 * 1024)
                    if not line:
                        continue
                    request = json.loads(line.decode("utf-8"))
                    self.requests.append(request)
                    reply = completed_reply(request["request_id"], **self.template)
                    connection.sendall(json.dumps(reply).encode("utf-8") + b"\n")
                except OSError:
                    continue
                finally:
                    stream.close()


class ImageServerSession:
    """One spawn of the image MCP server, driven over newline JSON-RPC."""

    def __init__(self, environment, timeout_value=None):
        environment = dict(environment)
        if timeout_value is not None:
            environment["QWEN_IMAGE_MCP_TIMEOUT_S"] = str(timeout_value)
        self.process = subprocess.Popen(
            [sys.executable, IMAGE_SERVER_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            text=True,
        )
        self.identifier = 0
        self.stdout_text = ""
        self.stderr_text = ""
        self.closed = False

    def request(self, method, params=None):
        self.identifier += 1
        message = {"jsonrpc": "2.0", "id": self.identifier, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())

    def call_tool(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        if self.closed:
            return self.process.returncode
        self.closed = True
        try:
            self.stdout_text, self.stderr_text = self.process.communicate(
                timeout=CLOSE_WAIT_SECONDS
            )
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.stdout_text, self.stderr_text = self.process.communicate()
        return self.process.returncode


class BrokerProcess:
    """A running approval broker and the client that speaks to its port."""

    def __init__(self, state_directory, token_key_path, api_key_path,
                 language_profile, image_profile):
        # The claim joins two profiles and the MCP child compares each against
        # its own setting, so the broker binds them separately: --profile is
        # the language profile a section serves and --image-profile is the
        # image profile the ledger armed.
        argv = [
            sys.executable,
            BROKER_PATH,
            "--state-dir",
            state_directory,
            "--token-key-file",
            token_key_path,
            "--api-key-file",
            api_key_path,
            "--provider",
            "fake",
            "--profile",
            language_profile,
            "--image-profile",
            image_profile,
            "--origin",
            ORIGIN,
        ]
        self.process = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        parts = self.process.stdout.readline().split()
        self.host, self.port = ("", 0)
        if len(parts) == 3 and parts[0] == "listening":
            self.host, self.port = parts[1], int(parts[2])

    def post(self, path, payload, headers):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            connection.request("POST", path, json.dumps(payload), headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read().decode("utf-8"))
        finally:
            connection.close()

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=STOP_WAIT_SECONDS)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=STOP_WAIT_SECONDS)
        self.process.stdout.close()
        self.process.stderr.close()


class ImageMcpTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        root = self.workspace.name
        self.state_directory = os.path.join(root, "state")
        os.makedirs(self.state_directory, mode=0o700)
        self.token_key_path = os.path.join(root, "token.key")
        self.api_key_path = os.path.join(root, "api.key")
        for path, secret in (
            (self.token_key_path, TOKEN_SECRET),
            (self.api_key_path, API_KEY),
        ):
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(secret + "\n")
            os.chmod(path, 0o600)
        # The tool schema states the served profile's geometry and ceilings, and
        # image-service.py enforces the same numbers from the same file, so the
        # suite writes one parameter file both readings would resolve against.
        self.profiles_json_path = os.path.join(root, "image-parameters.json")
        self.write_profile_parameters()
        # A Unix socket path is bounded by sun_path, so the stub binds inside a
        # short directory of its own rather than beside the state database.
        self.socket_directory = tempfile.TemporaryDirectory()
        self.socket_path = os.path.join(self.socket_directory.name, "image.sock")
        self.services = []
        self.sessions = []
        self.brokers = []
        self.addCleanup(self.workspace.cleanup)
        self.addCleanup(self.socket_directory.cleanup)
        self.addCleanup(self.stop_children)

    def write_profile_parameters(self, **overrides):
        parameters = {
            "profile_id": IMAGE_PROFILE,
            "model_id": "sdxs-512",
            "placement": "A",
            "sampler": "euler",
            "execution_policy": "validator-gated",
            "runtime_path": "/nonexistent/sd-cli",
            "width": PROFILE_WIDTH,
            "height": PROFILE_HEIGHT,
            "steps": PROFILE_STEPS,
            "max_steps": PROFILE_MAX_STEPS,
            "max_dimension": PROFILE_MAX_DIMENSION,
            "timeout_s": 300,
        }
        parameters.update(overrides)
        with open(self.profiles_json_path, "w", encoding="utf-8") as handle:
            json.dump({IMAGE_PROFILE: parameters}, handle)

    def stop_children(self):
        for session in self.sessions:
            session.close()
        for service in self.services:
            service.close()
        for broker in self.brokers:
            broker.close()

    def environment(self, **overrides):
        # The suite runs every arm under a 30 second bound rather than the
        # 360 second default, so a stub that stops answering fails an arm in
        # seconds. The banner arm asks for the default by clearing the value.
        environment = {
            **os.environ,
            "PYTHONDONTWRITEBYTECODE": "1",
            "QWEN_IMAGE_MCP_TIMEOUT_S": "30",
            "QWEN_IMAGE_PROFILE": IMAGE_PROFILE,
            "QWEN_IMAGE_LANGUAGE_PROFILE": LANGUAGE_PROFILE,
            "QWEN_IMAGE_TOKEN_KEY_FILE": self.token_key_path,
            "QWEN_IMAGE_STATE_DIR": self.state_directory,
            "QWEN_IMAGE_SERVICE_SOCKET": self.socket_path,
            "QWEN_IMAGE_PROFILES_JSON": self.profiles_json_path,
        }
        environment.update({key: str(value) for key, value in overrides.items()})
        return environment

    def start_service(self, service):
        self.services.append(service)
        return service

    def start_echo_service(self, template=None):
        return self.start_service(EchoingService(self.socket_path, template))

    def start_session(self, **overrides):
        session = ImageServerSession(self.environment(**overrides))
        self.sessions.append(session)
        return session

    def grant(self, lifetime=900, now=None, **overrides):
        return image_grant.issue_image_grant(
            self.token_key_path, approved_fields(**overrides), lifetime, now=now
        )

    def call(self, session, arguments):
        response = session.call_tool("generate_image", arguments)
        self.assertIn("result", response, response)
        return response["result"]

    def result_text(self, result):
        self.assertEqual(len(result["content"]), 1, result)
        return result["content"][0]["text"]

    def audit_rows(self):
        connection = sqlite3.connect(
            os.path.join(self.state_directory, web_server.LEDGER_FILE_NAME)
        )
        try:
            return connection.execute(
                "SELECT operation, status, query_sha256, domains FROM audit"
                " ORDER BY rowid"
            ).fetchall()
        finally:
            connection.close()

    # The tool surface

    def test_tools_list_names_one_tool_and_its_schema(self):
        session = self.start_session()
        response = session.request("tools/list")
        tools = response["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["generate_image"])
        schema = tools[0]["inputSchema"]
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(
            sorted(schema["properties"]),
            [
                "authorization",
                "height",
                "negative_prompt",
                "profile_id",
                "prompt",
                "seed",
                "steps",
                "width",
            ],
        )

    def test_schema_states_the_served_profile_and_its_bounds(self):
        """The listing bounds a proposal by the profile the section serves.

        A model proposes from this schema, so the enum, the maxima, and the
        descriptions are what keep a proposal inside what the broker signs and
        image-service.py executes.
        """
        session = self.start_session()
        schema = session.request("tools/list")["result"]["tools"][0]["inputSchema"]
        properties = schema["properties"]
        self.assertEqual(properties["profile_id"]["enum"], [IMAGE_PROFILE])
        for field in ("width", "height"):
            self.assertEqual(properties[field]["maximum"], PROFILE_MAX_DIMENSION)
        self.assertEqual(properties["width"]["default"], PROFILE_WIDTH)
        self.assertEqual(properties["height"]["default"], PROFILE_HEIGHT)
        self.assertEqual(properties["steps"]["maximum"], PROFILE_MAX_STEPS)
        self.assertEqual(properties["steps"]["default"], PROFILE_STEPS)
        self.assertIn(
            f"{PROFILE_WIDTH} natively", properties["width"]["description"]
        )
        self.assertIn(
            f"{PROFILE_HEIGHT} natively", properties["height"]["description"]
        )
        self.assertIn(str(PROFILE_STEPS), properties["steps"]["description"])
        description = session.request("tools/list")["result"]["tools"][0][
            "description"
        ]
        self.assertIn(IMAGE_PROFILE, description)
        self.assertIn(f"{PROFILE_WIDTH}x{PROFILE_HEIGHT}", description)
        self.assertIn(f"{PROFILE_MAX_STEPS} sampler steps", description)

    def test_schema_maxima_follow_the_parameter_file(self):
        """A parameter file is the schema's source rather than a constant.

        The ledger and this file are compared at launch, so lowering the
        ceiling here is what a registry edit reaches the child as, and the
        advertised maximum moves with it.
        """
        self.write_profile_parameters(max_dimension=256, max_steps=2)
        session = self.start_session()
        properties = session.request("tools/list")["result"]["tools"][0][
            "inputSchema"
        ]["properties"]
        self.assertEqual(properties["width"]["maximum"], 256)
        self.assertEqual(properties["height"]["maximum"], 256)
        self.assertEqual(properties["steps"]["maximum"], 2)

    def test_absent_parameter_file_answers_the_listing_with_an_error(self):
        """An unreadable parameter file offers no tool rather than an unbounded one.

        A schema falling back to image_grant's own ceilings would advertise a
        geometry the profile refuses, which is the proposal the bounds exist to
        prevent, so the listing fails closed.
        """
        os.unlink(self.profiles_json_path)
        session = self.start_session()
        response = session.request("tools/list")
        self.assertIn("error", response, response)
        self.assertIn("unreadable", response["error"]["message"])

    def test_parameter_file_naming_another_profile_answers_with_an_error(self):
        self.write_profile_parameters()
        with open(self.profiles_json_path, "w", encoding="utf-8") as handle:
            json.dump({"another-profile": {"width": 512}}, handle)
        session = self.start_session()
        response = session.request("tools/list")
        self.assertIn("error", response, response)
        self.assertIn(IMAGE_PROFILE, response["error"]["message"])

    def test_startup_names_the_timeout_it_enforces_on_stderr(self):
        session = self.start_session(QWEN_IMAGE_MCP_TIMEOUT_S="")
        session.request("ping")
        session.close()
        self.assertIn("timeouts mcp=360", session.stderr_text)

    def test_malformed_timeout_refuses_startup(self):
        session = ImageServerSession(
            self.environment(QWEN_IMAGE_MCP_TIMEOUT_S="soon")
        )
        self.sessions.append(session)
        self.assertEqual(session.close(), 2)
        self.assertIn("QWEN_IMAGE_MCP_TIMEOUT_S", session.stderr_text)

    # The grant

    def test_broker_issues_a_grant_the_server_spends_once(self):
        service = self.start_echo_service()
        broker = BrokerProcess(
            self.state_directory,
            self.token_key_path,
            self.api_key_path,
            LANGUAGE_PROFILE,
            IMAGE_PROFILE,
        )
        self.brokers.append(broker)
        secret_path = os.path.join(self.state_directory, SESSION_SECRET_FILE_NAME)
        deadline = time.time() + START_WAIT_SECONDS
        while time.time() < deadline and not os.path.exists(secret_path):
            time.sleep(0.05)
        with open(secret_path, encoding="ascii") as handle:
            secret = handle.read().strip()
        headers = {
            "Content-Type": "application/json",
            "Origin": ORIGIN,
            SESSION_HEADER: secret,
        }
        status, payload = broker.post("/grant-image", approved_fields(), headers)
        self.assertEqual(status, 200, payload)
        token = payload["authorization"]
        session = self.start_session()
        first = self.call(session, tool_arguments(token))
        self.assertFalse(first["isError"], first)
        second = self.call(session, tool_arguments(token))
        self.assertTrue(second["isError"], second)
        self.assertIn("spent", self.result_text(second))
        self.assertEqual(len(service.requests), 1)
        # The replay row carries `authorization_denied` because `GrantReplayed`
        # subclasses `AuthorizationDenied`. A status outside `AUDIT_STATUSES`
        # would reach the table as `internal_error`, so the term is pinned here
        # rather than read from the class.
        self.assertEqual(
            [(row[0], row[1]) for row in self.audit_rows()],
            [
                ("authorize-image", "success"),
                ("generate-image", "success"),
                ("generate-image", "authorization_denied"),
            ],
        )

    def test_broker_refuses_another_image_profile(self):
        broker = BrokerProcess(
            self.state_directory,
            self.token_key_path,
            self.api_key_path,
            LANGUAGE_PROFILE,
            IMAGE_PROFILE,
        )
        self.brokers.append(broker)
        secret_path = os.path.join(self.state_directory, SESSION_SECRET_FILE_NAME)
        deadline = time.time() + START_WAIT_SECONDS
        while time.time() < deadline and not os.path.exists(secret_path):
            time.sleep(0.05)
        with open(secret_path, encoding="ascii") as handle:
            secret = handle.read().strip()
        headers = {
            "Content-Type": "application/json",
            "Origin": ORIGIN,
            SESSION_HEADER: secret,
        }
        status, payload = broker.post(
            "/grant-image",
            approved_fields(image_profile="another-profile"),
            headers,
        )
        self.assertEqual(status, 400, payload)
        self.assertIn("image profile", payload["error"])
        absent = dict(approved_fields())
        del absent["seed"]
        status, payload = broker.post("/grant-image", absent, headers)
        self.assertEqual(status, 400, payload)
        self.assertIn("seed is required", payload["error"])
        status, payload = broker.post(
            "/grant-image", {**approved_fields(), "style": "photographic"}, headers
        )
        self.assertEqual(status, 400, payload)
        self.assertIn("outside the image claim: style", payload["error"])
        status, payload = broker.post(
            "/grant-image",
            {**approved_fields(), "context": "search-authorization"},
            headers,
        )
        self.assertEqual(status, 400, payload)
        self.assertIn("qwen-image-generate-v1", payload["error"])
        # The refusal path writes its own audit row rather than raising inside
        # the handler on a claim shaped for search fields.
        statuses = {row[1] for row in self.audit_rows()}
        self.assertEqual(statuses, {"invalid_argument"})

    def test_completed_generation_carries_digest_and_url_alone(self):
        service = self.start_echo_service()
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertFalse(result["isError"], result)
        text = self.result_text(result)
        # The whole result is asserted rather than the presence of two fields,
        # because an edit that appended the artifact itself would leave both in
        # place; a data URI and an unbroken base64 run are what that edit adds.
        self.assertEqual(
            json.loads(text),
            {
                "status": "completed",
                "sha256": ARTIFACT_SHA256,
                "provenance_url": PROVENANCE_URL,
            },
        )
        self.assertNotIn("data:", text)
        self.assertLessEqual(len(text), 256)
        job = service.requests[0]
        self.assertEqual(job["protocol_version"], 1)
        self.assertEqual(job["action"], "image_generate")
        self.assertEqual(job["aspect"], "square")
        self.assertEqual(job["seed"], SEED)
        self.assertEqual(
            sorted(job),
            [
                "action",
                "aspect",
                "authorization",
                "height",
                "negative_prompt",
                "profile_id",
                "prompt",
                "protocol_version",
                "request_id",
                "seed",
                "steps",
                "width",
            ],
        )

    def test_dimensions_at_the_grant_maximum_run(self):
        self.start_echo_service()
        session = self.start_session()
        result = self.call(
            session,
            tool_arguments(
                self.grant(max_dimension=512, max_steps=4),
                width=512,
                height=512,
                steps=4,
            ),
        )
        self.assertFalse(result["isError"], result)

    def test_dimensions_above_the_grant_refused(self):
        self.start_echo_service()
        session = self.start_session()
        token = self.grant(max_dimension=512, aspect="1:1")
        result = self.call(
            session, tool_arguments(token, width=1024, height=1024)
        )
        self.assertTrue(result["isError"], result)
        self.assertIn("width exceeds max_dimension", self.result_text(result))
        steps = self.call(session, tool_arguments(self.grant(), steps=8))
        self.assertTrue(steps["isError"], steps)
        self.assertIn("steps exceeds max_steps", self.result_text(steps))

    def test_replayed_grant_refused(self):
        service = self.start_echo_service()
        session = self.start_session()
        token = self.grant()
        self.assertFalse(self.call(session, tool_arguments(token))["isError"])
        replay = self.call(session, tool_arguments(token))
        self.assertTrue(replay["isError"], replay)
        self.assertIn("spent", self.result_text(replay))
        self.assertEqual(len(service.requests), 1)

    def test_tampered_grant_refused(self):
        self.start_echo_service()
        session = self.start_session()
        token = self.grant()
        payload, signature = token.split(".")
        forged = web_server.base64url_encode(
            json.dumps(
                {
                    **json.loads(
                        web_server.base64url_decode(payload).decode("utf-8")
                    ),
                    "max_dimension": 4096,
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        )
        result = self.call(
            session, tool_arguments(f"{forged}.{signature}", width=1024, height=1024)
        )
        self.assertTrue(result["isError"], result)
        self.assertIn("signature fails verification", self.result_text(result))

    def test_expired_grant_refused(self):
        self.start_echo_service()
        session = self.start_session()
        token = self.grant(lifetime=60, now=time.time() - 3600)
        result = self.call(session, tool_arguments(token))
        self.assertTrue(result["isError"], result)
        self.assertIn("expired", self.result_text(result))

    def test_grant_for_another_profile_refused(self):
        self.start_echo_service()
        session = self.start_session()
        image = self.call(
            session,
            tool_arguments(
                self.grant(image_profile="other-image"),
                profile_id="other-image",
            ),
        )
        self.assertTrue(image["isError"], image)
        self.assertIn("image profile", self.result_text(image))
        language = self.call(
            session, tool_arguments(self.grant(language_profile="other-language"))
        )
        self.assertTrue(language["isError"], language)
        self.assertIn("language profile", self.result_text(language))

    def test_search_grant_never_verifies_as_a_generation_grant(self):
        """A grant signed under the search context refuses the image tool."""
        self.start_echo_service()
        session = self.start_session()
        search_token = web_server.issue_grant(
            self.token_key_path,
            PROMPT,
            [],
            [],
            "",
            "",
            None,
            5,
            "fake",
            IMAGE_PROFILE,
            900,
        )
        result = self.call(session, tool_arguments(search_token))
        self.assertTrue(result["isError"], result)
        self.assertIn("signature fails verification", self.result_text(result))

    # The arguments

    def test_argument_outside_the_schema_refused_by_name(self):
        self.start_echo_service()
        session = self.start_session()
        result = self.call(
            session, {**tool_arguments(self.grant()), "model": "sdxs-512"}
        )
        self.assertTrue(result["isError"], result)
        self.assertIn(
            "the call carries an argument the tool does not read: model",
            self.result_text(result),
        )

    def test_absent_seed_refused(self):
        self.start_echo_service()
        session = self.start_session()
        arguments = tool_arguments(self.grant())
        del arguments["seed"]
        result = self.call(session, arguments)
        self.assertTrue(result["isError"], result)
        self.assertIn("seed is required", self.result_text(result))

    def test_altered_prompt_refused(self):
        self.start_echo_service()
        session = self.start_session()
        result = self.call(
            session,
            tool_arguments(self.grant(), prompt="a raven in Bergen instead"),
        )
        self.assertTrue(result["isError"], result)
        self.assertIn("prompt differs", self.result_text(result))

    # The service boundary

    def test_service_refusal_maps_onto_an_error_result(self):
        service = self.start_echo_service(
            {
                "status": "refused",
                "reason": "lease_unavailable",
                "sha256": None,
                "provenance_url": None,
                "error": "the workload lease is held",
            }
        )
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        text = self.result_text(result)
        self.assertIn("refused the generation", text)
        self.assertIn("the workload lease is held", text)
        self.assertEqual(len(service.requests), 1)

    def test_service_refusal_and_absence_take_their_own_audit_terms(self):
        """The trail separates a declined job from a service that took none.

        `provider_http_error` names a remote HTTP provider and this lane
        reaches none, so a refusal writes `service_refused` and a socket no
        process listens on writes `service_unavailable`.
        """
        session = self.start_session()
        absent = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(absent["isError"], absent)
        self.start_echo_service(
            {
                "status": "refused",
                "reason": "profile_refused",
                "sha256": None,
                "provenance_url": None,
                "error": "the profile carries execution_policy refused",
            }
        )
        declined = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(declined["isError"], declined)
        self.assertEqual(
            [row[1] for row in self.audit_rows()],
            ["service_unavailable", "service_refused"],
        )

    def test_reply_naming_another_request_refused(self):
        self.start_service(
            StubService(
                self.socket_path,
                replies=[completed_reply("another-request-identifier")],
            )
        )
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("another request", self.result_text(result))

    def test_service_failure_text_reaches_the_model(self):
        self.start_echo_service(
            {
                "status": "failed",
                "reason": "runtime_failed",
                "sha256": None,
                "provenance_url": None,
                "error": "vk\ndevice lost",
            }
        )
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        text = self.result_text(result)
        self.assertIn("failed the generation", text)
        self.assertIn("vk device lost", text)

    def test_accepted_alone_refuses_a_synchronous_call(self):
        self.start_echo_service(
            {"status": "accepted", "sha256": None, "provenance_url": None}
        )
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("accepted the generation", self.result_text(result))

    def test_status_outside_the_protocol_refused(self):
        self.start_echo_service({"status": "done", "sha256": None,
                                 "provenance_url": None})
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("outside the protocol", self.result_text(result))

    def test_provenance_url_naming_another_digest_refused(self):
        """The route is derived from the digest, so one spelling is admitted."""
        self.start_echo_service(
            {"provenance_url": "/artifacts/" + "c" * 64 + ".json"}
        )
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("does not name the digest", self.result_text(result))

    def test_provenance_url_carrying_an_origin_refused(self):
        """A reply names a route rather than a host.

        The artifact listener is the reader's own credentialed origin, so a
        reply carrying one would hand the page a host the digest does not
        identify.
        """
        self.start_echo_service(
            {
                "provenance_url": (
                    f"http://images.example.net/artifacts/{ARTIFACT_SHA256}.json"
                )
            }
        )
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("does not name the digest", self.result_text(result))

    def test_absent_service_refuses_without_spending_the_grant(self):
        session = self.start_session()
        token = self.grant()
        absent = self.call(session, tool_arguments(token))
        self.assertTrue(absent["isError"], absent)
        self.assertIn("unreachable", self.result_text(absent))
        self.start_echo_service()
        served = self.call(session, tool_arguments(token))
        self.assertFalse(served["isError"], served)

    def test_a_service_that_accepts_and_dies_spends_the_grant(self):
        """One approval buys one attempt past the connect.

        The connect proves a listener took the connection rather than that the
        service reads the line, so a stub that accepts and closes unanswered
        has already spent the grant. The second call reports the spend rather
        than running the generation again, which is what keeps one approval
        from reaching the runtime twice.
        """
        self.start_service(StubService(self.socket_path, replies=[]))
        session = self.start_session()
        token = self.grant()
        first = self.call(session, tool_arguments(token))
        self.assertTrue(first["isError"], first)
        self.assertIn("closed the connection unanswered", self.result_text(first))
        second = self.call(session, tool_arguments(token))
        self.assertTrue(second["isError"], second)
        self.assertIn("spent", self.result_text(second))

    def test_unparseable_reply_refused(self):
        self.start_service(
            StubService(self.socket_path, replies=[b"not json at all\n"])
        )
        session = self.start_session()
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("not UTF-8 JSON", self.result_text(result))

    def test_silent_service_meets_the_tool_deadline(self):
        self.start_service(
            StubService(self.socket_path, replies=[], answer=False)
        )
        session = ImageServerSession(self.environment(), timeout_value=1)
        self.sessions.append(session)
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("second tool deadline", self.result_text(result))

    def test_unconfigured_socket_refuses_the_call(self):
        session = ImageServerSession(
            {**self.environment(), "QWEN_IMAGE_SERVICE_SOCKET": ""}
        )
        self.sessions.append(session)
        result = self.call(session, tool_arguments(self.grant()))
        self.assertTrue(result["isError"], result)
        self.assertIn("QWEN_IMAGE_SERVICE_SOCKET", self.result_text(result))


if __name__ == "__main__":
    unittest.main(verbosity=2)
