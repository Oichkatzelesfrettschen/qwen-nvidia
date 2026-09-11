#!/usr/bin/env python3
"""Validate the bounded public record for the retired local AUR diff."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


IDENTITY_FIELDS = [
    "record_id",
    "base_commit",
    "fetched_origin_commit",
    "behind_commits",
    "base_pkgbuild_sha256",
    "modified_pkgbuild_sha256",
    "origin_pkgbuild_sha256",
    "raw_diff_sha256",
    "private_manifest_sha256",
    "added_lines",
    "removed_lines",
    "decision",
]

EXPECTED_IDENTITY = {
    "record_id": "aur-llama-cpp-cuda-stale-flags",
    "base_commit": "c3e10c5c98dae7e28592a35a7a8fc8175fe5c82a",
    "fetched_origin_commit": "be3761e6f248f1653fbf91b7a90c62bee28ff013",
    "behind_commits": "600",
    "base_pkgbuild_sha256": (
        "f24a9e826d2ee5106c40154af67e8acdc1df0d6eeb5ac7f9c2894e089f2c877f"
    ),
    "modified_pkgbuild_sha256": (
        "e7cfa51bb50a52cb0668f7875bb3172421dbc09bbc623a5c5a21a3d8d4d4ca8d"
    ),
    "origin_pkgbuild_sha256": (
        "2872fe0d1544170554c054967a5a880f9d4b0b606b73f64e707e1d0e91b4614d"
    ),
    "raw_diff_sha256": (
        "41dd78eebd954b0f5da43acbedfe5e579325d82efc19724549c761d110593bdb"
    ),
    "private_manifest_sha256": (
        "4c3350f2a3d146fa928765f23d9d815cf5c90ce78e6b645fcefba07f2b26807c"
    ),
    "added_lines": "20",
    "removed_lines": "0",
    "decision": "negative-admission",
}

DECISION_FIELDS = ["item", "stale_value", "current_observation", "decision"]
EXPECTED_DECISION_ROWS = [
    {
        "item": "strip-default",
        "stale_value": "options=(!strip)",
        "current_observation": (
            "fetched AUR master uses options=(lto !debug); the diff retains no "
            "current strip failure or reproducer"
        ),
        "decision": "refused",
    },
    {
        "item": "obsolete-v12-option",
        "stale_value": "GGML_CUDA_V12=ON",
        "current_observation": (
            "the option is absent from the cached newer llama.cpp source and the "
            "qwen-nvidia pinned source"
        ),
        "decision": "refused",
    },
    {
        "item": "hardcoded-sm89-default",
        "stale_value": "CMAKE_CUDA_ARCHITECTURES=89",
        "current_observation": (
            "the AUR package serves three architectures and exposes "
            "LLAMA_BUILD_EXTRA_ARGS; qwen-nvidia already owns its measured SM89 "
            "closure"
        ),
        "decision": "refused",
    },
    {
        "item": "global-fast-math",
        "stale_value": "CMAKE_CUDA_FLAGS=-use_fast_math -O3",
        "current_observation": (
            "the diff retains no numerical comparison or task result for the "
            "global compiler flags"
        ),
        "decision": "refused",
    },
    {
        "item": "unmeasured-performance-claim",
        "stale_value": "10-15 percent token generation gain",
        "current_observation": (
            "the diff retains no binary identities, workload, token output, "
            "clocks, timings, or control arm"
        ),
        "decision": "refused",
    },
    {
        "item": "force-policy-comments",
        "stale_value": "FORCE_CUBLAS 5x slower and FORCE_MMQ redundant",
        "current_observation": (
            "the free-form figures carry no retained source, binary, workload, "
            "or measurement tuple"
        ),
        "decision": "refused",
    },
]
EXPECTED_DECISION_ITEMS = {row["item"] for row in EXPECTED_DECISION_ROWS}

README_MARKERS = [
    EXPECTED_IDENTITY["base_commit"],
    EXPECTED_IDENTITY["fetched_origin_commit"],
    "aur_publication=not_run",
    "package_build=not_run",
    "device_execution=not_run",
    "performance_result=not_established",
    "decision=negative-admission",
]


class RetentionError(ValueError):
    """Report a malformed or semantically changed retention record."""


def read_tsv(path: Path, expected_fields: list[str]) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as source:
        reader = csv.DictReader(source, delimiter="\t")
        if reader.fieldnames != expected_fields:
            raise RetentionError(
                f"{path.name}: expected header {expected_fields}, found {reader.fieldnames}"
            )
        rows = list(reader)
    for row_index, row in enumerate(rows, start=2):
        for field_name, field_value in row.items():
            if field_value is None or not field_value.strip():
                raise RetentionError(
                    f"{path.name}:{row_index}: empty field {field_name}"
                )
    return rows


def verify(repository_root: Path) -> None:
    evidence_directory = (
        repository_root / "evidence" / "ada" / "aur-llama-cpp-cuda-stale-flags"
    )
    identity_rows = read_tsv(
        evidence_directory / "source-identity.tsv", IDENTITY_FIELDS
    )
    if identity_rows != [EXPECTED_IDENTITY]:
        raise RetentionError("source-identity.tsv: registered identity tuple changed")

    decision_rows = read_tsv(evidence_directory / "decision.tsv", DECISION_FIELDS)
    decision_items = [row["item"] for row in decision_rows]
    if len(decision_items) != len(set(decision_items)):
        raise RetentionError("decision.tsv: duplicate item")
    if set(decision_items) != EXPECTED_DECISION_ITEMS:
        raise RetentionError("decision.tsv: refusal denominator changed")
    for row in decision_rows:
        if row["decision"] != "refused":
            raise RetentionError(f"decision.tsv: {row['item']} is not refused")
    if decision_rows != EXPECTED_DECISION_ROWS:
        raise RetentionError("decision.tsv: registered decision rows changed")

    readme_text = (evidence_directory / "README.md").read_text(encoding="utf-8")
    for marker in README_MARKERS:
        if marker not in readme_text:
            raise RetentionError(f"README.md: missing marker {marker}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root containing the retained evidence",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        verify(arguments.root.resolve())
    except (OSError, RetentionError) as error:
        print(f"aur_llama_cpp_cuda_retention=rejected reason={error}")
        return 1
    print(
        "aur_llama_cpp_cuda_retention=accepted "
        "source_rows=1 decision_rows=6 device_execution=not_run"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
