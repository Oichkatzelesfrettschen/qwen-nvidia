#!/usr/bin/env python3
"""Refuse a wire protocol version written as a literal outside its module.

`scripts/physics_protocol.py` and `scripts/geometry_protocol.py` each define
`PROTOCOL_VERSION` and reject a message that does not carry it, so the
constant is the single authority for what the sidecar services speak. A
caller that writes the number instead agrees with the service only until the
schema moves: raising the physics protocol to 2 left
`scripts/admit-physics-runtime.sh` sending 1, which turns the next device
admission into a protocol refusal before the corrected runtime runs at all,
and the same literal sat in three geometry call sites waiting for the same
bump.

The rule is therefore absolute outside the protocol modules themselves: a
`"protocol"` key with an integer value is a finding, and a caller reads
`PROTOCOL_VERSION` from the module that owns the conversation. A protocol
identified by a name string rather than a number -- the image service's
`qwen-image-service/1` and the web broker's `qwen-web-broker/1` -- carries its
version inside an opaque identifier and is outside this gate.
"""

import pathlib
import re
import subprocess
import sys

LITERAL = re.compile(r'"protocol"\s*:\s*(\d+)')
DEFINITION = re.compile(r'^PROTOCOL_VERSION\s*=\s*(\d+)\s*$', re.M)
SCANNED_SUFFIXES = (".py", ".sh")


def tracked_paths(root):
    result = subprocess.run(
        ["git", "-C", str(root), "-c", "core.fsmonitor=false", "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    return [
        pathlib.Path(entry)
        for entry in result.stdout.decode("utf-8").split("\0")
        if entry
    ]


def protocol_modules(root, paths):
    """The modules that define the constant, mapped to the version they hold.

    A module whose name ends in _protocol.py without a PROTOCOL_VERSION
    definition is not an authority, so it is scanned like any other caller
    rather than exempted on its name.
    """
    modules = {}
    for path in paths:
        if not path.name.endswith("_protocol.py"):
            continue
        match = DEFINITION.search((root / path).read_text(encoding="utf-8"))
        if match:
            modules[path] = int(match.group(1))
    return modules


def main(argv):
    root = pathlib.Path(argv[1] if len(argv) > 1 else ".").resolve()
    paths = tracked_paths(root)
    modules = protocol_modules(root, paths)
    if not modules:
        sys.stderr.write(
            "protocol_version_authority=rejected reason=no_protocol_module\n"
            "the gate found no *_protocol.py defining PROTOCOL_VERSION, so a "
            "pass here would mean nothing was checked\n"
        )
        return 1

    offenders = []
    scanned = 0
    for path in paths:
        if path in modules or not path.name.endswith(SCANNED_SUFFIXES):
            continue
        try:
            text = (root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        for number, line in enumerate(text.splitlines(), start=1):
            for match in LITERAL.finditer(line):
                offenders.append((path, number, match.group(1)))

    if offenders:
        sys.stderr.write(
            "protocol_version_authority=rejected count=%d\n" % len(offenders)
        )
        for path, number, value in offenders:
            sys.stderr.write("  %s:%d writes %s\n" % (path, number, value))
        sys.stderr.write(
            "import PROTOCOL_VERSION from the protocol module the message "
            "belongs to; a literal agrees with the service only until the "
            "schema moves\n"
        )
        return 1

    print(
        "protocol_version_authority=accepted modules=%d versions=%s scanned=%d"
        % (
            len(modules),
            ",".join(
                "%s=%d" % (path.stem, version)
                for path, version in sorted(modules.items())
            ),
            scanned,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
