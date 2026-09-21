"""Reduce a crux attempt trace to one graded row per file and attempt.

A record reaches the graph only if its id matches a requested target and its
summary is non-blank, so a lost record has exactly one of three causes and the
trace carries enough to name it. `identity` means entries arrived under ids no
target claims and the targets stayed missing, `recovered` means they arrived
that way and the collector resolved them anyway, `blank` means the requested
ids arrived with no summary, `short` means the reply named fewer targets than
were asked for, and `complete` means every requested target came back
summarized under the id it was asked for.

usage: crux-identity-evidence.py TRACE [TRACE ...]
"""

import json
import pathlib
import sys

COLUMNS = ("file attempt requested parsed matched foreign summarized "
           "missing_after miss finish_reason outcome").split()


def classify(requested, parsed, matched, summarized, missing_after):
    if not parsed:
        return "silent"
    # An id resolved by the collector is not matched by the literal comparison
    # here, so the emptied retry set is what distinguishes a recovery from a
    # loss: the reply carried the defect and the graph did not.
    if matched < requested and not missing_after:
        return "recovered"
    if not matched:
        return "identity"
    if matched < requested:
        return "short"
    if not summarized:
        return "blank"
    if summarized < requested:
        return "partial"
    return "complete"


def rows(trace):
    for line in trace.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        requested = set(record["requested"])
        parsed = list(record["parsed"])
        matched = requested.intersection(parsed)
        summarized = requested.intersection(record["summarized"])
        yield {
            "file": record["path"],
            "attempt": record["attempt"],
            "requested": len(requested),
            "parsed": len(parsed),
            "matched": len(matched),
            "foreign": len([p for p in parsed if p not in requested]),
            "summarized": len(summarized),
            "missing_after": len(record["missing"]),
            "miss": record["miss"] or "-",
            "finish_reason": record["finish_reason"] or "-",
            "outcome": classify(len(requested), parsed, len(matched),
                                len(summarized), len(record["missing"])),
        }


def main(argv):
    print("\t".join(COLUMNS))
    for name in argv:
        for row in rows(pathlib.Path(name)):
            print("\t".join(str(row[column]) for column in COLUMNS))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
