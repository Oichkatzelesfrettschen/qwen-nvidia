#!/usr/bin/env python3
"""Read what a graft --deep pass left in a graph directory.

graft stores the meaning layer on the wiring nodes themselves: `.graph/
wiring.json` carries one record per symbol with `summary_state`, `summary`
and `crux`. A node the model never described keeps the `pending` state
graph/extract.js gives it, and graph/enrich.js promotes a node to `ready`
only after a record_symbols entry arrives for its id. Counting states is
therefore the direct measure of how much of the graph a checkpoint filled.

The crux counts stop short of fidelity on purpose. buildCrux clamps a
returned span into the node's own range with
`Math.max(nodeStart, Math.min(r.crux_start, nodeEnd))` before storing it,
so every stored crux lies inside its symbol whatever the model answered.
The boundary counts say where a stored span landed.
`crux_at_node_start` is the signature of a model that answered with the
whole definition the prompt forbids, since a span that opens before the
symbol and one that opens on its first line both clamp to that line.
`crux_at_node_end` is the same fact at the other edge. `crux_interior`
names a span that chose a focus inside the definition, which no clamp can
produce. Each is a lead, not a verdict, and span fidelity is measured on
the unclamped wire by admit-record-symbols.sh.

    usage: graft-deep-evidence.py GRAPH_DIRECTORY
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SPAN = re.compile(r"^L(\d+)-L(\d+)$")


def span_bounds(span: object) -> tuple[int, int] | None:
    """Return the inclusive line pair a graft span names, or None."""
    if not isinstance(span, str):
        return None
    hit = SPAN.match(span)
    if hit is None:
        return None
    return int(hit.group(1)), int(hit.group(2))


def read(graph_directory: Path) -> dict[str, object]:
    """Count node states and crux placement in one graph directory."""
    wiring = graph_directory / ".graph" / "wiring.json"
    counts: dict[str, object] = {
        "files": 0,
        "function_nodes": 0,
        "ready": 0,
        "pending": 0,
        "stale": 0,
        "other_state": 0,
        "summary_empty": 0,
        "crux_present": 0,
        "crux_null": 0,
        "crux_unparsed": 0,
        "crux_at_node_start": 0,
        "crux_at_node_end": 0,
        "crux_interior": 0,
    }
    if not wiring.is_file():
        counts["verdict"] = "rejected"
        counts["rejecting"] = f"no wiring graph at {wiring.name}"
        return counts
    try:
        graph = json.loads(wiring.read_text(encoding="utf-8"))
        nodes = graph["nodes"]
    except (ValueError, KeyError, OSError) as error:
        counts["verdict"] = "rejected"
        counts["rejecting"] = f"the wiring graph does not parse: {error}"
        return counts

    for node in nodes:
        if not isinstance(node, dict):
            continue
        kind = node.get("kind")
        if kind == "file":
            counts["files"] = int(counts["files"]) + 1
            continue
        if kind not in ("function", "class", "type"):
            continue
        counts["function_nodes"] = int(counts["function_nodes"]) + 1
        state = node.get("summary_state")
        if state in ("ready", "pending", "stale"):
            counts[str(state)] = int(counts[str(state)]) + 1
        else:
            counts["other_state"] = int(counts["other_state"]) + 1
        if state == "ready":
            summary = node.get("summary")
            if not isinstance(summary, str) or not summary.strip():
                counts["summary_empty"] = int(counts["summary_empty"]) + 1
        crux = node.get("crux")
        if crux is None:
            counts["crux_null"] = int(counts["crux_null"]) + 1
            continue
        counts["crux_present"] = int(counts["crux_present"]) + 1
        node_bounds = span_bounds(node.get("span"))
        crux_bounds = span_bounds(crux.get("span") if isinstance(crux, dict) else None)
        if node_bounds is None or crux_bounds is None:
            counts["crux_unparsed"] = int(counts["crux_unparsed"]) + 1
            continue
        at_start = crux_bounds[0] == node_bounds[0]
        at_end = crux_bounds[1] == node_bounds[1]
        if at_start:
            counts["crux_at_node_start"] = int(counts["crux_at_node_start"]) + 1
        if at_end:
            counts["crux_at_node_end"] = int(counts["crux_at_node_end"]) + 1
        if not at_start and not at_end:
            counts["crux_interior"] = int(counts["crux_interior"]) + 1

    if int(counts["function_nodes"]) == 0:
        counts["verdict"] = "rejected"
        counts["rejecting"] = "the graph carries no describable symbol"
    elif int(counts["summary_empty"]) > 0:
        counts["verdict"] = "rejected"
        counts["rejecting"] = (
            f"{counts['summary_empty']} nodes read ready with an empty summary"
        )
    elif int(counts["other_state"]) > 0:
        counts["verdict"] = "rejected"
        counts["rejecting"] = (
            f"{counts['other_state']} nodes carry a state graft does not write"
        )
    elif int(counts["pending"]) > 0 or int(counts["stale"]) > 0:
        counts["verdict"] = "incomplete"
        counts["rejecting"] = (
            f"{counts['pending']} pending and {counts['stale']} stale nodes"
        )
    else:
        counts["verdict"] = "accepted"
    return counts


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: graft-deep-evidence.py GRAPH_DIRECTORY\n")
        return 2
    for key, value in read(Path(argv[1])).items():
        sys.stdout.write(f"{key}\t{value}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
