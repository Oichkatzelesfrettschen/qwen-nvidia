#!/usr/bin/env python3
"""Regrade the retained record_symbols replies against per-occurrence targets.

The wire run behind evidence/ada/graft-deep-pilot built its expected set as a
dictionary keyed on the bare symbol name. swapram.c lists `sr_poke` twice (a
prototype at L72 and its definition at L782-L787) and `sr_offset_t` twice (two
typedefs under opposite preprocessor branches), so 36 requested rows became 34
expected keys: a reply carrying exactly one entry per requested row was graded
as 36 entries against 34 targets, and each surviving key's range graded the
occurrence it had overwritten. This reads the same retained bytes with every
occurrence kept.

Assignment is by containment and is decided by the reply, not chosen here: an
entry whose span lies inside exactly one of the rows carrying its name belongs
to that row. Where no row or more than one row contains it the occurrence is
undetermined on the wire and the span is reported `crux_ungradeable` rather
than resolved by position.

Gradeability follows record-symbols-contract.py and is read from the source
embedded in the retained request, so the judgment stands on the bytes the model
saw rather than on the tree as it stands now:

  A one-line row whose source line carries no trailing semicolon is a
  definition the extractor truncated to its name line, and it rejects every
  span inside the real body.

  A row covering another row's start line runs past its own end, and it
  accepts a span sitting inside a different symbol.

    usage: regrade-record-symbols-wire.py WIRE_DIRECTORY
"""

import importlib.util
import json
import os
import re
import sys

# One acceptance predicate, shared. A summary this reads as present and a span
# this reads as well formed must be the same ones record-symbols-contract.py
# reads that way, or the two graders disagree about the same bytes.
_spec = importlib.util.spec_from_file_location(
    "record_symbols_contract",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "record-symbols-contract.py"),
)
CONTRACT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(CONTRACT)

COLUMNS = (
    "model file targets entries id_exact id_missing id_invented id_duplicate "
    "summary_blank crux_in_range crux_zero crux_bad crux_ungradeable outcome"
).split()


def source_lines(request_path):
    """Recover the numbered source the request carried, as a 1-based list."""
    body = json.load(open(request_path, encoding="utf-8"))
    user = body["messages"][1]["content"]
    lines = {}
    for line in user.split("\n"):
        m = re.match(r"^(\d+)\t(.*)$", line)
        if m:
            lines[int(m.group(1))] = m.group(2)
    return lines


def load_rows(targets_path, lines):
    rows = []
    for line in open(targets_path, encoding="utf-8").read().split("\n"):
        if not line.strip():
            continue
        name, kind, start, end = line.split("\t")[:4]
        rows.append({"name": name, "kind": kind, "start": int(start), "end": int(end)})
    starts = [r["start"] for r in rows]
    for row in rows:
        truncated = row["start"] == row["end"] and not lines.get(
            row["start"], ""
        ).rstrip().endswith(";")
        broad = any(row["start"] < other <= row["end"] for other in starts)
        row["gradeable"] = not (truncated or broad)
    return rows


def grade(rows, symbols, model, rel):
    by_name = {}
    for row in rows:
        by_name.setdefault(row["name"], []).append(row)
    entries = [s for s in symbols if isinstance(s, dict)]
    seen = [s.get("id") for s in entries]
    names = {r["name"] for r in rows}
    invented = sorted({i for i in seen if i not in names})
    missing = sorted(n for n in names if n not in seen)
    # One entry per row: a name listed twice expects two entries, so a count
    # below its row count is a dropped occurrence and above it a duplicate.
    duplicate = sorted(n for n in names if seen.count(n) > len(by_name[n]))
    blank = sum(1 for s in entries if s.get("id") in names and not CONTRACT.summary_text(s))

    in_range = zero = bad = ungradeable = 0
    for s in entries:
        candidates = by_name.get(s.get("id"))
        if not candidates:
            continue
        a, b = s.get("crux_start"), s.get("crux_end")
        shape = CONTRACT.span_shape(a, b)
        if shape == "malformed":
            bad += 1
            continue
        if shape == "absent":
            zero += 1
            continue
        a, b = int(a), int(b)
        holding = [r for r in candidates if r["start"] <= a <= b <= r["end"]]
        if len(candidates) > 1 and len(holding) != 1:
            ungradeable += 1
        elif not all(r["gradeable"] for r in (holding or candidates)):
            ungradeable += 1
        elif holding:
            in_range += 1
        else:
            bad += 1

    ok = not missing and not invented and not duplicate and blank == 0 and bad == 0
    ok = ok and len(entries) == len(symbols) == len(rows)
    return [
        model, rel, len(rows), len(symbols), sum(1 for i in seen if i in names),
        len(missing), len(invented), len(duplicate), blank,
        in_range, zero, bad, ungradeable, "pass" if ok else "fail",
    ]


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__)
    wire = argv[1]
    old = os.path.join(wire, "symbols.tsv")
    order = []
    for line in open(old, encoding="utf-8").read().split("\n")[1:]:
        field = line.split("\t")
        if len(field) > 2 and field[0] != "symbols_done":
            order.append((field[0], field[1]))

    print("\t".join(COLUMNS))
    for model, rel in order:
        stem = rel.replace("/", "_")
        lines = source_lines(os.path.join(wire, f"{stem}.request.json"))
        rows = load_rows(os.path.join(wire, f"{stem}.targets"), lines)
        answer = os.path.join(wire, f"{model}.{os.path.basename(rel)}.symbols.json")
        reply = json.load(open(answer, encoding="utf-8"))
        arguments = reply["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"]
        symbols = json.loads(arguments)["symbols"]
        print("\t".join(str(x) for x in grade(rows, symbols, model, rel)))


if __name__ == "__main__":
    main(sys.argv)
