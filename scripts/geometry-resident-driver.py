#!/usr/bin/env python3
"""Drive one bounded geometry session, resident or one-shot, and record it.

The two arms this drives differ in residency and in nothing else. The one-shot
arm spawns the runtime once per request, which builds its device state, serves
the query and releases everything; the resident arm spawns it once for the
session, and each request runs against state the previous request left. Both
arms take the compute lease around each request through the same WorkloadLease
geometry-service.py uses, hold none between requests, and put every fresh
device result through the same independent host reference, ray by ray. What a
comparison of the two measures is therefore the setup a session keeps.

Residency is the separate permission: the bounded-resident profile row declares
the requests and wall seconds a session serves, the idle interval that ends it
early, and the device memory it may hold, and this reads them from the ledger
rather than from the command line. The worker is handed those bounds on argv
and reads them back in its ready line, so the supervisor and the binary hold
one session or the run refuses.

Nothing here promotes a ledger row. A row reading `refused` refuses, and the
admission harness raises its own copy for one run the way the geometry harness
does.

gpu-ownership: active-workload; takes the compute lease around each request and
holds none between them.
"""

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
import select
import signal
import subprocess
import sys
import time

DRIVER_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, DRIVER_DIRECTORY)
import geometry_protocol as protocol  # noqa: E402

# The lease and the ledger reader are the service's own, loaded from the file
# that defines them: a second implementation of either would be a second
# reading of the rule they carry. The module's name holds a hyphen, so it is
# loaded by path the way the other readers of a hyphenated script in this tree
# are.
_SPEC = importlib.util.spec_from_file_location(
    "geometry_service", os.path.join(DRIVER_DIRECTORY, "geometry-service.py"))
geometry_service = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(geometry_service)

READY_TIMEOUT_SECONDS = 120.0
RETIRE_TIMEOUT_SECONDS = 60.0
TERMINATE_GRACE_SECONDS = 10.0


class DriverError(RuntimeError):
    """A run that cannot continue under the bounds it was given."""


def runtime_environment(profile):
    """The environment the service gives the runtime, and for the same reasons."""
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.environ.get("HOME", "/"),
        "CUDA_VISIBLE_DEVICES": str(profile["device_index"]),
        "CUDA_MODULE_LOADING": "LAZY",
    }
    if profile["module_cache"] == "disabled":
        environment["OPTIX_CACHE_MAXSIZE"] = "0"
    else:
        environment["OPTIX_CACHE_PATH"] = os.path.join(
            os.environ.get("HOME", "/tmp"), ".cache", "qwen-optix-module")
    return environment


def scene_digest(profile, rays):
    """The identity of the problem one request poses, as the service names it."""
    return hashlib.sha256(json.dumps(
        {"scene": profile["scene"], "query_set": profile["query_set"], "rays": rays,
         "module_cache": profile["module_cache"]},
        sort_keys=True).encode()).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


class LineReader:
    """Lines off the worker's pipe under a deadline the supervisor owns.

    readline() on a pipe waits without bound, which would leave a wedged
    worker holding this process rather than the run ending on its own
    deadline. The bytes are read as they arrive and the wait is select's, so a
    partial line that never finishes ends the request the way silence does.
    """

    def __init__(self, descriptor):
        self.descriptor = descriptor
        self.buffer = b""

    def line(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DriverError("no line arrived before the deadline")
            ready, _, _ = select.select([self.descriptor], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(self.descriptor, 65536)
            if not chunk:
                raise DriverError("the worker closed its output")
            if len(self.buffer) + len(chunk) > protocol.MAX_LINE_BYTES * 2:
                raise DriverError("the worker printed more than one line's worth without a newline")
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return line.decode("utf-8", "replace")


class Worker:
    """The resident runtime: one process, one request at a time, bounded."""

    def __init__(self, runtime, profile, bounds, log):
        self.runtime = runtime
        self.profile = profile
        self.bounds = bounds
        self.log = log
        self.process = None
        self.reader = None
        self.ready = None
        self.served = 0
        self.startup_ms = 0.0

    def start(self):
        argv = [
            geometry_service.PRIORITY_WRAPPER, self.runtime, self.profile["scene"],
            self.profile["query_set"], "resident", str(self.profile["device_index"]),
            self.profile["module_cache"], str(self.bounds["session_requests"]),
            str(self.bounds["session_seconds"]), str(self.bounds["idle_timeout_s"]),
            str(self.bounds["residency_budget_mib"]),
        ]
        started = time.monotonic()
        # The worker is a grandchild with a closed descriptor set: flock binds
        # to the open file description, so a lease descriptor handed down would
        # hold the lease for as long as the session lives, which is the whole
        # thing this arm exists to avoid.
        self.process = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            env=runtime_environment(self.profile), close_fds=True, start_new_session=True,
            text=True, bufsize=1)
        self.reader = LineReader(self.process.stdout.fileno())
        line = self.reader.line(started + READY_TIMEOUT_SECONDS)
        event, message = protocol.parse_resident_line(line)
        if event != "ready":
            raise DriverError("the worker's first line is %s rather than ready" % event)
        self.ready = protocol.validate_resident_ready(message, self.bounds)
        self.startup_ms = self.ready["startup_ms"]
        return self.ready

    def query(self, request_id, rays):
        request = {"protocol": protocol.PROTOCOL_VERSION, "action": "query",
                   "request_id": request_id, "rays": rays}
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + self.profile["timeout_s"]
        event, message = protocol.parse_resident_line(self.reader.line(deadline))
        if event == "refused":
            protocol.validate_resident_refused(message, request_id)
            raise DriverError("the worker refused the request: %s %s"
                              % (message["reason"], message["detail"]))
        if event != "result":
            raise DriverError("the worker answered %s rather than result" % event)
        protocol.validate_resident_result(message, self.bounds, request_id, rays)
        self.served += 1
        return message

    def retire(self):
        """Ask for retirement and read the claim that the device holds nothing."""
        if self.process is None:
            return None
        request = {"protocol": protocol.PROTOCOL_VERSION, "action": "shutdown",
                   "request_id": "retire"}
        with contextlib.suppress(OSError, ValueError):
            self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
            self.process.stdin.flush()
        deadline = time.monotonic() + RETIRE_TIMEOUT_SECONDS
        try:
            event, message = protocol.parse_resident_line(self.reader.line(deadline))
            if event != "retired":
                raise DriverError("the worker answered %s rather than retired" % event)
            retired = protocol.validate_resident_retired(message, self.bounds, self.served)
        finally:
            self.close()
        return retired

    def close(self):
        """End the process and prove it left, rather than that it was asked to."""
        process = self.process
        self.process = None
        if process is None:
            return
        with contextlib.suppress(OSError):
            process.stdin.close()
        try:
            process.wait(timeout=TERMINATE_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=TERMINATE_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        with contextlib.suppress(OSError):
            process.stdout.close()


def one_shot_request(runtime, profile, rays, log):
    """Spawn the runtime for one request, the way geometry-service.py does."""
    argv = [geometry_service.PRIORITY_WRAPPER, runtime, profile["scene"], profile["query_set"],
            str(rays), str(profile["device_index"]), profile["module_cache"]]
    completed = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=log, env=runtime_environment(profile), close_fds=True,
                               start_new_session=True, timeout=profile["timeout_s"], check=False)
    if completed.returncode != 0:
        raise DriverError("the runtime exited %d" % completed.returncode)
    lines = [line for line in completed.stdout.decode("utf-8", "replace").splitlines() if line.strip()]
    if len(lines) != 1:
        raise DriverError("the runtime printed %d lines rather than one" % len(lines))
    return json.loads(lines[0])


def require_lease_free(lease):
    """The lease is free between requests, which is what residency does not buy."""
    descriptor = os.open(lease.lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    except OSError:
        raise DriverError("the compute lease is held with no request in flight") from None
    finally:
        os.close(descriptor)


def record_row(handle, fields):
    handle.write("\t".join(str(field) for field in fields) + "\n")
    handle.flush()


COLUMNS = ("arm", "request", "client_ms", "lease_wait_ms", "wall_ms", "rays", "hits",
           "reference_agreement", "reference_disagreement", "results_fnv1a64",
           "device_allocated_bytes") + tuple(sorted(protocol.STAGE_KEYS))


def stage_columns(timings):
    """Every stage in one order, with the stages this arm did not pay left empty.

    A resident request pays six of the thirteen and the session pays the rest
    once, so an empty cell reads as a stage this request did not run rather
    than as a stage that took no time.
    """
    return [("%.3f" % timings[key]) if key in timings else "" for key in sorted(protocol.STAGE_KEYS)]


def run_resident(arguments, profile, bounds, runtime_sha256, record, log):
    worker = Worker(arguments.runtime, profile, bounds, log)
    lease = geometry_service.WorkloadLease(arguments.state_dir, arguments.lease_wait_s)
    session_started = time.monotonic()
    # Building the session's device state is compute: it allocates, copies and
    # builds an acceleration structure. The lease is held for it and released
    # the moment the worker is ready, because what residency buys is the state
    # surviving, not the ownership.
    lease.acquire("%s-startup" % arguments.run_id)
    try:
        ready = worker.start()
    finally:
        lease.release()
    record_row(record, ["resident-startup", 0, "%.3f" % worker.startup_ms, "", "%.3f" % worker.startup_ms,
                        "", "", "", "", "", ready["device_allocated_bytes"]] +
               stage_columns(ready["timings"]))
    try:
        for index in range(1, arguments.requests + 1):
            require_lease_free(lease)
            request_id = "%s-%03d" % (arguments.run_id, index)
            client_started = time.monotonic()
            lease.acquire(request_id)
            lease_acquired = time.monotonic()
            try:
                message = worker.query(request_id, arguments.rays)
            finally:
                lease.release()
            client_ms = (time.monotonic() - client_started) * 1000.0
            lease_wait_ms = (lease_acquired - client_started) * 1000.0
            result = message["result"]
            result["runtime_sha256"] = runtime_sha256
            result["scene_sha256"] = scene_digest(profile, arguments.rays)
            protocol.validate_result(result, timings_keys=protocol.RESIDENT_REQUEST_STAGE_KEYS)
            if not protocol.gpu_proof_holds(result["gpu"]):
                raise DriverError("the worker answered without the GPU proof")
            if result["reference_disagreement"] != 0:
                raise DriverError("the host reference contradicts the device on %d of %d rays"
                                  % (result["reference_disagreement"], arguments.rays))
            record_row(record, ["resident", index, "%.3f" % client_ms, "%.3f" % lease_wait_ms,
                                "%.3f" % result["wall_ms"], result["rays"], result["hits"],
                                result["reference_agreement"], result["reference_disagreement"],
                                result["results_fnv1a64"],
                                message["residency"]["device_allocated_bytes"]] +
                       stage_columns(result["timings"]))
        require_lease_free(lease)
        # Destruction is compute too, so retirement runs under the lease and
        # the check that nothing is held comes after the worker has gone.
        lease.acquire("%s-retire" % arguments.run_id)
        try:
            retired = worker.retire()
        finally:
            lease.release()
    finally:
        worker.close()
    require_lease_free(lease)
    record_row(record, ["resident-retire", 0, "%.3f" % retired["timings"]["teardown_ms"], "",
                        "%.3f" % retired["timings"]["teardown_ms"], "", "", "", "", "",
                        retired["device_allocated_bytes"]] + stage_columns(retired["timings"]))
    return {"mode": "resident", "requests": worker.served, "startup_ms": worker.startup_ms,
            "retirement": retired["reason"], "teardown_ms": retired["timings"]["teardown_ms"],
            "session_s": time.monotonic() - session_started,
            "device_allocated_bytes": ready["device_allocated_bytes"]}


def run_one_shot(arguments, profile, runtime_sha256, record, log):
    lease = geometry_service.WorkloadLease(arguments.state_dir, arguments.lease_wait_s)
    session_started = time.monotonic()
    served = 0
    for index in range(1, arguments.requests + 1):
        require_lease_free(lease)
        request_id = "%s-%03d" % (arguments.run_id, index)
        client_started = time.monotonic()
        lease.acquire(request_id)
        lease_acquired = time.monotonic()
        try:
            result = one_shot_request(arguments.runtime, profile, arguments.rays, log)
        finally:
            lease.release()
        client_ms = (time.monotonic() - client_started) * 1000.0
        lease_wait_ms = (lease_acquired - client_started) * 1000.0
        result["runtime_sha256"] = runtime_sha256
        result["scene_sha256"] = scene_digest(profile, arguments.rays)
        protocol.validate_result(result)
        if not protocol.gpu_proof_holds(result["gpu"]):
            raise DriverError("the runtime answered without the GPU proof")
        if result["reference_disagreement"] != 0:
            raise DriverError("the host reference contradicts the device on %d of %d rays"
                              % (result["reference_disagreement"], arguments.rays))
        served += 1
        record_row(record, ["one-shot", index, "%.3f" % client_ms, "%.3f" % lease_wait_ms,
                            "%.3f" % result["wall_ms"], result["rays"], result["hits"],
                            result["reference_agreement"], result["reference_disagreement"],
                            result["results_fnv1a64"], 0] + stage_columns(result["timings"]))
    require_lease_free(lease)
    return {"mode": "one-shot", "requests": served, "startup_ms": 0.0, "retirement": "per-request",
            "teardown_ms": 0.0, "session_s": time.monotonic() - session_started,
            "device_allocated_bytes": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--profiles", required=True)
    parser.add_argument("--profile-id", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--record", required=True)
    parser.add_argument("--stderr", required=True)
    parser.add_argument("--mode", required=True, choices=("one-shot", "resident"))
    parser.add_argument("--requests", type=int, required=True)
    parser.add_argument("--rays", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--lease-wait-s", type=float, default=5.0)
    arguments = parser.parse_args()

    # The lease taken per request has to be the host's, named by the owner that
    # launched this: a lock file a run invented for itself serializes against
    # nothing, and a session that held such a file would look serialized while
    # running beside every other workload on the card.
    if not os.environ.get("QWEN_GPU_COMPUTE_LEASE"):
        raise SystemExit("geometry_resident_driver=refused reason=compute_lease_unnamed")
    profiles = geometry_service.load_profiles(arguments.profiles)
    profile = profiles.get(arguments.profile_id)
    if profile is None:
        raise SystemExit("geometry_resident_driver=refused reason=profile_absent")
    if profile["execution_policy"] != "validator-gated":
        raise SystemExit("geometry_resident_driver=refused reason=execution_policy=%s"
                         % profile["execution_policy"])
    if arguments.rays > profile["max_rays"]:
        raise SystemExit("geometry_resident_driver=refused reason=rays_over_ceiling")
    bounds = profile["residency_bounds"]
    # The arms are the same row's two readings: a resident run needs the row's
    # own session bounds, and a one-shot run needs the row to declare none,
    # because a mode taken from the command line against a row that says
    # otherwise is the permission and the act coming apart.
    if arguments.mode == "resident":
        if bounds is None:
            raise SystemExit("geometry_resident_driver=refused reason=row_is_one_shot")
        if arguments.requests > bounds["session_requests"]:
            raise SystemExit("geometry_resident_driver=refused reason=requests_over_session")
    elif bounds is not None:
        raise SystemExit("geometry_resident_driver=refused reason=row_is_bounded_resident")

    runtime_sha256 = sha256_file(arguments.runtime)
    os.makedirs(arguments.state_dir, exist_ok=True)
    with open(arguments.record, "w", encoding="utf-8") as record, \
            open(arguments.stderr, "w", encoding="utf-8") as log:
        record_row(record, COLUMNS)
        if arguments.mode == "resident":
            outcome = run_resident(arguments, profile, bounds, runtime_sha256, record, log)
        else:
            outcome = run_one_shot(arguments, profile, runtime_sha256, record, log)
    print("geometry_resident_driver=accepted " + " ".join(
        "%s=%s" % (key, ("%.3f" % value) if isinstance(value, float) else value)
        for key, value in sorted(outcome.items())))
    print("runtime_sha256=%s" % runtime_sha256)


if __name__ == "__main__":
    try:
        main()
    except (DriverError, protocol.ProtocolError, geometry_service.ProfileRefused) as error:
        print("geometry_resident_driver=rejected reason=%s" % error, file=sys.stderr)
        raise SystemExit(1) from None
