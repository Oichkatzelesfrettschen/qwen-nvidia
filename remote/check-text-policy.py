#!/usr/bin/env python3
"""Reject emoji code points and invalid UTF-8 in tracked text artifacts."""

import pathlib
import subprocess
import sys

TEXT_SUFFIXES = {".md", ".py", ".sh", ".tsv", ".txt", ".yml", ".yaml"}
EMOJI_RANGES = (
    (0x1F1E6, 0x1F1FF),
    (0x1F300, 0x1FAFF),
    (0x2600, 0x27BF),
)


def is_emoji(character):
    code_point = ord(character)
    return any(start <= code_point <= end for start, end in EMOJI_RANGES)


def tracked_text_paths():
    result = subprocess.run(
        ["git", "-c", "core.fsmonitor=false", "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    for encoded_path in result.stdout.split(b"\0"):
        if not encoded_path:
            continue
        path = pathlib.Path(encoded_path.decode("utf-8"))
        if path.suffix.lower() in TEXT_SUFFIXES:
            yield path


def main():
    failures = 0
    for path in tracked_text_paths():
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as error:
            print(f"{path}: invalid UTF-8: {error}", file=sys.stderr)
            failures += 1
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            emoji_characters = sorted(
                {character for character in line if is_emoji(character)}
            )
            if emoji_characters:
                code_points = ",".join(
                    f"U+{ord(character):04X}" for character in emoji_characters
                )
                print(
                    f"{path}:{line_number}: prohibited emoji {code_points}",
                    file=sys.stderr,
                )
                failures += 1
    if failures:
        print(f"text_policy=rejected failures={failures}", file=sys.stderr)
        return 1
    print("text_policy=accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
