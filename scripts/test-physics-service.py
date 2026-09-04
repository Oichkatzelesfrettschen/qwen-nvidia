#!/usr/bin/env python3
"""Hold physics-service.py to its contract against the fake runtime.

The service is started on a fixture ledger with one validator-gated row and
one refused row, the fake runtime stands in for the PhysX binary, and every
exchange runs over the service's own socket. The cases: a valid request
completes with the GPU proof and the runtime's digest; a request naming a
refused row, an unknown row, a step count over the profile ceiling, or an
unknown key is refused by name; a runtime that answers without the GPU proof
fails with gpu_fallback; a crashing runtime fails with runtime_failed; a
hanging runtime fails with runtime_timeout and leaves no child behind; a held
lease refuses with lease_unavailable before any runtime starts; and the
runtime runs at nice 19 through the priority wrapper with the lease held
across it and released after.
"""

import fcntl
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

SCRIPTS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import physics_protocol as protocol  # noqa: E402

FAKE = SCRIPTS / "test-fixtures" / "fake-physx-runtime.sh"
SERVICE = SCRIPTS / "physics-service.py"

LEDGER = (
    "# profile_id\tscene\ttimestep_s\tmax_steps\tgravity_y\tgpu_dynamics\tgpu_broadphase\ttimeout_s\texecution_policy\tdevice_index\n"
    "physics-d6-test\td6-chain-4\t0.0166667\t600\t9.81\tyes\tyes\t3\tvalidator-gated\t0\n"
    "physics-d6-refused\td6-chain-4\t0.0166667\t600\t9.81\tyes\tyes\t3\trefused\t0\n"
)


class Harness:
    def __init__(self, state, mode="ok"):
        self.state = state
        self.socket_path = str(state / "physics-service.sock")
        runtime_directory = state / "runtime"
        runtime_directory.mkdir(exist_ok=True)
        runtime = runtime_directory / "fake-physx-runtime.sh"
        runtime.write_bytes(FAKE.read_bytes())
        runtime.chmod(0o755)
        (runtime_directory / "fake-mode").write_text(mode + "\n")
        self.marker = runtime_directory / "runtime-marker.txt"
        self.process = subprocess.Popen(
            [sys.executable, str(SERVICE), "--state-dir", str(state), "--profiles", str(state / "profiles.tsv"),
             "--runtime", str(runtime), "--lease-wait-s", "0.5"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = self.process.stdout.readline()
        if not line.startswith("listening"):
            raise SystemExit("service did not announce: %r %s" % (line, self.process.stderr.read()))
        self.runtime_sha256 = line.split("runtime_sha256=")[1].split()[0]

    def exchange(self, message):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(30)
            connection.connect(self.socket_path)
            connection.sendall((json.dumps(message) + "\n").encode())
            buffer = b""
            while b"\n" not in buffer:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                buffer += chunk
        return json.loads(buffer.decode())

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()


def request(profile="physics-d6-test", steps=60, **extra):
    message = {"protocol": 1, "action": "physics_simulate_rigid", "request_id": "r-%d" % int(time.time() * 1000),
               "profile_id": profile, "steps": steps}
    message.update(extra)
    return message


def main():
    failures = []

    def check(condition, description):
        print(("ok " if condition else "FAIL ") + description)
        if not condition:
            failures.append(description)

    with tempfile.TemporaryDirectory() as directory:
        state = pathlib.Path(directory)
        (state / "profiles.tsv").write_text(LEDGER)
        harness = Harness(state)
        marker = harness.marker
        try:
            reply = harness.exchange(request())
            check(reply["status"] == "completed", "a valid request completes")
            check(reply.get("result", {}).get("gpu", {}).get("gpu_dynamics_active") is True,
                  "the completed reply carries the GPU proof")
            check(reply.get("result", {}).get("runtime_sha256") == harness.runtime_sha256,
                  "the result names the runtime digest the service announced")
            check(reply.get("result", {}).get("steps") == 60, "the result reports the requested steps")
            try:
                protocol.parse_reply(json.dumps(reply))
                check(True, "the reply parses under the protocol")
            except protocol.ProtocolError as error:
                check(False, "the reply parses under the protocol: %s" % error)
            check(marker.exists() and "nice=19" in marker.read_text(),
                  "the runtime ran at nice 19 through the priority wrapper")
            status = (state / "vulkan-workload.status").read_text()
            check(status.startswith("state=released"), "the lease is released after the job")

            reply = harness.exchange(request(profile="physics-d6-refused"))
            check(reply["status"] == "refused" and reply.get("reason") == "profile_refused",
                  "a refused row is refused by name")
            reply = harness.exchange(request(profile="physics-d6-absent"))
            check(reply["status"] == "refused" and reply.get("reason") == "profile_refused",
                  "an unknown row is refused")
            reply = harness.exchange(request(steps=601))
            check(reply["status"] == "refused" and reply.get("reason") == "invalid_argument",
                  "a step count over the ceiling is refused")
            reply = harness.exchange(request(scene="evil"))
            check(reply["status"] == "refused" and reply.get("reason") == "invalid_argument",
                  "an unknown key is refused")
            reply = harness.exchange({"protocol": 1, "action": "status", "request_id": "s1"})
            check(reply["status"] == "accepted" and reply.get("reason") == "idle", "status reads idle")

            lease = os.open(str(state / "vulkan-workload.lock"), os.O_RDWR | os.O_CREAT)
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            marker.unlink()
            reply = harness.exchange(request())
            check(reply["status"] == "refused" and reply.get("reason") == "lease_unavailable",
                  "a held lease refuses the request")
            check(not marker.exists(), "no runtime started under a held lease")
            os.close(lease)
        finally:
            harness.stop()

        for mode, reason, description in (("cpu", "gpu_fallback", "a runtime without the GPU proof fails"),
                                          ("crash", "runtime_failed", "a crashing runtime fails"),
                                          ("prose", "runtime_failed", "a runtime printing prose fails"),
                                          ("hang", "runtime_timeout", "a hanging runtime times out")):
            harness = Harness(state, mode=mode)
            try:
                reply = harness.exchange(request())
                check(reply["status"] == "failed" and reply.get("reason") == reason, description)
                if mode == "hang":
                    left = subprocess.run(["pgrep", "-f", "fake-physx-runtime.sh d6-chain-4"],
                                          capture_output=True, text=True).stdout.strip()
                    check(not left, "the timed-out runtime is gone")
            finally:
                harness.stop()
        check(not (state / "physics-service.sock").exists(), "the socket is removed at exit")
        teardown = subprocess.run([str(SCRIPTS / "physics-teardown-check.sh"), str(state)],
                                  capture_output=True, text=True)
        check(teardown.returncode == 0 and "physics_teardown=clean" in teardown.stdout,
              "the teardown check reads clean")

    if failures:
        print("physics_service=rejected failures=%d" % len(failures), file=sys.stderr)
        sys.exit(1)
    print("physics_service=accepted")


if __name__ == "__main__":
    main()
