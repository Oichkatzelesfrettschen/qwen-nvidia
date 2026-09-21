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

Destruction is compute, and so is whatever a failed request left running, so
every exit path after the worker is spawned ends and reaps it before the lease
protecting that work is released. A worker that reaches a bound of its own
announces the retirement it wants and waits; this takes the lease and answers.
The worker acquires no lease itself, so no parent holding one waits on a child
that wants one.

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
import shlex
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


class WorkerRetiring(Exception):
    """The worker reached a bound of its own where a request was going out.

    It is not a failure: the session ended between the supervisor's check and
    its request, nothing is in flight, and the retirement it announced is
    authorized the way one read between requests is.
    """


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

    def available(self, timeout=0.0):
        """Whether a complete line is in hand, without waiting for one to start.

        A worker announces its own retirement at the moment it reaches a bound,
        which is between requests rather than in answer to one, so the
        supervisor looks for that line where it would otherwise send the next
        request.
        """
        if b"\n" in self.buffer:
            return True
        ready, _, _ = select.select([self.descriptor], [], [], timeout)
        if not ready:
            return False
        chunk = os.read(self.descriptor, 65536)
        if not chunk:
            raise DriverError("the worker closed its output")
        self.buffer += chunk
        return b"\n" in self.buffer

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
        # The worker's own allocation figure as of its most recent line. The
        # ready line's figure is the session's startup allocation and stops
        # describing the worker the moment a request allocates a ray buffer,
        # so an idle reading taken after a request reads this rather than
        # ready's.
        self.allocated_bytes = 0
        self.notice = None

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
        try:
            line = self.reader.line(started + READY_TIMEOUT_SECONDS)
            event, message = protocol.parse_resident_line(line)
            if event != "ready":
                raise DriverError("the worker's first line is %s rather than ready" % event)
            self.ready = protocol.validate_resident_ready(message, self.bounds)
        except BaseException:
            # The caller holds the compute lease across start(), and a worker
            # that never reported ready may already hold a context and an
            # acceleration structure, so it is ended here rather than after
            # that lease is released.
            self.close()
            raise
        self.startup_ms = self.ready["startup_ms"]
        self.allocated_bytes = self.ready["device_allocated_bytes"]
        return self.ready

    def pending_notice(self):
        """The worker's retirement notice if it has printed one, else None.

        A session that reaches its request count, its wall seconds, its idle
        interval or its memory ceiling announces the retirement it wants and
        waits for authorization rather than destroying device state at that
        moment. The supervisor looks for that line between requests, because
        after it there are no more requests to send.
        """
        if self.notice is not None or self.process is None:
            return self.notice
        if not self.reader.available():
            return None
        event, message = protocol.parse_resident_line(self.reader.line(time.monotonic() + 1.0))
        if event != "retiring":
            raise DriverError("the worker printed %s where no request was in flight" % event)
        self.notice = protocol.validate_resident_retiring(message, self.served)
        return self.notice

    def query(self, request_id, rays):
        request = {"protocol": protocol.PROTOCOL_VERSION, "action": "query",
                   "request_id": request_id, "rays": rays}
        self.process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + self.profile["timeout_s"]
        event, message = protocol.parse_resident_line(self.reader.line(deadline))
        if event == "retiring":
            self.notice = protocol.validate_resident_retiring(message, self.served)
            raise WorkerRetiring(self.notice["reason"])
        if event == "refused":
            protocol.validate_resident_refused(message, request_id)
            raise DriverError("the worker refused the request: %s %s"
                              % (message["reason"], message["detail"]))
        if event != "result":
            raise DriverError("the worker answered %s rather than result" % event)
        protocol.validate_resident_result(message, self.bounds, request_id, rays)
        self.served += 1
        self.allocated_bytes = message["residency"]["device_allocated_bytes"]
        return message

    def retire(self):
        """Authorize retirement and read the claim that the device holds nothing.

        The caller holds the compute lease across this, because the shutdown
        line is what lets the worker free its allocations, tear down its
        acceleration structure and destroy its contexts. A worker that reached
        a bound of its own may have printed its notice while this was on its
        way, so one such line is read before the retirement it announced.
        """
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
            if event == "retiring":
                self.notice = protocol.validate_resident_retiring(message, self.served)
                event, message = protocol.parse_resident_line(self.reader.line(deadline))
            if event != "retired":
                raise DriverError("the worker answered %s rather than retired" % event)
            retired = protocol.validate_resident_retired(message, self.bounds, self.served)
            if retired["authorized"] is not True:
                raise DriverError("the worker destroyed its device state without the "
                                  "authorization this supervisor holds the lease to give")
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


# What reads the driver's own per-process residency. nvidia-smi is the
# instrument on this host; the token {pid} is substituted where a probe wants
# the process named rather than filtering a full listing itself. The command
# prints `pid, mebibytes` per compute client, and a pid absent from the
# listing holds nothing.
DEFAULT_RESIDENCY_PROBE = ("nvidia-smi --query-compute-apps=pid,used_memory"
                           " --format=csv,noheader,nounits")


class ResidencyUnread(DriverError):
    """The probe answered nothing, so no reading holds the ceiling."""


def device_residency_mib(probe, pid):
    """What the driver says a process holds on the device.

    The worker counts what it asked cudaMalloc for and cannot count the CUDA
    context the driver put beside it, so the residency a ceiling is held to is
    read here instead. It is read at a moment when this process holds no lease
    and no request is in flight, which is what makes the number residency
    rather than the footprint of a running query, and a sampler ticking beside
    the run cannot resolve that moment: the gap between two requests is shorter
    than any interval it could sample at.

    A probe that fails raises rather than returning: an allowance no reading
    tested is an allowance unenforced, and a run that continued past it would
    report a budget it never held anything against.
    """
    argv = [word.replace("{pid}", str(pid)) for word in probe]
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ResidencyUnread("the residency probe did not run: %s" % error) from None
    if completed.returncode != 0:
        raise ResidencyUnread("the residency probe exited %d" % completed.returncode)
    for line in completed.stdout.splitlines():
        fields = [field.strip() for field in line.split(",")]
        if len(fields) == 2 and fields[0] == str(pid):
            if not fields[1].isdigit():
                raise ResidencyUnread("the residency probe reported %r mebibytes" % fields[1])
            return int(fields[1])
    return 0


def record_row(handle, fields):
    handle.write("\t".join(str(field) for field in fields) + "\n")
    handle.flush()


# device_allocated_bytes is the worker's own accounting and device_resident_mib
# is the driver's reading of the same process; the second is filled only on the
# rows where this process held no lease and had no request in flight, because
# that is the only moment at which the number means residency.
COLUMNS = ("arm", "request", "client_ms", "lease_wait_ms", "wall_ms", "rays", "hits",
           "reference_agreement", "reference_disagreement", "results_fnv1a64",
           "device_allocated_bytes", "device_resident_mib") + tuple(
               sorted(protocol.STAGE_KEYS)) + ("note",)


def stage_columns(timings):
    """Every stage in one order, with the stages this arm did not pay left empty.

    A resident request pays six of the thirteen and the session pays the rest
    once, so an empty cell reads as a stage this request did not run rather
    than as a stage that took no time.
    """
    return [("%.3f" % timings[key]) if key in timings else "" for key in sorted(protocol.STAGE_KEYS)]


def row(arm, note="", timings=None, **fields):
    """One record line, with the columns this arm does not fill left empty.

    A resident request pays six of the thirteen stages and the session pays
    the rest once, so an empty cell reads as a stage this row did not run
    rather than as a stage that took no time.
    """
    values = dict.fromkeys(COLUMNS, "")
    values["arm"] = arm
    values["request"] = 0
    values["note"] = note
    for key, value in fields.items():
        if value is not None:
            values[key] = value
    for key, value in (timings or {}).items():
        values[key] = "%.3f" % value
    return [values[key] for key in COLUMNS]


def observe_idle_residency(worker, lease, bounds, probe, record, arm):
    """Read the worker's device residency at a moment nothing is in flight.

    The lease is checked free first, so the reading is taken under the state
    the claim is about: a process holding device memory while it owns no
    compute. The ceiling is held against this reading as well as against the
    worker's own, because neither sees what the other does, and the worker's
    own figure is its latest rather than the one its ready line carried: a
    request that allocated a ray buffer moved it.

    A probe that answers nothing ends the run. The reading is how the 512 MiB
    allowance is enforced at all, so a session continuing without one would be
    a session admitted against an allowance nothing tested.
    """
    require_lease_free(lease)
    try:
        observed = device_residency_mib(probe, worker.process.pid)
    except ResidencyUnread as error:
        record_row(record, row(arm, note="residency_unread",
                               device_allocated_bytes=worker.allocated_bytes))
        raise DriverError("%s, so the %d MiB allowance holds nothing"
                          % (error, bounds["residency_budget_mib"])) from None
    record_row(record, row(arm, device_allocated_bytes=worker.allocated_bytes,
                           device_resident_mib=observed))
    if observed > bounds["residency_budget_mib"]:
        raise DriverError("the worker holds %d MiB against a ceiling of %d MiB"
                          % (observed, bounds["residency_budget_mib"]))
    return observed


def terminate_under_lease(worker, lease, run_id, log):
    """End the worker holding the ownership that protects what it may be running.

    A request that failed may have left a launch in flight, and ending a
    worker destroys the device state it holds; both are compute. So the lease
    is taken, the process is ended and reaped, and only then is the lease
    released. A lease this process cannot take is the emergency path: the
    worker is ended regardless, because a process left running holds device
    memory nothing admitted, and the run records that it ended unowned rather
    than recording a clean stop.
    """
    if worker.process is None:
        return "already-gone"
    try:
        lease.acquire("%s-terminate" % run_id)
    except geometry_service.LeaseUnavailable as error:
        worker.close()
        print("geometry_resident_driver=emergency reason=terminated_without_the_lease detail=%s"
              % error, file=log, flush=True)
        return "unowned"
    try:
        worker.close()
    finally:
        lease.release()
    return "owned"


def run_resident(arguments, profile, bounds, runtime_sha256, record, log):
    lease = geometry_service.WorkloadLease(arguments.state_dir, arguments.lease_wait_s)
    worker = Worker(arguments.runtime, profile, bounds, log)
    session_started = time.monotonic()
    retired = None
    idle_before = idle_after = None
    try:
        # Building the session's device state is compute: it allocates, copies
        # and builds an acceleration structure. The lease is held for it and
        # released the moment the worker is ready, because what residency buys
        # is the state surviving, not the ownership. A start that fails ends
        # the worker before that release, inside start() itself.
        lease.acquire("%s-startup" % arguments.run_id)
        try:
            ready = worker.start()
        finally:
            lease.release()
        record_row(record, row("resident-startup", client_ms="%.3f" % worker.startup_ms,
                               wall_ms="%.3f" % worker.startup_ms,
                               device_allocated_bytes=ready["device_allocated_bytes"],
                               timings=ready["timings"]))
        idle_before = observe_idle_residency(worker, lease, bounds, arguments.residency_probe,
                                             record, "resident-idle-before")
        for index in range(1, arguments.requests + 1):
            if index > 1 and arguments.idle_between_requests_s > 0:
                # Silence is how a session reaches the idle interval and the
                # wall seconds its row declares. It is spent holding no lease,
                # which is the state those bounds are about.
                time.sleep(arguments.idle_between_requests_s)
            require_lease_free(lease)
            # A worker that reached a bound of its own has announced it and is
            # waiting for the lease under which it may destroy; there are no
            # more requests to send it.
            notice = worker.pending_notice()
            if notice is not None:
                record_row(record, row("resident-retiring", note=notice["reason"],
                                       device_allocated_bytes=worker.allocated_bytes))
                break
            request_id = "%s-%03d" % (arguments.run_id, index)
            client_started = time.monotonic()
            lease.acquire(request_id)
            lease_acquired = time.monotonic()
            try:
                message = worker.query(request_id, arguments.rays)
            except WorkerRetiring:
                # The bound arrived between the check above and the request.
                # Nothing is in flight and nothing was served, so the lease is
                # released and the retirement authorized below the way one
                # read between requests is.
                record_row(record, row("resident-retiring", request=index,
                                       note=worker.notice["reason"],
                                       device_allocated_bytes=worker.allocated_bytes))
                break
            except BaseException:
                # The request may have left a launch in flight, and this owns
                # it, so the worker is ended and reaped before the ownership
                # protecting that work is given up. The row goes down here
                # rather than after the release, so the record carries the
                # order the termination and the release actually happened in.
                worker.close()
                record_row(record, row("resident-terminated", note="owned-request",
                                       request=index,
                                       device_allocated_bytes=worker.allocated_bytes))
                raise
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
            record_row(record, row("resident", request=index, client_ms="%.3f" % client_ms,
                                   lease_wait_ms="%.3f" % lease_wait_ms,
                                   wall_ms="%.3f" % result["wall_ms"], rays=result["rays"],
                                   hits=result["hits"],
                                   reference_agreement=result["reference_agreement"],
                                   reference_disagreement=result["reference_disagreement"],
                                   results_fnv1a64=result["results_fnv1a64"],
                                   device_allocated_bytes=message["residency"]["device_allocated_bytes"],
                                   timings=result["timings"]))
        idle_after = observe_idle_residency(worker, lease, bounds, arguments.residency_probe,
                                            record, "resident-idle-after")
        # Destruction is compute too, so the shutdown line that authorizes it
        # goes out under the lease and the check that nothing is held comes
        # after the worker has gone.
        lease.acquire("%s-retire" % arguments.run_id)
        try:
            retired = worker.retire()
        finally:
            lease.release()
    except BaseException:
        ownership = terminate_under_lease(worker, lease, arguments.run_id, log)
        if ownership != "already-gone":
            record_row(record, row("resident-terminated", note=ownership,
                                   device_allocated_bytes=worker.allocated_bytes))
        raise
    require_lease_free(lease)
    record_row(record, row("resident-retire", note=retired["reason"],
                           client_ms="%.3f" % retired["timings"]["teardown_ms"],
                           wall_ms="%.3f" % retired["timings"]["teardown_ms"],
                           device_allocated_bytes=retired["device_allocated_bytes"],
                           timings=retired["timings"]))
    return {"mode": "resident", "requests": worker.served, "startup_ms": worker.startup_ms,
            "retirement": retired["reason"], "retirement_authorized": retired["authorized"],
            "teardown_ms": retired["timings"]["teardown_ms"],
            "session_s": time.monotonic() - session_started,
            "device_allocated_bytes": ready["device_allocated_bytes"],
            "idle_resident_mib_before": idle_before, "idle_resident_mib_after": idle_after}


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
        record_row(record, row("one-shot", request=index, client_ms="%.3f" % client_ms,
                               lease_wait_ms="%.3f" % lease_wait_ms,
                               wall_ms="%.3f" % result["wall_ms"], rays=result["rays"],
                               hits=result["hits"],
                               reference_agreement=result["reference_agreement"],
                               reference_disagreement=result["reference_disagreement"],
                               results_fnv1a64=result["results_fnv1a64"],
                               device_allocated_bytes=0, timings=result["timings"]))
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
    parser.add_argument("--idle-between-requests-s", type=float, default=0.0,
                        help="silence between requests, which is how a session's idle "
                             "interval and its wall bound are reached")
    parser.add_argument("--residency-probe", default=DEFAULT_RESIDENCY_PROBE,
                        help="command printing `pid, mebibytes` per compute client; {pid} "
                             "is substituted with the worker's process id")
    arguments = parser.parse_args()
    arguments.residency_probe = shlex.split(arguments.residency_probe)
    if not arguments.residency_probe:
        raise SystemExit("geometry_resident_driver=refused reason=residency_probe_empty")

    # The lease taken per request has to be the host's, named by the owner that
    # launched this: a lock file a run invented for itself serializes against
    # nothing, and a session that held such a file would look serialized while
    # running beside every other workload on the card.
    if not os.environ.get("QWEN_GPU_COMPUTE_LEASE"):
        raise SystemExit("geometry_resident_driver=refused reason=compute_lease_unnamed")
    # A worker that announced its retirement destroys unauthorized once its
    # authorization interval expires, so a supervisor willing to wait that
    # long for the lease could arrive after the device state it meant to own
    # the destruction of is already gone.
    if arguments.lease_wait_s >= protocol.RETIREMENT_AUTHORIZATION_S:
        raise SystemExit("geometry_resident_driver=refused reason=lease_wait_outlasts_authorization")
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
        for key, value in sorted(outcome.items()) if value is not None))
    print("runtime_sha256=%s" % runtime_sha256)


if __name__ == "__main__":
    try:
        main()
    except (DriverError, protocol.ProtocolError, geometry_service.ProfileRefused) as error:
        print("geometry_resident_driver=rejected reason=%s" % error, file=sys.stderr)
        raise SystemExit(1) from None
