"""Exercise Graft MCP admission against real session state and flock locks.

Fixture callbacks replace graph work while the session shell library arms and
quiesces the actual barrier. Lock probes measure callback coverage, release on
failure and drain refusal. Child probes bound acquisitions that must refuse
immediately, so a blocking regression produces a test failure.
"""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPTS = Path(__file__).resolve().parent


def load_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


WORKFLOW = load_module("graft_admission_workflow_test", SCRIPTS / "graft-workflow.py")
BARRIER = load_module("graft_admission_barrier_test", SCRIPTS / "admission_barrier.py")
CHILD_PROBE = """
import importlib.util
import json
import sys
spec = importlib.util.spec_from_file_location('graft_admission_probe', sys.argv[1])
workflow = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = workflow
spec.loader.exec_module(workflow)
try:
    result = workflow.with_mcp_admission(json.loads(sys.argv[2]), lambda: 'admitted')
    print(result)
except workflow.Refusal as error:
    print('refused:' + str(error))
"""


class GraftAdmissionTest(unittest.TestCase):
    def setUp(self):
        ancestors = [parent for parent in SCRIPTS.parents if parent.name == ".local-artifacts"]
        boundary = ancestors[-1] if ancestors else SCRIPTS.parent / ".local-artifacts"
        boundary.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="graft-admission-test-", dir=boundary)
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.config = {"model": {"api_key_file": str(self.directory / "api.key")}}
        self.environment = {
            "QWEN_GRAFT_SESSION_BARRIER": str(self.directory),
            "QWEN_GPU_ADMISSION_BARRIER": str(self.directory),
        }
        environment_patch = patch.dict(os.environ, self.environment)
        environment_patch.start()
        self.addCleanup(environment_patch.stop)

    def shell(self, operation):
        result = subprocess.run(
            ["sh", "-c", '. "$1"\n' + operation,
             "graft-admission-test", str(SCRIPTS / "qwen-admission-barrier.sh")],
            env={**os.environ, **self.environment}, capture_output=True,
            text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def arm(self):
        self.shell("qwen_barrier_initialize")
        self.assertEqual(BARRIER.verify_session_identity(self.environment), "match")

    def quiesce(self):
        self.shell("qwen_barrier_set_state quiescing")
        self.assertEqual(BARRIER.read_state(self.environment), "quiescing")

    def open_drain_probe(self):
        descriptor = os.open(BARRIER.inflight_path(self.environment), os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        return descriptor

    def assert_drain_free(self, descriptor):
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(descriptor, fcntl.LOCK_UN)

    def assert_drain_blocked(self, descriptor):
        with self.assertRaises(BlockingIOError):
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def child_probe(self):
        process = subprocess.Popen(
            [sys.executable, "-c", CHILD_PROBE, str(SCRIPTS / "graft-workflow.py"),
             json.dumps(self.config)], env=dict(os.environ),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            self.fail("MCP admission blocked beyond its refusal deadline")
        self.assertEqual(process.returncode, 0, stderr)
        return stdout.strip()

    def test_missing_each_session_binding_refuses_before_operation(self):
        self.arm()
        for field in self.environment:
            with self.subTest(field=field), patch.dict(os.environ):
                os.environ.pop(field)
                operation = Mock()
                with self.assertRaisesRegex(WORKFLOW.Refusal, "binding_required"):
                    WORKFLOW.with_mcp_admission(self.config, operation)
                operation.assert_not_called()

    def test_mismatched_bindings_and_config_directory_refuse(self):
        self.arm()
        other = str(self.directory / "other")
        bindings = [
            {"QWEN_GRAFT_SESSION_BARRIER": other},
            {"QWEN_GPU_ADMISSION_BARRIER": other},
            {"QWEN_GRAFT_SESSION_BARRIER": other, "QWEN_GPU_ADMISSION_BARRIER": other},
        ]
        for environment in bindings:
            with self.subTest(environment=environment), patch.dict(os.environ, environment):
                operation = Mock()
                with self.assertRaisesRegex(WORKFLOW.Refusal, "binding_required"):
                    WORKFLOW.with_mcp_admission(self.config, operation)
                operation.assert_not_called()

    def test_unarmed_barrier_refuses_legacy_optional_admission(self):
        self.assertEqual(BARRIER.read_state(self.environment), "running")
        operation = Mock()
        with self.assertRaisesRegex(WORKFLOW.Refusal, "identity_required"):
            WORKFLOW.with_mcp_admission(self.config, operation)
        operation.assert_not_called()

    def test_replaced_inflight_inode_refuses_before_operation(self):
        self.arm()
        inflight = Path(BARRIER.inflight_path(self.environment))
        inflight.rename(inflight.with_suffix(".retained"))
        inflight.touch()
        self.assertEqual(BARRIER.verify_session_identity(self.environment), "mismatch")
        operation = Mock()
        with self.assertRaisesRegex(WORKFLOW.Refusal, "identity_required"):
            WORKFLOW.with_mcp_admission(self.config, operation)
        operation.assert_not_called()

    def test_quiescing_refuses_before_operation(self):
        self.arm()
        self.quiesce()
        operation = Mock()
        with self.assertRaisesRegex(WORKFLOW.Refusal, "quiescing"):
            WORKFLOW.with_mcp_admission(self.config, operation)
        operation.assert_not_called()

    def test_exclusive_drain_refuses_with_bounded_child_probe(self):
        self.arm()
        descriptor = self.open_drain_probe()
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.child_probe(), "refused:mcp_session_draining")
        fcntl.flock(descriptor, fcntl.LOCK_UN)

    def test_operation_holds_shared_inflight_lock_and_returns_value(self):
        self.arm()
        descriptor = self.open_drain_probe()
        result = {"fixture": "completed"}

        def operation():
            self.assert_drain_blocked(descriptor)
            with BARRIER.require_admission(self.environment):
                self.assert_drain_blocked(descriptor)
            return result

        self.assertIs(WORKFLOW.with_mcp_admission(self.config, operation), result)
        self.assert_drain_free(descriptor)

    def test_operation_exception_releases_inflight_lock(self):
        self.arm()
        descriptor = self.open_drain_probe()

        def operation():
            self.assert_drain_blocked(descriptor)
            raise RuntimeError("fixture operation failed")

        with self.assertRaisesRegex(RuntimeError, "fixture operation failed"):
            WORKFLOW.with_mcp_admission(self.config, operation)
        self.assert_drain_free(descriptor)

    def test_state_flip_drains_prior_operation_and_refuses_later_work(self):
        self.arm()
        descriptor = self.open_drain_probe()

        def operation():
            self.quiesce()
            self.assert_drain_blocked(descriptor)

        WORKFLOW.with_mcp_admission(self.config, operation)
        self.assert_drain_free(descriptor)
        later_operation = Mock()
        with self.assertRaisesRegex(WORKFLOW.Refusal, "quiescing"):
            WORKFLOW.with_mcp_admission(self.config, later_operation)
        later_operation.assert_not_called()

    def test_gpu_compute_lease_is_independent_of_admission(self):
        self.arm()
        lease = self.directory / "compute.lock"
        lease.touch()
        descriptor = os.open(lease, os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with patch.dict(os.environ, {"QWEN_GPU_COMPUTE_LEASE": str(lease)}):
            self.assertEqual(self.child_probe(), "admitted")

    def test_mcp_start_and_query_routes_hold_admission(self):
        self.arm()
        descriptor = self.open_drain_probe()
        cases = [
            ("graft_start_build", "start_build", {"repository": "fixture", "mode": "structural",
                                                  "paths": [], "authorization": "fixture-grant"}),
            ("graft_query", "query_graph", {"job_id": "fixture", "operation": "graft_repo_map",
                                             "arguments": {}}),
        ]
        for tool_name, implementation, arguments in cases:
            with self.subTest(tool=tool_name):
                def operation(*_arguments):
                    self.assert_drain_blocked(descriptor)
                    return {"fixture": tool_name}

                with patch.object(WORKFLOW, implementation, side_effect=operation) as invoked:
                    self.assertEqual(WORKFLOW.call_tool(self.config, tool_name, arguments),
                                     {"fixture": tool_name})
                    invoked.assert_called_once()
                self.assert_drain_free(descriptor)


if __name__ == "__main__":
    unittest.main()
