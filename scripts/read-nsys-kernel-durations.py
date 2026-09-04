#!/usr/bin/env python3
# gpu-ownership: reads an exported capture and opens no device context
"""Report per-symbol kernel duration statistics from one Nsight Systems export.

evidence/ada/projection-fan-out/ needs the per-launch fixed cost t0, which is
what a merged mat-mul launch removes and what the byte-count model of a decode
token cannot supply. A launch whose traffic is far below one wave spends its
whole recorded duration on that fixed cost: `ssm_alpha` and `ssm_beta` are 2048
by 16 and move 18432 bytes, 0.04 us at the rate this device sustains, and
`quantize_q8_1` covers a decode activation in 8 blocks on 60 multiprocessors.
Reading those symbols' durations therefore measures t0 directly rather than
fitting it.

The reader reports every distinct kernel symbol rather than a selected family,
because the launches that estimate t0 are named by their template arguments and
identifying them means seeing the whole population. Rows carry count, total,
median, minimum, and maximum device time, sorted by count, so a symbol issued
once at load is separable from one issued per layer.

A capture taken with --cuda-graph-trace=node reports each replayed graph node as
its own kernel row in CUPTI_ACTIVITY_KIND_KERNEL. Graph granularity collapses
the replay into CUPTI_ACTIVITY_KIND_GRAPH_TRACE and reports no node, so this
reader requires the node capture and says so when the kernel table is empty.
"""

import argparse
import collections
import sqlite3
import statistics
import sys


def usage_error(message):
    sys.stderr.write("read-nsys-kernel-durations.py: %s\n" % message)
    sys.stderr.write(
        "usage: read-nsys-kernel-durations.py CAPTURE.sqlite "
        "[--match SUBSTRING] [--min-count N]\n")
    raise SystemExit(2)


def table_names(connection):
    return {row[0] for row in connection.execute(
        "select name from sqlite_master where type in ('table', 'view')")}


def main():
    parser = argparse.ArgumentParser(description=__doc__, add_help=True)
    parser.add_argument("capture", help="the .sqlite Nsight Systems export")
    parser.add_argument("--match", default=None,
                        help="report only symbols containing this substring")
    parser.add_argument("--min-count", type=int, default=1,
                        help="report only symbols launched at least this often")
    arguments = parser.parse_args()

    try:
        connection = sqlite3.connect("file:%s?mode=ro" % arguments.capture,
                                     uri=True)
    except sqlite3.Error as error:
        usage_error("cannot open %s: %s" % (arguments.capture, error))

    tables = table_names(connection)
    if "CUPTI_ACTIVITY_KIND_KERNEL" not in tables:
        usage_error("the capture holds no CUPTI_ACTIVITY_KIND_KERNEL table")

    name_column = ("demangledName" if "demangledName" in
                   {row[1] for row in connection.execute(
                       "pragma table_info(CUPTI_ACTIVITY_KIND_KERNEL)")}
                   else "shortName")

    rows = connection.execute(
        "select s.value, k.end - k.start from CUPTI_ACTIVITY_KIND_KERNEL k "
        "join StringIds s on s.id = k.%s where k.end > k.start" % name_column
    ).fetchall()

    if not rows:
        usage_error("the kernel table is empty; the capture needs "
                    "--cuda-graph-trace=node")

    durations = collections.defaultdict(list)
    for symbol, duration in rows:
        durations[str(symbol)].append(int(duration))

    graph_rows = 0
    if "CUPTI_ACTIVITY_KIND_GRAPH_TRACE" in tables:
        graph_rows = connection.execute(
            "select count(*) from CUPTI_ACTIVITY_KIND_GRAPH_TRACE").fetchone()[0]

    print("capture\t%s" % arguments.capture)
    print("kernel_rows\t%d" % len(rows))
    print("graph_trace_rows\t%d" % graph_rows)
    print("distinct_symbols\t%d" % len(durations))
    print()
    print("\t".join(("count", "total_ns", "median_ns", "min_ns", "max_ns",
                     "symbol")))

    selected = sorted(durations.items(), key=lambda item: -len(item[1]))
    for symbol, values in selected:
        if len(values) < arguments.min_count:
            continue
        if arguments.match is not None and arguments.match not in symbol:
            continue
        print("\t".join((
            str(len(values)), str(sum(values)),
            str(int(statistics.median(values))),
            str(min(values)), str(max(values)), symbol)))


if __name__ == "__main__":
    main()
