"""Calibrate CPU-child attribution through real MCP and sandbox processes."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest


SCRIPTS = Path(__file__).resolve().parent
RETIRE_SCRIPT = SCRIPTS / "qwen-retire-server-child.sh"
SPEC = importlib.util.spec_from_file_location("graft_retirement_fixture", SCRIPTS / "test-graft-workflow.py")
FIXTURE_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE_MODULE)

SERVER = r'''
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ["TEST_ROOT"])
command = json.loads((root / "mcp.json").read_text())["mcpServers"]["qwen_graft"]
mcp = subprocess.Popen([command["command"], *command["args"]],
                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                       env={**os.environ, **command.get("env", {})})
extra = None
if os.environ.get("TEST_UNKNOWN_CHILD"):
    extra = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
def retire(_signal, _frame):
    mcp.stdin.close()
    mcp.wait(timeout=3)
    if extra:
        extra.terminate()
        extra.wait(timeout=3)
    print("workload lease teardown: held=yes", flush=True)
    raise SystemExit(0)
signal.signal(signal.SIGTERM, retire)
message_path = root / "message.json"
message = json.loads(message_path.read_text()) if message_path.exists() else {
    "jsonrpc": "2.0", "id": 1, "method": "initialize"}
mcp.stdin.write(json.dumps(message) + "\n")
mcp.stdin.flush()
reply = json.loads(mcp.stdout.readline())
(root / "reply.json").write_text(json.dumps(reply))
(root / "server-ready").write_text(str(mcp.pid))
while True:
    signal.pause()
'''


class GraftCPURetirementTests(unittest.TestCase):
    def setUp(self):
        self.fixture = FIXTURE_MODULE.WorkflowTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.root = self.fixture.root
        self.config_path = self.fixture.config_path
        self.mcp_path = self.root / "mcp.json"
        self.mcp = {"mcpServers": {"qwen_graft": {
            "command": sys.executable,
            "args": [str(SCRIPTS / "graft-workflow.py"), "--config", str(self.config_path), "mcp"],
            "env": {"QWEN_GRAFT_SESSION_BARRIER": str(self.root),
                    "QWEN_GPU_ADMISSION_BARRIER": str(self.root)},
        }}}
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("QWEN_")}
        self.environment.update(PYTHON=sys.executable, QWEN_GPU_ADMISSION_BARRIER=str(self.root),
                                TMPDIR=str(self.root))
        subprocess.run([str(SCRIPTS / "qwen-drain-controller.sh"), "resume"],
                       env=self.environment, check=True, capture_output=True)
        self.mcp_path.write_text(json.dumps(self.mcp))
        (self.root / "server.py").write_text(SERVER)
        self.server = None
        self.log = None
        self.addCleanup(self.stop_server)

    def stop_server(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.server.pid, signal.SIGKILL)
                self.server.wait(timeout=5)
        if self.log:
            self.log.close()

    def wait_for(self, predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("fixture readiness deadline")

    def start_server(self, active=False, unknown=False):
        if active:
            self.fixture.control["sleep"] = 4
            self.fixture.write_control()
            request = self.fixture.request()
            token = FIXTURE_MODULE.WORKFLOW.issue_start_authorization(
                self.fixture.config, request, self.fixture.authorization_key.read_bytes())
            (self.root / "message.json").write_text(json.dumps({
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": {"name": "graft_start_build", "arguments": {**request, "authorization": token}},
            }))
        self.log = (self.root / "server.log").open("w")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("QWEN_")}
        environment.update(TEST_ROOT=str(self.root), PYTHON=sys.executable)
        if unknown:
            environment["TEST_UNKNOWN_CHILD"] = "1"
        self.server = subprocess.Popen([sys.executable, str(self.root / "server.py")],
                                       stdout=self.log, stderr=self.log, env=environment,
                                       start_new_session=True)
        self.wait_for(lambda: (self.root / "server-ready").exists())
        if active:
            reply = json.loads((self.root / "reply.json").read_text())
            self.assertFalse(reply["result"]["isError"], reply)
            state = json.loads(reply["result"]["content"][0]["text"])
            self.fixture.jobs.append(state["job_id"])
            directory = FIXTURE_MODULE.WORKFLOW.job_directory(self.fixture.config, state["job_id"])
            self.wait_for(lambda: (directory / "graph/probe.json").exists()
                          and (directory / "child.json").exists())
            return state["job_id"]
        return None

    def retire(self, raw=False, **overrides):
        start = FIXTURE_MODULE.WORKFLOW.process_identity(self.server.pid)["start_ticks"]
        environment = dict(self.environment)
        environment.update(PYTHON=sys.executable, QWEN_GRAFT_CONFIG=str(self.config_path),
                           QWEN_GRAFT_MCP_CONFIG=str(self.mcp_path), QWEN_DRAIN_ESCALATION_MS="5000")
        environment.update(overrides)
        command = [str(RETIRE_SCRIPT),
                   str(self.server.pid), start, str(self.root / "server.log")]
        if not raw:
            command = [str(SCRIPTS / "qwen-drain-controller.sh"), "retire", "--", *command]
        result = subprocess.run(command,
                                env=environment, capture_output=True, text=True, timeout=20)
        self.server.wait(timeout=5)
        return result

    def test_configured_idle_mcp_preserves_unique_server_teardown_proof(self):
        self.start_server()
        result = self.retire()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("graft_cpu_identity=", result.stdout)
        self.assertIn("\nteardown: held=yes\n", result.stdout)

    def test_active_configured_job_is_cancelled_before_server_retirement(self):
        identifier = self.start_server(active=True)
        result = self.retire()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("\nteardown: held=yes\n", result.stdout)
        state = FIXTURE_MODULE.WORKFLOW.build_status(self.fixture.config, identifier)
        self.assertEqual(state["state"], "cancelled")
        self.assertTrue(Path(state["graph_directory"], "probe.json").exists())

    def test_completed_unreaped_worker_keeps_cpu_attribution(self):
        identifier = self.start_server(active=True)
        self.wait_for(lambda: FIXTURE_MODULE.WORKFLOW.build_status(
            self.fixture.config, identifier)["state"] in FIXTURE_MODULE.WORKFLOW.TERMINAL)
        directory = FIXTURE_MODULE.WORKFLOW.job_directory(self.fixture.config, identifier)
        owner = json.loads((directory / "owner.json").read_text())
        stat_path = Path(f"/proc/{owner['pid']}/stat")
        self.wait_for(lambda: stat_path.read_text().rsplit(")", 1)[1].split()[0] == "Z")
        result = self.retire()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("\nteardown: held=yes\n", result.stdout)

    def test_terminal_worker_with_changed_owner_refuses_cpu_attribution(self):
        identifier = self.start_server(active=True)
        self.wait_for(lambda: FIXTURE_MODULE.WORKFLOW.build_status(
            self.fixture.config, identifier)["state"] in FIXTURE_MODULE.WORKFLOW.TERMINAL)
        directory = FIXTURE_MODULE.WORKFLOW.job_directory(self.fixture.config, identifier)
        owner = json.loads((directory / "owner.json").read_text())
        stat_path = Path(f"/proc/{owner['pid']}/stat")
        self.wait_for(lambda: stat_path.read_text().rsplit(")", 1)[1].split()[0] == "Z")
        owner["start_ticks"] = "0"
        (directory / "owner.json").write_text(json.dumps(owner))
        result = self.retire()
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("unrecognized_mcp_child", result.stdout)

    def test_unknown_server_descendant_keeps_teardown_unattributed(self):
        self.start_server(unknown=True)
        result = self.retire()
        self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_configured_command_mismatch_keeps_teardown_unattributed(self):
        self.start_server()
        self.mcp["mcpServers"]["qwen_graft"]["args"].append("unexpected")
        self.mcp_path.write_text(json.dumps(self.mcp))
        result = self.retire()
        self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
        self.assertIn("configured_mcp_command_mismatch", result.stderr + result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_router_still_requires_its_own_generation_proof(self):
        self.start_server()
        result = self.retire(QWEN_ROUTER="1")
        self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
        self.assertNotIn("graft_cpu_identity=", result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_open_publication_barrier_refuses_cpu_attribution(self):
        self.start_server()
        result = self.retire(raw=True, QWEN_DRAIN_MODE="orderly")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("mcp_publication_not_drained", result.stderr)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_mcp_without_bound_publication_barrier_refuses_cpu_attribution(self):
        self.mcp["mcpServers"]["qwen_graft"]["env"] = {}
        self.mcp_path.write_text(json.dumps(self.mcp))
        self.start_server()
        result = self.retire()
        self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
        self.assertIn("mcp_publication_barrier_mismatch", result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_mismatched_worker_identity_refuses_cpu_attribution(self):
        identifier = self.start_server(active=True)
        directory = FIXTURE_MODULE.WORKFLOW.job_directory(self.fixture.config, identifier)
        owner = json.loads((directory / "owner.json").read_text())
        owner["start_ticks"] = "0"
        (directory / "owner.json").write_text(json.dumps(owner))
        result = self.retire()
        self.assertIn("worker_identity_or_configuration_mismatch", result.stderr + result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_mismatched_sandbox_identity_refuses_cpu_attribution(self):
        identifier = self.start_server(active=True)
        directory = FIXTURE_MODULE.WORKFLOW.job_directory(self.fixture.config, identifier)
        child = json.loads((directory / "child.json").read_text())
        child["start_ticks"] = "0"
        (directory / "child.json").write_text(json.dumps(child))
        result = self.retire()
        self.assertIn("sandbox_identity_or_command_mismatch", result.stderr + result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_mismatched_source_descriptor_refuses_cpu_attribution(self):
        identifier = self.start_server(active=True)
        directory = FIXTURE_MODULE.WORKFLOW.job_directory(self.fixture.config, identifier)
        descriptors = json.loads((directory / "source-fds.json").read_text())
        descriptors["."] = descriptors["sys"]
        (directory / "source-fds.json").write_text(json.dumps(descriptors))
        result = self.retire()
        self.assertIn("worker_source_descriptor_identity_mismatch", result.stderr + result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)


if __name__ == "__main__":
    unittest.main()
