"""Exercise scheduler inheritance, failed startup retirement, and admission status.

Every process and artifact belongs to a temporary fixture tree. The CUDA
wrapper executes a scheduler recorder; the serving session owns a sleeping
fixture child and reads an empty fixture driver inventory.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPTS = Path(__file__).resolve().parent


class ServingStartupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="serving-startup-", dir=os.environ.get("TMPDIR", SCRIPTS.parent / ".local-artifacts")
        )
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.environment = {
            key: value for key, value in os.environ.items() if not key.startswith("QWEN_")
        }
        self.environment.update(PYTHON=sys.executable, TMPDIR=str(self.root))
        self.recorder = self.write("record.py", """
            import json, os
            print(json.dumps({"policy": os.sched_getscheduler(0),
                              "nice": os.getpriority(os.PRIO_PROCESS, 0)}))
        """)

    def write(self, relative, source, executable=False):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(source).lstrip(), encoding="utf-8")
        if executable:
            path.chmod(0o700)
        return path

    def run_command(self, command, **environment):
        return subprocess.run(
            command, env={**self.environment, **environment}, text=True,
            capture_output=True, timeout=30, check=False,
        )

    def permits_idle_transition(self):
        result = self.run_command(["chrt", "--idle", "0", sys.executable, "-c", """
import os
try:
    os.sched_setscheduler(0, os.SCHED_OTHER, os.sched_param(0))
except PermissionError:
    raise SystemExit(77)
"""])
        self.assertIn(result.returncode, (0, 77), result.stderr)
        return result.returncode == 0

    def test_idle_control_and_cuda_wrapper_establish_other(self):
        control = self.run_command(["chrt", "--idle", "0", sys.executable, str(self.recorder)])
        self.assertEqual(control.returncode, 0, control.stderr)
        self.assertEqual(json.loads(control.stdout)["policy"], os.SCHED_IDLE)
        result = self.run_command([
            "chrt", "--idle", "0", str(SCRIPTS / "cuda-runtime-env.sh"),
            sys.executable, str(self.recorder),
        ])
        if self.permits_idle_transition():
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"policy": os.SCHED_OTHER, "nice": 0})
        else:
            self.assertEqual(result.returncode, 1)
            self.assertIn("SCHED_OTHER", result.stderr)
            self.assertEqual(result.stdout, "")
            print("scheduler_transition=restricted live_success=not_run reason=RLIMIT_NICE "
                  "production_refusal=verified")

    def test_wrapper_establishes_scheduler_before_nice_affinity_and_exec(self):
        real_chrt = shutil.which("chrt")
        for utility in ("chrt", "renice", "taskset"):
            self.write(f"bin/{utility}", f"""
                #!/bin/sh
                printf '{utility}\\n' >>"$QWEN_TEST_ORDER"
                exit 0
            """, executable=True)
        result = self.run_command([
            real_chrt, "--other", "0", str(SCRIPTS / "cuda-runtime-env.sh"),
            sys.executable, str(self.recorder),
        ], PATH=f"{self.root / 'bin'}:{self.environment['PATH']}",
            QWEN_TEST_ORDER=str(self.root / "scheduler-order"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["policy"], os.SCHED_OTHER)
        self.assertEqual((self.root / "scheduler-order").read_text().splitlines(),
                         ["chrt", "renice", "taskset"])

    def test_scheduler_refusal_prevents_wrapper_execution(self):
        self.write("bin/chrt", "#!/bin/sh\nexit 1\n", executable=True)
        result = self.run_command(
            [str(SCRIPTS / "cuda-runtime-env.sh"), sys.executable, str(self.recorder)],
            PATH=f"{self.root / 'bin'}:{self.environment['PATH']}",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("SCHED_OTHER", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_wrapper_nice_is_absolute_under_posix_environment(self):
        result = self.run_command([
            "nice", "-n", "5", str(SCRIPTS / "cuda-runtime-env.sh"),
            sys.executable, str(self.recorder),
        ], POSIXLY_CORRECT="1", QWEN_SERVING_NICE="10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"policy": os.SCHED_OTHER, "nice": 10})

    def prepare_session(self):
        for name in (
            "gpu-workload-ownership.sh", "qwen-admission-barrier.sh", "qwen-drain-controller.sh",
            "qwen-retire-server-child.sh", "qwen-router-orderly-retire.py",
        ):
            shutil.copy2(SCRIPTS / name, self.scripts / name)
        session_source = (SCRIPTS / "qwen-webui-session.sh").read_text()
        # Shorten the deadline while retaining the production readiness and
        # cleanup code, including every identity and drain operation.
        readiness_bound = 'while [ "$attempt" -lt 1200 ]; do'
        self.assertEqual(session_source.count(readiness_bound), 1)
        self.write("scripts/qwen-webui-session.sh", session_source.replace(
            readiness_bound, 'while [ "$attempt" -lt 20 ]; do'
        ), executable=True)
        self.write("scripts/run-qwen-capacity-server.sh", """
            #!/bin/sh
            exec "$PYTHON" "$QWEN_TEST_SERVER_PROGRAM"
        """, executable=True)
        self.write("fake-driver", "#!/bin/sh\nexit 0\n", executable=True)
        server = self.write("server.py", """
            import json, os, signal
            from pathlib import Path
            def retire(_signal, _frame):
                print("workload lease teardown: held=yes", flush=True)
                raise SystemExit(0)
            signal.signal(signal.SIGTERM, retire)
            Path(os.environ["QWEN_TEST_SERVER_RECORD"]).write_text(json.dumps({
                "pid": os.getpid(), "policy": os.sched_getscheduler(0),
                "nice": os.getpriority(os.PRIO_PROCESS, 0),
                "start_time": Path("/proc/self/stat").read_text().rsplit(")", 1)[1].split()[19]}))
            print("model loaded", flush=True)
            while True:
                signal.pause()
        """)
        state = self.root / "state"
        self.environment.update({
            "QWEN_GPU_OWNERSHIP_LOCK": str(self.root / "owner.lock"),
            "QWEN_GPU_OWNERSHIP_NVIDIA_SMI": str(self.root / "fake-driver"),
            "QWEN_GPU_COMPUTE_LEASE": str(self.root / "compute.lease"),
            "QWEN_TEST_SERVER_PROGRAM": str(server),
            "QWEN_TEST_SERVER_RECORD": str(self.root / "server-record.json"),
            # Deliberately disagree with the fixture's nice value. Readiness
            # must fail while the child stays alive until the EXIT drain.
            "QWEN_SERVING_NICE": "19",
        })
        return [
            "chrt", "--idle", "0", str(self.scripts / "qwen-webui-session.sh"),
            "fixture-server", "fixture-model", "fixture-static", "4096", "4096",
            "18080", str(state), "default",
        ]

    def test_failed_readiness_retains_identity_and_retires_live_child(self):
        command = self.prepare_session()
        if not self.permits_idle_transition():
            command[1] = "--other"
            print("readiness_fixture=SCHED_OTHER reason=restricted_idle_transition")
        process = subprocess.Popen(command, env=self.environment, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=25)
        except subprocess.TimeoutExpired:
            self.fail("readiness failure waited on its live child before retirement")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            record_path = self.root / "server-record.json"
            if record_path.exists():
                child_record = json.loads(record_path.read_text())
                self.addCleanup(self.retire_fixture_residue, child_record)
        self.assertEqual(process.returncode, 1, stdout + stderr)
        record = json.loads(record_path.read_text())
        self.assertEqual(record["policy"], os.SCHED_OTHER)
        self.assertFalse(Path(f"/proc/{record['pid']}").exists(), "session left the fixture child live")
        status = (self.root / "state/session.status").read_text()
        fields = dict(field.split("=", 1) for field in status.split())
        self.assertEqual(fields["state"], "failed")
        self.assertEqual(fields["server_pid"], str(record["pid"]))
        self.assertGreater(int(fields["server_start_time"]), 0)
        self.assertEqual(fields["session_pid"], str(process.pid))
        self.assertEqual(fields["nice"], str(record["nice"]))
        self.assertEqual(fields["expected_nice"], "19")
        self.assertIn("session_retirement=completed",
                      (self.root / "state/session-drain.record").read_text())
        retirement_log = self.root / "state/server-retirement.log"
        self.assertEqual(retirement_log.stat().st_mode & 0o777, 0o600)
        self.assertIn("server_retirement=completed", retirement_log.read_text())
        self.assertIn("teardown_exclusion=orderly", retirement_log.read_text())

    def test_session_scheduler_refusal_precedes_server_launch(self):
        command = self.prepare_session()
        command = command[3:]
        self.write("bin/chrt", "#!/bin/sh\nexit 1\n", executable=True)
        result = self.run_command(command, PATH=f"{self.root / 'bin'}:{self.environment['PATH']}")
        self.assertEqual(result.returncode, 1)
        self.assertIn("session cannot establish SCHED_OTHER", result.stderr)
        self.assertFalse((self.root / "server-record.json").exists())

    @staticmethod
    def retire_fixture_residue(child_record):
        child_pid = child_record["pid"]
        try:
            live_start = Path(f"/proc/{child_pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
            if live_start != child_record["start_time"]:
                return
            os.kill(child_pid, signal.SIGKILL)
        except (FileNotFoundError, ProcessLookupError):
            pass

    def prepare_campaign(self, outcome="pass", launch_status=0):
        fixture_socket = self.root.name
        campaign_source = (SCRIPTS / "admit-record-symbols.sh").read_text()
        self.write("scripts/admit-record-symbols.sh", campaign_source.replace(
            "tmux -L qwen-runtime", f"tmux -L {fixture_socket}"
        ), executable=True)
        self.addCleanup(subprocess.run, ["tmux", "-L", fixture_socket,
                                        "kill-session", "-t", "qwen-webui"],
                        check=False, capture_output=True)
        self.write("scripts/model-registry.sh", """
            #!/bin/sh
            printf 'model_file=fixture.gguf\n'
        """, executable=True)
        self.write("scripts/qwen-launch.sh", f"""
            #!/bin/sh
            printf 'launch key=%s\\n' "${{QWEN_REQUIRE_API_KEY:-unset}}" >>"$QWEN_TEST_EVENTS"
            if [ "{launch_status}" -eq 0 ]; then
                tmux -L "$QWEN_TEST_TMUX_SOCKET" new-session -d -s qwen-webui \\
                    -e "QWEN_LAUNCH_ATTEMPT_NONCE=$QWEN_LAUNCH_ATTEMPT_NONCE" 'sleep 120'
            fi
            exit {launch_status}
        """, executable=True)
        self.write("scripts/qwen-teardown.sh", """
            #!/bin/sh
            printf 'teardown\n' >>"$QWEN_TEST_EVENTS"
            tmux -L "$QWEN_TEST_TMUX_SOCKET" kill-session -t qwen-webui
        """, executable=True)
        self.write("scripts/record-symbols-contract.py", """
            import os, sys
            from pathlib import Path
            operation = sys.argv[1]
            if operation == "targets":
                Path(sys.argv[4]).write_text("[]")
                print(1)
            elif operation == "request":
                Path(sys.argv[5]).write_text("{}")
            elif operation == "columns":
                print("model\\tfile\\toutcome")
            elif operation == "check":
                if os.environ.get("QWEN_TEST_CHECK_STATUS"):
                    raise SystemExit(int(os.environ["QWEN_TEST_CHECK_STATUS"]))
                print("fixture\\tfixture.c\\t" + os.environ["QWEN_TEST_OUTCOME"])
        """)
        self.write("bin/curl", """
            #!/bin/sh
            printf '200'
        """, executable=True)
        self.write("graph.json", "{}")
        self.write("state/api.key", "fixture-key")
        self.environment.update({
            "QWEN_SYMBOLS_GRAPH": str(self.root / "graph.json"),
            "QWEN_SYMBOLS_SOURCE": str(self.root),
            "QWEN_SYMBOLS_FILES": "fixture.c",
            "QWEN_SYMBOLS_IDS": "first second",
            "QWEN_WEBUI_STATE_DIRECTORY": str(self.root / "state"),
            "QWEN_TEST_EVENTS": str(self.root / "events"),
            "QWEN_TEST_OUTCOME": outcome,
            "QWEN_TEST_TMUX_SOCKET": fixture_socket,
            "PATH": f"{self.root / 'bin'}:{self.environment['PATH']}",
        })
        return [str(self.scripts / "admit-record-symbols.sh"), str(self.root / "output")]

    def test_campaign_retires_each_owned_arm_and_requires_api_key(self):
        result = self.run_command(self.prepare_campaign())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["launch key=1", "teardown", "launch key=1", "teardown"])

    def test_campaign_returns_failure_for_failed_contract(self):
        result = self.run_command(self.prepare_campaign(outcome="invalid_symbols"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "events").read_text().splitlines()[-1], "teardown")

    def test_campaign_returns_failure_when_every_launch_fails(self):
        result = self.run_command(self.prepare_campaign(launch_status=1))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["launch key=1", "launch key=1"])

    def test_campaign_check_error_removes_credential_header_and_retires(self):
        result = self.run_command(self.prepare_campaign(), QWEN_TEST_CHECK_STATUS="7")
        self.assertEqual(result.returncode, 7)
        self.assertEqual((self.root / "events").read_text().splitlines(),
                         ["launch key=1", "teardown"])
        self.assertEqual(list(self.root.glob("symbols.*")), [])


if __name__ == "__main__":
    unittest.main()
