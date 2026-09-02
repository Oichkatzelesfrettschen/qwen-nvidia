#!/usr/bin/env python3
"""Prove read-nsys-mat-mul-kernels.py classifies the stream-k fixup.

`ggml/src/ggml-cuda/mmq.cuh:1233-1235` declares `template <ggml_type type,
int J, bool fallback> __global__ void mul_mat_q_stream_k_fixup`, the same
template parameter list `mul_mat_q` carries at `mmq.cuh:946-948`, and
`mmq.cuh:1463` launches the reduction inside the call that already launched
`mul_mat_q` whenever `fixup_needed` at `mmq.cuh:1440` holds. The fixture builds
three SQLite exports carrying the tables `CUPTI_ACTIVITY_KIND_KERNEL` and
`StringIds` the reader joins, runs the reader over each, and reads the emitted
TSV: an MMQ symbol alone reads MMQ, an MMQ symbol beside the fixup emits both
rows with the fixup named FIXUP and its launch count carried, and the fixup
alone is emitted rather than dropped.

The verdict arm reads the awk program out of `run-ad104-path-audit.sh` and runs
it over synthetic observation rows, so MMQ admitting a fixup, MMQ+FIXUP
requiring one, MMVQ contradicted by one, and a fixup with no MMQ of its type
are each read from the verdict the shipped script computes.

The pre-fix pattern is inlined as a literal so the assertion stays true after
this change reaches the default branch: `PRE_FIX_MMQ` is what the reader
matched before FIXUP existed, and it fails to match the fixup symbol that
`classify` now names.
"""

import importlib.util
import pathlib
import re
import sqlite3
import subprocess
import sys
import tempfile

SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
READER = SCRIPT_DIRECTORY / "read-nsys-mat-mul-kernels.py"
AUDIT = SCRIPT_DIRECTORY / "run-ad104-path-audit.sh"

MMQ_SYMBOL = "void mul_mat_q<(ggml_type)8, (int)16, (bool)0>(...)"
FIXUP_SYMBOL = "void mul_mat_q_stream_k_fixup<(ggml_type)8, (int)16, (bool)0>(...)"
MMVQ_SYMBOL = "void mul_mat_vec_q<(ggml_type)12, (int)7, (bool)0>(...)"

# The pattern the reader carried before the fixup had a family of its own.
PRE_FIX_MMQ = re.compile(r"\bmul_mat_q<\(ggml_type\)(\d+)")

failures = 0


def report(check, outcome):
    global failures
    print(f"check={check} outcome={outcome}")
    if outcome != "pass":
        failures += 1


def load_reader():
    specification = importlib.util.spec_from_file_location(
        "read_nsys_mat_mul_kernels", READER)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def write_export(path, launches):
    """launches is a sequence of (symbol, count, nanoseconds_each)."""
    connection = sqlite3.connect(path)
    connection.execute("create table StringIds (id integer, value text)")
    connection.execute(
        "create table CUPTI_ACTIVITY_KIND_KERNEL "
        "(demangledName integer, start integer, end integer)")
    for identifier, (symbol, count, duration) in enumerate(launches, start=1):
        connection.execute("insert into StringIds values (?, ?)",
                           (identifier, symbol))
        for occurrence in range(count):
            start = 1000 * (occurrence + 1)
            connection.execute(
                "insert into CUPTI_ACTIVITY_KIND_KERNEL values (?, ?, ?)",
                (identifier, start, start + duration))
    connection.commit()
    connection.close()


def read_rows(path):
    completed = subprocess.run(
        [sys.executable, str(READER), str(path), "--arm-id", "t",
         "--quant-family", "Q8_0", "--ne11", "7"],
        capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        return completed.returncode, []
    rows = [line.split("\t")
            for line in completed.stdout.splitlines() if line]
    return 0, rows


def families(rows):
    return {row[4]: row for row in rows}


def verdict_program():
    """Return the verdict awk program the audit script carries."""
    text = AUDIT.read_text()
    opening = text.index("$6 == quant && $5 == \"MMVQ\"")
    closing = text.index("\n        ' \"$arm_observations\"", opening)
    return text[opening:closing]


def verdict(rows, quant, b, expected):
    """Run the audit's own verdict program over synthetic observation rows."""
    with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as handle:
        for family, type_name, ncols in rows:
            handle.write("\t".join((
                "t", quant, str(b), "symbol", family, type_name, ncols,
                "1", "1", "observed")) + "\n")
        path = handle.name
    try:
        completed = subprocess.run(
            ["awk", "-F", "\t", "-v", f"quant={quant}", "-v", f"b={b}",
             "-v", f"expected={expected}", verdict_program(), path],
            capture_output=True, text=True, check=True)
        return completed.stdout.strip()
    finally:
        pathlib.Path(path).unlink()


def check_verdict(name, rows, quant, b, expected, wanted):
    observed = verdict(rows, quant, b, expected)
    if observed == wanted:
        report(name, "pass")
    else:
        report(name, "fail")
        print(f"  verdict {observed!r} where {wanted!r} was required",
              file=sys.stderr)


def main():
    module = load_reader()

    # The old pattern cannot reach the fixup symbol, so every fixup launch a
    # capture holds was dropped before classify named the family.
    if PRE_FIX_MMQ.search(FIXUP_SYMBOL) is None:
        report("pre_fix_pattern_drops_the_fixup", "pass")
    else:
        report("pre_fix_pattern_drops_the_fixup", "fail")

    classified = module.classify(FIXUP_SYMBOL)
    if classified == ("FIXUP", 8, None):
        report("classify_names_the_fixup_family_type_and_no_ncols", "pass")
    else:
        report("classify_names_the_fixup_family_type_and_no_ncols", "fail")
        print(f"  classify returned {classified!r}", file=sys.stderr)

    if module.classify(MMQ_SYMBOL) == ("MMQ", 8, None):
        report("classify_still_names_mmq", "pass")
    else:
        report("classify_still_names_mmq", "fail")

    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)

        mmq_alone = root / "mmq-alone.sqlite"
        write_export(mmq_alone, [(MMQ_SYMBOL, 168, 500)])
        status, rows = read_rows(mmq_alone)
        seen = families(rows)
        if status == 0 and list(seen) == ["MMQ"] and seen["MMQ"][5] == "Q8_0" \
                and seen["MMQ"][6] == "-" and seen["MMQ"][7] == "168":
            report("mmq_alone_reads_mmq", "pass")
        else:
            report("mmq_alone_reads_mmq", "fail")
            print(f"  rows {rows!r}", file=sys.stderr)

        pair = root / "mmq-and-fixup.sqlite"
        write_export(pair, [(MMQ_SYMBOL, 168, 500), (FIXUP_SYMBOL, 48, 100)])
        status, rows = read_rows(pair)
        seen = families(rows)
        if status == 0 and set(seen) == {"MMQ", "FIXUP"} \
                and seen["FIXUP"][5] == "Q8_0" and seen["FIXUP"][6] == "-" \
                and seen["FIXUP"][7] == "48" and seen["MMQ"][7] == "168":
            report("fixup_beside_mmq_is_counted_and_named", "pass")
        else:
            report("fixup_beside_mmq_is_counted_and_named", "fail")
            print(f"  rows {rows!r}", file=sys.stderr)

        alone = root / "fixup-alone.sqlite"
        write_export(alone, [(FIXUP_SYMBOL, 48, 100)])
        status, rows = read_rows(alone)
        seen = families(rows)
        if status == 0 and list(seen) == ["FIXUP"] and seen["FIXUP"][7] == "48":
            report("fixup_alone_is_reported_rather_than_dropped", "pass")
        else:
            report("fixup_alone_is_reported_rather_than_dropped", "fail")
            print(f"  rows {rows!r}", file=sys.stderr)

        # The ncols column keeps one meaning: MMVQ carries ncols_dst and both
        # MMQ and FIXUP carry the tile width, so both report `-`.
        mixed = root / "mixed.sqlite"
        write_export(mixed, [(MMVQ_SYMBOL, 32, 200), (FIXUP_SYMBOL, 48, 100)])
        status, rows = read_rows(mixed)
        seen = families(rows)
        if status == 0 and seen.get("MMVQ", [""] * 7)[6] == "7" \
                and seen.get("FIXUP", [""] * 7)[6] == "-":
            report("ncols_column_holds_ncols_dst_for_mmvq_alone", "pass")
        else:
            report("ncols_column_holds_ncols_dst_for_mmvq_alone", "fail")
            print(f"  rows {rows!r}", file=sys.stderr)

    mmq_row = ("MMQ", "Q4_K", "-")
    fixup_row = ("FIXUP", "Q4_K", "-")
    mmvq_row = ("MMVQ", "Q4_K", "9")

    check_verdict("verdict_mmq_alone_agrees",
                  [mmq_row], "Q4_K", 9, "MMQ", "agrees")
    check_verdict("verdict_mmq_admits_the_fixup",
                  [mmq_row, fixup_row], "Q4_K", 9, "MMQ", "agrees")
    check_verdict("verdict_mmq_plus_fixup_requires_the_fixup",
                  [mmq_row], "Q4_K", 9, "MMQ+FIXUP", "differs-no-fixup")
    check_verdict("verdict_mmq_plus_fixup_agrees_with_the_fixup",
                  [mmq_row, fixup_row], "Q4_K", 9, "MMQ+FIXUP", "agrees")
    check_verdict("verdict_fixup_without_mmq_differs",
                  [fixup_row], "Q4_K", 9, "MMQ", "differs-fixup-without-mmq")
    check_verdict("verdict_fixup_contradicts_mmvq",
                  [mmvq_row, fixup_row], "Q4_K", 9, "MMVQ",
                  "differs-mmq-present")

    if failures == 0:
        print("read_nsys_mat_mul_kernels=accepted checks=13")
        return 0
    print(f"read_nsys_mat_mul_kernels=rejected failures={failures}",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
