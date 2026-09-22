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
PROBE = SCRIPTS / "test-fixtures" / "fake-residency-probe.sh"
DRIVER = SCRIPTS / "geometry-resident-driver.py"

_ROWS = (
    ("geometry-cube-test", "one-shot", "1", "n-a", "n-a", "n-a", "n-a"),
    ("geometry-cube-resident", "bounded-resident", "4", "60", "5", "512", "64"),
    ("geometry-cube-refused", "one-shot", "1", "n-a", "n-a", "n-a", "n-a"),
)
LEDGER = "# " + "\t".join(protocol.PROFILE_COLUMNS) + "\n" + "".join(
    "\t".join((profile_id, "cube-and-plane", "orbit", "4096", "10",
               "refused" if profile_id.endswith("refused") else "validator-gated", "0", "enabled",
               residency, requests, seconds, idle, budget, application)) + "\n"
    for profile_id, residency, requests, seconds, idle, budget, application in _ROWS)


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
            environment=None, probe="held"):
        record = self.root / ("record-%s.tsv" % mode)
        stderr = self.root / ("runtime-%s.err" % mode)
        argv = [sys.executable, str(DRIVER), "--profiles", str(self.ledger),
                "--profile-id", profile, "--runtime", str(self.runtime),
                "--state-dir", str(self.state), "--record", str(record),
                "--stderr", str(stderr), "--mode", mode, "--requests", str(requests),
                "--rays", str(rays), "--run-id", "test", "--lease-wait-s", "2",
                "--residency-probe", "%s %s {pid}" % (PROBE, probe)]
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
        check(arms == ["resident-startup", "resident-idle-before", "resident", "resident",
                       "resident-idle-after", "resident-retire"],
              "the record names the startup, each idle reading, each request, and the retirement")
        if len(rows) > 4:
            columns = dict(zip(header, rows[3]))
            paid = {key for key in sorted(protocol.STAGE_KEYS) if columns.get(key)}
            check(paid == set(protocol.RESIDENT_REQUEST_STAGE_KEYS),
                  "a resident request records the six stages it pays and no others")
            startup = dict(zip(header, rows[1]))
            startup_paid = {key for key in sorted(protocol.STAGE_KEYS) if startup.get(key)}
            check(startup_paid == set(protocol.RESIDENT_STARTUP_STAGE_KEYS),
                  "the session records the six stages it pays once")
            retire = dict(zip(header, rows[-1]))
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
                ("resident-refuses", "a worker refusing a well-formed request for no bound of its own")):
            completed, _ = Harness(root / mode, mode=mode).run(requests=2)
            check(completed.returncode != 0, "%s is refused" % label)

        # The residency allowance is enforced by a reading, so a probe that
        # answers nothing leaves it enforcing nothing: the run ends rather
        # than continuing against an allowance never tested.
        completed, record = Harness(root / "unread").run(requests=2, probe="unread")
        check(completed.returncode != 0,
              "a residency probe that answers nothing ends the session")
        rows = [line.split("\t") for line in record.read_text().splitlines()]
        check(any(row[0] == "resident-idle-before" and row[-1] == "residency_unread"
                  for row in rows[1:]),
              "the record names the reading it did not get rather than leaving the cell empty")
        completed, _ = Harness(root / "overbudget").run(requests=2, probe="over")
        check(completed.returncode != 0,
              "a worker resident past the row's allowance ends the session")
        completed, _ = Harness(root / "absent").run(requests=2, probe="absent")
        check(completed.returncode == 0,
              "a pid the driver does not list holds nothing, which is inside every allowance")

        # The two ceilings count different things, and this is the case one
        # number over both readings cannot catch: 128 MiB of the worker's own
        # allocations against a 64 MiB application ceiling, while the probe
        # reports 128 MiB against a 512 MiB residency allowance. The residency
        # reading passes and the application ceiling is what refuses.
        completed, _ = Harness(root / "overapplication", mode="resident-overallocates").run(
            requests=2, probe="held")
        check(completed.returncode != 0,
              "a worker allocating past the application ceiling is refused "
              "though its residency reading is inside the allowance")

        # Destroying device state is compute. A worker that reaches a bound of
        # its own asks for the lease that destruction runs under; one that
        # destroys at the moment its bound expires did it owning nothing.
        for mode, label in (
                ("resident-silent-retire", "a worker destroying on its own bound without asking"),
                ("resident-unauthorized", "a worker destroying without waiting for the answer")):
            completed, _ = Harness(root / mode, mode=mode).run(requests=4)
            check(completed.returncode != 0, "%s is refused" % label)

        harness = Harness(root / "early", mode="resident-early-retire")
        completed, record = harness.run(requests=4)
        rows = [line.split("\t") for line in record.read_text().splitlines()]
        check(completed.returncode == 0 and "retirement_authorized=True" in completed.stdout,
              "a worker announcing a bound of its own is authorized rather than killed")
        check([row[0] for row in rows[1:]] == [
            "resident-startup", "resident-idle-before", "resident", "resident-retiring",
            "resident-idle-after", "resident-retire"],
              "the notice stops the requests and the record names the bound it cited")

        # A refusal against the application ceiling is a bound the worker
        # reached, so it takes the authorized retirement path rather than the
        # termination one: the session ends with the worker told it may
        # destroy, not killed while it waits to be.
        harness = Harness(root / "appceiling", mode="resident-budget")
        completed, record = harness.run(requests=2)
        rows = [line.split("\t") for line in record.read_text().splitlines()]
        check(completed.returncode == 0 and "retirement_authorized=True" in completed.stdout,
              "a request refused against the application ceiling retires authorized "
              "rather than being terminated")
        check(any(row[0] == "resident-retiring" and row[-1] == "budget_exceeded"
                  for row in rows[1:]),
              "the record names the application ceiling as the bound the session ended on")

        # A request that fails may have left a launch in flight, so the worker
        # is ended and reaped before the ownership protecting that work goes.
        # A failure found after the reply arrived owns nothing in flight, so
        # that path takes the lease again to destroy under it. Either way the
        # row naming the ownership is written before the lease is released.
        for mode, note, label in (
                ("resident-refuses", "owned-request",
                 "a request that fails ends the worker under the lease that covered it"),
                ("resident-disagree", "owned",
                 "a reply that fails its check ends the worker under a lease taken to do it")):
            harness = Harness(root / ("reaped-" + mode), mode=mode)
            completed, record = harness.run(requests=2)
            rows = [line.split("\t") for line in record.read_text().splitlines()]
            check(completed.returncode != 0 and rows[-1][0] == "resident-terminated"
                  and rows[-1][-1] == note, label)
            check(subprocess.run(["pgrep", "-f", str(harness.runtime)], capture_output=True,
                                 check=False).returncode != 0,
                  "no worker outlives the run that spawned it on %s" % mode)
        descriptor = os.open(str(harness.lease), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            check(True, "the lease is free once the run that held it has ended")
        except OSError:
            check(False, "the lease is free once the run that held it has ended")
        finally:
            os.close(descriptor)

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
