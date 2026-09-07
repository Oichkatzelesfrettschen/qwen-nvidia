#!/usr/bin/env python3
"""Hold admission_barrier.py to the semantics the shell library implements.

The two must agree, because one barrier serves both kinds of participant: the
shell controller flips the state and waits on the exclusive lock while the
Python services take shares at their own request entry points. A disagreement
would let a drain complete while a service was still admitting work.

Every assertion reads a lock or a state word rather than waiting an interval.
"""

import ast
import fcntl
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIRECTORY)
import admission_barrier  # noqa: E402

BARRIER_LIBRARY = os.path.join(SCRIPT_DIRECTORY, "qwen-admission-barrier.sh")

# One admission attempt, run where a signal can reach it.
ADMISSION_PROBE = """
import sys
sys.path.insert(0, sys.argv[1])
import admission_barrier
try:
    with admission_barrier.require_admission():
        print("admitted")
except admission_barrier.AdmissionRefused as refusal:
    print("refused:%s" % refusal.reason)
"""

# The bound on a non-blocking acquisition, which answers in microseconds however
# loaded the host is. Reaching this deadline means the acquisition blocked.
ADMISSION_DEADLINE_S = 20.0


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

    def admit_in_a_child(self, deadline_s=ADMISSION_DEADLINE_S):
        """One admission attempt in a separately killable process.

        The deadline is the assertion rather than a pace: the acquisition is
        non-blocking, so a host under load answers inside it and only a blocking
        acquisition reaches it.
        """
        child = subprocess.Popen(
            [sys.executable, "-c", ADMISSION_PROBE, SCRIPT_DIRECTORY],
            env=dict(os.environ, **self.environment),
            stdout=subprocess.PIPE, text=True)
        try:
            output, _ = child.communicate(timeout=deadline_s)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            self.fail(
                "the admission blocked past %.0f s rather than refusing" % deadline_s)
        return output.strip()

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
        """A drain already holding the exclusive lock admits no further work.

        The attempt runs in a child with its own deadline. An admission that
        acquired the share blocking rather than `LOCK_NB` would wait on the
        exclusive lock this arm holds, and in-process that wait is unkillable:
        the suite would hang the unattended gate instead of failing it.
        """
        self.arm()
        descriptor = os.open(admission_barrier.inflight_path(self.environment), os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.admit_in_a_child(), "refused:draining")

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
        with admission_barrier.require_admission(self.environment) as share:
            # The flag is read off the descriptor that holds the share, while it
            # holds it. Asking a child whether the lock is free instead reports
            # the parent's own share, which is true whatever the flag says, and
            # counting a child's descriptors after the context closed reports an
            # already-released share. Both passed with the flag removed.
            #
            # The property has two sources and the arm reads the property. PEP
            # 446 makes every os.open descriptor non-inheritable, measured here
            # as FD_CLOEXEC set under O_RDONLY alone on CPython 3.14.7, so
            # deleting the explicit O_CLOEXEC changes no behavior and this arm
            # holds under that edit rather than catching it. What it catches is
            # a descriptor opened by some later route that does set the flag
            # off, and what the explicit flag buys is a reader who need not
            # know PEP 446 to see that the share is not inherited.
            flags = fcntl.fcntl(share._descriptor, fcntl.F_GETFD)
            self.assertTrue(
                flags & fcntl.FD_CLOEXEC,
                "the share descriptor is inheritable, so a spawned runtime "
                "would hold the barrier open past its admitter")

    def test_a_flip_between_the_two_reads_refuses_after_the_share(self):
        """The second state read is what makes an admission atomic against a flip.

        The interleaving is driven rather than waited for: the first read
        returns `running`, the flip lands before the share is counted, and the
        second read is the only thing that can still refuse. With that read
        removed the job body runs under a closed barrier and a drain waits on a
        share it never saw arrive.
        """
        self.arm()
        real_read_state = admission_barrier.read_state
        self.addCleanup(setattr, admission_barrier, "read_state", real_read_state)
        reads = []

        def flipping_read_state(environment=None):
            state = real_read_state(environment)
            reads.append(state)
            if len(reads) == 1:
                self.shell("qwen_barrier_set_state quiescing")
            return state

        admission_barrier.read_state = flipping_read_state
        with self.assertRaises(admission_barrier.AdmissionRefused) as refusal:
            with admission_barrier.require_admission(self.environment):
                self.fail("the job body ran under a barrier that closed before the share")
        self.assertEqual(refusal.exception.reason, "quiescing_after_share")
        self.assertEqual(reads, ["running", "quiescing"])
        # The refused share is released rather than leaked, so the drain that
        # follows the flip is granted.
        probe = os.open(admission_barrier.inflight_path(self.environment), os.O_RDONLY)
        self.addCleanup(os.close, probe)
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(probe, fcntl.LOCK_UN)

    def test_identity_reads_device_and_inode(self):
        """A participant refuses a barrier file that is not the session's."""
        self.arm()
        path = admission_barrier.inflight_path(self.environment)
        recorded = admission_barrier.identity(path)
        self.assertEqual(recorded, admission_barrier.identity(path))
        os.replace(path, path + ".moved")
        open(path, "w").close()
        self.assertNotEqual(recorded, admission_barrier.identity(path))


    def quiescing_class(self, service_name):
        """Execute one service's ServiceQuiescing over a stub base.

        The class is read out of each service's own source rather than imported,
        so the arm reaches the real mapping without the service's import-time
        work, and three copies that drift apart fail here rather than in an
        audit row.
        """
        source = pathlib.Path(SCRIPT_DIRECTORY, service_name).read_text()
        for node in ast.parse(source).body:
            if isinstance(node, ast.ClassDef) and node.name == "ServiceQuiescing":
                node.bases = [ast.Name(id="ServiceError", ctx=ast.Load())]
                node.decorator_list = []
                module = ast.fix_missing_locations(ast.Module(body=[node], type_ignores=[]))
                namespace = {"ServiceError": type("ServiceError", (Exception,), {})}
                exec(compile(module, service_name, "exec"), namespace)
                return namespace["ServiceQuiescing"]
        self.fail("%s carries no ServiceQuiescing class" % service_name)

    def test_a_barrier_fault_reason_does_not_claim_quiescence(self):
        """A refusal reason states what refused, and a fault claims no session state.

        The barrier refuses for two different reasons: the session reached a
        state that closes the entry point, or the barrier detected a fault while
        the session was still running. identity_mismatch is the second kind, so
        a reason prefixing it with the session's state word would report a
        quiescence that never began.
        """
        details = sorted({
            node.args[0].value
            for node in ast.walk(ast.parse(pathlib.Path(admission_barrier.__file__).read_text()))
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            and node.func.id == "AdmissionRefused" and node.args
            and isinstance(node.args[0], ast.Constant)})
        self.assertIn("quiescing", details)
        self.assertIn("identity_mismatch", details)

        readings = {}
        for service in ("image-service.py", "physics-service.py", "geometry-service.py"):
            quiescing = self.quiescing_class(service)
            for word in quiescing.STATE_REASONS:
                self.assertIn(word, details,
                              "%s names a state reason the barrier never raises: %s"
                              % (service, word))
            reading = {detail: quiescing(detail).reason for detail in details}
            for detail, reason in reading.items():
                if detail in quiescing.STATE_REASONS:
                    self.assertEqual(reason, detail,
                                     "%s renamed the session state %s" % (service, detail))
                else:
                    self.assertEqual(reason, "barrier_%s" % detail,
                                     "%s left the fault %s unclassified" % (service, detail))
                    self.assertFalse(reason.startswith("quiescing"),
                                     "%s reports the fault %s as a quiescence" % (service, detail))
            readings[service] = reading

        reference = readings["image-service.py"]
        for service, reading in readings.items():
            self.assertEqual(reading, reference,
                             "%s maps a barrier refusal differently than image-service.py"
                             % service)


if __name__ == "__main__":
    unittest.main(verbosity=2)
