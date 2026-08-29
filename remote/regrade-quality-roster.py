#!/usr/bin/env python3
"""Re-grade retained quality records against the current grader.

A grader defect found after a sweep leaves two claims in the tree: what the
harness reported, and what the corrected rule says about the same replies. This
reads the retained arm records, re-applies grade() to the reply each row already
holds, and reports the two totals beside each other. The records stay untouched,
because they are the measurement; this produces the derived claim.

A row re-grades only when the record carries the reply. A record written by an
older harness that dropped the content field is reported as unregradable rather
than silently counted as a pass.
"""

import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load_grader(path):
    specification = importlib.util.spec_from_file_location("quality_suite", path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def regrade_arm(module, document):
    rows = []
    for record in document["records"]:
        content = record.get("content")
        if content is None:
            rows.append({"id": record["id"], "regradable": False})
            continue
        # The retained tool calls are re-read as well, so a change to a tool
        # grader re-grades from the record on the same terms a text grader does.
        # Transport and attribution failures are properties of the evidence,
        # not grader verdicts. Re-applying a content rule cannot repair a reset,
        # an omitted served-model identity, or a response from another model.
        retained_evidence_error = (record.get("error")
                                   or record.get("attribution_error"))
        if retained_evidence_error:
            passed, reason = False, retained_evidence_error
        else:
            passed, reason = module.grade(
                record, content, record.get("truncated", False),
                record.get("tool_calls") or ())
        rows.append({
            "id": record["id"],
            "category": record["category"],
            "regradable": True,
            "recorded": bool(record["passed"]),
            "corrected": bool(passed),
            "truncated": bool(record.get("truncated", False)),
            "reason": reason,
        })
    return rows


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("records", nargs="+",
                        help="retained arm JSON records")
    parser.add_argument("--suite-runner",
                        default=os.path.join(HERE, "run-quality-suite.py"))
    parser.add_argument("--output-tsv",
                        help="write the per-arm totals to this path")
    arguments = parser.parse_args(argv[1:])

    module = load_grader(arguments.suite_runner)
    lines = ["\t".join((
        "model_id", "rows", "recorded_passes", "corrected_passes",
        "moved_rows", "unregradable"))]
    moved_detail = []
    for path in arguments.records:
        with open(path) as handle:
            document = json.load(handle)
        served = document["summary"].get("served_models") or []
        model_id = served[0] if served else os.path.splitext(
            os.path.basename(path))[0]
        rows = regrade_arm(module, document)
        regradable = [row for row in rows if row["regradable"]]
        moved = [row for row in regradable if row["recorded"] != row["corrected"]]
        moved_detail.extend((model_id, row) for row in moved)
        lines.append("\t".join((
            model_id,
            str(len(rows)),
            str(sum(row["recorded"] for row in regradable)),
            str(sum(row["corrected"] for row in regradable)),
            str(len(moved)),
            str(len(rows) - len(regradable)),
        )))

    report = "\n".join(lines)
    print(report)
    for model_id, row in moved_detail:
        print(f"moved model={model_id} row={row['id']} "
              f"category={row['category']} recorded={row['recorded']} "
              f"corrected={row['corrected']} truncated={row['truncated']} "
              f"reason={row['reason']}")
    if arguments.output_tsv:
        with open(arguments.output_tsv, "w") as handle:
            handle.write(report + "\n")
    print(f"regrade=completed arms={len(arguments.records)} "
          f"moved_rows={len(moved_detail)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
