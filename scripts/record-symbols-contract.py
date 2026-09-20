#!/usr/bin/env python3
"""Build and grade graft's record_symbols request against canonical node ids.

graft identifies a symbol by a path-scoped node id and disambiguates a name
that occurs twice in one file with a `~2` suffix, so a C file holding both a
prototype and its definition carries two distinct ids over the same name. A
target set keyed on the bare name collapses those two rows into one, which
sends a request for n targets and grades the reply against fewer than n: a
model that returns exactly one entry per requested row is recorded as having
overproduced, and the surviving row's line range grades the other row's span
as out of range. Reading the ids from `.graph/wiring.json` keeps each
occurrence distinct, which is the only way the count and the span reference
can both be right.

graft's generic C extractor misreports two span classes, and a span error is
graded against the reference before it is graded against the model:

  A definition whose return type sits on its own line reports start == end,
  because the extractor takes the name line for the whole definition.
  `sr_slot` spans L242-L250 in the source and L243-L243 in the graph. Its
  signature carries no trailing semicolon, which is what separates it from a
  prototype whose one-line span is correct.

  A definition can run past its own closing brace and swallow the functions
  after it. `swapram_evacuate` ends at L703 and the graph gives it L612-L854,
  covering ten later node starts. A span containing another node's start line
  is over-broad by that fact alone.

Neither class can grade a crux: the first rejects every span inside the real
body and the second accepts a span inside a different function. Both are
reported as `crux_ungradeable` rather than folded into the pass or the fail.

Both tests are suspicion, not proof, and they are written to withhold judgment
rather than to convict. A one-line function body is legal C and a nested or
inner definition legitimately sits inside an enclosing span, so either test
can withhold a reference that was correct. Withholding costs a span that would
have graded; the converse would charge the extractor's error to a model. The
pair is calibrated against this C corpus and carries no claim about another
language's extractor.
"""

import json
import re
import sys

SPAN = re.compile(r"^L(\d+)-L(\d+)$")
TOOL_NAME = "record_symbols"
MAX_CODE_CHARS = 18_000

COLUMNS = (
    "model file targets wall_ms called entries id_exact id_missing id_invented "
    "id_duplicate summary_blank crux_in_range crux_zero crux_bad "
    "crux_ungradeable outcome"
).split()


def parse_span(node):
    """Return (start, end) for a node carrying an `L<a>-L<b>` span, else None."""
    m = SPAN.match(node.get("span") or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def load_targets(graph_path, rel):
    """Return the describable nodes of one file, in span order, with gradeability.

    The file node itself spans the whole file and describes no symbol, so it
    carries no target row and takes no part in the over-breadth test.
    """
    graph = json.load(open(graph_path, encoding="utf-8"))
    nodes = []
    for node in graph.get("nodes", []):
        if node.get("path") != rel or node.get("kind") == "file":
            continue
        span = parse_span(node)
        if span:
            nodes.append((node, span))
    nodes.sort(key=lambda p: (p[1][0], p[1][1], p[0]["id"]))
    starts = [span[0] for _, span in nodes]
    rows = []
    for node, (start, end) in nodes:
        signature = (node.get("signature") or "").strip()
        truncated = start == end and not signature.endswith(";")
        broad = any(start < other <= end for other in starts)
        rows.append(
            {
                "id": node["id"],
                "kind": node.get("kind", ""),
                "start": start,
                "end": end,
                "signature": signature,
                "gradeable": not (truncated or broad),
            }
        )
    return rows


def write_targets(rows, out_path):
    with open(out_path, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(
                "\t".join(
                    (
                        row["id"],
                        row["kind"],
                        str(row["start"]),
                        str(row["end"]),
                        "yes" if row["gradeable"] else "no",
                        row["signature"].replace("\t", " "),
                    )
                )
                + "\n"
            )


def read_targets(path):
    rows = []
    for line in open(path, encoding="utf-8").read().split("\n"):
        if not line.strip():
            continue
        field = line.split("\t")
        rows.append(
            {
                "id": field[0],
                "kind": field[1],
                "start": int(field[2]),
                "end": int(field[3]),
                "gradeable": field[4] == "yes",
                "signature": field[5] if len(field) > 5 else "",
            }
        )
    return rows


def build_request(source_path, rel, rows, cap):
    """Mirror dist/ai/crux.js: one numbered file clipped at MAX_CODE_CHARS, then
    the target list by id with kind, line range and signature."""
    src = open(source_path, encoding="utf-8", errors="replace").read()
    if len(src) > MAX_CODE_CHARS:
        src = src[:MAX_CODE_CHARS] + "\n... (truncated)"
    numbered = "\n".join(f"{i + 1}\t{line}" for i, line in enumerate(src.split("\n")))
    targets = "\n".join(
        f"- id={r['id']} | {r['kind']} | lines L{r['start']}-L{r['end']}"
        + (f" | {r['signature']}" if r["signature"] else "")
        for r in rows
    )
    n = len(rows)
    system = (
        "You produce definitions for a code graph that helps engineers navigate "
        "a codebase.\n\nYou are given ONE source file with 1-based line numbers, "
        "and a list of TARGET definitions in it. Describe EVERY target via the "
        "record_symbols tool.\n\nRules:\n"
        "- Return EXACTLY ONE entry for EVERY target id, using that id verbatim. "
        "The number of entries you return MUST equal the number of targets.\n"
        "- summary: ONE sentence about what the symbol is FOR, not a restatement "
        "of its signature.\n"
        "- crux_start / crux_end: FILE line numbers, inside that symbol's own "
        "line range, at most about 8 lines, never the whole function. Where there "
        "is no single focal span, use crux_start 0 and crux_end 0."
    )
    user = f"FILE: {rel}\n\n{numbered}\n\nTARGETS ({n} - return all {n}, one entry per id):\n{targets}"
    schema = {
        "type": "object",
        "properties": {
            "symbols": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "summary": {"type": "string"},
                        "crux_start": {"type": "number"},
                        "crux_end": {"type": "number"},
                    },
                    "required": ["id", "summary", "crux_start", "crux_end"],
                },
            }
        },
        "required": ["symbols"],
    }
    return {
        "model": "qwen-nvidia",
        "temperature": 0,
        "max_tokens": int(cap),
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "tools": [
            {
                "type": "function",
                "function": {
                    "name": TOOL_NAME,
                    "description": "Record one entry per target definition.",
                    "parameters": schema,
                },
            }
        ],
        "tool_choice": "required",
    }


def summary_text(entry):
    """The summary graft would keep. crux.js normalizes a non-string summary to
    the empty string before enrich.js rejects it on `!r.summary.trim()`, so a
    numeric or null summary is blank at graft's boundary. A gate reading
    `str(value)` instead would accept `summary: 7` here and watch graft leave
    the node pending, which is the same disagreement between two acceptance
    rules that leaves an id retired from the retry and then discarded."""
    value = entry.get("summary")
    return value.strip() if isinstance(value, str) else ""


def span_shape(a, b):
    """Classify a returned interval by its own form, before any reference.

    bool is an int in Python, so a boolean line number passes a naive numeric
    test. `0/0` is the documented absence of a focal span. Every other pair has
    to be whole, positive and ordered; that judgment needs no target range, so
    a reference the extractor got wrong withholds containment alone and does
    not excuse an interval that could not be right against any symbol.
    """
    whole = all(
        isinstance(v, (int, float)) and not isinstance(v, bool) and float(v).is_integer()
        for v in (a, b)
    )
    if not whole:
        return "malformed"
    a, b = int(a), int(b)
    if a == 0 and b == 0:
        return "absent"
    if a < 1 or b < a:
        return "malformed"
    return "present"


def check(answer_path, rows, model, rel, wall, status):
    """Grade one reply. A duplicate id is a failure rather than a silent
    overwrite, because one entry per id is the contract under test.

    Transport, completion and tool identity are read before the arguments,
    because a body that parses is not by itself a served answer: a non-200
    carrying a plausible object, a generation stopped at the token cap, and a
    different function whose arguments happen to hold a `symbols` list each
    produce entries this would otherwise grade as a model's reply.
    """
    want = {r["id"]: r for r in rows}
    if len(want) != len(rows):
        raise SystemExit(f"invalid target set: {len(rows)} rows, {len(want)} ids")

    def line(*field):
        return "\t".join(str(x) for x in (model, rel, len(rows), wall) + field)

    def refused(called, outcome):
        return line(called, "-", "-", "-", "-", "-", "-", "-", "-", "-", "-", outcome)

    try:
        choice = json.load(open(answer_path, encoding="utf-8"))["choices"][0]
        message = choice["message"]
    except Exception:
        return refused("-", f"http_{status}")
    if str(status) != "200":
        return refused("-", f"http_{status}")
    # A reply cut off at the token cap is graft's `truncated` miss class, and
    # the entries before the cut are not a complete answer to the request.
    if choice.get("finish_reason") == "length":
        return refused("-", "truncated")
    calls = message.get("tool_calls") or []
    if not calls:
        return line("no", 0, 0, len(rows), 0, 0, 0, 0, 0, 0, 0, "no_call")
    if (calls[0].get("function") or {}).get("name") != TOOL_NAME:
        return refused("yes", "wrong_tool")
    try:
        symbols = json.loads(calls[0]["function"]["arguments"])["symbols"]
        assert isinstance(symbols, list)
    except Exception:
        return refused("yes", "arguments_unparsed")

    entries = [s for s in symbols if isinstance(s, dict)]
    seen = [s.get("id") for s in entries]
    exact = sum(1 for i in seen if i in want)
    invented = sorted({i for i in seen if i not in want})
    missing = sorted(set(want) - set(seen))
    duplicate = sorted({i for i in seen if seen.count(i) > 1 and i in want})
    blank = sum(1 for s in entries if s.get("id") in want and not summary_text(s))

    in_range = zero = bad = ungradeable = 0
    for s in entries:
        row = want.get(s.get("id"))
        if row is None:
            continue
        a, b = s.get("crux_start"), s.get("crux_end")
        shape = span_shape(a, b)
        if shape == "malformed":
            bad += 1
        elif shape == "absent":
            zero += 1
        elif not row["gradeable"]:
            ungradeable += 1
        elif row["start"] <= int(a) <= int(b) <= row["end"]:
            in_range += 1
        else:
            bad += 1

    ok = (
        not missing
        and not invented
        and not duplicate
        and blank == 0
        and bad == 0
        and len(entries) == len(symbols) == len(rows)
    )
    return line(
        "yes",
        len(symbols),
        exact,
        len(missing),
        len(invented),
        len(duplicate),
        blank,
        in_range,
        zero,
        bad,
        ungradeable,
        "pass" if ok else "fail",
    )


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    command = argv[1]
    if command == "columns":
        print("\t".join(COLUMNS))
    elif command == "targets":
        graph, rel, out_path = argv[2:5]
        rows = load_targets(graph, rel)
        write_targets(rows, out_path)
        print(len(rows))
    elif command == "request":
        source_path, rel, targets_path, out_path, cap = argv[2:7]
        rows = read_targets(targets_path)
        json.dump(build_request(source_path, rel, rows, cap), open(out_path, "w"))
    elif command == "check":
        answer, targets_path, model, rel, wall, status = argv[2:8]
        print(check(answer, read_targets(targets_path), model, rel, wall, status))
    else:
        raise SystemExit(f"unknown command: {command}")


if __name__ == "__main__":
    main(sys.argv)
