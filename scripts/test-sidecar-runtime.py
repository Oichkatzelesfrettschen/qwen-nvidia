#!/usr/bin/env python3
"""Hold sidecar_runtime.py to its collector, ledger, and identity claims.

The collector: a child that floods stdout is ended and reported as an
overflow; a child that runs past its deadline is ended and the deadline
carries a timeline naming the signal and the exit; a child whose helper
inherits the pipe and outlives it is bounded by the grace rather than by
the helper; a child that exits normally returns both streams. The ledger:
a grant id spends once and refuses its second use. The identity: a
descriptor of another file refuses, and the launch check refuses an absent
variable and a differing identity.
"""

import os
import pathlib
import subprocess
import sys
import tempfile
import time

SCRIPTS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import sidecar_runtime as runtime  # noqa: E402


def spawn(command):
    return subprocess.Popen(["sh", "-c", command], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)


def main():
    failures = []

    def check(condition, description):
        print(("ok " if condition else "FAIL ") + description)
        if not condition:
            failures.append(description)

    child = spawn("echo out; echo err >&2")
    check(runtime.collect_output(child, 5, 65536, 4096) == (b"out\n", b"err\n"), "a normal child returns both streams")
    check(child.returncode == 0, "the normal child is reaped")

    child = spawn("head -c 200000 /dev/zero; echo err >&2")
    try:
        runtime.collect_output(child, 5, 65536, 4096)
        check(False, "a flooding child overflows")
    except runtime.OutputOverflow as overflow:
        check(overflow.stream == "stdout" and child.poll() is not None, "a flooding child is ended and named")

    child = spawn("head -c 9000 /dev/zero >&2; sleep 30")
    try:
        runtime.collect_output(child, 5, 65536, 4096)
        check(False, "a stderr flood overflows")
    except runtime.OutputOverflow as overflow:
        check(overflow.stream == "stderr" and child.poll() is not None, "a stderr flood is ended and named")

    started = time.monotonic()
    child = spawn("sleep 30")
    try:
        runtime.collect_output(child, 0.5, 65536, 4096)
        check(False, "a child past its deadline is ended")
    except runtime.RuntimeDeadline as deadline:
        elapsed = time.monotonic() - started
        check("sigterm_s" in deadline.timeline and "exit_s" in deadline.timeline and child.poll() is not None,
              "the deadline carries the signal and exit timeline: %s" % deadline.timeline)
        check(elapsed < 3, "the deadline returns inside the grace")

    started = time.monotonic()
    child = spawn("sleep 20 & echo leader-done; wait")
    try:
        runtime.collect_output(child, 1, 65536, 4096)
        check(False, "a helper holding the pipe past the deadline is ended")
    except runtime.RuntimeDeadline:
        check(time.monotonic() - started < 4, "a helper holding the pipe does not hold the collector")

    child = spawn("trap '' TERM; sleep 30")
    started = time.monotonic()
    try:
        runtime.collect_output(child, 0.5, 65536, 4096)
        check(False, "a child ignoring SIGTERM is killed")
    except runtime.RuntimeDeadline as deadline:
        check("sigkill_s" in deadline.timeline and child.poll() is not None, "a child ignoring SIGTERM meets SIGKILL: %s" % deadline.timeline)
        check(time.monotonic() - started < 9, "the SIGKILL escalation is bounded")

    with tempfile.TemporaryDirectory() as directory:
        ledger = runtime.GrantLedger(directory)
        ledger.consume("grant-one", int(time.time()) + 300, time.time())
        try:
            ledger.consume("grant-one", int(time.time()) + 300, time.time())
            check(False, "a spent grant refuses")
        except runtime.GrantRefused as refusal:
            check(refusal.reason == "grant_replayed", "a spent grant refuses as replayed")
        ledger.consume("grant-two", int(time.time()) + 300, time.time())
        check(True, "another grant spends")
        ledger.close()

        lease = os.path.join(directory, "lease")
        other = os.path.join(directory, "other")
        for path in (lease, other):
            open(path, "w").close()
        expected = runtime.lease_identity(lease)
        descriptor = os.open(lease, os.O_RDWR)
        runtime.require_descriptor_identity(descriptor, expected)
        check(True, "the lease descriptor matches its identity")
        os.close(descriptor)
        descriptor = os.open(other, os.O_RDWR)
        try:
            runtime.require_descriptor_identity(descriptor, expected)
            check(False, "another file's descriptor refuses")
        except runtime.LeaseIdentityRefused:
            check(True, "another file's descriptor refuses")
        os.close(descriptor)
        check(runtime.require_lease_identity({"QWEN_GPU_COMPUTE_LEASE": lease, "QWEN_GPU_COMPUTE_LEASE_IDENTITY": expected}) == (lease, expected),
              "the launch check returns the path and identity")
        try:
            runtime.require_lease_identity({"QWEN_GPU_COMPUTE_LEASE": lease, "QWEN_GPU_COMPUTE_LEASE_IDENTITY": "1:2"})
            check(False, "a differing identity refuses at launch")
        except runtime.LeaseIdentityRefused:
            check(True, "a differing identity refuses at launch")
        try:
            runtime.require_lease_identity({})
            check(False, "an absent lease variable refuses at launch")
        except runtime.LeaseIdentityRefused:
            check(True, "an absent lease variable refuses at launch")

    if failures:
        print("sidecar_runtime=rejected failures=%d" % len(failures), file=sys.stderr)
        sys.exit(1)
    print("sidecar_runtime=accepted")


if __name__ == "__main__":
    main()
