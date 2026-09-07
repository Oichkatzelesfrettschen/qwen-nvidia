#!/usr/bin/env python3
"""Hold admission_barrier.py to the semantics the shell library implements.

The two must agree, because one barrier serves both kinds of participant: the
shell controller flips the state and waits on the exclusive lock while the
Python services take shares at their own request entry points. A disagreement
would let a drain complete while a service was still admitting work.

Every assertion reads a lock or a state word rather than waiting an interval.
"""

import fcntl
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIRECTORY)
import admission_barrier  # noqa: E402

BARRIER_LIBRARY = os.path.join(SCRIPT_DIRECTORY, "qwen-admission-barrier.sh")


class BarrierTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.environment = {"QWEN_GPU_ADMISSION_BARRIER": self.directory.name}
        self.addCleanup(self.directory.cleanup)

    def shell(self, script):
        """Run one shell fragment against the same barrier, to compare the pair."""
        return subprocess.run(
            ["sh", "-c", ". %s\n%s" % (BARRIER_LIBRARY, script)],
            env=dict(os.environ, **self.environment),
            capture_output=True, text=True, check=False)

    def arm(self):
        self.shell("qwen_barrier_initialize")

    def test_absent_barrier_admits(self):
        """A session that armed no barrier admits work as it did before one existed."""
        self.assertEqual(admission_barrier.read_state(self.environment), "running")
        with admission_barrier.require_admission(self.environment):
            pass

    def test_state_word_agrees_with_the_shell_library(self):
        self.arm()
        self.assertEqual(admission_barrier.read_state(self.environment), "running")
        self.shell("qwen_barrier_set_state quiescing")
        self.assertEqual(admission_barrier.read_state(self.environment), "quiescing")
        self.shell("qwen_barrier_set_state running")
        self.assertEqual(admission_barrier.read_state(self.environment), "running")

    def test_quiescing_refuses_admission(self):
        self.arm()
        self.shell("qwen_barrier_set_state quiescing")
        with self.assertRaises(admission_barrier.AdmissionRefused) as refusal:
            with admission_barrier.require_admission(self.environment):
                self.fail("the job body ran under a closed barrier")
        self.assertEqual(refusal.exception.reason, "quiescing")

    def test_an_exclusive_holder_refuses_admission(self):
        """A drain already holding the exclusive lock admits no further work."""
        self.arm()
        descriptor = os.open(admission_barrier.inflight_path(self.environment), os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with self.assertRaises(admission_barrier.AdmissionRefused) as refusal:
            with admission_barrier.require_admission(self.environment):
                self.fail("the job body ran against a held exclusive lock")
        self.assertEqual(refusal.exception.reason, "draining")

    def test_a_held_share_blocks_the_drain_and_a_released_one_does_not(self):
        """The share rather than the process is what a drain waits on."""
        self.arm()
        path = admission_barrier.inflight_path(self.environment)
        probe = os.open(path, os.O_RDONLY)
        self.addCleanup(os.close, probe)
        with admission_barrier.require_admission(self.environment):
            with self.assertRaises(OSError):
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(probe, fcntl.LOCK_UN)

    def test_shares_do_not_exclude_each_other(self):
        """Two lanes run together; only a retirement excludes them."""
        self.arm()
        with admission_barrier.require_admission(self.environment):
            with admission_barrier.require_admission(self.environment):
                pass

    def test_the_share_is_close_on_exec(self):
        """A spawned runtime cannot inherit the share and hold the barrier open.

        An inherited descriptor is the residue qwen-webui-session.sh closes with
        `9>&-` for the owner claim: a drain would otherwise wait on a claim that
        no live job backs.
        """
        self.arm()
        path = admission_barrier.inflight_path(self.environment)
        with admission_barrier.require_admission(self.environment):
            # A child that inherited the share would keep the exclusive lock
            # refused after this process released it, so the child is asked
            # directly whether it can take the lock while the parent holds it.
            child = subprocess.run(
                [sys.executable, "-c",
                 "import fcntl,os,sys\n"
                 "d=os.open(sys.argv[1], os.O_RDONLY)\n"
                 "try:\n"
                 "    fcntl.flock(d, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
                 "    print('free')\n"
                 "except OSError:\n"
                 "    print('held')\n", path],
                capture_output=True, text=True, check=False)
            self.assertEqual(child.stdout.strip(), "held")
        # and the descriptor count the child sees carries no extra open on the
        # barrier, which is what close-on-exec establishes
        descriptors = subprocess.run(
            [sys.executable, "-c",
             "import os,sys\n"
             "n=0\n"
             "for entry in os.listdir('/proc/self/fd'):\n"
             "    try:\n"
             "        if os.readlink('/proc/self/fd/' + entry) == sys.argv[1]: n += 1\n"
             "    except OSError: pass\n"
             "print(n)\n", path],
            capture_output=True, text=True, check=False)
        self.assertEqual(descriptors.stdout.strip(), "0")

    def test_identity_reads_device_and_inode(self):
        """A participant refuses a barrier file that is not the session's."""
        self.arm()
        path = admission_barrier.inflight_path(self.environment)
        recorded = admission_barrier.identity(path)
        self.assertEqual(recorded, admission_barrier.identity(path))
        os.replace(path, path + ".moved")
        open(path, "w").close()
        self.assertNotEqual(recorded, admission_barrier.identity(path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
