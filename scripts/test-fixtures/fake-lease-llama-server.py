#!/usr/bin/env python3
"""A lease-aware stand-in for the patched llama-server.

scripts/test-load-lease-coverage.sh reads its served arms out of a server's own
lease lines, so six of its ten readings need a binary that writes them. This
reproduces the transitions patches/llama-server-vulkan-workload-lease.patch
performs -- open at load, bounded acquire ahead of the upload, blocking acquire
per decode pass, release at the idle transition, and the teardown line on the
reacquire path -- and serves /health and /completion, so every arm executes its
real control flow on a host with no GPU. It allocates nothing on a device,
uploads nothing, and prints no loader line, which is what arm C reads to
separate a refusal that preceded an upload from one that followed it.

A passing run against this fixture states that the harness reads what it claims
to read. It states nothing about the closure under test, whose own lines are
what a device run grades.
"""
import fcntl
import json
import os
import select
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = 8080
for i, a in enumerate(sys.argv):
    if a == "--port":
        port = int(sys.argv[i + 1])

lease_path = os.environ.get("QWEN_GPU_COMPUTE_LEASE") or os.environ.get(
    "QWEN_VULKAN_WORKLOAD_LOCK")
wait_s = float(os.environ.get("QWEN_GPU_COMPUTE_LEASE_WAIT_S", "300"))

terminating = threading.Event()
held = threading.Lock()
lease_held = [False]


def log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


fd = -1
if lease_path:
    fd = os.open(lease_path, os.O_RDWR | os.O_CREAT, 0o644)
    log("vulkan workload lease armed: path=%s" % lease_path)


def acquire(deadline):
    """Poll LOCK_EX|LOCK_NB to the deadline; None means block until signalled."""
    if fd < 0:
        return True
    start = time.monotonic()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        lease_held[0] = True
        log("vulkan workload lease acquired: path=%s bound=deadline waited_ms=0"
            % lease_path)
        return True
    except OSError:
        pass
    log("vulkan workload lease waiting: path=%s" % lease_path)
    while deadline is None or time.monotonic() - start < deadline:
        if terminating.is_set():
            log("vulkan workload lease wait ended without the lease: path=%s"
                % lease_path)
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lease_held[0] = True
            log("vulkan workload lease acquired: path=%s bound=deadline waited_ms=%d"
                % (lease_path, int((time.monotonic() - start) * 1000)))
            return True
        except OSError:
            time.sleep(0.05)
    log("vulkan workload lease deadline reached without the lease: path=%s wait_s=%s"
        % (lease_path, wait_s))
    return False


def release():
    if fd < 0 or not lease_held[0]:
        return
    fcntl.flock(fd, fcntl.LOCK_UN)
    lease_held[0] = False
    log("vulkan workload lease released: path=%s" % lease_path)


def on_term(signum, frame):
    terminating.set()


signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)

if not acquire(wait_s):
    if fd >= 0 and not lease_held[0]:
        log("vulkan workload lease teardown: held=no")
    sys.exit(1)
time.sleep(0.5)
release()
loaded = True


# QWEN_FAKE_LEASE_STALL reproduces one of the two shutdown shapes
# scripts/probe-lease-shutdown-stall.sh discriminates between, so the probe can
# be shown to read each rather than to emit one. Under either, a request the
# terminating signal caught in flight is never answered and the process waits
# for every handler before it exits, which is what cpp-httplib's listener does
# when it joins its workers.
#
#   client   the handler holds until its own client disconnects, which is
#            llama.cpp's own path: server-queue.cpp polls a completion's result
#            at HTTP_POLLING_SECONDS and returns when is_connection_closed
#            reports the client gone
#   lease    the handler holds until the compute lease goes free, which is the
#            shape a teardown blocked on contention would have
#
# A probe hard-coded to report either would fail against the other, which is
# what makes the pair a discrimination test rather than a shape check.
stall_mode = os.environ.get("QWEN_FAKE_LEASE_STALL", "")
if stall_mode == "1":
    stall_mode = "client"
stall_shutdown = stall_mode in ("client", "lease")
in_flight = threading.Semaphore(0)
in_flight_count = [0]
in_flight_lock = threading.Lock()


def wait_for_client_departure(connection):
    while True:
        if select.select([connection], [], [], 1.0)[0]:
            try:
                if connection.recv(1, socket.MSG_PEEK) == b"":
                    return
            except OSError:
                return


def wait_for_lease_release():
    # A separate open is what the availability is tested through, because a
    # flock belongs to its open file description and reusing the server's own
    # descriptor would move the hold this fixture is reporting on.
    while True:
        probe = os.open(lease_path, os.O_RDWR)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except OSError:
            time.sleep(0.2)
        finally:
            os.close(probe)


def wait_for_stall_release(connection):
    if stall_mode == "lease":
        wait_for_lease_release()
    else:
        wait_for_client_departure(connection)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/health"):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        log("slot launch_slot_: id  0 | task 0 | processing task, is_child = 0")
        with in_flight_lock:
            in_flight_count[0] += 1
        try:
            self.serve_completion()
        finally:
            with in_flight_lock:
                in_flight_count[0] -= 1

    def serve_completion(self):
        if stall_shutdown and terminating.is_set():
            # The pass that would have answered this task left without posting
            # its result, so the reply never comes and the client's own
            # departure is what ends the handler.
            wait_for_stall_release(self.connection)
            return
        with held:
            if not acquire(None):
                if stall_shutdown:
                    wait_for_stall_release(self.connection)
                    return
                self.send_error(503)
                return
            time.sleep(0.2)
            release()
        body = json.dumps({"content": " ok"}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
terminating.wait()
server.shutdown()
if stall_shutdown:
    # The listener joins its workers, so the process cannot leave while a
    # handler is still inside a request.
    while True:
        with in_flight_lock:
            if in_flight_count[0] == 0:
                break
        time.sleep(0.1)
if fd >= 0 and not lease_held[0]:
    acquired = False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquired = True
        lease_held[0] = True
    except OSError:
        pass
    log("vulkan workload lease teardown: held=%s" % ("yes" if acquired else "no"))
release()
