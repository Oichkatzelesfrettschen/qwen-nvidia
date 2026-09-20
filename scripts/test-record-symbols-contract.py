#!/usr/bin/env python3
"""Calibrate record-symbols-contract.py against known-good and known-bad input.

The case that motivates the file is `collapsed_ids_rejected`: a graph holding
two nodes over one name produces two target rows, and a reply carrying one
entry per row grades as a pass. Under a target set keyed on the bare name the
same reply grades as a fail with two spans out of range, which is the reading
that PR #79 published and evidence/ada/graft-deep-pilot/README.md withdraws.
"""

import importlib.util
import json
import os
import sys
import tempfile

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "record_symbols_contract", os.path.join(_here, "record-symbols-contract.py")
)
CONTRACT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(CONTRACT)

FAILURES = []


def graph(nodes):
    return {"meta": {}, "nodes": nodes, "edges": []}


def node(nid, span, signature="void f(void)", kind="function", path="a.c"):
    return {"id": nid, "name": nid.split("#")[-1], "kind": kind, "path": path,
            "span": span, "signature": signature}


def reply(entries, name="record_symbols", finish="tool_calls"):
    """A served reply: a completed call to the named tool. The nominal fixture
    carries `finish_reason`, so a case turning it into `length` tests the
    truncation rule rather than the absence of the field."""
    return {"choices": [{"finish_reason": finish, "message": {"tool_calls": [{"function": {
        "name": name,
        "arguments": json.dumps({"symbols": entries})}}]}}]}


def entry(nid, summary="What it is for.", start=0, end=0):
    return {"id": nid, "summary": summary, "crux_start": start, "crux_end": end}


def run(name, rows, sent, want_outcome, tool="record_symbols", finish="tool_calls",
        status="200", **want_fields):
    """`sent` is the reply's entry list; `want_fields` names graded columns,
    one of which is `entries`, so the two cannot share a parameter name."""
    with tempfile.TemporaryDirectory() as tmp:
        answer = os.path.join(tmp, "answer.json")
        with open(answer, "w", encoding="utf-8") as handle:
            json.dump(reply(sent, tool, finish), handle)
        line = CONTRACT.check(answer, rows, "m", "a.c", "1", status)
    got = dict(zip(CONTRACT.COLUMNS, line.split("\t")))
    problems = []
    if got["outcome"] != want_outcome:
        problems.append(f"outcome {got['outcome']} != {want_outcome}")
    for key, value in want_fields.items():
        if got[key] != str(value):
            problems.append(f"{key} {got[key]} != {value}")
    report(name, problems)


def report(name, problems):
    if problems:
        FAILURES.append(name)
        print(f"  FAIL {name}: {'; '.join(problems)}")
    else:
        print(f"  ok   {name}")


def targets_from(nodes, rel="a.c"):
    with tempfile.TemporaryDirectory() as tmp:
        graph_path = os.path.join(tmp, "wiring.json")
        with open(graph_path, "w", encoding="utf-8") as handle:
            json.dump(graph(nodes), handle)
        return CONTRACT.load_targets(graph_path, rel)


def main():
    print("target extraction")

    # Two nodes over one name stay two rows, each keeping its own range.
    rows = targets_from([node("a.c#f", "L10-L20"), node("a.c#f~2", "L40-L50")])
    report("duplicate_name_keeps_two_rows",
           [] if [r["id"] for r in rows] == ["a.c#f", "a.c#f~2"] else [f"got {rows}"])

    # A prototype's one-line span is correct and stays gradeable.
    rows = targets_from([node("a.c#p", "L5-L5", "static void p(void);")])
    report("prototype_span_gradeable", [] if rows[0]["gradeable"] else ["marked ungradeable"])

    # A definition reported as one line is the extractor truncating it.
    rows = targets_from([node("a.c#d", "L5-L5", "d(struct proc *p)")])
    report("truncated_definition_ungradeable",
           [] if not rows[0]["gradeable"] else ["marked gradeable"])

    # A span covering a later node's start line swallows that node.
    rows = targets_from([node("a.c#wide", "L10-L90"), node("a.c#inner", "L40-L50")])
    wide = [r for r in rows if r["id"] == "a.c#wide"][0]
    inner = [r for r in rows if r["id"] == "a.c#inner"][0]
    report("over_broad_span_ungradeable",
           ([] if not wide["gradeable"] else ["wide marked gradeable"])
           + ([] if inner["gradeable"] else ["inner marked ungradeable"]))

    # The file node describes no symbol and must not become a target or make
    # every symbol in the file read as contained.
    rows = targets_from([node("a.c", "L1-L99", "", kind="file"), node("a.c#f", "L10-L20")])
    report("file_node_excluded",
           ([] if len(rows) == 1 else [f"{len(rows)} rows"])
           + ([] if rows and rows[0]["gradeable"] else ["symbol marked ungradeable"]))

    print("grading")
    two = targets_from([node("a.c#f", "L10-L20"), node("a.c#f~2", "L40-L50")])
    one_each = [entry("a.c#f", start=11, end=12), entry("a.c#f~2", start=41, end=42)]

    run("one_entry_per_row_passes", two, one_each, "pass",
        targets=2, entries=2, id_exact=2, crux_in_range=2, crux_bad=0)

    # The published reading: the second occurrence's range grades the first.
    run("collapsed_ids_rejected", two,
        [entry("a.c#f", start=41, end=42), entry("a.c#f~2", start=41, end=42)],
        "fail", crux_bad=1, crux_in_range=1)

    run("missing_id_fails", two, [one_each[0]], "fail", id_missing=1, entries=1)
    run("invented_id_fails", two, one_each + [entry("a.c#ghost")], "fail",
        id_invented=1, entries=3)
    run("duplicate_entry_fails", two, one_each + [entry("a.c#f", start=11, end=12)],
        "fail", id_duplicate=1, entries=3)

    # A blank summary is what enrich rejects, so the gate rejects it too.
    run("blank_summary_fails", two,
        [entry("a.c#f", summary="   ", start=11, end=12), one_each[1]],
        "fail", summary_blank=1)
    run("absent_summary_fails", two,
        [{"id": "a.c#f", "crux_start": 11, "crux_end": 12}, one_each[1]],
        "fail", summary_blank=1)

    run("span_outside_range_fails", two,
        [entry("a.c#f", start=99, end=99), one_each[1]], "fail", crux_bad=1)
    run("inverted_span_fails", two,
        [entry("a.c#f", start=15, end=11), one_each[1]], "fail", crux_bad=1)
    run("zero_span_accepted", two,
        [entry("a.c#f", start=0, end=0), one_each[1]], "pass", crux_zero=1, crux_in_range=1)

    # A boolean satisfies isinstance(x, int); a line number that is not an
    # integer is malformed whatever Python's type lattice says.
    run("boolean_span_fails", two,
        [entry("a.c#f", start=True, end=True), one_each[1]], "fail", crux_bad=1)
    run("fractional_span_fails", two,
        [entry("a.c#f", start=11.5, end=12), one_each[1]], "fail", crux_bad=1)
    run("string_span_fails", two,
        [entry("a.c#f", start="11", end="12"), one_each[1]], "fail", crux_bad=1)

    # An ungradeable reference withholds containment and decides nothing.
    ungradeable = targets_from([node("a.c#d", "L5-L5", "d(struct proc *p)")])
    run("ungradeable_span_not_counted_bad", ungradeable,
        [entry("a.c#d", start=5, end=9)], "pass", crux_ungradeable=1, crux_bad=0,
        crux_in_range=0)
    run("absent_span_on_ungradeable_counts_zero", ungradeable,
        [entry("a.c#d", start=0, end=0)], "pass", crux_zero=1, crux_ungradeable=0)

    # graft normalizes a non-string summary to "" and then rejects it, so a
    # gate reading str(value) would pass what graft leaves pending.
    run("numeric_summary_is_blank", two,
        [{"id": "a.c#f", "summary": 7, "crux_start": 11, "crux_end": 12}, one_each[1]],
        "fail", summary_blank=1)
    run("null_summary_is_blank", two,
        [{"id": "a.c#f", "summary": None, "crux_start": 11, "crux_end": 12}, one_each[1]],
        "fail", summary_blank=1)

    # An interval that could not be right against any symbol is malformed
    # whatever the reference is worth.
    run("inverted_span_on_ungradeable_is_bad", ungradeable,
        [entry("a.c#d", start=9, end=5)], "fail", crux_bad=1, crux_ungradeable=0)
    run("negative_span_on_ungradeable_is_bad", ungradeable,
        [entry("a.c#d", start=-3, end=-1)], "fail", crux_bad=1, crux_ungradeable=0)
    run("half_zero_span_is_bad", two,
        [entry("a.c#f", start=0, end=12), one_each[1]], "fail", crux_bad=1)

    print("transport")
    run("truncated_completion_refused", two, one_each, "truncated", finish="length")
    run("non_200_with_a_valid_body_refused", two, one_each, "http_500", status="500")
    run("wrong_tool_refused", two, one_each, "wrong_tool", tool="record_probe")
    run("stop_finish_accepted", two, one_each, "pass", finish="stop")

    with tempfile.TemporaryDirectory() as tmp:
        answer = os.path.join(tmp, "answer.json")
        with open(answer, "w", encoding="utf-8") as handle:
            json.dump({"choices": [{"finish_reason": "stop",
                                    "message": {"content": "here you go"}}]}, handle)
        got = CONTRACT.check(answer, two, "m", "a.c", "1", "200").split("\t")
        report("no_tool_call_reported", [] if got[-1] == "no_call" else [got[-1]])
        with open(answer, "w", encoding="utf-8") as handle:
            handle.write("not json")
        got = CONTRACT.check(answer, two, "m", "a.c", "1", "transport").split("\t")
        report("transport_failure_reported",
               [] if got[-1] == "http_transport" else [got[-1]])

    print("request")
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "a.c")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write("\n".join(f"line {i}" for i in range(1, 60)))
        body = CONTRACT.build_request(source, "a.c", two, 4096)
        user = body["messages"][1]["content"]
        problems = []
        if "TARGETS (2 - return all 2" not in user:
            problems.append("count does not match the row list")
        for nid in ("id=a.c#f ", "id=a.c#f~2 "):
            if nid not in user:
                problems.append(f"{nid} absent")
        if body["tool_choice"] != "required":
            problems.append("tool_choice changed")
        report("request_counts_every_row", problems)

    name = "test_record_symbols_contract"
    print(f"{name}: {'ACCEPTED' if not FAILURES else f'REJECTED ({len(FAILURES)} failures)'}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
