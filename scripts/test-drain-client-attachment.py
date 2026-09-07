#!/usr/bin/env python3
"""Tell a client attached to completed work from one attached to an unanswered
request, which is the fourth discrimination the drain policy needs.

The barrier answers the same question for a share it issued: a released share
with the process still resident is idle, and scripts/test-qwen-drain-controller.sh
reads that as idle_participant_releases. A server is the other half, because an
open socket says nothing by itself. llama.cpp's shutdown sits in
ctx_http.thread.join() while a worker waits inside server_response::recv_with_timeout
for a task no pass answered, and that wait ends at the client's own departure,
so an orchestrator reading "a client is attached" as "work is in flight" would
refuse to retire a server with nothing left to do.

The two arms differ in one dimension: whether the compute lease is held by
another process when the request arrives. An uncontended request is answered
and its handler returns, so the listener's join finds nothing in flight and the
process leaves while the client is still attached. A contended request blocks
inside the acquire, the terminating signal ends that acquire without the lease,
and the handler that can no longer answer waits for the client instead, so the
process is held until the client departs.

Every assertion reads an event the server itself announces and then an outcome,
rather than an interval. The stand-in logs the acquire's wait and the wait's
interrupted end, so an arm knows the handler is inside the stall branch before
it asserts the process is held, and a deadline is an upper bound on a
transition that has already happened rather than a pace. That is what keeps the
suite from grading the host's scheduler: a first draft asserting on a settle
interval read a held process as departed while a quality-gate run loaded the
machine beside it.

The subject is scripts/test-fixtures/fake-lease-llama-server.py, so a passing
run states that this discrimination is readable and states nothing about a
closure. What a served binary does with an unanswered task is a device reading,
and evidence/lease-coverage/shutdown-stall/ carries the one this stands beside.
"""

import fcntl
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(SCRIPT_DIRECTORY, "test-fixtures", "fake-lease-llama-server.py")

# Upper bounds on transitions that complete in milliseconds when the machine is
# idle. They are generous because a bound that a loaded host can cross reports
# the load rather than the code path.
DEADLINE_S = 30.0
POLL_S = 0.02

# The bound on a negative claim. A held process stays held however loaded the
# host is, and an unsent reply stays unsent, so exceeding this bound is the
# assertion rather than a pace: load can delay an event, and it cannot produce
# one the code path does not reach.
HELD_BOUND_S = 5.0

LEASE_WAITING = "vulkan workload lease waiting:"
LEASE_WAIT_INTERRUPTED = "vulkan workload lease wait ended without the lease:"
LEASE_ACQUIRED = "vulkan workload lease acquired:"


def free_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


class ClientAttachmentTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.lease_path = os.path.join(self.directory.name, "vulkan-workload.lock")
        open(self.lease_path, "w").close()
        self.log_path = os.path.join(self.directory.name, "server.log")
        self.log = open(self.log_path, "wb")
        self.addCleanup(self.log.close)
        self.port = free_port()
        self.holder = None
        self.client = None
        self.server = None

    def tearDown(self):
        if self.client is not None:
            self.client.close()
        if self.server is not None and self.server.poll() is None:
            self.server.kill()
            self.server.wait(timeout=DEADLINE_S)
        if self.holder is not None:
            os.close(self.holder)

    def log_text(self):
        with open(self.log_path, "rb") as handle:
            return handle.read().decode("utf-8", "replace")

    def await_log(self, fragment, what):
        """Block until the server announces an event, bounded."""
        deadline = time.monotonic() + DEADLINE_S
        while time.monotonic() < deadline:
            if fragment in self.log_text():
                return
            if self.server.poll() is not None and fragment not in self.log_text():
                self.fail("the server left before it announced %s" % what)
            time.sleep(POLL_S)
        self.fail("the server never announced %s" % what)

    def await_exit(self):
        """Whether the process leaves inside the bound, read by waiting for it."""
        try:
            self.server.wait(timeout=DEADLINE_S)
            return True
        except subprocess.TimeoutExpired:
            return False

    def held_with_the_client_attached(self):
        """Whether the process stays and its client hears nothing, over the bound.

        Both halves are negative claims. An exit or a reply arriving inside the
        bound refutes the hold; neither can be produced by a loaded host that
        would otherwise not produce it, so the bound is safe in the direction
        this arm reads.
        """
        self.client.settimeout(POLL_S)
        deadline = time.monotonic() + HELD_BOUND_S
        while time.monotonic() < deadline:
            if self.server.poll() is not None:
                return False, "the process left"
            try:
                if self.client.recv(4096):
                    return False, "the client received a reply"
            except OSError:
                pass
        return True, ""

    def start_server(self):
        environment = dict(os.environ)
        environment["QWEN_FAKE_LEASE_STALL"] = "client"
        environment["QWEN_GPU_COMPUTE_LEASE"] = self.lease_path
        environment["QWEN_GPU_COMPUTE_LEASE_WAIT_S"] = str(DEADLINE_S)
        self.server = subprocess.Popen(
            [sys.executable, SERVER, "--port", str(self.port)],
            env=environment, stderr=self.log)
        # The load-path acquire is the server's own first event, and the health
        # route answers only once serve_forever runs.
        self.await_log(LEASE_ACQUIRED, "its load-path lease acquisition")
        deadline = time.monotonic() + DEADLINE_S
        while time.monotonic() < deadline:
            try:
                probe = socket.create_connection(("127.0.0.1", self.port), 0.2)
            except OSError:
                time.sleep(POLL_S)
                continue
            try:
                probe.sendall(b"GET /health HTTP/1.0\r\n\r\n")
                if b"ok" in probe.recv(4096):
                    return
            except OSError:
                pass
            finally:
                probe.close()
            time.sleep(POLL_S)
        self.fail("the stand-in served no health route inside its bound")

    def hold_the_lease(self):
        """Take the lease from a separate open, so the hold is this process's own."""
        self.holder = os.open(self.lease_path, os.O_RDWR)
        fcntl.flock(self.holder, fcntl.LOCK_EX)

    def post_completion(self):
        self.client = socket.create_connection(("127.0.0.1", self.port), DEADLINE_S)
        body = b'{"prompt":"x"}'
        self.client.sendall(
            b"POST /completion HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"
            b"Content-Length: %d\r\nConnection: keep-alive\r\n\r\n%s"
            % (self.port, len(body), body))

    def read_answer(self):
        self.client.settimeout(DEADLINE_S)
        seen = b""
        while b'"content"' not in seen:
            chunk = self.client.recv(4096)
            if not chunk:
                break
            seen += chunk
        return b'"content"' in seen

    def test_a_client_on_completed_work_does_not_hold_the_process(self):
        """An answered request leaves nothing in flight, so the socket holds nothing."""
        self.start_server()
        self.post_completion()
        self.assertTrue(self.read_answer(), "the uncontended request went unanswered")
        self.server.send_signal(signal.SIGTERM)
        self.assertTrue(
            self.await_exit(),
            "a client attached to completed work held the process open")

    def test_a_client_on_an_unanswered_task_holds_the_process(self):
        """A request the interrupted acquire abandoned is held open by its client."""
        self.start_server()
        self.hold_the_lease()
        self.post_completion()
        # The handler is inside the acquire, which is the only place the signal
        # can interrupt a request into the unanswerable state.
        self.await_log(LEASE_WAITING, "the acquire its request is waiting in")
        self.server.send_signal(signal.SIGTERM)
        # The acquire ended without the lease, so the handler is in the stall
        # branch and the listener's join has something in flight to wait for.
        self.await_log(LEASE_WAIT_INTERRUPTED, "the acquire it abandoned")
        held, refutation = self.held_with_the_client_attached()
        self.assertTrue(
            held,
            "a request the acquire abandoned was not held open by its client: %s"
            % refutation)
        self.client.close()
        self.client = None
        self.assertTrue(
            self.await_exit(), "the client's departure did not end the shutdown")

    def test_the_hold_is_the_only_dimension_that_differs(self):
        """The arms share every input but the hold, so the hold is what separates them."""
        self.start_server()
        self.post_completion()
        answered_without_a_holder = self.read_answer()
        self.server.send_signal(signal.SIGTERM)
        self.assertTrue(self.await_exit())
        self.client.close()
        self.client = None

        self.port = free_port()
        self.start_server()
        self.hold_the_lease()
        self.post_completion()
        self.await_log(LEASE_WAITING, "the acquire its request is waiting in")
        self.client.settimeout(0.5)
        try:
            answered_under_a_holder = b'"content"' in self.client.recv(4096)
        except OSError:
            answered_under_a_holder = False
        self.assertTrue(answered_without_a_holder)
        self.assertFalse(answered_under_a_holder)


if __name__ == "__main__":
    unittest.main(verbosity=2)
