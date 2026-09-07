"""The admission barrier a service consults before it admits GPU work.

`scripts/qwen-admission-barrier.sh` is the same mechanism for shell callers and
this module is what the Python services read, so one barrier serves every
participant. The barrier is deliberately not the compute lease: `flock(2)`
associates a lock with the open file description, so an independent open is a
separate participant, and an orchestrator holding the lease while it waits for
a child whose teardown acquires that same lease would deadlock. The
orchestrator holds the barrier and prevents new work; the retiring child takes
the lease for its own teardown.

Two files carry the two questions, because one lock cannot answer both without
starving. `admission.barrier` holds the state word under brief shared and
exclusive locks, so a flip never waits on a running job. `admission.inflight`
holds one shared lock per admitted job for that job's duration, and the
orchestrator's exclusive acquisition of it is the drain itself.

Linux grants a pending exclusive request no priority over later shared ones, so
the state word rather than the lock is what stops arrivals; the flip runs first
and the exclusive wait that follows sees a set that can only shrink. An
admitting participant reads the state again after it holds its share, which
closes the window between reading `running` and being counted.

A session that armed no barrier reads `running`, so an absent barrier admits
work exactly as before this mechanism existed.
"""

import errno
import fcntl
import io
import os

STATE_RUNNING = "running"
STATE_QUIESCING = "quiescing"
STATE_FILE = "admission.barrier"
INFLIGHT_FILE = "admission.inflight"
SESSION_FILE = "admission.identity"


class AdmissionRefused(Exception):
    """The barrier declined to admit new work."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def barrier_directory(environment=None):
    environment = os.environ if environment is None else environment
    named = environment.get("QWEN_GPU_ADMISSION_BARRIER")
    if named:
        return named
    return environment.get("QWEN_WEBUI_STATE_DIRECTORY") or os.path.join(
        environment.get("HOME", ""), "qwen-webui-state")


def state_path(environment=None):
    return os.path.join(barrier_directory(environment), STATE_FILE)


def inflight_path(environment=None):
    return os.path.join(barrier_directory(environment), INFLIGHT_FILE)


def session_path(environment=None):
    return os.path.join(barrier_directory(environment), SESSION_FILE)


def session_identity(environment=None):
    """The identity the barrier was armed with, or `unrecorded` where none was.

    An unrecorded barrier admits, which keeps the mechanism optional for a
    session that armed none.
    """
    try:
        with io.open(session_path(environment), encoding="utf-8") as handle:
            return handle.readline().strip() or "unrecorded"
    except OSError as error:
        if error.errno in (errno.ENOENT, errno.ENOTDIR):
            return "unrecorded"
        raise


def verify_session_identity(environment=None):
    """Whether the in-flight file is still the inode the session armed.

    `flock(2)` belongs to an open file description rather than to a pathname, so
    a replacement inode at the same path is a different lock: an exclusive
    acquisition on it is granted while a share on the original is still held.
    A participant that took a share on the replacement would be counted by no
    drain, so the mismatch is refused rather than serialized against.
    """
    expected = session_identity(environment)
    if expected == "unrecorded":
        return "unrecorded"
    try:
        actual = identity(inflight_path(environment))
    except OSError:
        actual = "absent"
    return "match" if actual == expected else "mismatch"


def read_state(environment=None):
    """The state word, read under a shared lock so no reader sees a partial write.

    An absent file reads `running`: a caller that armed no barrier is not
    refused by one.
    """
    path = state_path(environment)
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except OSError as error:
        if error.errno in (errno.ENOENT, errno.ENOTDIR):
            return STATE_RUNNING
        raise
    try:
        fcntl.flock(descriptor, fcntl.LOCK_SH)
        with os.fdopen(os.dup(descriptor), "r") as handle:
            return (handle.readline().strip() or STATE_RUNNING)
    finally:
        os.close(descriptor)


def identity(path):
    """`st_dev:st_ino` of a barrier file, the way the lease identity is read.

    A participant handed a path compares this against the session's value and
    refuses a mismatch rather than serializing against another inode.
    """
    status = os.stat(path)
    return "%d:%d" % (status.st_dev, status.st_ino)


class InFlightShare:
    """One admitted job's share of the barrier.

    The share is held for the job's whole duration and released afterwards,
    which is what the orchestrator's exclusive acquisition waits on. The
    descriptor is opened close-on-exec, so a spawned runtime cannot inherit the
    share and hold the barrier open past its admitter -- the residue
    `qwen-webui-session.sh` closes with `9>&-` for the owner claim.
    """

    def __init__(self, environment=None):
        self._environment = environment
        self._descriptor = None

    def __enter__(self):
        path = inflight_path(self._environment)
        if read_state(self._environment) != STATE_RUNNING:
            raise AdmissionRefused("quiescing")
        if verify_session_identity(self._environment) == "mismatch":
            raise AdmissionRefused("identity_mismatch")
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ENOTDIR):
                # No barrier is armed, so there is nothing to take a share of
                # and nothing that will wait on one.
                return self
            raise
        try:
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except OSError:
            os.close(descriptor)
            raise AdmissionRefused("draining") from None
        # The second read is what makes the admission atomic against a flip
        # that landed between the first read and this share.
        if read_state(self._environment) != STATE_RUNNING:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            raise AdmissionRefused("quiescing_after_share")
        self._descriptor = descriptor
        return self

    def __exit__(self, *exception):
        if self._descriptor is not None:
            fcntl.flock(self._descriptor, fcntl.LOCK_UN)
            os.close(self._descriptor)
            self._descriptor = None
        return False


def require_admission(environment=None):
    """The share a service holds across one job, as a context manager."""
    return InFlightShare(environment)
