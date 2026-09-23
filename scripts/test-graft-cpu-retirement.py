"""Calibrate CPU-child attribution through real MCP and sandbox processes."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parent
RETIRE_SCRIPT = SCRIPTS / "qwen-retire-server-child.sh"
SPEC = importlib.util.spec_from_file_location("graft_retirement_fixture", SCRIPTS / "test-graft-workflow.py")
FIXTURE_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE_MODULE)
RETIREMENT_SPEC = importlib.util.spec_from_file_location(
    "graft_cpu_retirement", SCRIPTS / "graft-retire-cpu-children.py")
RETIREMENT = importlib.util.module_from_spec(RETIREMENT_SPEC)
RETIREMENT_SPEC.loader.exec_module(RETIREMENT)

SERVER = r'''
import json, os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ["TEST_ROOT"])
command = json.loads((root / "mcp.json").read_text())["mcpServers"]["qwen_graft"]
mcp = subprocess.Popen([command["command"], *command["args"]],
                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                       env={**os.environ, **command.get("env", {})})
retained = None
if os.environ.get("TEST_RETAINED_CHILD"):
    retained_command = json.loads((root / "mcp.json").read_text())["mcpServers"]["retained"]
    retained = subprocess.Popen([retained_command["command"], *retained_command.get("args", [])],
                                env={**os.environ, **retained_command.get("env", {})})
    (root / "retained-ready").write_text(str(retained.pid))
extra = None
if os.environ.get("TEST_UNKNOWN_CHILD"):
    extra = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
def retire(_signal, _frame):
    mcp.stdin.close()
    mcp.wait(timeout=3)
    if retained:
        retained.terminate()
        retained.wait(timeout=3)
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
        self.probe_processes = []
        self.addCleanup(self.stop_probe_processes)

    def stop_probe_processes(self):
        for process in reversed(self.probe_processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    def publication_fixture(self):
        self.fixture.control["sleep"] = 4
        self.fixture.write_control()
        workflow = FIXTURE_MODULE.WORKFLOW
        request = workflow.normalize_start(self.fixture.config, self.fixture.request())
        descriptors = workflow.pin_request_sources(self.fixture.config, request)
        self.addCleanup(workflow.close_source_fds, descriptors)
        directory = self.root / "publication-probe"
        (directory / "graph").mkdir(parents=True)
        (directory / "scratch/tmp").mkdir(parents=True)
        workflow.atomic_json(directory / "status.json", {"state": "running"})
        return request, descriptors, directory, RETIREMENT.process(os.getpid())

    def launch_probe_sandbox(self, request, descriptors, directory):
        workflow = FIXTURE_MODULE.WORKFLOW
        workflow.atomic_json(directory / "source-fds.json", descriptors)
        command = workflow.sandbox_command(self.fixture.config, request, directory, source_fds=descriptors)
        child = subprocess.Popen(command, pass_fds=workflow.sandbox_pass_fds(request, descriptors),
                                 env={"PATH": "/usr/bin:/bin"}, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.probe_processes.append(child)
        self.wait_for(lambda: RETIREMENT.exact_command(RETIREMENT.process(child.pid), command))
        return child

    def launch_blocked_head_probe(self, descriptors):
        fifo = self.root / "git-include.fifo"
        os.mkfifo(fifo, 0o600)
        config_path = self.fixture.repository / ".git/config"
        original_config = config_path.read_text()
        config_path.write_text(original_config + f"\n[include]\n\tpath = {fifo}\n")
        self.addCleanup(config_path.write_text, original_config)
        child = subprocess.Popen(
            ["/usr/bin/git", "--no-optional-locks", "-C", f"/proc/self/fd/{descriptors['.']}",
             "rev-parse", "--verify", "HEAD"], pass_fds=(descriptors["."],),
            env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.probe_processes.append(child)
        return child, fifo

    def observe_publication(self, request, directory, worker, seconds=3):
        return RETIREMENT.observe_worker_publication(
            FIXTURE_MODULE.WORKFLOW, self.fixture.config, request, directory, worker,
            time.monotonic() + seconds)

    def launch_pending_sandbox(self, request, descriptors, directory):
        workflow = FIXTURE_MODULE.WORKFLOW
        workflow.atomic_json(directory / "source-fds.json", descriptors)
        command = workflow.sandbox_command(self.fixture.config, request, directory, source_fds=descriptors)
        ready_read, ready_write = os.pipe()
        child_pid = os.fork()
        if child_pid == 0:
            try:
                os.close(ready_write)
                os.read(ready_read, 1)
                os.close(ready_read)
                for descriptor in workflow.sandbox_pass_fds(request, descriptors):
                    os.set_inheritable(descriptor, True)
                os.execve(command[0], command, {"PATH": "/usr/bin:/bin"})
            finally:
                os._exit(127)
        os.close(ready_read)

        def stop_child():
            try:
                os.kill(child_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(child_pid, 0)
            os.close(ready_write)

        self.addCleanup(stop_child)
        return child_pid, ready_write, command

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

    def start_server(self, active=False, unknown=False, retained=False):
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
        if retained:
            environment["TEST_RETAINED_CHILD"] = "1"
        self.server = subprocess.Popen([sys.executable, str(self.root / "server.py")],
                                       stdout=self.log, stderr=self.log, env=environment,
                                       start_new_session=True)
        self.wait_for(lambda: (self.root / "server-ready").exists())
        if retained:
            self.wait_for(lambda: (self.root / "retained-ready").exists())
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

    def test_configured_retained_mcp_child_preserves_teardown_proof(self):
        self.mcp["mcpServers"]["retained"] = {
            "command": "/usr/bin/sleep", "args": ["300"],
            "env": {"QWEN_TEST_RETAINED_MARKER": "bound"},
        }
        self.mcp_path.write_text(json.dumps(self.mcp))
        self.start_server(retained=True)
        result = self.retire()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("\nteardown: held=yes\n", result.stdout)

    def test_path_resolved_retained_mcp_child_preserves_teardown_proof(self):
        self.mcp["mcpServers"]["retained"] = {"command": "sleep", "args": ["300"]}
        self.mcp_path.write_text(json.dumps(self.mcp))
        self.start_server(retained=True)
        result = self.retire()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("\nteardown: held=yes\n", result.stdout)

    def test_retained_mcp_command_mismatch_refuses_teardown_proof(self):
        self.mcp["mcpServers"]["retained"] = {"command": "sleep", "args": ["300"]}
        self.mcp_path.write_text(json.dumps(self.mcp))
        self.start_server(retained=True)
        self.mcp["mcpServers"]["retained"]["args"] = ["301"]
        self.mcp_path.write_text(json.dumps(self.mcp))
        result = self.retire()
        self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
        self.assertNotIn("\nteardown: held=yes\n", result.stdout)

    def test_retained_mcp_environment_mismatch_refuses_teardown_proof(self):
        self.mcp["mcpServers"]["retained"] = {
            "command": "/usr/bin/sleep", "args": ["300"],
            "env": {"QWEN_TEST_RETAINED_MARKER": "bound"},
        }
        self.mcp_path.write_text(json.dumps(self.mcp))
        self.start_server(retained=True)
        self.mcp["mcpServers"]["retained"]["env"]["QWEN_TEST_RETAINED_MARKER"] = "changed"
        self.mcp_path.write_text(json.dumps(self.mcp))
        result = self.retire()
        self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
        self.assertIn("retained_mcp_environment_mismatch", result.stderr + result.stdout)
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

    def test_queued_git_probe_reobserves_published_sandbox(self):
        request, descriptors, directory, worker = self.publication_fixture()
        git_child, fifo = self.launch_blocked_head_probe(descriptors)
        inspected = threading.Event()
        exited_seen = threading.Event()
        observer_done = threading.Event()
        errors = []
        published = {}
        original_classifier = RETIREMENT.source_head_child
        original_process = RETIREMENT.process

        def process(pid):
            result = original_process(pid)
            if pid == git_child.pid and result and result["state"] == "Z":
                exited_seen.set()
            return result

        def classify(*arguments):
            result = original_classifier(*arguments)
            if result:
                inspected.set()
            return result

        def publish():
            try:
                if not inspected.wait(2):
                    raise AssertionError("Git startup was not inspected")
                with fifo.open("w"):
                    pass
                if not exited_seen.wait(2):
                    raise AssertionError("Git zombie was not inspected")
                git_child.wait(timeout=2)
                sandbox = self.launch_probe_sandbox(request, descriptors, directory)
                published["pid"] = sandbox.pid
                FIXTURE_MODULE.WORKFLOW.atomic_json(directory / "child.json", RETIREMENT.identity(
                    RETIREMENT.process(sandbox.pid)))
                # PR_SET_PDEATHSIG follows the spawning thread, so the fixture
                # keeps that thread alive for the sandbox observation.
                observer_done.wait(4)
            except BaseException as error:
                errors.append(error)

        publisher = threading.Thread(target=publish, daemon=True)
        publisher.start()
        try:
            with mock.patch.object(RETIREMENT, "source_head_child", side_effect=classify), \
                    mock.patch.object(RETIREMENT, "process", side_effect=process):
                captured = self.observe_publication(request, directory, worker)
        finally:
            observer_done.set()
            publisher.join(timeout=4)
        self.assertFalse(publisher.is_alive())
        self.assertEqual(errors, [])
        self.assertIn(git_child.pid, [record["pid"] for record in captured])
        self.assertIn(published["pid"], [record["pid"] for record in captured])

    def test_bwrap_waits_for_child_identity_publication(self):
        request, descriptors, directory, worker = self.publication_fixture()
        sandbox = self.launch_probe_sandbox(request, descriptors, directory)
        inspected = threading.Event()
        original_match = RETIREMENT.exact_command

        def match(record, command):
            result = original_match(record, command)
            if result and record["pid"] == sandbox.pid:
                inspected.set()
            return result

        def publish():
            if inspected.wait(2):
                FIXTURE_MODULE.WORKFLOW.atomic_json(directory / "child.json", RETIREMENT.identity(
                    RETIREMENT.process(sandbox.pid)))

        publisher = threading.Thread(target=publish, daemon=True)
        publisher.start()
        try:
            with mock.patch.object(RETIREMENT, "exact_command", side_effect=match):
                captured = self.observe_publication(request, directory, worker)
        finally:
            publisher.join(timeout=3)
        self.assertFalse(publisher.is_alive())
        self.assertTrue(inspected.is_set())
        self.assertIn(sandbox.pid, [record["pid"] for record in captured])

    def test_unpublished_sandbox_has_bounded_wait(self):
        request, descriptors, directory, worker = self.publication_fixture()
        self.launch_probe_sandbox(request, descriptors, directory)
        started = time.monotonic()
        with self.assertRaisesRegex(RETIREMENT.Refusal, "worker_publication_deadline"):
            self.observe_publication(request, directory, worker, seconds=0.1)
        self.assertLess(time.monotonic() - started, 1)

    def test_childless_queued_worker_returns_for_cancellation(self):
        request, _descriptors, directory, worker = self.publication_fixture()
        FIXTURE_MODULE.WORKFLOW.atomic_json(directory / "status.json", {"state": "queued"})
        with mock.patch.object(RETIREMENT.time, "sleep") as sleep:
            captured = self.observe_publication(request, directory, worker, seconds=0.1)
        self.assertEqual([RETIREMENT.identity(record) for record in captured],
                         [RETIREMENT.identity(worker)])
        sleep.assert_not_called()

    def test_childless_running_worker_waits_for_publication(self):
        request, _descriptors, directory, worker = self.publication_fixture()
        with self.assertRaisesRegex(RETIREMENT.Refusal, "worker_publication_deadline"):
            self.observe_publication(request, directory, worker, seconds=0.1)

    def test_inherited_worker_image_waits_for_exact_sandbox_exec(self):
        request, descriptors, directory, worker = self.publication_fixture()
        child_pid, ready_write, command = self.launch_pending_sandbox(request, descriptors, directory)
        inspected = threading.Event()
        errors = []
        original_match = RETIREMENT.exact_command

        def match(record, expected):
            result = original_match(record, expected)
            if result and record["pid"] == child_pid and record["args"] == worker["args"]:
                inspected.set()
            return result

        def publish():
            try:
                if not inspected.wait(2):
                    raise AssertionError("Inherited worker image was not inspected")
                os.write(ready_write, b"1")
                self.wait_for(lambda: original_match(RETIREMENT.process(child_pid), command))
                FIXTURE_MODULE.WORKFLOW.atomic_json(directory / "child.json", RETIREMENT.identity(
                    RETIREMENT.process(child_pid)))
            except BaseException as error:
                errors.append(error)

        publisher = threading.Thread(target=publish, daemon=True)
        publisher.start()
        try:
            with mock.patch.object(RETIREMENT, "exact_command", side_effect=match):
                captured = self.observe_publication(request, directory, worker)
        finally:
            publisher.join(timeout=3)
        self.assertFalse(publisher.is_alive())
        self.assertEqual(errors, [])
        self.assertIn(child_pid, [record["pid"] for record in captured])

    def test_inherited_worker_image_requires_exec_before_deadline(self):
        request, descriptors, directory, worker = self.publication_fixture()
        self.launch_pending_sandbox(request, descriptors, directory)
        started = time.monotonic()
        with self.assertRaisesRegex(RETIREMENT.Refusal, "worker_publication_deadline"):
            self.observe_publication(request, directory, worker, seconds=0.1)
        self.assertLess(time.monotonic() - started, 1)

    def test_startup_git_requires_approved_root_descriptor(self):
        request, descriptors, directory, worker = self.publication_fixture()
        child, _fifo = self.launch_blocked_head_probe(descriptors)
        self.wait_for(lambda: RETIREMENT.exact_command(RETIREMENT.process(child.pid), child.args))
        with self.assertRaisesRegex(RETIREMENT.Refusal, "startup_git_source_descriptor_mismatch"):
            self.observe_publication({**request, "repository_inode": 0}, directory, worker)

    def test_unknown_startup_child_refuses_without_waiting(self):
        request, _descriptors, directory, worker = self.publication_fixture()
        FIXTURE_MODULE.WORKFLOW.atomic_json(directory / "status.json", {"state": "queued"})
        child = subprocess.Popen(["/usr/bin/sleep", "4"])
        self.probe_processes.append(child)
        self.wait_for(lambda: RETIREMENT.exact_command(RETIREMENT.process(child.pid), child.args))
        started = time.monotonic()
        with self.assertRaisesRegex(RETIREMENT.Refusal, "unrecognized_worker_startup_child"):
            self.observe_publication(request, directory, worker)
        self.assertLess(time.monotonic() - started, 1)


if __name__ == "__main__":
    unittest.main()
