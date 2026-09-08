#!/usr/bin/env python3
"""Copy text for publication and refuse private workstation identifiers in Git."""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


HOME_PATH = re.compile(
    r"(?<![A-Za-z0-9_$])/(?:home|Users)/[A-Za-z0-9_.-]+(?=/|[\s\"':,]|$)"
)
WINDOWS_HOME = re.compile(r"[A-Za-z]:\\{1,2}Users\\{1,2}[A-Za-z0-9_.-]+")
IDENTITY_FIELD = re.compile(
    r'(?im)([\"\']?(?:username|user_name|hostname|host_name)[\"\']?\s*[:=]\s*)'
    r'([\"\']?)([A-Za-z0-9_.-]+)(\2)'
)
PUBLIC_IDENTITIES = {"qwen-laptop", "redacted", "unavailable"}


def sanitize(text):
    text = HOME_PATH.sub(lambda match: "$HOME", text)
    text = WINDOWS_HOME.sub(lambda match: "$HOME", text)

    def identity(match):
        if match[3] in PUBLIC_IDENTITIES:
            return match[0]
        return match[1] + match[2] + "redacted" + match[4]

    return IDENTITY_FIELD.sub(identity, text)


def read_text(path):
    payload = path.read_bytes()
    if b"\0" in payload:
        raise ValueError("binary input requires a sanitized text export")
    return payload.decode("utf-8")


def copy_sanitized(source, destination):
    if source.resolve() == destination.resolve():
        raise ValueError("source and destination must differ; preserve the raw record")
    if destination.exists():
        raise ValueError("destination exists; choose a fresh publication copy")
    text = sanitize(read_text(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".sanitize-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(text)
        # Publish only into an absent name; a racing writer remains intact.
        os.link(temporary, destination)
    finally:
        os.unlink(temporary)


def check_repository():
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    tracked = subprocess.check_output(
        ["git", "-C", str(root), "-c", "core.fsmonitor=false", "ls-files", "-z"]
    )
    failures = 0
    checked = 0
    for entry in tracked.split(b"\0"):
        if not entry:
            continue
        relative = Path(os.fsdecode(entry))
        path = root / relative
        if relative.parts[0] == ".local-artifacts":
            print(f"{relative}: local artifacts must stay untracked", file=sys.stderr)
            failures += 1
            continue
        try:
            # Retained token logs can end inside a UTF-8 sequence. Surrogate
            # escape preserves every byte while the ASCII identity patterns
            # inspect text and embedded binary strings through the same path.
            text = path.read_bytes().decode("utf-8", errors="surrogateescape")
        except OSError as error:
            print(f"{relative}: unreadable publication text ({type(error).__name__})", file=sys.stderr)
            failures += 1
            continue
        checked += 1
        if sanitize(text) != text:
            # A diagnostic names the file, never the private value it refused.
            print(f"{relative}: workstation identifier requires sanitization", file=sys.stderr)
            failures += 1
    print(f"publication_sanitization={'rejected' if failures else 'accepted'} files={checked} failures={failures}")
    return int(bool(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("destination", type=Path, nargs="?")
    arguments = parser.parse_args()
    if arguments.check:
        if arguments.source or arguments.destination:
            parser.error("--check takes no paths")
        return check_repository()
    if arguments.source is None or arguments.destination is None:
        parser.error("provide SOURCE DESTINATION or --check")
    try:
        copy_sanitized(arguments.source, arguments.destination)
    except (OSError, ValueError):
        print("publication_copy=refused reason=invalid_input_or_destination", file=sys.stderr)
        return 1
    print("publication_copy=written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
