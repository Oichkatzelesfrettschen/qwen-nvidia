#!/usr/bin/env python3
"""Calibrate graft-deep-evidence.py against graphs it must accept and refuse.

A reader that accepts every graph reports nothing, so each verdict is put
against a graph that earns it: a filled graph, a graph with a symbol the
model never described, a graph whose node claims ready over an empty
summary, a graph with no describable symbol at all, and a wiring file that
is absent or unparseable. The crux counts are calibrated the same way,
against a span that touches its node's boundary and one that does not.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "graft_deep_evidence", HERE / "graft-deep-evidence.py"
)
assert SPEC is not None and SPEC.loader is not None
EVIDENCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVIDENCE)

FAILURES = 0


def node(name, state="ready", summary="What it is for.", span="L10-L40", crux="L12-L16"):
    """One wiring node in the shape graph/extract.js writes."""
    return {
        "id": f"f.c#{name}",
        "name": name,
        "kind": "function",
        "path": "f.c",
        "span": span,
        "summary_state": state,
        "summary": summary,
        "crux": None if crux is None else {"code": "x;", "span": crux},
    }


FILE_NODE = {"id": "f.c", "name": "f.c", "kind": "file", "path": "f.c",
             "span": "L1-L80", "summary_state": "ready", "summary": "A file.",
             "crux": None}


def case(name, graph, expect_verdict, expect_counts=None, write_wiring=True):
    """Run the reader over one graph and hold it to a stated verdict."""
    global FAILURES
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory) / "graph"
        if write_wiring:
            (root / ".graph").mkdir(parents=True)
            body = graph if isinstance(graph, str) else json.dumps(graph)
            (root / ".graph" / "wiring.json").write_text(body, encoding="utf-8")
        else:
            root.mkdir(parents=True)
        got = EVIDENCE.read(root)
    if got.get("verdict") != expect_verdict:
        print(f"FAIL {name}: verdict {got.get('verdict')}, expected "
              f"{expect_verdict} ({got.get('rejecting', '-')})", file=sys.stderr)
        FAILURES += 1
        return
    for key, want in (expect_counts or {}).items():
        if got.get(key) != want:
            print(f"FAIL {name}: {key} is {got.get(key)}, expected {want}",
                  file=sys.stderr)
            FAILURES += 1
            return
    print(f"ok {name}")


def main():
    # A graph whose every symbol carries a state graft only writes after a
    # record_symbols entry arrived for that id.
    case("filled_graph_accepted",
         {"nodes": [FILE_NODE, node("a"), node("b"), node("c")]},
         "accepted", {"function_nodes": 3, "ready": 3, "files": 1})

    # A symbol the model never described keeps the pending state extract.js
    # gave it, which is exactly what a dropped id looks like in the graph.
    case("pending_symbol_incomplete",
         {"nodes": [FILE_NODE, node("a"), node("b", state="pending",
                                               summary=None, crux=None)]},
         "incomplete", {"pending": 1, "ready": 1})

    # enrich.js writes stale when a body moved under a summary; the graph is
    # as unfinished as a pending one and says so.
    case("stale_symbol_incomplete",
         {"nodes": [FILE_NODE, node("a", state="stale")]},
         "incomplete", {"stale": 1})

    # A node that claims ready over an empty summary is a false record, not a
    # thin one, because the state asserts a description that is not there.
    case("empty_summary_rejected",
         {"nodes": [FILE_NODE, node("a", summary="   ")]},
         "rejected", {"summary_empty": 1})

    # Nothing was measured, so nothing is accepted.
    case("no_symbols_rejected", {"nodes": [FILE_NODE]}, "rejected")

    # A state graft never writes means the file was edited or written by
    # something else, and the counts beneath it carry no authority.
    case("unknown_state_rejected",
         {"nodes": [FILE_NODE, node("a", state="described")]},
         "rejected", {"other_state": 1})

    case("absent_wiring_rejected", {"nodes": []}, "rejected", None, False)
    case("unparsed_wiring_rejected", "{not json", "rejected")
    case("wiring_without_nodes_rejected", {"meta": {}}, "rejected")

    # buildCrux clamps a span to the node boundary, so a boundary-touching
    # crux is counted and a strictly interior one is not.
    case("crux_at_node_start_counted",
         {"nodes": [FILE_NODE, node("a", span="L10-L40", crux="L10-L14")]},
         "accepted", {"crux_at_node_start": 1, "crux_interior": 0})
    case("crux_at_node_end_counted",
         {"nodes": [FILE_NODE, node("a", span="L10-L40", crux="L36-L40")]},
         "accepted", {"crux_at_node_end": 1, "crux_interior": 0})
    case("interior_crux_counted",
         {"nodes": [FILE_NODE, node("a", span="L10-L40", crux="L12-L16")]},
         "accepted", {"crux_interior": 1, "crux_at_node_start": 0})
    case("absent_crux_counted_null",
         {"nodes": [FILE_NODE, node("a", crux=None)]},
         "accepted", {"crux_null": 1, "crux_present": 0})
    case("unparsed_crux_span_counted",
         {"nodes": [FILE_NODE, node("a", crux="lines 12 to 16")]},
         "accepted", {"crux_unparsed": 1, "crux_interior": 0})

    if FAILURES:
        print(f"test_graft_deep_evidence: REJECTED ({FAILURES} failures)",
              file=sys.stderr)
        sys.exit(1)
    print("test_graft_deep_evidence: ACCEPTED")
    sys.exit(0)


if __name__ == "__main__":
    main()
