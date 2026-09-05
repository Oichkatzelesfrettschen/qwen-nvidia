#!/usr/bin/env python3
"""Hold geometry-service.py to its contract against the fake runtime.

The service is started on a fixture ledger with one validator-gated row and
one refused row, the fake runtime stands in for the OptiX binary, and every
exchange runs over the service's own socket. The cases: a valid request
completes with the GPU proof, the reference agreeing on every ray, and the
runtime's digest; a request naming a refused row, an unknown row, a ray count
over the profile ceiling, or an unknown key is refused by name; a runtime
that answers without the GPU proof fails with gpu_fallback; a runtime whose
host reference contradicts one ray fails with reference_disagreement; a
crashing runtime fails with runtime_failed; a hanging runtime fails with
runtime_timeout and leaves no child behind; a held lease refuses with
lease_unavailable before any runtime starts; and the runtime runs at nice 19
through the priority wrapper with the lease held across it and released
after.
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
import geometry_protocol as protocol  # noqa: E402

FAKE = SCRIPTS / "test-fixtures" / "fake-optix-runtime.sh"
SERVICE = SCRIPTS / "geometry-service.py"

LEDGER = (
    "# profile_id\tscene\tquery_set\tmax_rays\ttimeout_s\texecution_policy\tdevice_index\n"
    "geometry-cube-test\tcube-and-plane\torbit\t4096\t3\tvalidator-gated\t0\n"
    "geometry-cube-refused\tcube-and-plane\torbit\t4096\t3\trefused\t0\n"
)


class Harness:
    def __init__(self, state, mode="ok"):
        self.state = state
        self.socket_path = str(state / "geometry-service.sock")
        runtime_directory = state / "runtime"
        runtime_directory.mkdir(exist_ok=True)
        runtime = runtime_directory / "fake-optix-runtime.sh"
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


def request(profile="geometry-cube-test", rays=1024, **extra):
    message = {"protocol": 1, "action": "geometry_ray_query", "request_id": "r-%d" % int(time.time() * 1000),
               "profile_id": profile, "rays": rays}
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
            check(reply.get("result", {}).get("gpu", {}).get("launch_completed") is True,
                  "the completed reply carries the GPU proof")
            check(reply.get("result", {}).get("reference_disagreement") == 0,
                  "the completed reply carries no reference disagreement")
            check(reply.get("result", {}).get("runtime_sha256") == harness.runtime_sha256,
                  "the result names the runtime digest the service announced")
            check(reply.get("result", {}).get("rays") == 1024, "the result reports the requested rays")
            try:
                protocol.parse_reply(json.dumps(reply))
                check(True, "the reply parses under the protocol")
            except protocol.ProtocolError as error:
                check(False, "the reply parses under the protocol: %s" % error)
            check(marker.exists() and "nice=19" in marker.read_text(),
                  "the runtime ran at nice 19 through the priority wrapper")
            status = (state / "vulkan-workload.status").read_text()
            check(status.startswith("state=released"), "the lease is released after the job")

            reply = harness.exchange(request(profile="geometry-cube-refused"))
            check(reply["status"] == "refused" and reply.get("reason") == "profile_refused",
                  "a refused row is refused by name")
            reply = harness.exchange(request(profile="geometry-cube-absent"))
            check(reply["status"] == "refused" and reply.get("reason") == "profile_refused",
                  "an unknown row is refused")
            reply = harness.exchange(request(rays=4097))
            check(reply["status"] == "refused" and reply.get("reason") == "invalid_argument",
                  "a ray count over the ceiling is refused")
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
                                          ("disagree", "reference_disagreement",
                                           "a runtime the host reference contradicts fails"),
                                          ("crash", "runtime_failed", "a crashing runtime fails"),
                                          ("prose", "runtime_failed", "a runtime printing prose fails"),
                                          ("hang", "runtime_timeout", "a hanging runtime times out")):
            harness = Harness(state, mode=mode)
            try:
                reply = harness.exchange(request())
                check(reply["status"] == "failed" and reply.get("reason") == reason, description)
                if mode == "hang":
                    left = subprocess.run(["pgrep", "-f", "fake-optix-runtime.sh cube-and-plane"],
                                          capture_output=True, text=True).stdout.strip()
                    check(not left, "the timed-out runtime is gone")
            finally:
                harness.stop()
        check(not (state / "geometry-service.sock").exists(), "the socket is removed at exit")
        teardown = subprocess.run([str(SCRIPTS / "geometry-teardown-check.sh"), str(state)],
                                  capture_output=True, text=True)
        check(teardown.returncode == 0 and "geometry_teardown=clean" in teardown.stdout,
              "the teardown check reads clean")

    if failures:
        print("geometry_service=rejected failures=%d" % len(failures), file=sys.stderr)
        sys.exit(1)
    print("geometry_service=accepted")


if __name__ == "__main__":
    main()
