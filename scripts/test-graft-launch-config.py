"""Exercise Graft launch snapshots and broker grants without model execution."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parent


def load_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


launcher = load_module("graft_launch_config", SCRIPTS / "graft-launch-config.py")
workflow = load_module("graft_workflow_test", SCRIPTS / "graft-workflow.py")
broker_test = load_module("graft_broker_test", SCRIPTS / "web-mcp/test-authorize-broker.py")


class GraftLaunchTest(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("QWEN_WEB_PROFILE", None)
        output_ancestors = [parent for parent in SCRIPTS.parents if parent.name == ".local-artifacts"]
        boundary = output_ancestors[-1] if output_ancestors else SCRIPTS.parent / ".local-artifacts"
        boundary.mkdir(exist_ok=True)
        self.workspace = tempfile.TemporaryDirectory(prefix="graft-launch-test-", dir=boundary)
        self.addCleanup(self.workspace.cleanup)
        root = Path(self.workspace.name)
        source = root / "source"
        source.mkdir()
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty",
                        "-qm", "fixture"], check=True)
        self.state_directory = str(root / "state")
        Path(self.state_directory).mkdir(mode=0o700)
        self.token_key_path = str(root / "token.key")
        self.api_key_path = str(Path(self.state_directory) / "api.key")
        for path, content in ((self.token_key_path, "x" * 64 + "\n"),
                              (self.api_key_path, broker_test.API_KEY)):
            Path(path).write_text(content)
            os.chmod(path, 0o600)
        self.config = {
            "version": 1, "artifact_root": str(root / "output"),
            "graft_executable": "/usr/bin/true", "bwrap_executable": "/usr/bin/true",
            "authorization_key_file": self.token_key_path,
            "repositories": {"fixture": {"path": str(source), "allowed_paths": []}},
            "model": {"base_url": "http://127.0.0.1:8080/v1", "name": "qwen-nvidia",
                      "api_key_file": self.api_key_path},
            "limits": {"seconds": 5, "log_bytes": 1024, "maximum_paths": 2},
        }
        self.config_path = root / "config.json"
        self.write_config()

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config))

    def launch_broker(self, environment=None):
        options = {"--graft-config": str(self.config_path)}
        if environment:
            options.update({"--graft-config": environment["QWEN_GRAFT_CONFIG"],
                            "--profile": environment["QWEN_WEB_PROFILE"],
                            "--token-key-file": environment["QWEN_WEB_TOKEN_KEY_FILE"]})
        broker = broker_test.BrokerProcess(self, **options)
        self.addCleanup(broker.close)
        self.assertGreater(broker.port, 0)
        status, _, body = broker.request("GET", "/session", headers={
            "Origin": broker_test.ORIGIN, "Authorization": f"Bearer {broker_test.API_KEY}"})
        self.assertEqual(status, 200)
        secret = json.loads(body)["session_secret"]
        return broker, {"Origin": broker_test.ORIGIN, "X-Qwen-Web-Session": secret,
                        "Content-Type": "application/json"}

    def test_launch_preserves_existing_mcp_and_pins_config(self):
        base = Path(self.workspace.name) / "base.json"
        base.write_text(json.dumps({"mcpServers": {"retained": {"command": "/usr/bin/true"}}}))
        environment = launcher.prepare(self.config_path, base)
        mcp = json.loads(Path(environment["QWEN_GRAFT_MCP_CONFIG"]).read_text())
        self.assertEqual(mcp["mcpServers"]["retained"], {"command": "/usr/bin/true"})
        self.assertEqual(mcp["mcpServers"]["qwen_graft"]["command"], sys.executable)
        self.assertEqual(environment["QWEN_REQUIRE_API_KEY"], "1")
        self.assertEqual(environment["QWEN_CHAT_TOOLS"], "on")
        self.assertEqual(environment["QWEN_WEB_PROFILE"], "graft")
        self.assertEqual(environment, launcher.prepare(self.config_path, base))
        self.config["limits"]["seconds"] = 6
        self.write_config()
        self.assertEqual(workflow.read_json(environment["QWEN_GRAFT_CONFIG"])["limits"]["seconds"], 5)

    def test_conflicting_mcp_name_is_refused(self):
        base = Path(self.workspace.name) / "base.json"
        base.write_text('{"mcpServers":{"qwen_graft":{}}}')
        with self.assertRaisesRegex(ValueError, "already names"):
            launcher.prepare(self.config_path, base)

    def write_base(self, servers):
        base = Path(self.workspace.name) / "base.json"
        base.write_text(json.dumps({"mcpServers": servers}))
        return base

    def test_profile_inferred_from_preserved_children(self):
        servers = {
            "web": {"command": "/usr/bin/true", "env": {
                "QWEN_WEB_PROFILE": "fast-text", "QWEN_WEB_TOKEN_KEY_FILE": self.token_key_path}},
            "image": {"command": "/usr/bin/true", "env": {
                "QWEN_IMAGE_LANGUAGE_PROFILE": "fast-text", "QWEN_IMAGE_TOKEN_KEY_FILE": self.token_key_path}},
            "geometry": {"command": "/usr/bin/true", "env": {
                "QWEN_SIDECAR_LANGUAGE_PROFILE": "fast-text", "QWEN_SIDECAR_TOKEN_KEY_FILE": self.token_key_path}},
        }
        environment = launcher.prepare(self.config_path, self.write_base(servers))
        self.assertEqual(environment["QWEN_WEB_PROFILE"], "fast-text")
        actual = json.loads(Path(environment["QWEN_GRAFT_MCP_CONFIG"]).read_text())["mcpServers"]
        for name, server in servers.items():
            self.assertEqual(actual[name], server)

    def test_explicit_profile_preserved_and_conflicts_refused(self):
        os.environ["QWEN_WEB_PROFILE"] = "selected-profile"
        self.assertEqual(launcher.prepare(self.config_path)["QWEN_WEB_PROFILE"], "selected-profile")
        base = self.write_base({"web": {"env": {"QWEN_WEB_PROFILE": "selected-profile"}}})
        self.assertEqual(launcher.prepare(self.config_path, base)["QWEN_WEB_PROFILE"], "selected-profile")
        with self.assertRaisesRegex(ValueError, "contradictory"):
            launcher.prepare(self.config_path, base, "different-profile")

    def test_contradictory_base_profiles_refused_before_publication(self):
        base = self.write_base({"web": {"env": {"QWEN_WEB_PROFILE": "first"}},
                                "image": {"env": {"QWEN_IMAGE_LANGUAGE_PROFILE": "second"}}})
        with self.assertRaisesRegex(ValueError, "contradictory"):
            launcher.prepare(self.config_path, base)
        self.assertFalse(Path(self.config["artifact_root"]).exists())

    def test_base_signing_keys_require_identical_bytes(self):
        different_key = Path(self.workspace.name) / "different.key"
        different_key.write_bytes(b"other-signing-key-material")
        different_key.chmod(0o600)
        for field in ("QWEN_WEB_TOKEN_KEY_FILE", "QWEN_IMAGE_TOKEN_KEY_FILE", "QWEN_SIDECAR_TOKEN_KEY_FILE"):
            with self.subTest(field=field):
                base = self.write_base({"retained": {"env": {field: str(different_key)}}})
                with self.assertRaisesRegex(ValueError, "signing-key mismatch"):
                    launcher.prepare(self.config_path, base)
        different_key.write_bytes(Path(self.token_key_path).read_bytes())
        different_key.chmod(0o600)
        base = self.write_base({"retained": {"env": {"QWEN_WEB_TOKEN_KEY_FILE": str(different_key)}}})
        self.assertEqual(launcher.prepare(self.config_path, base)["QWEN_WEB_PROFILE"], "graft")
        different_key.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "private ownership and mode"):
            launcher.prepare(self.config_path, base)
        different_key.chmod(0o600)
        different_key.write_bytes(Path(self.token_key_path).read_bytes().rstrip(b"\n"))
        with self.assertRaisesRegex(ValueError, "signing-key mismatch"):
            launcher.prepare(self.config_path, base)

    def test_retained_tools_export_distinct_broker_settings(self):
        base = self.write_base({
            "web": {"env": {"QWEN_WEB_PROVIDER": "fake"}},
            "image": {"env": {"QWEN_IMAGE_PROFILE": "image-a"}},
            "coding": {"env": {"QWEN_CODING_PROFILE": "code-a"}},
            "physics": {"env": {"QWEN_SIDECAR_SERVICE": "physics",
                                "QWEN_SIDECAR_PROFILE": "physics-a"}},
            "geometry": {"env": {"QWEN_SIDECAR_SERVICE": "geometry",
                                 "QWEN_SIDECAR_PROFILE": "geometry-a"}},
        })
        environment = launcher.prepare(self.config_path, base)
        self.assertEqual({field: environment[field] for field in (
            "QWEN_WEB_PROVIDER", "QWEN_IMAGE_PROFILE", "QWEN_CODING_PROFILE",
            "QWEN_PHYSICS_PROFILE", "QWEN_GEOMETRY_PROFILE")}, {
                "QWEN_WEB_PROVIDER": "fake", "QWEN_IMAGE_PROFILE": "image-a",
                "QWEN_CODING_PROFILE": "code-a", "QWEN_PHYSICS_PROFILE": "physics-a",
                "QWEN_GEOMETRY_PROFILE": "geometry-a"})
        for change in ({"QWEN_WEB_PROVIDER": "searxng"},
                       {"QWEN_CODING_PROFILE": "code-b"}):
            conflicting = self.write_base({"first": {"env": change}, "second": {"env": {
                next(iter(change)): "fake" if "QWEN_WEB_PROVIDER" in change else "code-a"}}})
            with self.assertRaisesRegex(ValueError, "contradictory"):
                launcher.prepare(self.config_path, conflicting)
        invalid = self.write_base({"sidecar": {"env": {"QWEN_SIDECAR_SERVICE": "unknown",
                                                             "QWEN_SIDECAR_PROFILE": "profile-a"}}})
        with self.assertRaisesRegex(ValueError, "sidecar service"):
            launcher.prepare(self.config_path, invalid)
        incomplete = self.write_base({"sidecar": {"env": {"QWEN_SIDECAR_SERVICE": "physics"}}})
        with self.assertRaisesRegex(ValueError, "QWEN_SIDECAR_PROFILE"):
            launcher.prepare(self.config_path, incomplete)

    def test_composed_profile_signs_web_and_graft_grants(self):
        base = self.write_base({"web": {"command": "/usr/bin/true", "env": {
            "QWEN_WEB_PROFILE": "retained-web", "QWEN_WEB_TOKEN_KEY_FILE": self.token_key_path}}})
        environment = launcher.prepare(self.config_path, base)
        broker, headers = self.launch_broker(environment)
        status, _, body = broker.request("POST", "/grant", json.dumps({
            "query": "fixture repository context", "profile_id": "retained-web"}), headers)
        self.assertEqual(status, 200, body)
        token = json.loads(body)["authorization"]
        server = broker_test.server
        claim = server.verify_claim(server.read_secret_file(self.token_key_path, "fixture signing"),
                                    server.AUTHORIZATION_CLAIM_CONTEXT, token, time.time(), "authorization")
        self.assertEqual(claim["profile_id"], "retained-web")
        arguments = {"repository": "fixture", "mode": "structural", "paths": []}
        status, _, body = broker.request("POST", "/grant-graft", json.dumps({
            "tool": "graft_start_build", "arguments": arguments}), headers)
        self.assertEqual(status, 200, body)
        loaded = workflow.load_config(environment["QWEN_GRAFT_CONFIG"])
        normalized = workflow.normalize_start(loaded, arguments)
        self.assertTrue(workflow.verify_authorization(
            loaded, {"action": "start", **normalized}, json.loads(body)["authorization"]))

    def test_special_signing_key_and_malformed_environment_refused(self):
        pipe = Path(self.workspace.name) / "key-pipe"
        os.mkfifo(pipe, 0o600)
        base = self.write_base({"retained": {"env": {"QWEN_WEB_TOKEN_KEY_FILE": str(pipe)}}})
        with self.assertRaisesRegex(ValueError, "regular file"):
            launcher.prepare(self.config_path, base)
        base = self.write_base({"retained": {"env": []}})
        with self.assertRaisesRegex(ValueError, "object environment"):
            launcher.prepare(self.config_path, base)

    def test_unserved_alias_is_refused(self):
        self.config["model"]["name"] = "other"
        self.write_config()
        with self.assertRaisesRegex(ValueError, "alias"):
            launcher.prepare(self.config_path)

    def test_start_grant_verifies_exact_request(self):
        broker, headers = self.launch_broker()
        arguments = {"repository": "fixture", "mode": "structural", "paths": []}
        status, _, body = broker.request("POST", "/grant-graft", json.dumps({
            "tool": "graft_start_build", "arguments": arguments}), headers)
        self.assertEqual(status, 200, body)
        token = json.loads(body)["authorization"]
        loaded = workflow.load_config(self.config_path)
        normalized = workflow.normalize_start(loaded, arguments)
        self.assertTrue(workflow.verify_authorization(loaded, {"action": "start", **normalized}, token))
        changed = workflow.normalize_start(loaded, {**arguments, "mode": "deep"})
        with self.assertRaisesRegex(workflow.Refusal, "start_authorization_invalid_or_stale"):
            workflow.verify_authorization(loaded, {"action": "start", **changed}, token)

    def test_resume_grant_binds_retained_job(self):
        loaded = workflow.load_config(self.config_path)
        root = workflow.initialize_storage(loaded)
        identifier = "a" * 32
        directory = root / "jobs" / identifier
        directory.mkdir()
        request = workflow.normalize_start(loaded, {
            "repository": "fixture", "mode": "deep", "paths": []})
        workflow.atomic_json(directory / "request.json", request)
        workflow.atomic_json(directory / "status.json", {"state": "partial", "attempt": 1})
        broker, headers = self.launch_broker()
        status, _, body = broker.request("POST", "/grant-graft", json.dumps({
            "tool": "graft_resume_build", "arguments": {"job_id": identifier}}), headers)
        self.assertEqual(status, 200, body)
        token = json.loads(body)["authorization"]
        self.assertTrue(workflow.verify_authorization(
            loaded, workflow.normalize_resume(loaded, identifier), token))
        with self.assertRaisesRegex(workflow.Refusal, "start_authorization_invalid_or_stale"):
            workflow.verify_authorization(
                loaded, {**workflow.normalize_resume(loaded, identifier),
                         "source_head": "0" * 40}, token)
        workflow.atomic_json(directory / "status.json", {"state": "partial", "attempt": 2})
        with self.assertRaisesRegex(workflow.Refusal, "start_authorization_invalid_or_stale"):
            workflow.verify_authorization(loaded, workflow.normalize_resume(loaded, identifier), token)

    def test_grants_refuse_missing_session(self):
        broker, headers = self.launch_broker()
        headers["X-Qwen-Web-Session"] = "wrong"
        status, _, _ = broker.request("POST", "/grant-graft", json.dumps({
            "tool": "graft_start_build", "arguments": {}}), headers)
        self.assertEqual(status, 403)

    def test_grants_refuse_key_replacement_and_shutdown_promptly(self):
        broker, headers = self.launch_broker()
        signing_path = Path(self.token_key_path)
        original_key = signing_path.read_bytes()
        target = Path(self.workspace.name) / "symlink-target.key"
        target.write_bytes(original_key)
        target.chmod(0o600)
        payload = json.dumps({"tool": "graft_start_build", "arguments": {
            "repository": "fixture", "mode": "structural", "paths": []}})
        for replacement in ("public", "symlink", "oversized", "fifo"):
            with self.subTest(replacement=replacement):
                signing_path.unlink()
                if replacement == "symlink":
                    signing_path.symlink_to(target)
                elif replacement == "fifo":
                    os.mkfifo(signing_path, 0o600)
                else:
                    signing_path.write_bytes(original_key if replacement == "public" else b"x" * 8193)
                    signing_path.chmod(0o644 if replacement == "public" else 0o600)
                started = time.monotonic()
                status, _, body = broker.request("POST", "/grant-graft", payload, headers)
                self.assertEqual(status, 400, body)
                self.assertNotIn("authorization", json.loads(body))
                self.assertLess(time.monotonic() - started, 5)
        started = time.monotonic()
        self.assertTrue(broker.close())
        self.assertLess(time.monotonic() - started, 5)
        self.assertFalse((Path(self.state_directory) / broker_test.SESSION_SECRET_FILE_NAME).exists())

    def test_grants_refuse_separately_rotated_workflow_key(self):
        workflow_key = Path(self.workspace.name) / "workflow.key"
        workflow_key.write_bytes(Path(self.token_key_path).read_bytes())
        workflow_key.chmod(0o600)
        self.config["authorization_key_file"] = str(workflow_key)
        self.write_config()
        broker, headers = self.launch_broker()
        workflow_key.write_bytes(b"rotated-private-signing-key-material")
        status, _, body = broker.request("POST", "/grant-graft", json.dumps({
            "tool": "graft_start_build", "arguments": {
                "repository": "fixture", "mode": "structural", "paths": []}}), headers)
        self.assertEqual(status, 400, body)
        self.assertIn("keys differ", json.loads(body)["error"])

    def test_grants_refuse_injected_authority(self):
        broker, headers = self.launch_broker()
        status, _, _ = broker.request("POST", "/grant-graft", json.dumps({
            "tool": "graft_start_build", "arguments": {"authorization": "old"}}), headers)
        self.assertEqual(status, 400)

    def test_grants_refuse_unregistered_repository(self):
        broker, headers = self.launch_broker()
        status, _, _ = broker.request("POST", "/grant-graft", json.dumps({
            "tool": "graft_start_build", "arguments": {"repository": "outside", "mode": "deep"}}), headers)
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
