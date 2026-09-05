#!/usr/bin/env python3
"""Serve one bounded OptiX ray query at a time behind the compute lease.

The service listens on a Unix socket under its state directory, holds no CUDA
context while idle, and for each accepted request reads the profile row from
scripts/geometry-profiles.tsv, takes the GPU compute lease, spawns the pinned
runtime through scripts/qwen-exec-idle-priority.sh with the profile's own
arguments, reads back one JSON line, requires the GPU proof block to hold and
the host reference to agree on every ray, validates the summary against
scripts/geometry_protocol.py, and releases the lease. A caller supplies a
profile_id and a ray count and nothing else the query reads: no geometry, no
native code, no path, no OptiX or CUDA flag.

An OptiX launch that never reached the device answers nothing rather than
falling back, so the proof is read rather than assumed: the runtime reports
the device context, the acceleration structure build with its byte count,
the pipeline, and the completed launch, and names the device. The runtime
also intersects every ray on the host against the same triangles, so a
device answer the reference contradicts reads failed with reason
reference_disagreement rather than completed.

The lease is the same file the image and physics services and llama-server
hold, named by QWEN_GPU_COMPUTE_LEASE and defaulting to vulkan-workload.lock
under the state directory, second in the fixed order of four under the
owner lock, and every refusal above it runs before flock, so a request the
service declines leaves the lease alone. The runtime is a grandchild that
inherits no descriptor of the lease: flock binds to the open file
description and a descriptor handed down would hold the lease for every
process that inherited it.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time

SERVICE_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SERVICE_DIRECTORY)
import geometry_protocol as protocol  # noqa: E402

PRIORITY_WRAPPER = os.path.join(SERVICE_DIRECTORY, "qwen-exec-idle-priority.sh")
LEASE_FILE_NAME = "vulkan-workload.lock"
LEASE_STATUS_FILE_NAME = "vulkan-workload.status"
LEASE_WAIT_POLL_SECONDS = 0.05
PROFILE_COLUMNS = (
    "profile_id", "scene", "query_set", "max_rays", "timeout_s", "execution_policy", "device_index",
)
SCENES = ("cube-and-plane",)
QUERY_SETS = ("orbit",)
MAX_RUNTIME_OUTPUT_BYTES = 1 << 20


class ServiceError(Exception):
    reason = "service_error"


class InvalidArgument(ServiceError):
    reason = "invalid_argument"


class ProfileRefused(ServiceError):
    reason = "profile_refused"


class ServiceBusy(ServiceError):
    reason = "busy"


class LeaseUnavailable(ServiceError):
    reason = "lease_unavailable"


class RuntimeFailed(ServiceError):
    reason = "runtime_failed"


class RuntimeTimeout(ServiceError):
    reason = "runtime_timeout"


class GpuFallback(ServiceError):
    reason = "gpu_fallback"


class ReferenceDisagreement(ServiceError):
    reason = "reference_disagreement"


def utc_timestamp(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_profiles(path):
    """Read the ledger whole and refuse it on any malformed row."""
    header = None
    profiles = {}
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            stripped = line.rstrip("\n")
            if not stripped:
                continue
            if stripped.startswith("#"):
                candidate = stripped.lstrip("#").strip()
                if "\t" in candidate and candidate.split("\t")[0] == "profile_id":
                    header = candidate.split("\t")
                continue
            if header is None:
                raise ProfileRefused("geometry-profiles.tsv has no header ahead of line %d" % number)
            fields = stripped.split("\t")
            if tuple(header) != PROFILE_COLUMNS or len(fields) != len(PROFILE_COLUMNS):
                raise ProfileRefused("geometry-profiles.tsv line %d does not carry the %d columns"
                                     % (number, len(PROFILE_COLUMNS)))
            row = dict(zip(header, fields))
            try:
                protocol._identifier(row["profile_id"], "profile_id")
                if row["scene"] not in SCENES:
                    raise ValueError("scene %s is not one the runtime carries" % row["scene"])
                if row["query_set"] not in QUERY_SETS:
                    raise ValueError("query_set %s is not one the runtime carries" % row["query_set"])
                row["max_rays"] = int(row["max_rays"])
                if not protocol.MIN_RAYS <= row["max_rays"] <= protocol.MAX_RAYS:
                    raise ValueError("max_rays is outside the protocol range")
                row["timeout_s"] = int(row["timeout_s"])
                if not 1 <= row["timeout_s"] <= 3600:
                    raise ValueError("timeout_s is outside [1, 3600]")
                if row["execution_policy"] not in ("refused", "validator-gated"):
                    raise ValueError("execution_policy is not refused or validator-gated")
                row["device_index"] = int(row["device_index"])
                if not 0 <= row["device_index"] <= 15:
                    raise ValueError("device_index is outside [0, 15]")
            except (ValueError, protocol.ProtocolError) as error:
                raise ProfileRefused("geometry-profiles.tsv line %d: %s" % (number, error)) from None
            if row["profile_id"] in profiles:
                raise ProfileRefused("geometry-profiles.tsv repeats %s" % row["profile_id"])
            profiles[row["profile_id"]] = row
    if not profiles:
        raise ProfileRefused("geometry-profiles.tsv holds no row")
    return profiles


class WorkloadLease:
    """The compute lease: flock on a descriptor, with an observed status line."""

    def __init__(self, state_directory, wait_seconds):
        self.lock_path = os.environ.get("QWEN_GPU_COMPUTE_LEASE") or os.path.join(
            state_directory, LEASE_FILE_NAME)
        self.status_path = os.path.join(state_directory, LEASE_STATUS_FILE_NAME)
        self.descriptor = None
        self.wait_seconds = wait_seconds

    def acquire(self, job_id):
        if self.descriptor is not None:
            raise LeaseUnavailable("this service already holds the workload lease")
        descriptor = os.open(self.lock_path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o644)
        deadline = time.monotonic() + self.wait_seconds
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    os.close(descriptor)
                    raise LeaseUnavailable("another workload holds the lease; one runs at a time") from None
                time.sleep(LEASE_WAIT_POLL_SECONDS)
        self.descriptor = descriptor
        self.write_status("state=held holder=geometry-service pid=%d job=%s since=%s"
                          % (os.getpid(), job_id, utc_timestamp(time.time())))

    def write_status(self, line):
        with contextlib.suppress(OSError):
            with open(self.status_path, "w", encoding="ascii") as handle:
                handle.write(line + "\n")

    def release(self):
        if self.descriptor is None:
            return
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
        finally:
            os.close(self.descriptor)
            self.descriptor = None
        self.write_status("state=released pid=%d at=%s" % (os.getpid(), utc_timestamp(time.time())))


class GeometryService:
    def __init__(self, settings):
        self.settings = settings
        self.profiles = load_profiles(settings["profiles"])
        self.runtime_sha256 = sha256_file(settings["runtime"])
        self.lease = WorkloadLease(settings["state_dir"], settings["lease_wait_s"])
        self.busy = threading.Lock()
        self.child = None
        self.audit_path = os.path.join(settings["state_dir"], "geometry-audit.log")

    def audit(self, **fields):
        line = " ".join("%s=%s" % (key, value) for key, value in fields.items())
        with contextlib.suppress(OSError):
            with open(self.audit_path, "a", encoding="utf-8") as handle:
                handle.write("%s %s\n" % (utc_timestamp(time.time()), line))

    def handle(self, raw):
        try:
            message = protocol.parse_line(raw)
            action, request_id, profile_id, rays = protocol.validate_request(message)
        except protocol.ProtocolError as error:
            return protocol.encode_reply("invalid", "refused", error=str(error)[:protocol.MAX_ERROR_CHARACTERS],
                                         reason="invalid_argument")
        if action == "status":
            return protocol.encode_reply(request_id, "accepted", error=None,
                                         reason="idle" if not self.busy.locked() else "busy")
        started = time.time()
        try:
            profile = self.profiles.get(profile_id)
            if profile is None:
                raise ProfileRefused("profile %s is not in the ledger" % profile_id)
            if profile["execution_policy"] != "validator-gated":
                raise ProfileRefused("profile %s reads %s" % (profile_id, profile["execution_policy"]))
            if rays > profile["max_rays"]:
                raise InvalidArgument("rays %d exceeds the profile ceiling %d" % (rays, profile["max_rays"]))
            if not self.busy.acquire(blocking=False):
                raise ServiceBusy("a query is running")
            try:
                result = self.run(request_id, profile, rays)
            finally:
                self.busy.release()
        except ServiceError as error:
            self.audit(request=request_id, profile=profile_id, status="refused" if not isinstance(
                error, (RuntimeFailed, RuntimeTimeout, GpuFallback, ReferenceDisagreement)) else "failed",
                reason=error.reason,
                elapsed_ms="%.1f" % ((time.time() - started) * 1000))
            status = "failed" if isinstance(
                error, (RuntimeFailed, RuntimeTimeout, GpuFallback, ReferenceDisagreement)) else "refused"
            return protocol.encode_reply(request_id, status, profile_id=profile_id,
                                         error=str(error)[:protocol.MAX_ERROR_CHARACTERS], reason=error.reason)
        self.audit(request=request_id, profile=profile_id, status="completed", rays=rays,
                   hits=result["hits"], launch_ms="%.3f" % result["launch_ms"],
                   device=result["gpu"]["device_name"].replace(" ", "_"),
                   elapsed_ms="%.1f" % ((time.time() - started) * 1000))
        return protocol.encode_reply(request_id, "completed", profile_id=profile_id, result=result)

    def run(self, request_id, profile, rays):
        self.lease.acquire(request_id)
        try:
            return self.execute(request_id, profile, rays)
        finally:
            self.lease.release()

    def execute(self, request_id, profile, rays):
        argv = [
            PRIORITY_WRAPPER, self.settings["runtime"], profile["scene"], profile["query_set"],
            str(rays), str(profile["device_index"]),
        ]
        scene_sha256 = hashlib.sha256(json.dumps(
            {"scene": profile["scene"], "query_set": profile["query_set"], "rays": rays},
            sort_keys=True).encode()).hexdigest()
        environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": os.environ.get("HOME", "/"),
            "CUDA_VISIBLE_DEVICES": str(profile["device_index"]),
            "CUDA_MODULE_LOADING": "LAZY",
        }
        # The runtime is spawned with a closed descriptor set: the lease and
        # the listener stay with this process. close_fds is the mechanism.
        try:
            self.child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, env=environment, close_fds=True,
                                          start_new_session=True)
        except OSError as error:
            raise RuntimeFailed("runtime did not start: %s" % error) from None
        try:
            stdout, stderr = self.child.communicate(timeout=profile["timeout_s"])
        except subprocess.TimeoutExpired:
            self.terminate_child()
            raise RuntimeTimeout("runtime exceeded %d s" % profile["timeout_s"]) from None
        finally:
            returncode = self.child.returncode
            self.child = None
        stderr_text = stderr.decode("utf-8", "replace")[-2000:]
        # The runtime's diagnostics are its own account of a refusal, so the
        # last job's stderr is retained whole beside the audit log and a
        # failure names the OptiX and CUDA error lines ahead of the rejected line.
        with contextlib.suppress(OSError):
            with open(os.path.join(self.settings["state_dir"], "runtime-stderr.txt"), "w",
                      encoding="utf-8") as handle:
                handle.write("request=%s exit=%s\n%s" % (request_id, returncode, stderr_text))
        if len(stdout) > MAX_RUNTIME_OUTPUT_BYTES:
            raise RuntimeFailed("runtime output exceeds %d bytes" % MAX_RUNTIME_OUTPUT_BYTES)
        if returncode != 0:
            named = [line for line in stderr_text.splitlines()
                     if line.startswith(("optix_runtime=rejected", "optix: ", "optix[", "cuda: "))]
            raise RuntimeFailed("runtime exited %d: %s" % (returncode, " | ".join(named[-4:]) or stderr_text[-300:]))
        lines = [line for line in stdout.decode("utf-8", "replace").splitlines() if line.strip()]
        if len(lines) != 1:
            raise RuntimeFailed("runtime printed %d lines rather than one" % len(lines))
        try:
            state = json.loads(lines[0])
        except ValueError:
            raise RuntimeFailed("runtime printed no JSON object") from None
        if not isinstance(state, dict):
            raise RuntimeFailed("runtime printed no JSON object")
        state["runtime_sha256"] = self.runtime_sha256
        state["scene_sha256"] = scene_sha256
        try:
            protocol.validate_result(state)
        except protocol.ProtocolError as error:
            raise RuntimeFailed("runtime state failed the schema: %s" % error) from None
        if state["rays"] != rays:
            raise RuntimeFailed("runtime traced %d rays where %d were asked" % (state["rays"], rays))
        if not protocol.gpu_proof_holds(state["gpu"]):
            raise GpuFallback("the runtime answered without the GPU proof: %s" % json.dumps(state["gpu"]))
        if state["reference_disagreement"] != 0:
            raise ReferenceDisagreement("the host reference contradicts the device on %d of %d rays"
                                        % (state["reference_disagreement"], rays))
        return state

    def terminate_child(self):
        child = self.child
        if child is None or child.poll() is not None:
            return
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            child.wait()


def serve(service, socket_path, ready_stream):
    with contextlib.suppress(FileNotFoundError):
        os.unlink(socket_path)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    os.chmod(socket_path, 0o600)
    listener.listen(4)
    stop = threading.Event()

    def on_signal(_signum, _frame):
        stop.set()
        service.terminate_child()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    ready_stream.write("listening socket=%s pid=%d runtime_sha256=%s profiles=%d\n" % (
        socket_path, os.getpid(), service.runtime_sha256, len(service.profiles)))
    ready_stream.flush()
    selector = selectors.DefaultSelector()
    selector.register(listener, selectors.EVENT_READ)
    while not stop.is_set():
        if not selector.select(timeout=0.2):
            continue
        try:
            connection, _address = listener.accept()
        except OSError:
            continue
        with connection:
            connection.settimeout(30)
            buffer = b""
            try:
                while b"\n" not in buffer and len(buffer) <= protocol.MAX_LINE_BYTES:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    buffer += chunk
            except OSError:
                continue
            line = buffer.split(b"\n", 1)[0]
            reply = service.handle(line)
            with contextlib.suppress(OSError):
                connection.sendall(reply.encode("utf-8"))
    listener.close()
    with contextlib.suppress(FileNotFoundError):
        os.unlink(socket_path)
    service.lease.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--profiles", required=True, help="scripts/geometry-profiles.tsv or a copy")
    parser.add_argument("--runtime", required=True, help="the compiled optix-ray-runtime")
    parser.add_argument("--socket", default=None, help="default STATE_DIR/geometry-service.sock")
    parser.add_argument("--lease-wait-s", type=float, default=60.0)
    args = parser.parse_args()
    if not os.path.isdir(args.state_dir):
        sys.exit("state directory is absent: %s" % args.state_dir)
    if not os.access(args.runtime, os.X_OK):
        sys.exit("runtime is not executable: %s" % args.runtime)
    if not os.access(PRIORITY_WRAPPER, os.X_OK):
        sys.exit("priority wrapper is absent: %s" % PRIORITY_WRAPPER)
    settings = {
        "state_dir": args.state_dir,
        "profiles": args.profiles,
        "runtime": os.path.abspath(args.runtime),
        "lease_wait_s": args.lease_wait_s,
    }
    try:
        service = GeometryService(settings)
    except ServiceError as error:
        sys.exit("geometry_service=refused reason=%s %s" % (error.reason, error))
    serve(service, args.socket or os.path.join(args.state_dir, "geometry-service.sock"), sys.stdout)


if __name__ == "__main__":
    main()
