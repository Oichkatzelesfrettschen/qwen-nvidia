#!/usr/bin/env python3
"""Exercise the router retirement adapter and the patched caller contract off-device."""

import http.server
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
ADAPTER = ROOT / "scripts/qwen-router-orderly-retire.py"
PATCH = ROOT / "patches/llama-router-orderly-retirement.patch"
BARRIER = ROOT / "scripts/qwen-admission-barrier.sh"


class RetirementHandler(http.server.BaseHTTPRequestHandler):
    proof = "orderly"
    exit_status = 0
    events = []

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).events.append("unload:" + body["model"])
        response = json.dumps({
            "success": True,
            "model": body["model"],
            "generation_port": 19001,
            "pid": os.getpid(),
            "start_time": "12345",
            "exited": True,
            "exit_status": type(self).exit_status,
            "teardown_exclusion": type(self).proof,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, _format, *_args):
        return


class RouterOrderlyRetirement(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = pathlib.Path(self.temporary.name) / "state"
        self.environment = dict(os.environ, QWEN_GPU_ADMISSION_BARRIER=str(self.state))
        subprocess.run(
            [str(ROOT / "scripts/qwen-drain-controller.sh"), "status"],
            env=self.environment,
            stdout=subprocess.DEVNULL,
            check=True,
        )
        self.identity = (self.state / "admission.identity").read_text().strip()
        self.environment["QWEN_GPU_ADMISSION_IDENTITY"] = self.identity
        server_socket = socket.socket()
        server_socket.bind(("127.0.0.1", 0))
        self.port = server_socket.getsockname()[1]
        server_socket.close()
        RetirementHandler.events = []
        RetirementHandler.exit_status = 0
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), RetirementHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def run_adapter(self):
        return subprocess.run(
            [str(ADAPTER), "old-model", str(self.port)],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_real_controller_waits_for_explicit_release(self):
        holder_started = pathlib.Path(self.temporary.name) / "holder-started"
        holder_release = pathlib.Path(self.temporary.name) / "holder-release"
        holder = subprocess.Popen(
            [str(ROOT / "scripts/qwen-drain-controller.sh"), "admit", "--",
             "sh", "-c", 'touch "$1"; while [ ! -e "$2" ]; do sleep .01; done',
             "holder", str(holder_started), str(holder_release)],
            env=self.environment,
            stdout=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and not holder_started.exists():
            time.sleep(0.01)
        self.assertTrue(holder_started.exists())
        RetirementHandler.proof = "orderly"
        adapter = subprocess.Popen(
            [str(ADAPTER), "old-model", str(self.port)],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if (self.state / "admission.barrier").read_text().strip() == "quiescing":
                break
            time.sleep(0.01)
        self.assertEqual(RetirementHandler.events, [])
        holder_release.touch()
        holder.wait(timeout=2)
        output, _ = adapter.communicate(timeout=5)
        self.assertEqual(adapter.returncode, 0, output)
        self.assertIn("teardown_exclusion=orderly", output)
        self.assertEqual(RetirementHandler.events, ["unload:old-model"])
        with __import__("urllib.request").request.urlopen(
            "http://127.0.0.1:%d/health" % self.port, timeout=2
        ) as response:
            self.assertEqual(response.status, 200)
        self.assertEqual((self.state / "admission.barrier").read_text().strip(), "quiescing")

    def test_zero_exit_without_teardown_proof_stays_closed(self):
        RetirementHandler.proof = "unattributed"
        result = self.run_adapter()
        self.assertEqual(result.returncode, 4, result.stdout)
        self.assertIn("teardown_exclusion=unattributed", result.stdout)
        self.assertEqual((self.state / "admission.barrier").read_text().strip(), "quiescing")

    def test_nonzero_child_exit_refuses_orderly_proof(self):
        RetirementHandler.proof = "orderly"
        RetirementHandler.exit_status = 9
        result = self.run_adapter()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("child_exit_status_not_zero", result.stdout)
        self.assertEqual((self.state / "admission.barrier").read_text().strip(), "quiescing")

    def test_patch_keeps_deferred_selection_outside_old_reference(self):
        text = PATCH.read_text()
        self.assertIn("bool server_models::ensure_model_ready", text)
        self.assertIn("QWEN_ROUTER_RETIRE_COMMAND", text)
        self.assertIn("status == 0 && log.find", text)
        self.assertIn("models.wait(model->name", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
