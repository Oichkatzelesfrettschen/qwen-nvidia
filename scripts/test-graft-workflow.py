"""Exercise Graft job lifecycle and sandbox boundaries with a fixture runtime.

The fixture is an operator-selected executable. Tests use real bubblewrap;
namespace refusal fails the test instead of substituting a host execution.
The fixture writes a small graph and makes deliberate prohibited source writes.
The suite starts neither a model nor the installed Graft CLI.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("graft_workflow", HERE / "graft-workflow.py")
WORKFLOW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKFLOW)

FIXTURE = r'''
import json
import os
from pathlib import Path
import sys
import time
import subprocess

control = json.loads(Path('/repo/sys/control.json').read_text())
graph = Path('/graph')
probe = {'argv': sys.argv[1:], 'ci': os.environ.get('CI'),
         'tracking': os.environ.get('DO_NOT_TRACK'),
         'lease_present': 'QWEN_GPU_COMPUTE_LEASE' in os.environ,
         'provider': os.environ.get('GRAFT_PROVIDER'),
         'model': os.environ.get('GRAFT_MODEL')}
probe['inherited_fds'] = []
for descriptor_name in os.listdir('/proc/self/fd'):
    descriptor = int(descriptor_name)
    if descriptor > 2:
        try:
            os.fstat(descriptor)
        except OSError:
            continue
        probe['inherited_fds'].append(descriptor)
try:
    Path('/repo/sys/sentinel').write_text('overwritten')
    probe['source_write'] = 'succeeded'
except OSError:
    probe['source_write'] = 'refused'
probe['outside_scope_visible'] = Path('/repo/outside-scope').exists()
try:
    Path('/unapproved-output').write_text('bad')
    probe['root_write'] = 'succeeded'
except OSError:
    probe['root_write'] = 'refused'
probe['key_file_visible'] = Path(control['key_file']).exists()
(graph / 'probe.json').write_text(json.dumps(probe))
secret = os.environ.get('GRAFT_API_KEY', '')
if secret:
    for letter in secret:
        sys.stdout.write(letter)
        sys.stdout.flush()
        time.sleep(0.002)
    print()
print('x' * control.get('log_bytes', 0), flush=True)
if control.get('descendant'):
    subprocess.Popen([sys.executable, '-c',
        "import time; from pathlib import Path; time.sleep(1); Path('/graph/orphan-survived').write_text('bad')"],
        start_new_session=True)
time.sleep(control.get('sleep', 0))
if control.get('graph', True):
    (graph / '.graph').mkdir()
    nodes = [{'id': 'sys/main.c', 'kind': 'file', 'path': 'sys/main.c',
              'summary_state': 'ready', 'summary': 'Fixture source.'},
             {'id': 'sys/main.c#main', 'kind': 'function', 'path': 'sys/main.c',
              'summary_state': control.get('summary_state', 'ready'),
              'summary': control.get('summary', 'Fixture entry point.')}]
    (graph / '.graph/wiring.json').write_text(json.dumps({'nodes': nodes, 'edges': []}))
sys.exit(control.get('exit_code', 0))
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.previous_umask = os.umask(0o077)
        git_environment = mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"})
        git_environment.start()
        self.addCleanup(git_environment.stop)
        output = HERE.parent / ".local-artifacts" / "graft-workflow-tests"
        output.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="fixture-", dir=output)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "source"
        (self.repository / "sys").mkdir(parents=True)
        (self.repository / "sys/main.c").write_text("int main(void) { return 0; }\n")
        (self.repository / "sys/sentinel").write_text("original\n")
        (self.repository / "outside-scope").write_text("outside approved scope\n")
        self.key = self.root / "api-key"
        self.key.write_bytes(b"fixture-api-key-kept-private")
        self.authorization_key = self.root / "authorization-key"
        self.authorization_key.write_bytes(b"fixture-authorization-key-exact-bytes\n")
        self.control = {"key_file": str(self.key)}
        self.write_control()
        for command in (["init", "--quiet", "--template="],
                        ["config", "core.fsmonitor", "false"],
                        ["config", "commit.gpgsign", "false"], ["add", "."],
                        ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                         "commit", "--quiet", "-m", "fixture"]):
            subprocess.run(["git", "-C", str(self.repository), *command],
                           check=True, capture_output=True)
        self.executable = self.root / "fixture-graft"
        self.executable.write_text("#!" + sys.executable + "\n" + FIXTURE)
        self.executable.chmod(0o700)
        sandbox = shutil.which("bwrap")
        self.assertIsNotNone(sandbox, "bubblewrap package is required")
        self.config_path = self.root / "config.json"
        self.config = {
            "version": 1, "artifact_root": str(self.root / "jobs-output"),
            "graft_executable": str(self.executable), "bwrap_executable": sandbox,
            "authorization_key_file": str(self.authorization_key),
            "repositories": {"fixture": {"path": str(self.repository), "allowed_paths": ["sys"]}},
            "model": {"base_url": "http://127.0.0.1:65530/v1", "name": "fixture-model",
                      "api_key_file": str(self.key)},
            "limits": {"seconds": 5, "log_bytes": 1024, "maximum_paths": 4},
        }
        self.save_config()
        self.jobs = []

    def tearDown(self):
        for identifier in self.jobs:
            try:
                state = WORKFLOW.build_status(self.config, identifier)
                if state["state"] not in WORKFLOW.TERMINAL:
                    token = WORKFLOW.issue_cancel_authorization(
                        self.config, {"job_id": identifier}, self.authorization_key.read_bytes())
                    WORKFLOW.cancel_build(self.config, identifier, token)
                    self.wait_terminal(identifier)
            except (OSError, ValueError):
                pass
        self.temporary.cleanup()
        os.umask(self.previous_umask)

    def save_config(self):
        self.config_path.write_text(json.dumps(self.config))
        self.config = WORKFLOW.load_config(self.config_path)

    def write_control(self):
        (self.repository / "sys/control.json").write_text(json.dumps(self.control))

    def request(self, mode="structural"):
        return {"repository": "fixture", "mode": mode, "paths": ["sys"]}

    def start(self, mode="structural"):
        request = self.request(mode)
        token = WORKFLOW.issue_start_authorization(
            self.config, request, self.authorization_key.read_bytes())
        state = WORKFLOW.start_build(self.config, request, token)
        self.jobs.append(state["job_id"])
        return state

    def wait_terminal(self, identifier):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = WORKFLOW.build_status(self.config, identifier)
            if state["state"] in WORKFLOW.TERMINAL:
                return state
            time.sleep(0.05)
        self.fail("job exceeded fixture wait deadline")

    def test_source_read_only_and_structural_command(self):
        before = hashlib.sha256((self.repository / "sys/sentinel").read_bytes()).hexdigest()
        initial = self.start()
        state = self.wait_terminal(initial["job_id"])
        self.assertEqual(state["state"], "completed", state)
        probe = json.loads((Path(state["graph_directory"]) / "probe.json").read_text())
        self.assertEqual(probe["source_write"], "refused")
        self.assertEqual(probe["root_write"], "refused")
        self.assertFalse(probe["outside_scope_visible"])
        self.assertFalse(probe["key_file_visible"])
        self.assertFalse(probe["lease_present"])
        self.assertEqual(probe["inherited_fds"], [])
        self.assertIsNone(probe["provider"])
        self.assertEqual(probe["ci"], "1")
        self.assertEqual(probe["tracking"], "1")
        self.assertEqual(probe["argv"], ["--dir", "/graph", "build", "/repo", "-j", "1",
                                         "--no-gitignore", "--no-ignore", "--only-dir", "sys"])
        self.assertEqual(before, hashlib.sha256((self.repository / "sys/sentinel").read_bytes()).hexdigest())

    def test_fixture_git_disables_fsmonitor(self):
        result = subprocess.run(["git", "-C", str(self.repository), "config", "core.fsmonitor"],
                                text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), "false")
        self.assertFalse((self.repository / ".git/fsmonitor--daemon.ipc").exists())

    def assert_key_read_refused_within_deadline(self, expected):
        program = (
            "import importlib.util, sys\n"
            "spec = importlib.util.spec_from_file_location('workflow', sys.argv[1])\n"
            "workflow = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(workflow)\n"
            "try:\n"
            "    workflow.read_key(sys.argv[2], strip=True)\n"
            "except (workflow.Refusal, OSError) as error:\n"
            "    print(str(error) if isinstance(error, workflow.Refusal) else type(error).__name__)\n"
            "else:\n"
            "    raise SystemExit('unsafe key accepted')\n")
        result = subprocess.run([sys.executable, "-c", program, str(HERE / "graft-workflow.py"),
                                 str(self.authorization_key)], text=True, capture_output=True,
                                check=True, timeout=2)
        self.assertEqual(result.stdout.strip(), expected)

    def test_key_reader_preserves_authorization_bytes(self):
        key = b"  exact-signing-bytes-with-whitespace\n"
        self.authorization_key.write_bytes(key)
        self.assertEqual(WORKFLOW.read_key(self.authorization_key), key)
        self.assertEqual(WORKFLOW.read_key(self.authorization_key, strip=True), key.strip())

    def test_key_reader_refuses_fifo_replacement_within_deadline(self):
        self.authorization_key.unlink()
        os.mkfifo(self.authorization_key, mode=0o600)
        self.assert_key_read_refused_within_deadline("key_file_requires_private_permissions")

    def test_key_reader_refuses_symlink_replacement_within_deadline(self):
        self.authorization_key.unlink()
        self.authorization_key.symlink_to(self.key)
        self.assert_key_read_refused_within_deadline("OSError")

    def test_key_reader_refuses_oversized_file_before_stripping(self):
        self.authorization_key.write_bytes(b" " + b"k" * 8192)
        self.assert_key_read_refused_within_deadline("key_file_length_invalid")

    def test_key_reader_refuses_public_permissions_within_deadline(self):
        self.authorization_key.chmod(0o644)
        self.assert_key_read_refused_within_deadline("key_file_requires_private_permissions")

    def test_detached_cli_build_survives_parent_exit(self):
        self.control["sleep"] = 0.4
        self.write_control()
        result = subprocess.run([sys.executable, str(HERE / "graft-workflow.py"),
                                 "--config", str(self.config_path), "start", "--repository",
                                 "fixture", "--mode", "structural"], capture_output=True,
                                check=True, timeout=3)
        initial = json.loads(result.stdout)
        self.jobs.append(initial["job_id"])
        self.assertEqual(initial["state"], "queued")
        self.assertEqual(self.wait_terminal(initial["job_id"])["state"], "completed")

    def test_single_repo_lock_and_preserved_job_outputs(self):
        self.control["sleep"] = 0.5
        self.write_control()
        first = self.start()
        with self.assertRaisesRegex(WORKFLOW.Refusal, "repository_build_busy"):
            self.start()
        self.assertEqual(self.wait_terminal(first["job_id"])["state"], "completed")
        second = self.start()
        self.assertEqual(self.wait_terminal(second["job_id"])["state"], "completed")
        self.assertNotEqual(first["graph_directory"], second["graph_directory"])
        self.assertTrue(Path(first["graph_directory"]).is_dir())

    def test_deep_partial_redaction_and_log_cap(self):
        self.control.update(summary_state="pending", log_bytes=8000)
        self.write_control()
        state = self.wait_terminal(self.start("deep")["job_id"])
        self.assertEqual(state["state"], "partial", state)
        self.assertEqual(state["coverage"]["pending"], 1)
        log = (Path(state["graph_directory"]).parent / "build.log").read_bytes()
        self.assertLessEqual(len(log), 1024)
        self.assertNotIn(self.key.read_bytes(), log)
        self.assertIn(b"[redacted]", log)
        probe = json.loads((Path(state["graph_directory"]) / "probe.json").read_text())
        self.assertEqual(probe["provider"], "openai")
        self.assertEqual(probe["model"], "fixture-model")
        self.assertIn("--deep", probe["argv"])

    def test_failure_and_timeout(self):
        self.control.update(graph=False, exit_code=7)
        self.write_control()
        self.assertEqual(self.wait_terminal(self.start()["job_id"])["state"], "failed")
        self.control.update(sleep=30)
        self.write_control()
        self.config["limits"]["seconds"] = 1
        self.save_config()
        self.assertEqual(self.wait_terminal(self.start()["job_id"])["state"], "timed_out")

    def test_signed_cancellation(self):
        self.control["sleep"] = 30
        self.control["descendant"] = True
        self.write_control()
        initial = self.start()
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.cancel_build(self.config, initial["job_id"], "invalid")
        token = WORKFLOW.issue_cancel_authorization(
            self.config, {"job_id": initial["job_id"]}, self.authorization_key.read_bytes())
        deadline = time.monotonic() + 3
        while not (Path(initial["graph_directory"]) / "probe.json").exists():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        WORKFLOW.cancel_build(self.config, initial["job_id"], token)
        self.assertEqual(self.wait_terminal(initial["job_id"])["state"], "cancelled")
        with self.assertRaisesRegex(WORKFLOW.Refusal, "spent"):
            WORKFLOW.cancel_build(self.config, initial["job_id"], token)
        time.sleep(1.1)
        self.assertFalse((Path(initial["graph_directory"]) / "orphan-survived").exists())

    def test_cancellation_refuses_changed_process_identity(self):
        self.control["sleep"] = 1
        self.write_control()
        initial = self.start()
        owner_path = Path(initial["graph_directory"]).parent / "owner.json"
        owner = WORKFLOW.read_json(owner_path)
        WORKFLOW.atomic_json(owner_path, {**owner, "start_ticks": "0"})
        token = WORKFLOW.issue_cancel_authorization(
            self.config, {"job_id": initial["job_id"]}, self.authorization_key.read_bytes())
        try:
            result = WORKFLOW.cancel_build(self.config, initial["job_id"], token)
            self.assertEqual(result["reason"], "supervisor_exited")
        finally:
            WORKFLOW.atomic_json(owner_path, owner)
        self.assertEqual(self.wait_terminal(initial["job_id"])["state"], "completed")

    def test_approval_replay_and_changed_request(self):
        request = self.request()
        token = WORKFLOW.issue_start_authorization(self.config, request, self.authorization_key.read_bytes())
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.start_build(self.config, self.request("deep"), token)
        state = WORKFLOW.start_build(self.config, request, token)
        self.jobs.append(state["job_id"])
        self.wait_terminal(state["job_id"])
        with self.assertRaisesRegex(WORKFLOW.Refusal, "spent"):
            WORKFLOW.start_build(self.config, request, token)

    def test_approval_binds_config_and_head(self):
        request = self.request()
        token = WORKFLOW.issue_start_authorization(self.config, request, self.authorization_key.read_bytes())
        self.config["limits"]["seconds"] = 4
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.start_build(self.config, request, token)
        self.config["limits"]["seconds"] = 5
        subprocess.run(["git", "-C", str(self.repository), "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty",
                        "--quiet", "-m", "changed"], check=True)
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.start_build(self.config, request, token)

    def test_approval_binds_scope_directory_identity(self):
        request = self.request()
        token = WORKFLOW.issue_start_authorization(self.config, request, self.authorization_key.read_bytes())
        normalized = WORKFLOW.normalize_start(self.config, request)
        before = len(list(Path("/proc/self/fd").iterdir()))
        original = self.repository / "original-sys"
        (self.repository / "sys").rename(original)
        shutil.copytree(original, self.repository / "sys")
        self.assertEqual(WORKFLOW.source_head(self.repository), normalized["source_head"])
        with self.assertRaisesRegex(WORKFLOW.Refusal, "identity_changed"):
            WORKFLOW.pin_request_sources(self.config, normalized)
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.start_build(self.config, request, token)
        self.assertEqual(len(list(Path("/proc/self/fd").iterdir())), before)

    def test_approval_refuses_retargeted_scope_symlink(self):
        (self.repository / "sys/link").symlink_to(".", target_is_directory=True)
        request = {**self.request(), "paths": ["sys/link"]}
        normalized = WORKFLOW.normalize_start(self.config, request)
        (self.repository / "sys/other").mkdir()
        (self.repository / "sys/link").unlink()
        (self.repository / "sys/link").symlink_to("other", target_is_directory=True)
        with self.assertRaisesRegex(WORKFLOW.Refusal, "identity_changed"):
            WORKFLOW.pin_request_sources(self.config, normalized)

    def assert_pinned_mount_survives_path_replacement(self, replace_root):
        request = WORKFLOW.normalize_start(self.config, self.request())
        before = len(list(Path("/proc/self/fd").iterdir()))
        descriptors = WORKFLOW.pin_request_sources(self.config, request)
        try:
            source = self.repository if replace_root else self.repository / "sys"
            source.rename(self.root / "approved-directory")
            replacement = self.root / "outside-directory"
            replacement.mkdir()
            (replacement / "sentinel").write_text("outside approved source\n")
            source.symlink_to(replacement, target_is_directory=True)
            directory = self.root / "mount-probe"
            (directory / "graph").mkdir(parents=True)
            (directory / "scratch/tmp").mkdir(parents=True)
            command = WORKFLOW.sandbox_base(self.config, request, directory, source_fds=descriptors)
            command.extend(["--", "/usr/bin/cat", "/repo/sys/sentinel"])
            result = subprocess.run(command, pass_fds=WORKFLOW.sandbox_pass_fds(request, descriptors),
                                    env={"PATH": "/usr/bin:/bin"}, capture_output=True,
                                    text=True, timeout=3, check=True)
            self.assertEqual(result.stdout, "original\n")
            for name, identity in WORKFLOW.source_directory_identities(request).items():
                self.assertEqual(WORKFLOW.descriptor_identity(descriptors[name]), identity)
        finally:
            WORKFLOW.close_source_fds(descriptors)
        self.assertEqual(len(list(Path("/proc/self/fd").iterdir())), before)

    def test_root_descriptor_closes_validation_to_mount_race(self):
        self.assert_pinned_mount_survives_path_replacement(replace_root=True)

    def test_scope_descriptor_closes_validation_to_mount_race(self):
        self.assert_pinned_mount_survives_path_replacement(replace_root=False)

    def test_linked_worktree_metadata_uses_pinned_descriptors(self):
        linked = self.root / "linked-source"
        subprocess.run(["git", "-C", str(self.repository), "worktree", "add", "--quiet",
                        "--detach", str(linked)], check=True, capture_output=True)
        self.config["repositories"]["fixture"]["path"] = str(linked)
        self.save_config()
        request = WORKFLOW.normalize_start(self.config, self.request())
        self.assertEqual(set(request["git_mounts"]), {"/git", "/gitdir", "/commondir"})
        before = len(list(Path("/proc/self/fd").iterdir()))
        descriptors = WORKFLOW.pin_request_sources(self.config, request, check_head=True)
        try:
            directory = self.root / "linked-probe"
            (directory / "graph").mkdir(parents=True)
            (directory / "scratch/tmp").mkdir(parents=True)
            command = WORKFLOW.sandbox_base(self.config, request, directory, source_fds=descriptors)
            command.extend(["--", "/usr/bin/git", "-C", "/repo", "rev-parse", "HEAD"])
            result = subprocess.run(command, pass_fds=WORKFLOW.sandbox_pass_fds(request, descriptors),
                                    env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null",
                                         "GIT_CONFIG_NOSYSTEM": "1"},
                                    capture_output=True, text=True, timeout=3, check=True)
            self.assertEqual(result.stdout.strip(), request["source_head"])
        finally:
            WORKFLOW.close_source_fds(descriptors)
        self.assertEqual(len(list(Path("/proc/self/fd").iterdir())), before)
        gitdir = Path(request["git_mounts"]["/gitdir"]["destination"])
        gitdir.rename(gitdir.with_name("replaced-metadata"))
        gitdir.mkdir()
        with self.assertRaisesRegex(WORKFLOW.Refusal, "identity_changed"):
            WORKFLOW.pin_request_sources(self.config, request)
        self.assertEqual(len(list(Path("/proc/self/fd").iterdir())), before)

    def configure_query_fixture(self):
        package = self.root / "query-package"
        (package / "dist/mcp").mkdir(parents=True)
        (package / "package.json").write_text(json.dumps({"name": "@nanonets/graft", "type": "module"}))
        (package / "dist/mcp/tools.js").write_text(
            "import fs from 'node:fs'; export async function callTool(root) {"
            "return {text:fs.readFileSync(root+'/sys/sentinel','utf8')};}")
        self.config["graft_package_root"] = str(package)
        self.save_config()
        state = self.wait_terminal(self.start()["job_id"])
        self.assertEqual(state["state"], "completed", state)
        return {"job_id": state["job_id"], "operation": "graft_find_code", "arguments": {"query": "fixture"}}

    def test_query_allows_in_place_bytes_and_refuses_replaced_root(self):
        arguments = self.configure_query_fixture()
        (self.repository / "sys/sentinel").write_text("edited in place\n")
        result = WORKFLOW.query_graph(self.config, arguments)
        self.assertEqual(result["result"]["text"], "edited in place\n")
        self.repository.rename(self.root / "original-source")
        shutil.copytree(self.root / "original-source", self.repository)
        with self.assertRaisesRegex(WORKFLOW.Refusal, "identity_changed"):
            WORKFLOW.query_graph(self.config, arguments)

    def test_query_refuses_root_symlink_and_closes_spawn_failure_descriptors(self):
        arguments = self.configure_query_fixture()
        before = len(list(Path("/proc/self/fd").iterdir()))
        with mock.patch.object(WORKFLOW.subprocess, "Popen", side_effect=OSError("fixture spawn refusal")):
            with self.assertRaises(OSError):
                WORKFLOW.query_graph(self.config, arguments)
        self.assertEqual(len(list(Path("/proc/self/fd").iterdir())), before)
        original = self.root / "original-source"
        self.repository.rename(original)
        self.repository.symlink_to(original, target_is_directory=True)
        with self.assertRaisesRegex(WORKFLOW.Refusal, "identity_changed"):
            WORKFLOW.query_graph(self.config, arguments)
        self.assertEqual(len(list(Path("/proc/self/fd").iterdir())), before)

    def test_model_roots_scopes_and_extra_fields_rejected(self):
        for path in ("../", "/", "--flag", "."):
            with self.assertRaises(WORKFLOW.Refusal):
                WORKFLOW.normalize_start(self.config, {**self.request(), "paths": [path]})
        (self.repository / "sys/escape").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.normalize_start(self.config, {**self.request(), "paths": ["sys/escape"]})
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.normalize_start(self.config, {**self.request(), "command": "true"})
        self.config["model"]["base_url"] = "http://example.invalid/v1"
        self.config_path.write_text(json.dumps(self.config))
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.load_config(self.config_path)

    def test_mcp_protocol_and_authorization_required(self):
        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize"},
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                        "name": "graft_start_build", "arguments": self.request()}}]
        result = subprocess.run([sys.executable, str(HERE / "graft-workflow.py"), "--config",
                                 str(self.config_path), "mcp"],
                                input="\n".join(json.dumps(message) for message in messages) + "\n",
                                text=True, capture_output=True, timeout=3, check=True)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(replies), 3)
        self.assertEqual(len(replies[1]["result"]["tools"]), 4)
        self.assertTrue(replies[2]["result"]["isError"])
        self.assertNotIn(self.authorization_key.read_text().strip(), result.stdout)

    def test_read_only_query_import_and_operation_validation(self):
        package = self.root / "graft-package"
        (package / "dist/mcp").mkdir(parents=True)
        (package / "package.json").write_text(json.dumps({"name": "@nanonets/graft", "type": "module"}))
        (package / "dist/mcp/tools.js").write_text(
            "import fs from 'node:fs';\n"
            "export async function callTool(root, op, args, graph) {\n"
            " let write='succeeded'; try {fs.writeFileSync(graph+'/query-write','bad')}"
            " catch {write='refused'};\n"
            " return {text:JSON.stringify({root,op,args,graph,write,refresh:process.env.GRAFT_NO_REFRESH})};}\n")
        self.config["graft_package_root"] = str(package)
        self.save_config()
        state = self.wait_terminal(self.start()["job_id"])
        self.assertEqual(state["state"], "completed", state)
        for operation in WORKFLOW.QUERY_FIELDS:
            params = {"graft_find_code": {"query": "entry"}, "graft_file_api": {"file": "sys/main.c"},
                      "graft_trace_calls": {"symbol": "main"}, "graft_find_all": {"pattern": "main"}}.get(operation, {})
            result = WORKFLOW.query_graph(self.config, {"job_id": state["job_id"],
                                                       "operation": operation, "arguments": params})
            probe = json.loads(result["result"]["text"])
            self.assertEqual(probe["write"], "refused")
            self.assertEqual(probe["refresh"], "1")
            self.assertEqual(result["source_view"], "live_read_only")
        with self.assertRaises(WORKFLOW.Refusal):
            WORKFLOW.query_graph(self.config, {"job_id": state["job_id"], "operation": "graft_file_api",
                                               "arguments": {"file": "../../api-key"}})


if __name__ == "__main__":
    unittest.main()
