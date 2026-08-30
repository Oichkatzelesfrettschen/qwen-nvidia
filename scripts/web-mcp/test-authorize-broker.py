#!/usr/bin/env python3
"""Drive the approval broker over its own socket with the fake provider.

Each arm launches the broker as a subprocess the way a session launches it,
reads the listening port from its first stdout line, and speaks HTTP to that
port, so the bind refusal, the CORS preflight, the session header, and the
audit rows are measured on the wire rather than through an imported handler.
The grant the broker issues is then spent against `server.py` itself under a
fake provider, which is what proves the two paths agree on one canonical
claim without reaching a network or a key of the operator's.
"""

import hashlib
import http.client
import importlib.util
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor

BROKER_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
BROKER_PATH = os.path.join(BROKER_DIRECTORY, "authorize-broker.py")
SERVER_PATH = os.path.join(BROKER_DIRECTORY, "server.py")
sys.path.insert(0, BROKER_DIRECTORY)

import server  # noqa: E402


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

TOKEN_SECRET = "broker-token-secret-QJ4LZP"
API_KEY = "web-ui-api-key-V8N2QK"
ORIGIN = "http://127.0.0.1:8080"
START_WAIT_SECONDS = 15.0
STOP_WAIT_SECONDS = 5.0
# What the broker's own shutdown sequence costs. A terminating signal raises
# inside `serve_forever`, whose selector poll is 0.5 s, and `server_close` then
# joins every handler thread because BrokerServer sets `daemon_threads = False`
# with `block_on_close = True`; a handler blocked on a client that stopped
# writing leaves after its own 5 s request read timeout. The unlink of the
# session secret follows that join in the same `finally`, so the file is gone
# exactly when the process is. The bound is those two terms with room for a
# loaded runner, and it exists so the wait never ends in a SIGKILL: a killed
# broker skips the unlink, which is the property the residue arm measures.
BROKER_SHUTDOWN_WAIT_SECONDS = 30.0

FIXTURES = {
    "search": {
        "bench vulkan decode": [
            {
                "title": "Vulkan decode on Bench",
                "url": "https://example.org/bench",
                "publishedDate": "2026-01-05",
                "author": "A. Measurer",
                "highlights": ["decode reaches 3.07 tok/s"],
            }
        ]
    },
    "contents": {
        "https://example.org/bench": {"text": "measured decode", "status": "ok"}
    },
}


class BrokerProcess:
    """A running broker and the client that speaks to its port."""

    def __init__(self, test, **overrides):
        self.test = test
        arguments = {
            "--state-dir": test.state_directory,
            "--token-key-file": test.token_key_path,
            "--api-key-file": test.api_key_path,
            "--provider": "fake",
            "--profile": "default",
            "--origin": ORIGIN,
        }
        arguments.update(overrides)
        argv = [sys.executable, BROKER_PATH]
        for option, value in arguments.items():
            if value is not None:
                argv += [option, str(value)]
        self.process = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.host = ""
        self.port = 0
        line = self.process.stdout.readline()
        parts = line.split()
        if len(parts) == 3 and parts[0] == "listening":
            self.host, self.port = parts[1], int(parts[2])

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            connection.request(method, path, body, headers or {})
            response = connection.getresponse()
            payload = response.read().decode("utf-8")
            return response.status, dict(response.getheaders()), payload
        finally:
            connection.close()

    def close(self):
        """End the broker on SIGTERM and report whether it unwound itself.

        The SIGKILL is a last resort rather than a deadline: it skips the
        cleanup that removes the session secret, so an arm reading that file
        checks the returned status instead of racing the unwind.
        """
        if self.process.poll() is None:
            self.process.terminate()
        unwound = True
        try:
            self.process.wait(timeout=BROKER_SHUTDOWN_WAIT_SECONDS)
        except subprocess.TimeoutExpired:
            unwound = False
            self.process.kill()
            self.process.wait(timeout=STOP_WAIT_SECONDS)
        self.process.stdout.close()
        self.process.stderr.close()
        return unwound


class BrokerTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        root = self.workspace.name
        self.state_directory = os.path.join(root, "state")
        os.makedirs(self.state_directory, mode=0o700)
        self.token_key_path = os.path.join(root, "token.key")
        with open(self.token_key_path, "w", encoding="utf-8") as handle:
            handle.write(TOKEN_SECRET + "\n")
        os.chmod(self.token_key_path, 0o600)
        self.api_key_path = os.path.join(root, "api.key")
        with open(self.api_key_path, "w", encoding="utf-8") as handle:
            handle.write(API_KEY + "\n")
        os.chmod(self.api_key_path, 0o600)
        self.fixture_path = os.path.join(root, "fixtures.json")
        with open(self.fixture_path, "w", encoding="utf-8") as handle:
            json.dump(FIXTURES, handle)
        self.brokers = []
        self.addCleanup(self.workspace.cleanup)
        self.addCleanup(self.stop_brokers)

    def stop_brokers(self):
        for broker in self.brokers:
            broker.close()

    def launch(self, **overrides):
        broker = BrokerProcess(self, **overrides)
        self.brokers.append(broker)
        return broker

    def session_secret(self):
        """Read the secret from its file rather than through the endpoint.

        The file is the delivery channel a page uses, so reading it here
        exercises the same authority the browser presents while leaving the
        `/session` arm free to measure the Origin gate on its own.
        """
        path = os.path.join(
            self.state_directory, SESSION_SECRET_FILE_NAME
        )
        deadline = time.time() + START_WAIT_SECONDS
        while time.time() < deadline:
            if os.path.exists(path):
                with open(path, encoding="ascii") as handle:
                    return handle.read().strip()
            time.sleep(0.05)
        self.fail("the broker wrote no session secret file")

    def grant_headers(self, secret=None):
        return {
            "Content-Type": "application/json",
            "Origin": ORIGIN,
            SESSION_HEADER: (
                self.session_secret() if secret is None else secret
            ),
        }

    def session_headers(self, api_key=API_KEY):
        return {
            "Origin": ORIGIN,
            "Authorization": f"Bearer {api_key}",
        }

    def post_grant(self, broker, payload, headers=None):
        status, response_headers, body = broker.request(
            "POST",
            "/grant",
            json.dumps(payload),
            self.grant_headers() if headers is None else headers,
        )
        return status, response_headers, json.loads(body)

    def audit_rows(self):
        connection = sqlite3.connect(
            os.path.join(self.state_directory, server.LEDGER_FILE_NAME)
        )
        try:
            return connection.execute(
                "SELECT profile, operation, query_sha256, domains, result_count,"
                " fetched_host, provider_bytes, returned_characters, status"
                " FROM audit"
            ).fetchall()
        finally:
            connection.close()

    def spend(self, token, **overrides):
        """Run one `search_exa` through the server with this grant."""
        arguments = {
            "query": "bench vulkan decode",
            "max_results": 1,
            "authorization": token,
        }
        arguments.update(overrides)
        requests = [
            {
                "jsonrpc": "2.0",
                "id": "1",
                "method": "initialize",
                "params": {"protocolVersion": server.PROTOCOL_VERSION},
            },
            {
                "jsonrpc": "2.0",
                "id": "2",
                "method": "tools/call",
                "params": {"name": "search_exa", "arguments": arguments},
            },
        ]
        completed = subprocess.run(
            [sys.executable, SERVER_PATH],
            input="".join(json.dumps(entry) + "\n" for entry in requests),
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "PYTHONDONTWRITEBYTECODE": "1",
                "QWEN_WEB_PROVIDER": "fake",
                "QWEN_WEB_FAKE_FIXTURES": self.fixture_path,
                "QWEN_WEB_TOKEN_KEY_FILE": self.token_key_path,
                "QWEN_WEB_STATE_DIR": self.state_directory,
                "QWEN_WEB_SEARCH_AUTH": "required",
                "QWEN_WEB_PROFILE": "default",
            },
        )
        for line in completed.stdout.splitlines():
            message = json.loads(line)
            if message.get("id") == "2":
                return message
        self.fail(f"the server returned no tool result: {completed.stderr}")

    def test_the_broker_refuses_a_bind_outside_loopback(self):
        for host in ("0.0.0.0", "localhost", "192.168.1.10", "::"):
            with self.subTest(host=host):
                completed = subprocess.run(
                    [
                        sys.executable,
                        BROKER_PATH,
                        "--host",
                        host,
                        "--state-dir",
                        self.state_directory,
                        "--token-key-file",
                        self.token_key_path,
                        "--origin",
                        ORIGIN,
                    ],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(completed.returncode, 2)
                self.assertIn("loopback literal alone", completed.stderr)
                self.assertEqual(completed.stdout, "")

    def run_broker_expecting_refusal(self, token_key_file, expected_message):
        completed = subprocess.run(
            [
                sys.executable,
                BROKER_PATH,
                "--state-dir",
                self.state_directory,
                "--token-key-file",
                token_key_file,
                "--origin",
                ORIGIN,
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn(expected_message, completed.stderr)
        self.assertEqual(completed.stdout, "")
        return completed

    def test_an_absent_signing_key_path_is_refused_at_startup(self):
        self.run_broker_expecting_refusal(
            os.path.join(self.workspace.name, "no-such-key"),
            "unreadable",
        )

    def test_a_signing_key_readable_outside_its_owner_is_refused(self):
        loose_path = os.path.join(self.workspace.name, "loose.key")
        with open(loose_path, "w", encoding="utf-8") as handle:
            handle.write(TOKEN_SECRET + "\n")
        os.chmod(loose_path, 0o644)
        self.run_broker_expecting_refusal(loose_path, "chmod 0600")

    def test_a_signing_key_that_is_a_symlink_is_refused(self):
        link_path = os.path.join(self.workspace.name, "key.link")
        os.symlink(self.token_key_path, link_path)
        self.run_broker_expecting_refusal(link_path, "symlink")

    def test_an_empty_signing_key_is_refused(self):
        empty_path = os.path.join(self.workspace.name, "empty.key")
        open(empty_path, "wb").close()
        os.chmod(empty_path, 0o600)
        self.run_broker_expecting_refusal(empty_path, "empty")

    def test_a_whitespace_signing_key_is_refused(self):
        whitespace_path = os.path.join(self.workspace.name, "whitespace.key")
        with open(whitespace_path, "w", encoding="utf-8") as handle:
            handle.write(" \t\n")
        os.chmod(whitespace_path, 0o600)
        self.run_broker_expecting_refusal(whitespace_path, "empty")

    def test_a_non_utf8_signing_key_is_refused(self):
        invalid_path = os.path.join(self.workspace.name, "invalid-utf8.key")
        with open(invalid_path, "wb") as handle:
            handle.write(b"\xff\xfe")
        os.chmod(invalid_path, 0o600)
        self.run_broker_expecting_refusal(invalid_path, "not UTF-8 text")

    def test_the_broker_requires_a_state_directory_and_an_origin(self):
        for argv, expected in (
            (["--token-key-file", self.token_key_path, "--origin", ORIGIN],
             "QWEN_WEB_STATE_DIR"),
            (["--token-key-file", self.token_key_path,
              "--state-dir", self.state_directory], "QWEN_WEB_BROKER_ORIGIN"),
        ):
            with self.subTest(argv=argv):
                completed = subprocess.run(
                    [sys.executable, BROKER_PATH, *argv],
                    capture_output=True,
                    text=True,
                    env={
                        **os.environ,
                        "QWEN_WEB_STATE_DIR": "",
                        "QWEN_WEB_BROKER_ORIGIN": "",
                    },
                )
                self.assertEqual(completed.returncode, 2)
                self.assertIn(expected, completed.stderr)

    def test_the_broker_requires_the_web_ui_api_key_at_startup(self):
        completed = subprocess.run(
            [
                sys.executable,
                BROKER_PATH,
                "--state-dir",
                self.state_directory,
                "--token-key-file",
                self.token_key_path,
                "--origin",
                ORIGIN,
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "QWEN_WEBUI_API_KEY_FILE": ""},
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("Web UI API key", completed.stderr)

    def test_a_grant_request_without_the_session_secret_is_refused(self):
        broker = self.launch()
        headers = self.grant_headers()
        for description, replacement in (
            ("absent", None),
            ("empty", ""),
            ("wrong", "a-secret-this-launch-never-wrote"),
        ):
            with self.subTest(secret=description):
                sent = dict(headers)
                if replacement is None:
                    sent.pop(SESSION_HEADER)
                else:
                    sent[SESSION_HEADER] = replacement
                status, _, payload = self.post_grant(
                    broker, {"query": "bench vulkan decode"}, sent
                )
                self.assertEqual(status, 403)
                self.assertIn(SESSION_HEADER, payload["error"])
                self.assertNotIn("authorization", payload)

    def test_a_grant_request_from_a_foreign_origin_is_refused(self):
        """The secret alone buys nothing from a page the launch did not name."""
        broker = self.launch()
        for description, origin in (
            ("foreign", "http://localhost:8080"),
            ("absent", None),
        ):
            with self.subTest(origin=description):
                sent = self.grant_headers()
                if origin is None:
                    sent.pop("Origin")
                else:
                    sent["Origin"] = origin
                status, _, payload = self.post_grant(
                    broker,
                    {"query": "bench vulkan decode", "profile_id": "default"},
                    sent,
                )
                self.assertEqual(status, 403)
                self.assertIn("Origin", payload["error"])
                self.assertNotIn("authorization", payload)

    def test_the_session_endpoint_requires_origin_and_the_web_ui_bearer_key(self):
        broker = self.launch()
        secret = self.session_secret()
        for description, headers in (
            ("absent", {}),
            ("foreign", {"Origin": "https://evil.example.net"}),
            ("missing bearer", {"Origin": ORIGIN}),
            ("wrong bearer", self.session_headers("not-the-api-key")),
        ):
            with self.subTest(origin=description):
                status, _, body = broker.request("GET", "/session", None, headers)
                self.assertEqual(status, 403)
                self.assertNotIn(secret, body)
        status, response_headers, body = broker.request(
            "GET", "/session", None, self.session_headers()
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["session_secret"], secret)
        self.assertEqual(response_headers["Access-Control-Allow-Origin"], ORIGIN)
        self.assertNotIn("*", response_headers["Access-Control-Allow-Origin"])
        self.assertNotIn("Access-Control-Allow-Credentials", response_headers)

    def test_the_preflight_admits_the_session_header_for_one_origin(self):
        broker = self.launch()
        status, headers, _ = broker.request(
            "OPTIONS",
            "/grant",
            None,
            {
                "Origin": ORIGIN,
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": SESSION_HEADER,
            },
        )
        self.assertEqual(status, 204)
        self.assertEqual(headers["Access-Control-Allow-Origin"], ORIGIN)
        self.assertIn(
            SESSION_HEADER, headers["Access-Control-Allow-Headers"]
        )
        self.assertIn(
            "Authorization", headers["Access-Control-Allow-Headers"]
        )
        status, headers, _ = broker.request(
            "OPTIONS", "/grant", None, {"Origin": "https://evil.example.net"}
        )
        self.assertEqual(status, 403)
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_a_host_header_naming_a_resolved_name_is_refused(self):
        broker = self.launch()
        headers = self.grant_headers()
        headers["Host"] = f"rebind.example.net:{broker.port}"
        status, _, payload = self.post_grant(
            broker, {"query": "bench vulkan decode"}, headers
        )
        self.assertEqual(status, 403)
        self.assertIn("loopback literal", payload["error"])

    def test_the_issued_grant_admits_the_search_exactly_once(self):
        broker = self.launch()
        status, _, payload = self.post_grant(
            broker,
            {"query": "  bench vulkan decode  ", "max_results": 1, "profile_id": "default"},
        )
        self.assertEqual(status, 200)
        token = payload["authorization"]
        first = self.spend(token)
        self.assertFalse(first["result"]["isError"])
        self.assertIn("URL: https://example.org/bench", self.text(first))
        replayed = self.spend(token)
        self.assertTrue(replayed["result"]["isError"])
        self.assertIn("spent", self.text(replayed))

    def test_a_changed_field_leaves_the_grant(self):
        broker = self.launch()
        status, _, payload = self.post_grant(
            broker,
            {
                "query": "bench vulkan decode",
                "max_results": 3,
                "include_domains": ["Example.ORG"],
                "max_age_hours": 24,
                "profile_id": "default",
            },
        )
        self.assertEqual(status, 200)
        token = payload["authorization"]
        for description, overrides in (
            ("query", {"query": "bench vulkan decode in Paris"}),
            ("include_domains", {"include_domains": ["evil.example.net"]}),
            ("exclude_domains", {"exclude_domains": ["example.org"]}),
            ("max_age_hours", {"max_age_hours": 0}),
            ("published_after", {"published_after": "2026-01-01"}),
            ("max_results", {"max_results": 10}),
        ):
            with self.subTest(field=description):
                arguments = {
                    "max_results": 3,
                    "include_domains": ["example.org"],
                    "max_age_hours": 24,
                }
                arguments.update(overrides)
                response = self.spend(token, **arguments)
                self.assertTrue(response["result"]["isError"])
                self.assertIn("authorization", self.text(response))
        admitted = self.spend(
            token,
            max_results=2,
            include_domains=["example.org"],
            max_age_hours=24,
        )
        self.assertFalse(admitted["result"]["isError"])

    def test_a_malformed_field_is_refused_before_the_key_is_read(self):
        # Startup validates the key file's own bytes
        # (test_an_absent_signing_key_path_is_refused_at_startup and its
        # siblings), so a launched broker always names a readable key; this
        # arm proves `parse_request_arguments` still refuses a malformed
        # field ahead of `issue_grant`'s own read of that file.
        broker = self.launch()
        for payload in (
            {"query": 5},
            {"query": "q", "max_results": "many"},
            {"query": "q", "include_domains": "example.org"},
            {"query": "q", "max_age_hours": "soon"},
        ):
            with self.subTest(payload=sorted(payload)):
                status, _, body = self.post_grant(broker, payload)
                self.assertEqual(status, 400)
                self.assertNotIn("authorization", body)

    def test_a_request_naming_no_profile_id_is_refused(self):
        # The grant is bound to the profile whose MCP child will verify it
        # (`enforce_search_authorization` in server.py), so a request that
        # names no profile at all is refused before a token is signed rather
        # than signed against the broker's own launch profile silently.
        broker = self.launch()
        for payload in (
            {"query": "bench vulkan decode"},
            {"query": "bench vulkan decode", "profile_id": ""},
            {"query": "bench vulkan decode", "profile_id": 7},
        ):
            with self.subTest(payload=sorted(payload)):
                status, _, body = self.post_grant(broker, payload)
                self.assertEqual(status, 400)
                self.assertIn("profile_id", body["error"])
                self.assertNotIn("authorization", body)

    def test_a_request_naming_another_profile_is_refused(self):
        # A grant signed for the wrong profile reads as authorized to this
        # broker and is rejected downstream by the child serving the
        # requested profile; refusing it here reports the mismatch where the
        # human approval happened instead of at the MCP boundary.
        broker = self.launch(**{"--profile": "fast-text"})
        status, _, body = self.post_grant(
            broker,
            {"query": "bench vulkan decode", "profile_id": "vision"},
        )
        self.assertEqual(status, 400)
        self.assertIn("fast-text", body["error"])
        self.assertIn("vision", body["error"])
        self.assertNotIn("authorization", body)
        self.assertIn("invalid_argument", [row[8] for row in self.audit_rows()])

    def test_an_inverted_publication_window_is_refused_before_signing(self):
        broker = self.launch()
        status, _, body = self.post_grant(
            broker,
            {
                "query": "bench vulkan decode",
                "profile_id": "default",
                "published_after": "2026-08-01",
                "published_before": "2026-07-31",
            },
        )
        self.assertEqual(status, 400)
        self.assertIn("published_after falls after published_before", body["error"])
        self.assertNotIn("authorization", body)

    def test_the_rate_bucket_bounds_the_approval_endpoint(self):
        broker = self.launch(**{"--per-minute": 2})
        for _ in range(2):
            status, _, _ = self.post_grant(
                broker, {"query": "bench vulkan decode", "profile_id": "default"}
            )
            self.assertEqual(status, 200)
        def exhaust(_index):
            return self.post_grant(
                broker, {"query": "bench vulkan decode"}
            )

        with ThreadPoolExecutor(max_workers=5) as executor:
            refusals = list(executor.map(exhaust, range(5)))
        for status, _, payload in refusals:
            self.assertEqual(status, 429)
            self.assertIn("authorize-minute", payload["error"])
        statuses = [row[8] for row in self.audit_rows()]
        self.assertEqual(statuses.count("rate_limited"), 1)

    def test_a_stale_session_refusal_has_an_explicit_retry_code(self):
        broker = self.launch()
        headers = self.grant_headers("a-secret-this-launch-never-wrote")
        status, _, payload = self.post_grant(
            broker,
            {"query": "bench vulkan decode", "profile_id": "default"},
            headers,
        )
        self.assertEqual(status, 403)
        self.assertEqual(payload["code"], "stale_session_secret")

    def test_a_bad_session_header_spends_the_same_bucket(self):
        broker = self.launch(**{"--per-minute": 2})
        headers = self.grant_headers()
        headers[SESSION_HEADER] = "a-secret-this-launch-never-wrote"
        for _ in range(2):
            status, _, payload = self.post_grant(
                broker, {"query": "bench vulkan decode"}, headers
            )
            self.assertEqual(status, 403)
            self.assertIn(SESSION_HEADER, payload["error"])
        status, _, payload = self.post_grant(
            broker, {"query": "bench vulkan decode"}, headers
        )
        self.assertEqual(status, 429)
        self.assertIn("authorize-minute", payload["error"])
        statuses = [row[8] for row in self.audit_rows()]
        self.assertEqual(statuses.count("authorization_denied"), 2)
        self.assertEqual(statuses.count("rate_limited"), 1)
        # The bucket admitted no valid grant in this arm, so a caller that
        # never presents a real session cannot outrun the meter by failing.
        status, _, payload = self.post_grant(broker, {"query": "bench vulkan decode"})
        self.assertEqual(status, 429)

    def test_concurrent_grants_use_independent_ledger_connections(self):
        request_count = 4
        broker = self.launch(**{"--per-minute": request_count})

        def issue(index):
            return self.post_grant(
                broker,
                {
                    "query": f"bench vulkan decode {index}",
                    "profile_id": "default",
                },
            )[0]

        with ThreadPoolExecutor(max_workers=request_count) as executor:
            statuses = list(executor.map(issue, range(request_count)))
        self.assertEqual(statuses, [200] * request_count)
        self.assertEqual(
            [row[8] for row in self.audit_rows()].count("success"),
            request_count,
        )

    def test_a_slow_request_has_a_total_deadline_and_blocks_no_peer(self):
        timeout_seconds = 0.4
        broker = self.launch(
            **{"--request-read-timeout": timeout_seconds}
        )
        slow_client = socket.create_connection((broker.host, broker.port), timeout=2)
        self.addCleanup(slow_client.close)
        partial_request = (
            f"POST /grant HTTP/1.1\r\n"
            f"Host: {broker.host}:{broker.port}\r\n"
            f"Origin: {ORIGIN}\r\n"
            f"{SESSION_HEADER}: {self.session_secret()}\r\n"
            "Content-Type: application/json\r\n"
            "Content-Length: 128\r\n\r\n"
            "{"
        )
        slow_client.sendall(partial_request.encode("ascii"))
        peer_started = time.monotonic()
        status, _, _ = broker.request("GET", "/health")
        peer_elapsed = time.monotonic() - peer_started
        self.assertEqual(status, 200)
        self.assertLess(peer_elapsed, timeout_seconds / 2)

        slow_client.settimeout(timeout_seconds * 3)
        deadline_started = time.monotonic()
        self.assertEqual(slow_client.recv(1), b"")
        self.assertLess(time.monotonic() - deadline_started, timeout_seconds * 3)

    def test_the_audit_trail_carries_the_digest_and_no_secret(self):
        broker = self.launch()
        status, _, payload = self.post_grant(
            broker,
            {
                "query": "bench vulkan decode",
                "max_results": 4,
                "include_domains": ["example.org"],
                "exclude_domains": ["evil.example.net"],
                "profile_id": "default",
            },
        )
        self.assertEqual(status, 200)
        token = payload["authorization"]
        self.post_grant(broker, {"query": 5})
        rows = self.audit_rows()
        self.assertEqual([row[1] for row in rows], ["authorize", "authorize"])
        self.assertEqual(
            sorted(row[8] for row in rows), ["invalid_argument", "success"]
        )
        issued = next(row for row in rows if row[8] == "success")
        self.assertEqual(issued[2], query_digest("bench vulkan decode"))
        self.assertEqual(issued[3], "example.org,-evil.example.net")
        self.assertEqual(issued[4], 4)
        flattened = "\n".join(str(field) for row in rows for field in row)
        self.assertNotIn(TOKEN_SECRET, flattened)
        self.assertNotIn(token, flattened)
        self.assertNotIn("bench vulkan decode", flattened)
        self.assertNotIn(self.session_secret(), flattened)

    def test_the_secret_file_is_private_and_leaves_no_residue(self):
        broker = self.launch()
        path = os.path.join(
            self.state_directory, SESSION_SECRET_FILE_NAME
        )
        self.session_secret()
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        # The unlink runs in the `finally` that follows `server_close`, so the
        # secret is gone once the process is: waiting on the exit rather than
        # polling the path removes the timing dependence, and the assertion
        # keeps its intent on a runner of any speed.
        self.assertTrue(
            broker.close(),
            "the broker unwound from SIGTERM rather than needing SIGKILL",
        )
        self.assertIsNotNone(broker.process.returncode)
        self.assertFalse(os.path.lexists(path))

    def test_no_response_or_stream_carries_the_signing_key(self):
        broker = self.launch()
        status, _, payload = self.post_grant(
            broker, {"query": "bench vulkan decode", "profile_id": "default"}
        )
        self.assertEqual(status, 200)
        self.assertNotIn(TOKEN_SECRET, json.dumps(payload))
        # A refusal path is what would raise, so the malformed request runs
        # before stderr is read: a traceback carrying the key would arrive
        # there rather than in the response the client already checked.
        self.post_grant(broker, {"query": 5})
        secret = self.session_secret()
        broker.process.terminate()
        broker.process.wait(timeout=STOP_WAIT_SECONDS)
        stderr = broker.process.stderr.read()
        self.assertNotIn(TOKEN_SECRET, stderr)
        self.assertNotIn("bench vulkan decode", stderr)
        self.assertNotIn(secret, stderr)

    def image_grant_body(self, **overrides):
        """Return one qwen-image-generate-v1 request the page would post."""
        empty = hashlib.sha256(b"").hexdigest()
        fields = {
            "context": "qwen-image-generate-v1",
            "language_profile": "default",
            "image_profile": "image-fixture-a",
            "prompt_hash": hashlib.sha256(b"a fox").hexdigest(),
            "negative_prompt_hash": empty,
            "seed": 7,
            "aspect": "1:1",
            "max_dimension": 512,
            "max_steps": 4,
            "conversation_generation": 0,
        }
        fields.update(overrides)
        return fields

    def test_image_grant_binds_both_profiles(self):
        """The claim joins two profiles, so two arguments bind them.

        `image_grant.enforce_image_authorization` compares the claim's
        `language_profile` against `QWEN_IMAGE_LANGUAGE_PROFILE` and its
        `image_profile` against `QWEN_IMAGE_PROFILE`, and the MCP child reads
        those from separate settings. One broker argument for both would sign
        a claim naming the language profile twice, which the child then
        refuses, so no grant could ever be spent.
        """
        broker = self.launch(**{"--image-profile": "image-fixture-a"})
        secret = self.session_secret()
        status, _, body = broker.request(
            "POST", "/grant-image", json.dumps(self.image_grant_body()),
            self.grant_headers(secret))
        self.assertEqual(status, 200, body)
        self.assertTrue(json.loads(body)["authorization"])
        for overrides, named in (
            ({"image_profile": "image-other"}, "image profile"),
            ({"language_profile": "web-other"}, "language profile"),
        ):
            status, _, body = broker.request(
                "POST", "/grant-image", json.dumps(self.image_grant_body(**overrides)),
                self.grant_headers(secret))
            self.assertEqual(status, 400, body)
            self.assertIn(named, json.loads(body)["error"])

    def test_image_grant_refused_where_no_lane_is_armed(self):
        """A launch that armed no image lane signs no generation grant."""
        broker = self.launch()
        status, _, body = broker.request(
            "POST", "/grant-image", json.dumps(self.image_grant_body()),
            self.grant_headers())
        self.assertEqual(status, 400, body)
        self.assertIn("no image profile", json.loads(body)["error"])

    def test_health_reports_process_identity_and_needs_no_origin(self):
        broker = self.launch()
        status, _, body = broker.request("GET", "/health")
        self.assertEqual(status, 200)
        payload = json.loads(body)
        self.assertEqual(
            set(payload),
            {
                "protocol",
                "profile",
                "image_profile",
                "provider",
                "pid",
                "start_time",
                "signing_key_sha256",
                "state_dir",
                "origins",
            },
        )
        self.assertEqual(payload["protocol"], "qwen-web-broker/1")
        self.assertEqual(payload["profile"], "default")
        self.assertEqual(payload["provider"], "fake")
        self.assertEqual(payload["pid"], broker.process.pid)
        self.assertEqual(
            payload["signing_key_sha256"],
            hashlib.sha256((TOKEN_SECRET + "\n").encode("utf-8")).hexdigest(),
        )
        self.assertEqual(payload["origins"], [ORIGIN])
        self.assertIsInstance(payload["start_time"], int)
        state_status = os.stat(self.state_directory)
        self.assertEqual(
            payload["state_dir"], f"{state_status.st_dev}:{state_status.st_ino}"
        )

    def test_health_refuses_a_non_loopback_host_header(self):
        broker = self.launch()
        status, _, body = broker.request(
            "GET", "/health", None, {"Host": "evil.example"}
        )
        self.assertEqual(status, 403)
        self.assertNotIn(TOKEN_SECRET, body)

    def test_health_never_carries_the_signing_key_bytes(self):
        broker = self.launch()
        status, _, body = broker.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertNotIn(TOKEN_SECRET, body)

    def text(self, message):
        return message["result"]["content"][0]["text"]

    def test_the_usage_text_states_profile_id_is_required(self):
        # `parse_request_arguments` refuses a `POST /grant` naming no
        # `profile_id` (test_a_request_naming_no_profile_id_is_refused), so
        # the broker's own --help and the module docstring it is built from
        # must say so rather than leaving a caller to infer the requirement
        # from a 400 response.
        help_text = subprocess.run(
            [sys.executable, BROKER_PATH, "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=True,
        ).stdout.decode("utf-8")
        self.assertIn("profile_id", help_text)
        self.assertIn("--profile", help_text)

    def test_the_readme_states_profile_id_is_required(self):
        readme_path = os.path.join(BROKER_DIRECTORY, "README.md")
        with open(readme_path, encoding="utf-8") as readme_file:
            readme_text = readme_file.read()
        self.assertIn("profile_id", readme_text)
        self.assertIn("requires `profile_id`", readme_text)


def query_digest(query):
    return hashlib.sha256(query.strip().encode("utf-8")).hexdigest()


if __name__ == "__main__":
    unittest.main(verbosity=2)
