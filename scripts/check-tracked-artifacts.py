#!/usr/bin/env python3
"""Refuse raw profiler and database artifacts in the tracked tree.

Nsight Systems writes the capturing process's entire environment into its
report: a `.nsys-rep` and the `.sqlite` exported from it both carry a
`DeviceEnvironment` string holding every exported variable, credentials
included. Eight `profile.nsys-rep` captures reached this repository that
way and carried a live third-party API key and a session token with them,
so an opaque binary report is a credential container rather than a
measurement and the tree refuses to hold one.

The retained form of a profiler run is its derived export -- the CSV or TSV
a reader can inspect before it is committed -- beside the SHA-256 of the raw
report, which is what `evidence/ada/mmvq-crossover-ad104/binaries.sha256`
already does. `scripts/exec-profiler-clean-env.sh` bounds what a capture can
absorb in the first place; this gate bounds what the tree can retain.

The suffix list is a denylist because the file types are known and named by
the tools that write them. The environment allowlist in the profiler wrapper
is the control that covers what nobody anticipated.
"""

import pathlib
import subprocess
import sys

FORBIDDEN_SUFFIXES = (
    ".nsys-rep",
    ".ncu-rep",
    ".qdrep",
    ".qdstrm",
    ".sqlite",
    ".sqlite3",
)


def tracked_paths():
    result = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    return [
        pathlib.Path(entry)
        for entry in result.stdout.decode("utf-8").split("\0")
        if entry
    ]


def main():
    offenders = [
        path
        for path in tracked_paths()
        if path.name.endswith(FORBIDDEN_SUFFIXES)
    ]
    if offenders:
        sys.stderr.write(
            "tracked_artifacts=rejected count=%d\n" % len(offenders)
        )
        for path in offenders:
            sys.stderr.write("  %s\n" % path)
        sys.stderr.write(
            "a raw profiler report carries the capturing process's whole "
            "environment; retain its CSV/TSV export and the report's "
            "SHA-256 instead\n"
        )
        return 1
    print("tracked_artifacts=accepted suffixes=%d" % len(FORBIDDEN_SUFFIXES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
