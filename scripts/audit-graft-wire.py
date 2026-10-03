"""Report source clipping and focal-span policy separately from ID completion.

Graft can request a symbol beyond its clipped source prefix. A complete tool
reply therefore establishes ID coverage rather than a source-grounded summary.
The containment grader also leaves focal-span length and whole-body selection
outside its verdict; this audit exposes those dimensions without changing the
served requests or treating an approximate length preference as exact syntax.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import re


SPECIFICATION = importlib.util.spec_from_file_location(
    "contract", Path(__file__).with_name("record-symbols-contract.py")
)
CONTRACT = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(CONTRACT)


def audit_request(request, response, graph):
    if request.get("tool_choice") != {
        "type": "function", "function": {"name": "record_symbols"}
    }:
        return None
    user = request["messages"][-1]["content"]
    relative_path = re.search(r"^FILE: (.+)$", user, re.MULTILINE).group(1)
    code = user.split("\nTARGETS", 1)[0]
    numbered = re.findall(r"^(\d+)\t(.*)$", code, re.MULTILINE)
    markers = {"... (truncated)", "\u2026 (truncated)"}
    clipped = bool(numbered and numbered[-1][1].strip() in markers)
    source_lines = numbered[:-1] if clipped else numbered
    source_end = max((int(line) for line, _text in source_lines), default=0)
    # Character clipping can cut the final numbered line in the middle.
    complete_prefix_end = source_end - int(clipped)
    references = {row["id"]: row for row in CONTRACT.load_targets(graph, relative_path)}
    targets = re.findall(r"^- id=(.*?) \| .*? \| lines L(\d+)-L(\d+)", user, re.MULTILINE)
    coverage = {name: [] for name in ("full", "partial", "absent")}
    for identifier, start, end in targets:
        if identifier not in references:
            continue
        category = "full" if int(end) <= complete_prefix_end else (
            "partial" if int(start) <= source_end else "absent"
        )
        coverage[category].append(identifier)
    calls = (response.get("choices") or [{}])[0].get("message", {}).get("tool_calls") or []
    result = {"file": relative_path, "source_end": source_end,
              "source_clipped": clipped, "complete_prefix_end": complete_prefix_end,
              "source_coverage": coverage,
              "tool_call_count": len(calls), "over_eight_lines": [],
              "whole_gradeable_definition": [], "unparsed_calls": 0}
    for call in calls:
        function = call.get("function") or {}
        if function.get("name") != "record_symbols":
            continue
        try:
            entries = json.loads(function["arguments"])["symbols"]
        except (KeyError, TypeError, ValueError):
            result["unparsed_calls"] += 1
            continue
        if not isinstance(entries, list):
            result["unparsed_calls"] += 1
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            row = references.get(entry.get("id"))
            start, end = entry.get("crux_start"), entry.get("crux_end")
            if row is None or CONTRACT.span_shape(start, end) != "present":
                continue
            if int(end) - int(start) + 1 > 8:
                result["over_eight_lines"].append(entry["id"])
            if (row["gradeable"] and row["end"] > row["start"]
                    and int(start) == row["start"] and int(end) == row["end"]):
                result["whole_gradeable_definition"].append(entry["id"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arm", type=Path)
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    graph = options.arm / "graph/.graph/wiring.json"
    records = json.loads((options.arm / "requests.json").read_text())
    rows = []
    for record in records:
        stem = options.arm / f"wire-{record['request_id']:04d}"
        request = json.loads(stem.with_suffix(".request.json").read_text())
        try:
            response = json.loads(stem.with_suffix(".response.json").read_text())
        except (OSError, ValueError):
            response = {}
        result = audit_request(request, response, graph)
        if result is not None:
            rows.append({"request_id": record["request_id"],
                         "status": record.get("status", "capture_incomplete"),
                         "capture_complete": "status" in record and "ended" in record,
                         **result})
    options.output.write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
