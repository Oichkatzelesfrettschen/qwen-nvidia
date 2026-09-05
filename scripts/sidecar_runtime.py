"""What the physics and geometry services share ahead of their runtimes.

Three checks and one collector. `require_lease_identity` proves at launch
that the compute lease the service was handed is the file the session
named: `QWEN_GPU_COMPUTE_LEASE` is required, and where the session also
passes `QWEN_GPU_COMPUTE_LEASE_IDENTITY` as `device:inode` the path is
stat'ed and compared, so a service configured against a lease file the
server does not hold refuses to start. `require_descriptor_identity` repeats
that comparison on the descriptor a service opened for its acquire, so a
file replaced between launch and acquire is refused at the acquire rather
than locked. `require_grant` revalidates the single-use grant a request
carries against the signing key the MCP child used, and `GrantLedger`
spends its nonce at the service under a primary key, so a request that
reached the socket without passing through the child, or a token replayed
against the socket, meets the same refusal there. `collect_output` reads a
runtime's stdout and stderr under separate byte limits from one select
loop: `communicate()` buffers without bound, so a runtime that floods either
stream would grow the service's memory until the kernel ended it; here an
overflow or the deadline ends the process group, the loop drains what the
group still writes for a bounded grace, and the read ends are closed
whether or not a descendant holding the write end has left.
"""

import contextlib
import os
import select
import signal
import sqlite3
import subprocess
import sys
import time

_sidecar_grant = None


def _grant_module():
    global _sidecar_grant
    if _sidecar_grant is None:
        import importlib
        here = os.path.dirname(os.path.abspath(__file__))
        web_mcp = os.path.join(here, "web-mcp")
        if web_mcp not in sys.path:
            sys.path.insert(0, web_mcp)
        _sidecar_grant = importlib.import_module("sidecar_grant")
    return _sidecar_grant


class LeaseIdentityRefused(Exception):
    """The lease the service was handed is not the one the session named."""


class GrantRefused(Exception):
    """The request's grant fails verification, names another run, or is spent."""

    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


def lease_identity(path):
    status = os.stat(path)
    return "%d:%d" % (status.st_dev, status.st_ino)


def require_lease_identity(environment=None):
    """Return (path, expected_identity), or raise LeaseIdentityRefused.

    The identity is `st_dev:st_ino` of the lease file as the session opened
    it; a service launched by hand without the identity variable still
    requires the path variable, since a default file under its own state
    directory would serialize against no one.
    """
    environment = os.environ if environment is None else environment
    path = environment.get("QWEN_GPU_COMPUTE_LEASE", "")
    if not path:
        raise LeaseIdentityRefused("QWEN_GPU_COMPUTE_LEASE names no lease file")
    expected = environment.get("QWEN_GPU_COMPUTE_LEASE_IDENTITY", "")
    if expected:
        try:
            observed = lease_identity(path)
        except OSError as error:
            raise LeaseIdentityRefused("the lease file cannot be stat'ed: %s" % error) from None
        if observed != expected:
            raise LeaseIdentityRefused(
                "the lease file identity %s differs from the session's %s" % (observed, expected))
    return path, expected


def require_descriptor_identity(descriptor, expected):
    """Raise LeaseIdentityRefused where an open descriptor is not the expected file."""
    if not expected:
        return
    status = os.fstat(descriptor)
    observed = "%d:%d" % (status.st_dev, status.st_ino)
    if observed != expected:
        raise LeaseIdentityRefused(
            "the lease descriptor identity %s differs from the session's %s" % (observed, expected))


class GrantLedger:
    """Single use at the service: one row per grant id, spent under a primary key."""

    def __init__(self, state_directory):
        self.path = os.path.join(state_directory, "sidecar-grants.sqlite")
        self.connection = sqlite3.connect(self.path, timeout=5)
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS grants (grant_id TEXT PRIMARY KEY, expiry INTEGER NOT NULL, spent_at INTEGER NOT NULL)")
        self.connection.commit()
        with contextlib.suppress(OSError):
            os.chmod(self.path, 0o600)

    def consume(self, grant_id, expiry, now):
        """Spend one grant, or raise GrantRefused where it was spent before."""
        self.connection.execute("DELETE FROM grants WHERE expiry < ?", (int(now) - 86400,))
        try:
            self.connection.execute("INSERT INTO grants (grant_id, expiry, spent_at) VALUES (?, ?, ?)",
                                    (grant_id, int(expiry), int(now)))
            self.connection.commit()
        except sqlite3.IntegrityError:
            self.connection.rollback()
            raise GrantRefused("grant_replayed", "the grant was spent at this service before") from None

    def close(self):
        self.connection.close()


def require_grant(token_key_file, authorization, service, language_profile, sidecar_profile,
                  runtime_sha256, scene, count, now):
    """Verify and enforce one sidecar grant, or raise GrantRefused with a reason."""
    grant = _grant_module()
    server = grant.server
    if not token_key_file:
        raise GrantRefused("grant_unconfigured", "the service holds no signing key to verify a grant")
    if not authorization:
        raise GrantRefused("grant_absent", "the request carries no authorization")
    try:
        signing_key = server.read_secret_file(token_key_file, "token signing")
        claim = grant.verify_sidecar_grant(signing_key, authorization, now)
        grant.enforce_sidecar_authorization(claim, service, language_profile, sidecar_profile,
                                            runtime_sha256, scene, count)
    except server.ExpiredResult as error:
        raise GrantRefused("grant_expired", str(error)) from None
    except server.ToolError as error:
        raise GrantRefused("grant_refused", str(error)) from None
    return claim


class OutputOverflow(Exception):
    def __init__(self, stream):
        super().__init__("runtime %s exceeds its byte limit" % stream)
        self.stream = stream


class RuntimeDeadline(Exception):
    """The runtime ran past its deadline; carries the shutdown timeline."""

    def __init__(self, timeline):
        super().__init__("runtime exceeded its deadline")
        self.timeline = timeline


def _signal_group(child, number):
    with contextlib.suppress(ProcessLookupError):
        os.killpg(child.pid, number)


def terminate_process_group(child, timeline=None, started=None):
    """End the child's process group and reap it, with a bounded escalation.

    The timeline, where given, records the offsets of SIGTERM, SIGKILL, and
    the leader's exit from `started`, so a service can state where the time
    between a deadline and its reply went.
    """
    started = time.monotonic() if started is None else started
    if child.poll() is not None:
        return
    _signal_group(child, signal.SIGTERM)
    if timeline is not None:
        timeline["sigterm_s"] = round(time.monotonic() - started, 3)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _signal_group(child, signal.SIGKILL)
        if timeline is not None:
            timeline["sigkill_s"] = round(time.monotonic() - started, 3)
        child.wait()
    if timeline is not None:
        timeline["exit_s"] = round(time.monotonic() - started, 3)


def collect_output(child, timeout_seconds, stdout_limit, stderr_limit, grace_seconds=2.0):
    """Return (stdout, stderr) of a child spawned with both pipes.

    One select loop reads both pipes under their own limits until both
    reach end of file. The deadline and an overflow each end the process
    group; the loop then drains for `grace_seconds` and closes its read ends
    whether or not a descendant still holds a write end, so a runtime that
    forked a helper cannot hold the service on its pipe. Raises
    OutputOverflow naming the stream, or RuntimeDeadline carrying the
    shutdown timeline; a child that exits normally is reaped here.
    """
    started = time.monotonic()
    deadline = started + timeout_seconds
    chunks = {"stdout": [], "stderr": []}
    totals = {"stdout": 0, "stderr": 0}
    limits = {"stdout": stdout_limit, "stderr": stderr_limit}
    streams = {child.stdout.fileno(): "stdout", child.stderr.fileno(): "stderr"}
    open_fds = set(streams)
    overflow = None
    timeline = {}
    ended = False
    deadline_hit = False
    drain_until = None
    while open_fds:
        now = time.monotonic()
        if not ended and overflow is None and now >= deadline:
            ended = True
            deadline_hit = True
            terminate_process_group(child, timeline, started)
            drain_until = time.monotonic() + grace_seconds
        wait = 0.2 if drain_until is None else max(0.0, min(0.2, drain_until - now))
        if drain_until is not None and now >= drain_until:
            break
        readable, _w, _x = select.select(list(open_fds), [], [], wait)
        for descriptor in readable:
            name = streams[descriptor]
            try:
                data = os.read(descriptor, 65536)
            except OSError:
                data = b""
            if not data:
                open_fds.discard(descriptor)
                continue
            totals[name] += len(data)
            if totals[name] > limits[name]:
                if overflow is None:
                    overflow = name
                    ended = True
                    terminate_process_group(child, timeline, started)
                    drain_until = time.monotonic() + grace_seconds
                continue
            chunks[name].append(data)
        if not open_fds:
            break
        if not ended and child.poll() is not None and not readable:
            # the leader has left; whatever still holds a write end gets the
            # grace and no more
            ended = True
            drain_until = time.monotonic() + grace_seconds
    for stream in (child.stdout, child.stderr):
        with contextlib.suppress(OSError):
            stream.close()
    # Both pipes at end of file means the leader is leaving or has left; it
    # is reaped inside the grace, and only a leader that still runs past it
    # is ended, which is the descendant-holds-the-pipe case rather than a
    # deadline.
    if child.poll() is None:
        try:
            child.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            terminate_process_group(child, timeline, started)
    if overflow is not None:
        raise OutputOverflow(overflow)
    if deadline_hit:
        raise RuntimeDeadline(timeline)
    return b"".join(chunks["stdout"]), b"".join(chunks["stderr"])
