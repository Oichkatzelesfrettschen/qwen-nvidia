#!/usr/bin/env python3
"""Exercise admission recovery, inode lifetime, and exceptional descriptor cleanup."""

import errno
import fcntl
import os
import pathlib
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))
import admission_barrier as barrier  # noqa: E402

CONTROLLER = SCRIPT_DIRECTORY / "qwen-drain-controller.sh"
LIBRARY = SCRIPT_DIRECTORY / "qwen-admission-barrier.sh"

# Every step these arms drive is a lock operation or a short fork, which answers
# in milliseconds however loaded the host is, so this bound separates a hung
# step from a slow one rather than pacing anything. It matches
# `test-admission-barrier.py`'s own deadline, because the two suites run beside
# each other in the unattended gate and an interval that reads a running process
# as departed is the failure this record already names once.
SUBPROCESS_DEADLINE_S = 20.0

# The spawn window is microseconds wide, so the arm that reads it repeats. The
# repaired admitter holds the share on every repeat, which is the invariant it
# asserts; one repeat that released it would be the defect, and reverting the
# handler's position refuses this arm within this count.
# The stub holds the spawn window open for this long, which is what turns a
# microsecond race into a reading. REAL_AWK is resolved once so the stub can
# exec the genuine one after it sleeps.
SPAWN_WINDOW_HOLD_S = 3
REAL_AWK = shutil.which("awk")


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
                              text=True, capture_output=True, timeout=SUBPROCESS_DEADLINE_S, check=False)

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
                                text=True, capture_output=True, timeout=SUBPROCESS_DEADLINE_S, check=False)
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
        # The child reports its teardown line as well as its descriptor count,
        # because the controller emits the exclusion from positive readings and
        # a silent destroy reads `unattributed` at exit 4. Naming the line keeps
        # this arm on descriptor inheritance rather than on the classification,
        # and reading `inherited=0` back through the controller's own output
        # also proves the destroy step still forwards what the child wrote.
        code = ("import os,sys;"
                " print('inherited=' + str(sum(os.path.exists('/proc/self/fd/'+f)"
                " and os.path.realpath('/proc/self/fd/'+f)==sys.argv[1]"
                " for f in os.listdir('/proc/self/fd'))));"
                " print('teardown: held=yes')")
        result = self.run_controller("retire", "--deadline", "100", "--",
                                     sys.executable, "-c", code, str(self.inflight))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("inherited=0", result.stdout)
        self.assertIn("teardown_exclusion=orderly", result.stdout)

    def test_share_is_non_inheritable_with_close_fds_disabled(self):
        with barrier.InFlightShare(self.env):
            code = "import os,sys; print(sum(os.path.exists('/proc/self/fd/'+f) and os.path.realpath('/proc/self/fd/'+f)==sys.argv[1] for f in os.listdir('/proc/self/fd')))"
            result = subprocess.run([sys.executable, "-c", code, str(self.inflight)],
                                    env=self.env, close_fds=False, text=True,
                                    capture_output=True, timeout=SUBPROCESS_DEADLINE_S, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "0")

    # ---- arms for the stage-one review findings ----------------------------
    #
    # Each of these reproduces one reported defect: it fails against the
    # implementation as reviewed and passes against the repair, so the arm
    # rather than the repair's name is what decides the finding.

    def retiring_marker(self):
        return pathlib.Path(self.temporary.name) / "admission.retiring"

    def marker_is_held(self, path):
        """Whether some process holds the marker, read on this reader's own open."""
        descriptor = os.open(path, os.O_RDONLY)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return True
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            return False
        finally:
            os.close(descriptor)

    def controller_in_background(self, *arguments):
        process = subprocess.Popen([str(CONTROLLER), *arguments], env=self.env,
                                   text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        self.addCleanup(self.reap, process)
        return process

    def reap(self, process):
        if process.poll() is None:
            process.kill()
        process.wait(timeout=SUBPROCESS_DEADLINE_S)
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()

    def wait_for(self, predicate, description):
        """Poll a state change rather than assume an interval reached it."""
        deadline = time.monotonic() + SUBPROCESS_DEADLINE_S
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("never observed: %s" % description)

    def test_a_second_retirement_is_refused_while_one_runs(self):
        """Two retirements cannot interleave their state writes.

        A retirement that released its references before writing `running` left
        an interval in which a second could take them and close admission, and
        the first then reopened it behind a retirement already under way.
        """
        marker = pathlib.Path(self.temporary.name) / "destroy-entered"
        slow = ("import pathlib,sys,time;"
                " pathlib.Path(sys.argv[1]).write_text('x');"
                " time.sleep(3); print('teardown: held=yes')")
        first = self.controller_in_background(
            "retire", "--deadline", "100", "--", sys.executable, "-c", slow, str(marker))
        self.wait_for(marker.exists, "the first retirement entering destruction")
        second = self.run_controller("retire", "--deadline", "100", "--", "true")
        self.assertEqual(second.returncode, 75,
                         "a second retirement ran beside the first: %s%s"
                         % (second.stdout, second.stderr))
        self.assertIn("retirement_already_running", second.stderr)
        self.assertEqual(first.wait(timeout=SUBPROCESS_DEADLINE_S), 0,
                         "the first retirement did not complete")

    def test_recovery_is_refused_while_an_emergency_destruction_runs(self):
        """A drain that reaches its deadline holds no in-flight reference.

        The emergency destruction that follows therefore runs with the in-flight
        file free, and a recovery reading only that file would reopen admission
        into a live teardown.
        """
        share = self.hold_share()
        marker = pathlib.Path(self.temporary.name) / "emergency-entered"
        slow = ("import pathlib,sys,time;"
                " pathlib.Path(sys.argv[1]).write_text('x'); time.sleep(3)")
        retire = self.controller_in_background(
            "retire", "--deadline", "0", "--", sys.executable, "-c", slow, str(marker))
        self.wait_for(marker.exists, "the emergency destruction starting")
        fcntl.flock(share, fcntl.LOCK_UN)
        self.assertFalse(self.marker_is_held(self.inflight),
                         "this arm requires the in-flight reference to be free")
        resume = self.run_controller("resume")
        self.assertNotEqual(resume.returncode, 0,
                            "recovery reopened admission during destruction: %s" % resume.stdout)
        self.assertIn("retirement_running", resume.stderr)
        admit = self.run_controller("admit", "--", "true")
        self.assertNotEqual(admit.returncode, 0,
                            "admission was granted during destruction: %s" % admit.stdout)
        retire.wait(timeout=SUBPROCESS_DEADLINE_S)

    def test_terminating_a_retirement_holds_its_references_until_the_child_leaves(self):
        """The destroy child is supervised the way the admitted job is.

        A signal that ended the controller while its destroy child ran released
        the exclusive reference under a live teardown, and recovery then
        succeeded with the child still resident.
        """
        marker = pathlib.Path(self.temporary.name) / "destroy-entered"
        child = ("import pathlib,signal,sys,time;"
                 " signal.signal(signal.SIGTERM, lambda *a: None);"
                 " pathlib.Path(sys.argv[1]).write_text('x');"
                 " time.sleep(2); print('teardown: held=yes')")
        retire = self.controller_in_background(
            "retire", "--deadline", "100", "--", sys.executable, "-c", child, str(marker))
        self.wait_for(marker.exists, "the destroy child starting")
        retire.send_signal(signal.SIGTERM)
        # The child ignores the forwarded signal, so the controller is still
        # inside its wait; both references stay held for as long as that lasts.
        self.assertTrue(self.marker_is_held(self.retiring_marker()),
                        "the retirement reference was released with the child alive")
        resume = self.run_controller("resume")
        self.assertNotEqual(resume.returncode, 0,
                            "recovery succeeded with the destroy child alive: %s" % resume.stdout)
        retire.wait(timeout=SUBPROCESS_DEADLINE_S)
        self.wait_for(lambda: not self.marker_is_held(self.retiring_marker()),
                      "the retirement reference released after the child left")

    def test_an_identity_mismatch_refuses_destruction_rather_than_reporting_it(self):
        """A drain over a replacement inode establishes nothing to destroy on.

        The reference this retirement drained is then not the one the session
        armed, so the destroy command is refused before invocation rather than
        run and classified afterwards.
        """
        share = self.hold_share()
        self.addCleanup(fcntl.flock, share, fcntl.LOCK_UN)
        replacement = self.inflight.with_suffix(".replacement")
        replacement.write_text("")
        os.replace(replacement, self.inflight)
        ran = pathlib.Path(self.temporary.name) / "destroy-ran"
        result = self.run_controller(
            "retire", "--deadline", "100", "--", sys.executable, "-c",
            "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('x');"
            " print('teardown: held=yes')", str(ran))
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("teardown_exclusion=not_established", result.stdout)
        self.assertFalse(ran.exists(),
                         "the destroy command ran under a drain that proved nothing")

    def test_a_contradictory_teardown_report_establishes_nothing(self):
        """One destroy reporting both readings is neither of them.

        An aggregate teardown over several participants can print one of each,
        and taking the first match let the held line decide for a set that was
        not wholly held.
        """
        result = self.run_controller(
            "retire", "--deadline", "100", "--", sys.executable, "-c",
            "print('teardown: held=yes'); print('teardown: held=no')")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("teardown_exclusion=not_established", result.stdout)

    def test_a_signal_inside_the_spawn_window_still_holds_the_share(self):
        """The handler is in force from the moment the child exists.

        Installing it after the spawn left that interval uncovered, and it
        contains the record write that timestamps `job_started`. The timestamp
        forks `awk`, so a stub that is slow on its second call holds the interval
        open for as long as the arm needs rather than racing it: the signal lands
        inside the window by construction. The repaired admitter catches it and
        holds the share; the reverted one has not yet installed its handler and
        exits with the job alive.
        """
        stub_directory = pathlib.Path(self.temporary.name) / "slow-awk"
        stub_directory.mkdir()
        counter = stub_directory / "calls"
        stub = stub_directory / "awk"
        stub.write_text(
            "#!/bin/sh\n"
            "calls=$(cat '%s' 2>/dev/null || echo 0)\n"
            "echo $((calls + 1)) > '%s'\n"
            "[ \"$calls\" -eq 1 ] && sleep %d\n"
            "exec %s \"$@\"\n" % (counter, counter, SPAWN_WINDOW_HOLD_S, REAL_AWK))
        stub.chmod(0o755)
        environment = dict(self.env, PATH="%s:%s" % (stub_directory, self.env["PATH"]))

        admit = subprocess.Popen(
            [str(CONTROLLER), "admit", "--", "sleep", str(SPAWN_WINDOW_HOLD_S + 3)],
            env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.reap, admit)
        # The counter reaching two means the second timestamp has started, which
        # is the spawn window and is held open for SPAWN_WINDOW_HOLD_S. Waiting
        # on that event rather than on an interval is what makes the signal land
        # inside the window rather than near it.
        self.wait_for(lambda: counter.exists() and counter.read_text().strip() == "2",
                      "the admitter entering the timestamp of its job_started record")
        admit.send_signal(signal.SIGTERM)
        admit.wait(timeout=SUBPROCESS_DEADLINE_S)
        self.assertIsNotNone(admit.returncode)
        self.assertGreaterEqual(
            admit.returncode, 0,
            "the admitter was killed by signal %d inside the spawn window, so the"
            " share was released with its job alive" % -admit.returncode)

    def test_a_signal_during_admission_holds_the_share_until_the_job_leaves(self):
        """The handler is installed before the child exists.

        A signal arriving between the spawn and the handler ended the admitter
        with the job running and the share released. The residual interval
        between `cmd &` and `$!` forwards no signal and holds the share, which
        is the emergency exception the policy already reserves.
        """
        marker = pathlib.Path(self.temporary.name) / "job-entered"
        job = ("import pathlib,signal,sys,time;"
               " signal.signal(signal.SIGTERM, lambda *a: None);"
               " pathlib.Path(sys.argv[1]).write_text('x');"
               " time.sleep(2)")
        admit = self.controller_in_background(
            "admit", "--", sys.executable, "-c", job, str(marker))
        self.wait_for(marker.exists, "the admitted job starting")
        admit.send_signal(signal.SIGTERM)
        self.assertTrue(self.marker_is_held(self.inflight),
                        "the share was released with the admitted job alive")
        admit.wait(timeout=SUBPROCESS_DEADLINE_S)
        self.wait_for(lambda: not self.marker_is_held(self.inflight),
                      "the share released after the job left")


if __name__ == "__main__":
    unittest.main(verbosity=2)
