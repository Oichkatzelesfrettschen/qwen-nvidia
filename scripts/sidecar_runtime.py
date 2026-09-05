"""What the physics and geometry services share ahead of their runtimes.

Two checks and one collector. `require_lease_identity` proves at launch that
the compute lease the service was handed is the file the session named:
`QWEN_GPU_COMPUTE_LEASE` is required, and where the session also passes
`QWEN_GPU_COMPUTE_LEASE_IDENTITY` as `device:inode` the path is stat'ed and
compared, so a service configured against a lease file the server does
not hold refuses to start rather than serializing against nothing.
`require_grant` revalidates the single-use grant a request carries against
the signing key the MCP child used, ahead of the lease acquire, so a
request that reached the socket without passing through the child meets
the same refusal there. `collect_output` reads a runtime's stdout and
stderr concurrently under separate byte limits: `communicate()` buffers
without bound, so a runtime that floods either stream would grow the
service's memory until the kernel ended it; here an overflow ends the
child, reaps it, and reports which stream overflowed.
"""

import os
import subprocess
import threading

_sidecar_grant = None


def _grant_module():
    global _sidecar_grant
    if _sidecar_grant is None:
        import importlib
        import sys
        here = os.path.dirname(os.path.abspath(__file__))
        web_mcp = os.path.join(here, "web-mcp")
        if web_mcp not in sys.path:
            sys.path.insert(0, web_mcp)
        _sidecar_grant = importlib.import_module("sidecar_grant")
    return _sidecar_grant


class LeaseIdentityRefused(Exception):
    """The lease the service was handed is not the one the session named."""


class GrantRefused(Exception):
    """The request's grant fails verification or names another run."""

    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


def require_lease_identity(environment=None):
    """Return the lease path, or raise LeaseIdentityRefused.

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
            status = os.stat(path)
        except OSError as error:
            raise LeaseIdentityRefused("the lease file cannot be stat'ed: %s" % error) from None
        observed = "%d:%d" % (status.st_dev, status.st_ino)
        if observed != expected:
            raise LeaseIdentityRefused(
                "the lease file identity %s differs from the session's %s" % (observed, expected))
    return path


def lease_identity(path):
    status = os.stat(path)
    return "%d:%d" % (status.st_dev, status.st_ino)


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


def _drain(stream, limit, sink, overflow, name):
    total = 0
    try:
        while True:
            chunk = stream.read1(65536) if hasattr(stream, "read1") else stream.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                overflow.append(name)
                break
            sink.append(chunk)
    except OSError:
        pass


def terminate_process_group(child):
    """End the child's process group and reap it, with a bounded escalation."""
    import contextlib
    import signal
    if child.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGKILL)
        child.wait()


def collect_output(child, timeout_seconds, stdout_limit, stderr_limit):
    """Return (stdout, stderr) of a child spawned with both pipes.

    Both streams drain in their own threads with their own limits. The first
    stream to pass its limit ends the child through its process group, both
    threads finish, and OutputOverflow names the stream. A child that runs
    past the deadline is ended the same way and subprocess.TimeoutExpired is
    raised, so the caller's timeout path is unchanged.
    """
    stdout_chunks, stderr_chunks, overflow = [], [], []
    readers = [
        threading.Thread(target=_drain, args=(child.stdout, stdout_limit, stdout_chunks, overflow, "stdout")),
        threading.Thread(target=_drain, args=(child.stderr, stderr_limit, stderr_chunks, overflow, "stderr")),
    ]
    for reader in readers:
        reader.daemon = True
        reader.start()
    deadline_hit = False
    try:
        child.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        deadline_hit = True
    # an overflowed reader stopped consuming, so the child may now block on
    # a full pipe: it is ended before the readers are joined
    if overflow or deadline_hit:
        terminate_process_group(child)
    for reader in readers:
        reader.join(timeout=5)
    for stream in (child.stdout, child.stderr):
        try:
            stream.close()
        except OSError:
            pass
    if overflow:
        raise OutputOverflow(overflow[0])
    if deadline_hit:
        raise subprocess.TimeoutExpired(child.args, timeout_seconds)
    return b"".join(stdout_chunks), b"".join(stderr_chunks)
