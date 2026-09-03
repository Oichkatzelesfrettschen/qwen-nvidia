#!/usr/bin/env python3
# gpu-ownership: reads an exported capture and opens no device context
"""Partition a decode token into device execution, device idle, host CUDA API,
host computation, and synchronization, from one Nsight Systems export.

evidence/ada/ncu-decode-baseline/ measured the decode mat-vec kernels at the
sustainable DRAM roofline, which places the remaining per-token time outside
the kernels. This reader locates that time. A capture taken with
--cuda-graph-trace=node reports each replayed graph node as its own kernel row,
so the intervals between nodes are visible where graph granularity would report
one span.

Five terms are computed per token over the interval between consecutive anchors:

  device_busy        union of kernel and memcpy intervals on the device
  device_idle        span minus device_busy
  idle_between_device_rows   idle inside the stretch the device rows occupy
  idle_outside_device_work   idle before the first row and after the last
  api_host           union of CUDA runtime API intervals on the host
  sync_host          the subset of api_host whose API name synchronizes
  host_uncovered     span minus api_host, host work inside no CUDA call

device_busy and device_idle sum to the span, and api_host and host_uncovered
sum to the span, so the two decompositions are two views of one interval rather
than five addends of it. sync_host is inside api_host and is reported for what
it is: the host waiting on the device rather than issuing to it.

An interval union is taken rather than a duration sum, because two overlapping
kernels on different streams occupy one stretch of wall time and adding their
durations would report more device time than the token contains.
"""
import argparse
import io
import os
import sqlite3
import statistics
import sys

SYNC_API_FRAGMENTS = (
    "Synchronize",
    "cudaStreamQuery",
    "cudaEventQuery",
)


def table_names(connection):
    rows = connection.execute(
        "select name from sqlite_master where type = 'table'").fetchall()
    return {row[0] for row in rows}


def union_length(intervals):
    """Total wall time covered by a set of half-open intervals."""
    if not intervals:
        return 0
    ordered = sorted(intervals)
    total = 0
    current_start, current_end = ordered[0]
    for start, end in ordered[1:]:
        if start > current_end:
            total += current_end - current_start
            current_start, current_end = start, end
        elif end > current_end:
            current_end = end
    return total + current_end - current_start


def clip(intervals, span_start, span_end):
    out = []
    for start, end in intervals:
        lo = max(start, span_start)
        hi = min(end, span_end)
        if hi > lo:
            out.append((lo, hi))
    return out


def load_device_intervals(connection, tables):
    intervals = []
    counts = {}
    # CUPTI_ACTIVITY_KIND_GRAPH_TRACE is where a graph-granularity capture puts
    # the replay: one row per launch spanning the whole graph, and nothing in
    # the kernel table for it. Reading the kernel table alone reports a
    # graph-granularity capture as an idle device, which is what a first run of
    # this reader did. A node-granularity capture carries the nodes in the
    # kernel table and leaves this one empty, so including both makes the same
    # reader correct at either granularity.
    for table in ("CUPTI_ACTIVITY_KIND_KERNEL", "CUPTI_ACTIVITY_KIND_MEMCPY",
                  "CUPTI_ACTIVITY_KIND_MEMSET",
                  "CUPTI_ACTIVITY_KIND_GRAPH_TRACE"):
        if table not in tables:
            counts[table] = 0
            continue
        rows = connection.execute(
            "select start, end from %s where end > start" % table).fetchall()
        counts[table] = len(rows)
        intervals.extend((int(a), int(b)) for a, b in rows)
    return intervals, counts


def load_api_intervals(connection, tables):
    """Every CUDA runtime API call as (start, end, name)."""
    if "CUPTI_ACTIVITY_KIND_RUNTIME" not in tables:
        return []
    rows = connection.execute(
        "select r.start, r.end, s.value from CUPTI_ACTIVITY_KIND_RUNTIME r "
        "join StringIds s on s.id = r.nameId where r.end > r.start").fetchall()
    return [(int(a), int(b), str(c)) for a, b, c in rows]


def is_sync(name):
    return any(fragment in name for fragment in SYNC_API_FRAGMENTS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", help="the .sqlite Nsight Systems export")
    parser.add_argument("--anchor", default="cudaGraphLaunch",
                        help="CUDA API whose calls mark token boundaries")
    parser.add_argument("--per-token", default=None,
                        help="write one row per partitioned token to this path")
    parser.add_argument("--drop-first", type=int, default=2,
                        help="leading anchors to discard as warm-up")
    arguments = parser.parse_args()

    if not os.path.exists(arguments.capture):
        sys.stderr.write("capture absent: %s\n" % arguments.capture)
        return 1

    connection = sqlite3.connect(arguments.capture)
    tables = table_names(connection)

    device_intervals, device_counts = load_device_intervals(connection, tables)
    api_records = load_api_intervals(connection, tables)

    rows = []
    rows.append(("capture", os.path.basename(arguments.capture)))
    for table, count in sorted(device_counts.items()):
        rows.append(("device_rows_%s" % table.split("KIND_")[-1].lower(), count))
    rows.append(("api_rows", len(api_records)))

    api_counts = {}
    for _, _, name in api_records:
        api_counts[name] = api_counts.get(name, 0) + 1

    # Nsight Systems reports a CUDA runtime API under its versioned symbol, so
    # cudaGraphLaunch arrives as cudaGraphLaunch_v10000 and an equality match
    # finds nothing. The anchor is a prefix.
    anchors = sorted(start for start, _, name in api_records
                     if name.startswith(arguments.anchor))
    if len(anchors) < arguments.drop_first + 2:
        # Report what the capture does hold rather than failing silently: an
        # absent anchor is usually graphs disabled or a different API name, and
        # the counts name the alternative.
        rows.append(("anchor", arguments.anchor))
        rows.append(("anchor_count", len(anchors)))
        rows.append(("tokens_partitioned", 0))
        write(rows, api_counts)
        sys.stderr.write(
            "anchor %s appears %d times, too few to partition\n"
            % (arguments.anchor, len(anchors)))
        return 1

    anchors = anchors[arguments.drop_first:]
    spans = list(zip(anchors, anchors[1:]))

    api_all = [(a, b) for a, b, _ in api_records]
    sync_only = [(a, b) for a, b, name in api_records if is_sync(name)]

    per_token = []
    for span_start, span_end in spans:
        span = span_end - span_start
        occupied = clip(device_intervals, span_start, span_end)
        device_busy = union_length(occupied)
        api_host = union_length(clip(api_all, span_start, span_end))
        sync_host = union_length(clip(sync_only, span_start, span_end))
        # Idle splits at the device work itself. The stretch from the first
        # device row to the last is the span the submitted work occupies, so
        # idle inside it is time no node fills while the device has work
        # pending, and idle outside it is time before the first node or after
        # the last. A graph-granularity capture reports one row per replay and
        # cannot separate the two; splitting here reads both from the node
        # capture, which is the only one that holds the nodes.
        if occupied:
            work_start = min(start for start, _ in occupied)
            work_end = max(end for _, end in occupied)
            idle_inside = (work_end - work_start) - device_busy
            idle_outside = span - (work_end - work_start)
        else:
            idle_inside = 0
            idle_outside = span
        per_token.append({
            "span_ns": span,
            "device_busy_ns": device_busy,
            "device_idle_ns": span - device_busy,
            "idle_between_device_rows_ns": idle_inside,
            "idle_outside_device_work_ns": idle_outside,
            "api_host_ns": api_host,
            "sync_host_ns": sync_host,
            "host_uncovered_ns": span - api_host,
        })

    fields = ["span_ns", "device_busy_ns", "device_idle_ns",
              "idle_between_device_rows_ns", "idle_outside_device_work_ns",
              "api_host_ns", "sync_host_ns", "host_uncovered_ns"]

    rows.append(("anchor", arguments.anchor))
    rows.append(("tokens_partitioned", len(per_token)))
    median_span = statistics.median(t["span_ns"] for t in per_token)
    for field in fields:
        values = sorted(t[field] for t in per_token)
        median = statistics.median(values)
        rows.append(("median_" + field, median))
        rows.append(("median_%s_pct_of_span" % field,
                     "%.1f" % (100.0 * median / median_span) if median_span else "-"))
    for field in fields:
        values = sorted(t[field] for t in per_token)
        rows.append(("min_" + field, values[0]))
        rows.append(("max_" + field, values[-1]))

    write(rows, api_counts)

    if arguments.per_token:
        with io.open(arguments.per_token, "w", encoding="utf-8") as handle:
            handle.write("token\t" + "\t".join(fields) + "\n")
            for index, token in enumerate(per_token):
                handle.write("%d\t%s\n"
                             % (index, "\t".join(str(token[f]) for f in fields)))
    return 0


def write(rows, api_counts):
    for key, value in rows:
        sys.stdout.write("%s\t%s\n" % (key, value))
    for name, count in sorted(api_counts.items(), key=lambda kv: -kv[1])[:20]:
        sys.stdout.write("api_call\t%s\t%d\n" % (name, count))


if __name__ == "__main__":
    sys.exit(main())
