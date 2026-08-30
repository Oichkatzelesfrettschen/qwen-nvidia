#!/usr/bin/env python3
"""Prove that regrading changes grader verdicts, not evidence identity."""

import importlib.util
import os
import sys


REMOTE_DIRECTORY = os.path.dirname(os.path.abspath(__file__))


def load_module(name, filename):
    specification = importlib.util.spec_from_file_location(
        name, os.path.join(REMOTE_DIRECTORY, filename))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


grader = load_module("quality_suite", "run-quality-suite.py")
regrader = load_module("quality_regrader", "regrade-quality-roster.py")


def record(identifier, **overrides):
    retained = {
        "id": identifier,
        "category": "arithmetic",
        "grader": "numeric",
        "expectation": "42",
        "content": "The answer is 42.",
        "passed": False,
        "truncated": False,
        "tool_calls": [],
        "error": None,
        "attribution_error": None,
    }
    retained.update(overrides)
    return retained


transport_error = "connection reset by fixture"
attribution_error = "response model 'foreign' differs from requested model 'target'"
rows = regrader.regrade_arm(grader, {"records": [
    record("grader-change"),
    record("transport-failure", error=transport_error),
    record("attribution-failure", attribution_error=attribution_error),
    record("content-absent", content=None),
]})
rows_by_id = {row["id"]: row for row in rows}
failures = []

if not rows_by_id["grader-change"]["corrected"]:
    failures.append("a valid retained reply did not receive its corrected verdict")
if rows_by_id["transport-failure"]["corrected"]:
    failures.append("regrading converted a transport failure into a pass")
if rows_by_id["transport-failure"]["reason"] != transport_error:
    failures.append("regrading replaced the retained transport failure")
if rows_by_id["attribution-failure"]["corrected"]:
    failures.append("regrading converted an attribution failure into a pass")
if rows_by_id["attribution-failure"]["reason"] != attribution_error:
    failures.append("regrading replaced the retained attribution failure")
if rows_by_id["content-absent"]["regradable"]:
    failures.append("regrading accepted a record without retained content")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"quality_regrade_identity=rejected failures={len(failures)}",
          file=sys.stderr)
    sys.exit(1)

print("quality_regrade_identity=accepted rows=4")
