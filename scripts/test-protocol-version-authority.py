#!/usr/bin/env python3
"""Fixture tests for scripts/check-protocol-version-authority.py.

Each arm builds a small indexed tree and reads the verdict, so the gate is
shown rejecting the literal it exists for, exempting the module that owns the
constant, admitting a name-string protocol, and refusing to pass a tree that
holds no authority at all.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

CHECKER = pathlib.Path(__file__).resolve().parent / "check-protocol-version-authority.py"

MODULE = 'PROTOCOL_VERSION = 2\n\n\ndef reply():\n    return {"protocol": PROTOCOL_VERSION}\n'


TREES = []


def build_tree(files):
    root = pathlib.Path(tempfile.mkdtemp(prefix="protocol-authority."))
    TREES.append(root)
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    return root


def run(root):
    result = subprocess.run(
        [sys.executable, str(CHECKER), str(root)],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout + result.stderr


def main():
    checks = []

    def check(name, passed, detail=""):
        checks.append((name, passed))
        if passed:
            print("check=%s outcome=pass" % name)
        else:
            sys.stderr.write("check=%s outcome=FAIL detail=%s\n" % (name, detail))

    code, output = run(build_tree({
        "scripts/thing_protocol.py": MODULE,
        "scripts/caller.py": "from thing_protocol import PROTOCOL_VERSION\n"
                             'MESSAGE = {"protocol": PROTOCOL_VERSION}\n',
    }))
    check("symbolic_caller_accepted", code == 0 and "accepted" in output, output)
    check("module_version_reported", "thing_protocol=2" in output, output)

    code, output = run(build_tree({
        "scripts/thing_protocol.py": MODULE,
        "scripts/admit-thing.sh": '#!/bin/sh\nprintf \'{"protocol": 2}\'\n',
    }))
    check(
        "literal_caller_rejected",
        code == 1 and "scripts/admit-thing.sh:2 writes 2" in output,
        output,
    )

    # The module's own construction of the reply is the definition site, so
    # exempting it is what keeps the gate from rejecting its own authority.
    code, output = run(build_tree({"scripts/thing_protocol.py": MODULE}))
    check("owning_module_exempt", code == 0, output)

    # A name-string protocol carries its version inside an identifier and is a
    # different scheme; flagging it would be a false verdict.
    code, output = run(build_tree({
        "scripts/thing_protocol.py": MODULE,
        "scripts/broker.py": 'HEADER = {"protocol": "qwen-web-broker/1"}\n',
    }))
    check("name_string_protocol_accepted", code == 0, output)

    # A _protocol.py that defines nothing is a caller wearing the name.
    code, output = run(build_tree({
        "scripts/thing_protocol.py": MODULE,
        "scripts/other_protocol.py": 'MESSAGE = {"protocol": 1}\n',
    }))
    check(
        "unauthoritative_module_scanned",
        code == 1 and "scripts/other_protocol.py:1 writes 1" in output,
        output,
    )

    code, output = run(build_tree({"scripts/caller.py": 'M = {"protocol": 1}\n'}))
    check(
        "empty_authority_rejected",
        code == 1 and "no_protocol_module" in output,
        output,
    )

    failed = [name for name, passed in checks if not passed]
    print("checks_total=%d checks_failed=%d" % (len(checks), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        status = main()
    finally:
        for tree in TREES:
            shutil.rmtree(tree, ignore_errors=True)
    sys.exit(status)
