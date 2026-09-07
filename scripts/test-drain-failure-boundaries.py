#!/usr/bin/env python3
"""Exercise admission recovery, inode lifetime, and exceptional descriptor cleanup."""

import errno
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))
import admission_barrier as barrier  # noqa: E402

CONTROLLER = SCRIPT_DIRECTORY / "qwen-drain-controller.sh"
LIBRARY = SCRIPT_DIRECTORY / "qwen-admission-barrier.sh"


class DrainFailureBoundaries(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="drain-boundaries-")
        self.addCleanup(self.temporary.cleanup)
        self.env = dict(os.environ, QWEN_GPU_ADMISSION_BARRIER=self.temporary.name)
        self.run_controller("status")
        self.inflight = Path(self.temporary.name) / "admission.inflight"
        self.state = Path(self.temporary.name) / "admission.barrier"

    def run_controller(self, *arguments):
        return subprocess.run([str(CONTROLLER), *arguments], env=self.env,
                              text=True, capture_output=True, timeout=8, check=False)

    def hold_share(self):
        descriptor = os.open(self.inflight, os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return descriptor

    def test_failed_destroy_keeps_admission_closed(self):
        result = self.run_controller("retire", "--deadline", "0", "--", "false")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.state.read_text().strip(), "quiescing")
        result = self.run_controller("admit", "--", "true")
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_expired_drain_keeps_admission_closed(self):
        self.hold_share()
        result = self.run_controller("retire", "--deadline", "0", "--", "true")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("orderly_drain=failed", result.stdout)
        self.assertEqual(self.state.read_text().strip(), "quiescing")

    def test_resume_refuses_while_work_remains(self):
        descriptor = self.hold_share()
        self.state.write_text("quiescing\n")
        result = self.run_controller("resume")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.state.read_text().strip(), "quiescing")
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        result = self.run_controller("resume")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state.read_text().strip(), "running")

    def test_state_transition_preserves_locked_inode(self):
        descriptor = os.open(self.state, os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        identity = os.fstat(descriptor).st_ino
        result = subprocess.run(["sh", "-c", '. "$1"; qwen_barrier_set_state quiescing',
                                 "barrier", str(LIBRARY)], env=self.env,
                                text=True, capture_output=True, timeout=8, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state.stat().st_ino, identity)
        os.lseek(descriptor, 0, os.SEEK_SET)
        self.assertEqual(os.read(descriptor, 64), b"quiescing\n")

    def test_second_read_failure_closes_acquired_share(self):
        opened = []
        actual_open = os.open

        def record_open(*args, **kwargs):
            descriptor = actual_open(*args, **kwargs)
            opened.append(descriptor)
            return descriptor

        try:
            with mock.patch.object(barrier, "read_state", side_effect=["running", OSError(errno.EIO, "fixture")]):
                with mock.patch.object(barrier.os, "open", side_effect=record_open):
                    with self.assertRaises(OSError):
                        barrier.InFlightShare(self.env).__enter__()
            self.assertEqual(len(opened), 1)
            with self.assertRaises(OSError):
                os.fstat(opened[0])
        finally:
            for descriptor in opened:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    def test_unlock_failure_still_closes_descriptor(self):
        share = barrier.InFlightShare(self.env)
        share.__enter__()
        descriptor = share._descriptor
        actual_flock = fcntl.flock

        def fail_unlock(fd, flags):
            if flags == fcntl.LOCK_UN:
                raise OSError(errno.EIO, "fixture unlock failure")
            return actual_flock(fd, flags)

        try:
            with mock.patch.object(barrier.fcntl, "flock", side_effect=fail_unlock):
                with self.assertRaises(OSError):
                    share.__exit__(None, None, None)
            self.assertIsNone(share._descriptor)
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        finally:
            if share._descriptor is not None:
                os.close(share._descriptor)
                share._descriptor = None

    def test_destroy_child_does_not_inherit_drain_lock(self):
        code = "import os,sys; print('inherited=' + str(sum(os.path.exists('/proc/self/fd/'+f) and os.path.realpath('/proc/self/fd/'+f)==sys.argv[1] for f in os.listdir('/proc/self/fd'))))"
        result = self.run_controller("retire", "--deadline", "100", "--",
                                     sys.executable, "-c", code, str(self.inflight))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("inherited=0", result.stdout)

    def test_share_is_non_inheritable_with_close_fds_disabled(self):
        with barrier.InFlightShare(self.env):
            code = "import os,sys; print(sum(os.path.exists('/proc/self/fd/'+f) and os.path.realpath('/proc/self/fd/'+f)==sys.argv[1] for f in os.listdir('/proc/self/fd')))"
            result = subprocess.run([sys.executable, "-c", code, str(self.inflight)],
                                    env=self.env, close_fds=False, text=True,
                                    capture_output=True, timeout=8, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
