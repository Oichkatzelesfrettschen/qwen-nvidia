"""Calibrate wire grading and the Graft experiment's tmux environment boundary."""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import concurrent.futures
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import urllib.error
import urllib.request
import time
from types import SimpleNamespace


SCRIPTS = Path(__file__).resolve().parent
specification = importlib.util.spec_from_file_location("arm", SCRIPTS / "run-graft-model-arm.py")
ARM = importlib.util.module_from_spec(specification)
specification.loader.exec_module(ARM)


class GraftArmTests(unittest.TestCase):
    def setUp(self):
        artifact_root = SCRIPTS.parent / ".local-artifacts"
        artifact_root.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=artifact_root)
        self.output = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def test_wire_grades_exact_named_call_and_retry_subset(self):
        graph = self.output / "graph.json"
        ARM.write_json(graph, {"nodes": [
            {"id": "a.c", "path": "a.c", "kind": "file", "span": "L1-L9"},
            {"id": "a.c#first", "path": "a.c", "kind": "function",
             "span": "L1-L3", "signature": "int first(void);"},
            {"id": "a.c#second", "path": "a.c", "kind": "function",
             "span": "L5-L7", "signature": "int second(void);"},
        ]})
        request = {"tool_choice": {"type": "function", "function": {"name": "record_symbols"}},
                   "messages": [{"content": "FILE: a.c\n- id=a.c | file | lines L1-L9\n- id=a.c#second | function | lines L5-L7"}]}
        response = {"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
            {"function": {"name": "record_symbols", "arguments": json.dumps({"symbols": [
                {"id": "a.c", "summary": "Defines values.", "crux_start": 0, "crux_end": 0},
                {"id": "a.c#second", "summary": "Returns the second value.",
                 "crux_start": 5, "crux_end": 6},
            ]})}},
        ]}}]}
        ARM.write_json(self.output / "wire-0000.request.json", request)
        ARM.write_json(self.output / "wire-0000.response.json", response)
        records = [{"request_id": 0, "started": 1, "ended": 2, "status": 200}]
        self.assertEqual(ARM.grade_wire(self.output, graph, records, "fixture"), 1)
        self.assertTrue((self.output / "symbols.tsv").read_text().rstrip().endswith("\tpass"))
        grade_columns = (self.output / "symbols.tsv").read_text().splitlines()[1].split("\t")
        self.assertEqual(grade_columns[2], "2")
        for mutation in ("blank", "length", "wrong_id", "transport"):
            mutated = json.loads(json.dumps(response))
            mutated_records = [dict(records[0])]
            if mutation == "length":
                mutated["choices"][0]["finish_reason"] = "length"
            elif mutation == "transport":
                mutated_records[0]["status"] = 500
            else:
                function = mutated["choices"][0]["message"]["tool_calls"][0]["function"]
                entries = json.loads(function["arguments"])
                entries["symbols"][0]["summary" if mutation == "blank" else "id"] = ""
                function["arguments"] = json.dumps(entries)
            ARM.write_json(self.output / "wire-0000.response.json", mutated)
            ARM.grade_wire(self.output, graph, mutated_records, "fixture")
            self.assertFalse((self.output / "symbols.tsv").read_text().rstrip().endswith("\tpass"), mutation)

    def test_tmux_forwards_reasoning_tools_budget_and_slots(self):
        fake_bin = self.output / "bin"
        fake_bin.mkdir()
        fake_tmux = fake_bin / "tmux"
        fake_tmux.write_text(
            "#!/bin/sh\nset -eu\n"
            "case \" $* \" in *' has-session '*) exit 1;; esac\n"
            "for argument do final_argument=$argument; done\n"
            "printf '%s\\n' \"$final_argument\" > \"$FIXTURE_COMMAND\"\n"
        )
        fake_tmux.chmod(0o700)
        environment = os.environ.copy()
        expected = {"QWEN_CHAT_TOOLS": "on", "QWEN_CHAT_REASONING": "off",
                    "QWEN_CHAT_REASONING_BUDGET": "512", "QWEN_GRAFT_EXPERIMENT_SLOTS": "2",
                    "QWEN_BATCH_SIZE": "128", "QWEN_UBATCH_SIZE": "32",
                    "QWEN_MMPROJ": "", "QWEN_SPEC_TYPE": ""}
        environment.update(expected)
        command_record = self.output / "command.txt"
        environment.update(PATH=str(fake_bin) + os.pathsep + environment["PATH"],
                           FIXTURE_COMMAND=str(command_record),
                           TMUX_TMPDIR=str(self.output),
                           QWEN_WEBUI_STATE_DIRECTORY=str(self.output / "state"))
        subprocess.run([str(SCRIPTS / "qwen-webui-control.sh"), "start"],
                       env=environment, capture_output=True, text=True, check=True)
        command_arguments = shlex.split(command_record.read_text())
        for name, value in expected.items():
            self.assertIn(name + "=" + value, command_arguments)

    def test_capture_serializes_identity_across_two_requests_and_refuses_foreign_auth(self):
        class Fixture(BaseHTTPRequestHandler):
            def log_message(self, *_arguments):
                pass

            def do_POST(self):
                payload = self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        capture = ARM.Capture(self.output, f"http://127.0.0.1:{upstream.server_port}",
                              "fixture-credential", deadline=time.monotonic() + 600)
        proxy = ThreadingHTTPServer(("127.0.0.1", 0), capture.handler())
        upstream_thread = threading.Thread(target=upstream.serve_forever)
        proxy_thread = threading.Thread(target=proxy.serve_forever)
        upstream_thread.start()
        proxy_thread.start()
        url = f"http://127.0.0.1:{proxy.server_port}/v1/chat/completions"

        def send(identifier):
            request = urllib.request.Request(url, json.dumps({"identifier": identifier}).encode(),
                                             {"Authorization": "Bearer fixture-credential"})
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.loads(response.read())

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                replies = list(pool.map(send, ("first", "second")))
            self.assertEqual({reply["identifier"] for reply in replies}, {"first", "second"})
            self.assertEqual({record["request_id"] for record in capture.records}, {0, 1})
            for record in capture.records:
                self.assertEqual(record["status"], 200)
                self.assertLess(record["started"], record["ended"])
                self.assertGreater(record["upstream_timeout_seconds"], 240)
                self.assertLessEqual(record["upstream_timeout_seconds"], 600)
            with self.assertRaises(urllib.error.HTTPError) as refusal:
                urllib.request.urlopen(urllib.request.Request(url, b"{}"), timeout=5)
            self.assertEqual(refusal.exception.code, 401)
            refusal.exception.close()
            self.assertEqual(len(capture.records), 2)
            capture.deadline = time.monotonic() - 1
            with self.assertRaises(urllib.error.HTTPError) as timeout:
                send("expired")
            self.assertEqual(timeout.exception.code, 502)
            timeout.exception.close()
            self.assertEqual(capture.records[-1]["status"], 502)
            for artifact in self.output.iterdir():
                self.assertNotIn("fixture-credential", artifact.read_text())
        finally:
            proxy.shutdown()
            upstream.shutdown()
            proxy.server_close()
            upstream.server_close()
            proxy_thread.join()
            upstream_thread.join()

    def test_usage_keeps_missing_reasoning_separate_from_zero(self):
        ARM.write_json(self.output / "wire-0000.response.json", {"usage": {
            "prompt_tokens": 10, "completion_tokens": 20,
            "completion_tokens_details": {"reasoning_tokens": 0}}})
        ARM.write_json(self.output / "wire-0001.response.json", {"usage": {
            "prompt_tokens": 15, "completion_tokens": 25}})
        totals = ARM.summarize_usage(self.output, [{"request_id": 0, "status": 200},
                                                 {"request_id": 1, "status": 200}])
        self.assertEqual(totals["prompt_tokens"]["sum_available"], 25)
        self.assertEqual(totals["reasoning_tokens"], {"sum_available": 0, "requests_available": 1,
                                                   "requests_missing": 1})

    def test_scope_denominator_refuses_wrong_or_whole_tree_graph(self):
        graph = self.output / "scope.json"
        nodes = [{"kind": "file"} for _ in range(3)] + [{"kind": "function"} for _ in range(7)]
        ARM.write_json(graph, {"nodes": nodes})
        self.assertEqual(ARM.validate_graph_scope(graph, "contract"), {"files": 3, "describable_symbols": 7})
        with self.assertRaises(ValueError):
            ARM.validate_graph_scope(graph, "pilot")
        ARM.write_json(graph, {"nodes": nodes + [{"kind": "file"}]})
        with self.assertRaises(ValueError):
            ARM.validate_graph_scope(graph, "contract")

    def test_command_deadline_reaps_only_the_spawned_process_group(self):
        marker = self.output / "child.pid"
        program = "import os,pathlib,time; pathlib.Path(os.environ['FIXTURE_PID']).write_text(str(os.getpid())); time.sleep(30)"
        environment = os.environ.copy()
        environment["FIXTURE_PID"] = str(marker)
        with self.assertRaises(subprocess.TimeoutExpired):
            ARM.run_command([sys.executable, "-c", program], self.output / "deadline.log", environment, 2)
        self.assertTrue(marker.exists())
        child_pid = int(marker.read_text())
        self.assertFalse(Path(f"/proc/{child_pid}").exists())

    def test_fixed_threads_and_projector_are_overridden_and_verified(self):
        options = SimpleNamespace(model=self.output / "model.gguf", reasoning="off",
                                  context=16384, slots=1)
        environment = {"QWEN_SERVING_THREADS": "2", "QWEN_MMPROJ": "foreign.gguf"}
        ARM.fixed_environment(environment, options, "fixture-nonce")
        self.assertEqual(environment["QWEN_SERVING_THREADS"], "6")
        self.assertEqual(environment["QWEN_MMPROJ"], "")
        argv = ["server", "--parallel", "1", "--reasoning", "off", "--ctx-size", "16384",
                "--device", "CUDA0", "--batch-size", "128", "--ubatch-size", "32",
                "--threads", "6", "--threads-batch", "6", "--jinja"]
        ARM.validate_server_argv(argv, options)
        for flag in ["--threads", "--threads-batch"]:
            invalid = list(argv)
            invalid[invalid.index(flag) + 1] = "2"
            with self.assertRaises(RuntimeError):
                ARM.validate_server_argv(invalid, options)
        for projector in [["--mmproj", "foreign.gguf"], ["--mmproj=foreign.gguf"]]:
            with self.assertRaises(RuntimeError):
                ARM.validate_server_argv(argv + projector, options)

    def test_fixed_arms_clear_and_reject_speculation(self):
        options = SimpleNamespace(model=self.output / "model.gguf", reasoning="off",
                                  context=16384, slots=1)
        environment = {"QWEN_SPEC_TYPE": "draft-mtp", "QWEN_SPEC_DRAFT_N_MAX": "4",
                       "QWEN_SPEC_DRAFT_P_MIN": "0.5", "QWEN_SPEC_BACKEND_SAMPLING": "1",
                       "QWEN_DRAFT_MODEL": "foreign.gguf", "QWEN_BACKEND_SAMPLING": "1",
                       "QWEN_ROUTER": "1", "QWEN_ROUTER_PRESETS": "foreign.ini"}
        ARM.fixed_environment(environment, options, "fixture-nonce")
        self.assertEqual(environment.pop("QWEN_SPEC_TYPE"), "")
        self.assertFalse(any(name.startswith(("QWEN_SPEC_", "QWEN_DRAFT_")) for name in environment))
        self.assertEqual(environment["QWEN_BACKEND_SAMPLING"], "0")
        self.assertEqual(environment["QWEN_ROUTER"], "0")
        self.assertNotIn("QWEN_ROUTER_PRESETS", environment)
        argv = ["server", "--parallel", "1", "--reasoning", "off", "--ctx-size", "16384",
                "--device", "CUDA0", "--batch-size", "128", "--ubatch-size", "32",
                "--threads", "6", "--threads-batch", "6", "--jinja"]
        ARM.validate_server_argv(argv, options)
        for flags in (["--spec-type", "draft-mtp"], ["--spec-type=draft-mtp"],
                      ["--spec-draft-n-max", "4"], ["--model-draft=foreign.gguf"],
                      ["-md", "foreign.gguf"], ["--backend-sampling"],
                      ["--models-preset", "foreign.ini"]):
            with self.assertRaises(RuntimeError):
                ARM.validate_server_argv(argv + flags, options)

    def test_geometry_matches_exact_campaign_pairs(self):
        for slots, context in ((1, 16384), (2, 32768)):
            ARM.validate_geometry(slots, context)
        for slots, context in ((1, 32768), (2, 32769), (2, 32767), (1, 16385), (3, 49152)):
            with self.assertRaises(ValueError):
                ARM.validate_geometry(slots, context)

    def test_final_admission_requires_owned_successful_teardown(self):
        for owned, status, expected in ((True, 0, "completed"), (False, 0, "void"),
                                        (True, None, "failed"), (True, 1, "failed")):
            metadata = {"state": "completed", "teardown_status": status}
            ARM.finalize_completion(metadata, owned)
            self.assertEqual(metadata["state"], expected)
        metadata = {"state": "failed", "error": "primary failure"}
        ARM.finalize_completion(metadata, False)
        self.assertEqual(metadata, {"state": "failed", "error": "primary failure"})

    def test_graft_client_identity_records_resolved_package_and_detects_change(self):
        package_root = self.output / "package"
        (package_root / "dist").mkdir(parents=True)
        executable = package_root / "dist/cli.js"
        executable.write_text("fixture client")
        ARM.write_json(package_root / "package.json", {"name": "@nanonets/graft", "version": "0.18.0"})
        launcher = self.output / "graft"
        launcher.symlink_to(executable)
        identity = ARM.graft_identity(launcher)
        self.assertEqual(identity["resolved_executable"], str(executable))
        self.assertEqual(identity["package_name"], "@nanonets/graft")
        self.assertEqual(identity["package_version"], "0.18.0")
        imported = package_root / "dist/enrich.js"
        imported.write_text("collector")
        closure_identity = ARM.graft_identity(launcher)
        imported.write_text("modified collector")
        self.assertNotEqual(ARM.graft_identity(launcher)["runtime_manifest_sha256"],
                            closure_identity["runtime_manifest_sha256"])
        link = package_root / "dist/import.js"
        link.symlink_to(imported.name)
        self.assertGreater(ARM.graft_identity(launcher)["runtime_entries"], identity["runtime_entries"])
        link.unlink()
        link.symlink_to(self.output / "outside.js")
        (self.output / "outside.js").write_text("foreign runtime")
        with self.assertRaises(ValueError):
            ARM.graft_identity(launcher)
        link.unlink()
        executable.write_text("modified client")
        self.assertNotEqual(ARM.graft_identity(launcher), identity)
        with self.assertRaises(ValueError):
            ARM.graft_identity(package_root / "package.json")
        ARM.write_json(package_root / "package.json", {"name": "foreign", "version": "0.18.0"})
        with self.assertRaises(ValueError):
            ARM.graft_identity(launcher)

    def test_teardown_receipt_requires_the_expected_nonce(self):
        metadata = {"state": "completed"}
        ARM.record_teardown(metadata, 0, "fixture-nonce",
                            "teardown_receipt nonce=fixture-nonce state=completed\n")
        self.assertEqual(metadata["teardown_status"], 0)
        self.assertEqual(metadata["teardown_nonce"], "fixture-nonce")
        for receipt in ("", "teardown_receipt nonce=foreign-nonce state=completed\n"):
            metadata = {"state": "completed"}
            ARM.record_teardown(metadata, 0, "fixture-nonce", receipt)
            self.assertEqual(metadata["state"], "failed")
            self.assertEqual(metadata["teardown_status"], 1)

    def test_teardown_refuses_foreign_nonce_and_excludes_replacement_start(self):
        fixture_scripts = self.output / "scripts"
        fake_bin = self.output / "bin"
        state = self.output / "state"
        for directory in (fixture_scripts, fake_bin, state):
            directory.mkdir()
        teardown = fixture_scripts / "qwen-teardown.sh"
        teardown.write_bytes((SCRIPTS / "qwen-teardown.sh").read_bytes())
        teardown.chmod(0o700)
        control = fixture_scripts / "qwen-webui-control.sh"
        control.write_text("#!/bin/sh\nset -eu\n: > \"$FIXTURE_ENTERED\"\n"
                           "if [ \"$FIXTURE_BLOCK\" = 1 ]; then\n"
                           " while [ ! -e \"$FIXTURE_RELEASE\" ]; do sleep 0.01; done\nfi\n")
        control.chmod(0o700)
        for executable in (fixture_scripts / "image-teardown-check.sh", fake_bin / "ss"):
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o700)
        fake_tmux = fake_bin / "tmux"
        fake_tmux.write_text("#!/bin/sh\nset -eu\ncase \" $* \" in\n"
                             " *' show-environment '*) printf 'QWEN_LAUNCH_ATTEMPT_NONCE=%s\\n' \"$FIXTURE_NONCE\";;\n"
                             " *' has-session '*) exit 1;;\n"
                             " *' new-session '*) : > \"$FIXTURE_STARTED\";;\n"
                             " *) exit 1;;\nesac\n")
        fake_tmux.chmod(0o700)
        entered, release, started = [self.output / name for name in ("entered", "release", "started")]
        status = state / "session.status"
        status.write_text("state=running server_pid=99999999 server_start_time=1\n")
        marker = state / "server.pid"
        marker.write_text("99999999\n")
        environment = os.environ.copy()
        environment.update(PATH=str(fake_bin) + os.pathsep + environment["PATH"],
                           QWEN_WEBUI_STATE_DIRECTORY=str(state),
                           TMUX_TMPDIR=str(self.output),
                           QWEN_SESSION_LIFECYCLE_FD="unowned", QWEN_TEARDOWN_EXPECTED_NONCE="fixture-nonce",
                           FIXTURE_NONCE="foreign-nonce", FIXTURE_BLOCK="0",
                           FIXTURE_ENTERED=str(entered), FIXTURE_RELEASE=str(release), FIXTURE_STARTED=str(started))
        refusal = subprocess.run([str(teardown)], env=environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(refusal.returncode, 3, refusal.stderr)
        self.assertFalse(entered.exists())
        self.assertEqual(marker.read_text(), "99999999\n")
        self.assertEqual(status.read_text(), "state=running server_pid=99999999 server_start_time=1\n")
        environment.update(FIXTURE_NONCE="fixture-nonce", FIXTURE_BLOCK="1")
        retirement = subprocess.Popen([str(teardown)], env=environment, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True)
        replacement = None
        try:
            deadline = time.monotonic() + 5
            while not entered.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(entered.exists())
            replacement_environment = environment | {
                "QWEN_WEBUI_STATE_DIRECTORY": str(self.output / "replacement-state")}
            replacement = subprocess.Popen([str(SCRIPTS / "qwen-webui-control.sh"), "start"],
                                           env=replacement_environment, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, text=True)
            time.sleep(0.2)
            self.assertIsNone(replacement.poll())
            self.assertFalse(started.exists())
            release.touch()
            stdout, stderr = retirement.communicate(timeout=10)
            self.assertEqual(retirement.returncode, 0, stderr)
            self.assertIn("teardown_receipt nonce=fixture-nonce state=completed", stdout)
            _stdout, stderr = replacement.communicate(timeout=10)
            self.assertEqual(replacement.returncode, 0, stderr)
            self.assertTrue(started.exists())
        finally:
            release.touch()
            for child in (retirement, replacement):
                if child is not None and child.poll() is None:
                    child.terminate()
                    child.communicate(timeout=5)

    def test_output_requires_the_actual_repository_artifact_root(self):
        self.assertTrue(ARM.output_is_owned(self.output))
        self.assertFalse(ARM.output_is_owned(Path("/tmp/.local-artifacts/foreign")))
        with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
            alias = self.output / "external"
            alias.symlink_to(temporary, target_is_directory=True)
            self.assertFalse(ARM.output_is_owned(alias / "run"))
        internal = self.output / "internal"
        internal.symlink_to(self.output / "owned", target_is_directory=True)
        self.assertTrue(ARM.output_is_owned(internal / "run"))

    def test_failed_build_and_secondary_teardown_keep_distinct_provenance(self):
        self.assertEqual(ARM.completion_state(0, True), "completed")
        self.assertEqual(ARM.completion_state(0, False), "void")
        self.assertEqual(ARM.completion_state(1, True), "failed")
        metadata = {"state": "failed", "error": "TimeoutExpired: primary deadline"}
        ARM.record_teardown(metadata, 1)
        self.assertEqual(metadata["error"], "TimeoutExpired: primary deadline")
        self.assertEqual(metadata["teardown_error"], "owned teardown failed")
        self.assertEqual(metadata["state"], "failed")

    def test_direct_kernel_hazard_refuses_completion_before_monitor_transition(self):
        metadata = {"state": "completed"}
        (self.output / "kernel-hazards.log").write_text("watch_ready_utc=fixture\n")
        ARM.classify_guards(metadata, self.output)
        self.assertEqual(metadata["state"], "completed")
        (self.output / "kernel-hazards.log").write_text("hazard_utc=fixture category=fixture\n")
        ARM.classify_guards(metadata, self.output)
        self.assertEqual(metadata["state"], "void")


if __name__ == "__main__":
    unittest.main()
