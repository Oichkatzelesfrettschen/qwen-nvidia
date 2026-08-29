#!/usr/bin/env python3
"""Generate the deterministic long-context retrieval benchmark corpus."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

RETRIEVAL_KEY = "ORBITAL-CEDAR-7319"
RETRIEVAL_VALUE = "violet compass at archive shelf 42"


def build_record(record_index: int) -> str:
    """Return one unique record spanning each benchmark domain."""
    predecessor = max(0, record_index - 17)
    checksum = (record_index * 7919 + 104729) % 1_000_003
    tool_record = {
        "call_id": f"tool-{record_index:05d}",
        "arguments": {
            "document": record_index,
            "expected_predecessor": predecessor,
            "checksum": checksum,
        },
        "result": {"status": "ok", "rows": (record_index % 23) + 1},
    }
    return "\n".join(
        (
            f"DOCUMENT {record_index:05d}",
            (
                f"Research note: sample {record_index:05d} links measurement "
                f"{checksum} to document {predecessor:05d}. The link is a corpus "
                "fixture, not an empirical hardware claim."
            ),
            f"def stable_partition_{record_index:05d}(values: list[int]) -> tuple[list[int], list[int]]:",
            "    accepted = [value for value in values if value % 2 == 0]",
            "    deferred = [value for value in values if value % 2 != 0]",
            "    return accepted, deferred",
            json.dumps(tool_record, ensure_ascii=False, sort_keys=True),
            (
                f"Multilingual {record_index:05d}: español conserva índice {record_index}; "
                f"français conserve la clé {checksum}; Deutsch bewahrt den Verweis "
                f"{predecessor}; 日本語の記録番号は {record_index} です。"
            ),
            (
                f"Retrieval edge: document {record_index:05d} depends on document "
                f"{predecessor:05d}; decoy key CEDAR-{checksum:06d}."
            ),
            f"END DOCUMENT {record_index:05d}",
            "",
        )
    )


def generate_corpus(record_count: int) -> str:
    """Return a corpus with one early needle and unique multi-domain filler."""
    header = "\n".join(
        (
            "LONG-CONTEXT MULTI-DOMAIN RETRIEVAL CORPUS",
            "Authoritative retrieval record:",
            f"key={RETRIEVAL_KEY}",
            f"value={RETRIEVAL_VALUE}",
            "The final question requests this exact value. Similar CEDAR keys are decoys.",
            "END AUTHORITATIVE RETRIEVAL RECORD",
            "",
        )
    )
    return header + "".join(build_record(index) for index in range(record_count))


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--records", type=int, default=2000)
    arguments = parser.parse_args()
    if arguments.records < 1:
        parser.error("--records must be positive")
    return arguments


def main() -> None:
    arguments = parse_arguments()
    corpus = generate_corpus(arguments.records)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary_path.write_text(corpus, encoding="utf-8", newline="\n")
    temporary_path.replace(arguments.output)
    print(
        f"corpus={arguments.output} records={arguments.records} "
        f"bytes={arguments.output.stat().st_size}"
    )


if __name__ == "__main__":
    main()
