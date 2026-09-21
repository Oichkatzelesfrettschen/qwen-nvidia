#!/usr/bin/env python3
"""Run geometry-resident-driver.py against a fake runtime on a host with no card.

The driver's claims are the ones a supervisor cannot take from the worker: that
a session serves the bounds the ledger declares, that the lease is free between
requests, that a retired worker holds no device memory, and that every fresh
result met an independent reference. Each is checked here against a worker that
holds and one that does not, so a passing arm names a rejection the driver
makes rather than a run that happened to succeed.

The fake runtime speaks the same line protocol the compiled binary does and
reads its version from scripts/geometry_protocol.py, so an arm that passes here
is an arm the real worker meets.
"""

import fcntl
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import geometry_protocol as protocol  # noqa: E402

FAKE = SCRIPTS / "test-fixtures" / "fake-optix-runtime.sh"
DRIVER = SCRIPTS / "geometry-resident-driver.py"

_ROWS = (
    ("geometry-cube-test", "one-shot", "1", "n-a", "n-a", "n-a"),
    ("geometry-cube-resident", "bounded-resident", "4", "60", "5", "512"),
    ("geometry-cube-refused", "one-shot", "1", "n-a", "n-a", "n-a"),
)
LEDGER = "# " + "\t".join(protocol.PROFILE_COLUMNS) + "\n" + "".join(
    "\t".join((profile_id, "cube-and-plane", "orbit", "4096", "10",
               "refused" if profile_id.endswith("refused") else "validator-gated", "0", "enabled",
               residency, requests, seconds, idle, budget)) + "\n"
    for profile_id, residency, requests, seconds, idle, budget in _ROWS)


class Harness:
    def __init__(self, root, mode="ok"):
        self.root = root
        self.runtime_directory = root / "runtime"
        self.runtime_directory.mkdir(parents=True, exist_ok=True)
        self.runtime = self.runtime_directory / "optix-ray-runtime"
        self.runtime.write_bytes(FAKE.read_bytes())
        self.runtime.chmod(0o755)
        (self.runtime_directory / "fake-mode").write_text(mode)
        # The fixture reads the protocol version out of the module beside the
        # scripts directory, so the copy keeps that relationship.
        (root / "geometry_protocol.py").write_bytes(
            (SCRIPTS / "geometry_protocol.py").read_bytes())
        self.ledger = root / "geometry-profiles.tsv"
        self.ledger.write_text(LEDGER)
        self.state = root / "state"
        self.state.mkdir(exist_ok=True)
        self.lease = self.state / "vulkan-workload.lock"
        self.lease.touch()

    def run(self, mode="resident", profile="geometry-cube-resident", requests=2, rays=1024,
            environment=None):
        record = self.root / ("record-%s.tsv" % mode)
        stderr = self.root / ("runtime-%s.err" % mode)
        argv = [sys.executable, str(DRIVER), "--profiles", str(self.ledger),
                "--profile-id", profile, "--runtime", str(self.runtime),
                "--state-dir", str(self.state), "--record", str(record),
                "--stderr", str(stderr), "--mode", mode, "--requests", str(requests),
                "--rays", str(rays), "--run-id", "test", "--lease-wait-s", "2"]
        env = dict(os.environ)
        env["QWEN_GPU_COMPUTE_LEASE"] = str(self.lease)
        if environment:
            env.update(environment)
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=120, check=False,
                                   env=env)
        return completed, record


def main():
    failures = []

    def check(condition, label):
        print("%s %s" % ("ok" if condition else "FAIL", label))
        if not condition:
            failures.append(label)

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)

        harness = Harness(root / "good")
        completed, record = harness.run(requests=2)
        if completed.returncode != 0:
            # The driver's own refusal is the finding when this arm fails, so
            # it is printed rather than left in a captured pipe.
            print(completed.stdout + completed.stderr, file=sys.stderr)
        check(completed.returncode == 0, "a bounded resident session serves its requests")
        rows = [line.split("\t") for line in record.read_text().splitlines()] if record.exists() else []
        header = rows[0] if rows else []
        arms = [row[0] for row in rows[1:]]
        check(header[:1] == ["arm"] and protocol.STAGE_KEYS.issubset(header),
              "the record carries a header naming the arm and every stage")
        check(arms == ["resident-startup", "resident", "resident", "resident-retire"],
              "the record names the startup, each request, and the retirement")
        if len(rows) > 2:
            columns = dict(zip(header, rows[2]))
            paid = {key for key in sorted(protocol.STAGE_KEYS) if columns.get(key)}
            check(paid == set(protocol.RESIDENT_REQUEST_STAGE_KEYS),
                  "a resident request records the six stages it pays and no others")
            startup = dict(zip(header, rows[1]))
            startup_paid = {key for key in sorted(protocol.STAGE_KEYS) if startup.get(key)}
            check(startup_paid == set(protocol.RESIDENT_STARTUP_STAGE_KEYS),
                  "the session records the six stages it pays once")
            retire = dict(zip(header, rows[4] if len(rows) > 4 else rows[-1]))
            retire_paid = {key for key in sorted(protocol.STAGE_KEYS) if retire.get(key)}
            check(retire_paid == set(protocol.RESIDENT_RETIRE_STAGE_KEYS),
                  "the retirement records teardown alone")
            check(startup_paid | paid | retire_paid == protocol.STAGE_KEYS,
                  "the three sets together name every stage a one-shot run names")

        # The one-shot control runs the same driver against the same ledger.
        completed, record = Harness(root / "control").run(
            mode="one-shot", profile="geometry-cube-test", requests=2)
        check(completed.returncode == 0, "the one-shot control serves its requests")
        rows = [line.split("\t") for line in record.read_text().splitlines()]
        check([row[0] for row in rows[1:]] == ["one-shot", "one-shot"],
              "the control records one row per request and no session rows")
        columns = dict(zip(rows[0], rows[1]))
        check({key for key in sorted(protocol.STAGE_KEYS) if columns.get(key)} == protocol.STAGE_KEYS,
              "a one-shot request records every stage, because it pays every stage")

        # A mode the row does not declare is the permission and the act coming
        # apart, in both directions.
        completed, _ = Harness(root / "cross-a").run(mode="resident", profile="geometry-cube-test")
        check(completed.returncode != 0 and "row_is_one_shot" in completed.stderr + completed.stdout,
              "a resident run against a one-shot row refuses")
        completed, _ = Harness(root / "cross-b").run(mode="one-shot", profile="geometry-cube-resident")
        check(completed.returncode != 0 and "row_is_bounded_resident" in completed.stderr + completed.stdout,
              "a one-shot run against a bounded-resident row refuses")
        completed, _ = Harness(root / "refused").run(mode="one-shot", profile="geometry-cube-refused")
        check(completed.returncode != 0 and "execution_policy" in completed.stderr + completed.stdout,
              "a refused row refuses")
        completed, _ = Harness(root / "over").run(requests=5)
        check(completed.returncode != 0 and "requests_over_session" in completed.stderr + completed.stdout,
              "a run asking for more requests than the session declares refuses")

        for mode, label in (
                ("resident-bounds", "a worker reading back a session other than the one it was given"),
                ("resident-protocol", "a worker speaking another protocol version"),
                ("resident-holds", "a worker retiring while it still holds device memory"),
                ("resident-served", "a worker retiring having served more than it was sent"),
                ("resident-disagree", "a worker answering with a ray the reference contradicts"),
                ("resident-budget", "a worker refusing a request against its residency ceiling")):
            completed, _ = Harness(root / mode, mode=mode).run(requests=2)
            check(completed.returncode != 0, "%s is refused" % label)

        completed, _ = Harness(root / "unnamed").run(
            requests=1, environment={"QWEN_GPU_COMPUTE_LEASE": ""})
        check(completed.returncode != 0 and "compute_lease_unnamed" in completed.stdout + completed.stderr,
              "a run with no lease named refuses rather than inventing one")

        # The lease is what residency does not buy: a held lease with no
        # request in flight ends the run before the first request goes out.
        harness = Harness(root / "held")
        descriptor = os.open(str(harness.lease), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            completed, _ = harness.run(requests=1)
            check(completed.returncode != 0 and "lease" in completed.stderr,
                  "a lease another holder has refuses the session rather than waiting it out")
        finally:
            os.close(descriptor)

    print("geometry_resident_driver=%s%s" % (
        "accepted" if not failures else "rejected",
        "" if not failures else " failures=%d" % len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
