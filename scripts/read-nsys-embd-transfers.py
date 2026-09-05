#!/usr/bin/env python3
# gpu-ownership: reads an exported capture and opens no device context
"""List the memory copies one Nsight Systems export holds, sized against an
embedding transfer.

The embedding handoff recorder reads device bytes back to digest them, so a
capture taken with the recorder on says nothing about the transfers the
mechanism itself issues. This reader answers the transfer question from a
capture taken with the recorder off: every row of CUPTI_ACTIVITY_KIND_MEMCPY
in time order with its copy kind, byte count, source and destination memory
kinds, the runtime call that issued it, and the kernels executed before and
after it, which together name the copy's place in the pipeline.

--sizes names the byte counts an embedding transfer would carry, taken from
the trace run of the same request sequence: the whole projector output per
batch and the bytes per ubatch slice. A copy whose byte count equals one of
them is `embedding_sized`, and the summary counts those per copy kind. On
the host path the projector output leaves the device once per batch and the
graph input arrives once per ubatch; on the device path a device-to-device
copy per batch is the whole traffic of the handoff, and an embedding-sized
device-to-host or host-to-device copy is what would refute it.

usage: read-nsys-embd-transfers.py CAPTURE.sqlite --sizes BYTES[,BYTES...] [--row-bytes N] [--min-bytes N] [--out TSV]
"""

import argparse
import sqlite3
import sys


def usage_error(message):
    sys.stderr.write("read-nsys-embd-transfers.py: %s\n" % message)
    raise SystemExit(2)


def table_names(connection):
    return {row[0] for row in connection.execute("select name from sqlite_master where type in ('table', 'view')")}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture")
    parser.add_argument("--sizes", required=True, help="comma-separated byte counts an embedding transfer carries")
    parser.add_argument("--min-bytes", type=int, default=65536, help="list every copy at or above this size")
    parser.add_argument("--row-bytes", type=int, default=0,
                        help="bytes per embedding row; a copy of a whole number of rows at or above --min-bytes is row_multiple")
    parser.add_argument("--out", default=None, help="write the copy table here rather than to stdout")
    arguments = parser.parse_args()
    try:
        sizes = {int(v) for v in arguments.sizes.split(",") if v}
    except ValueError:
        usage_error("--sizes takes integers")
    if not sizes:
        usage_error("--sizes names at least one byte count")
    try:
        connection = sqlite3.connect("file:%s?mode=ro" % arguments.capture, uri=True)
        # StringIds carries the target's captured console text as well as
        # symbol names, and that text is not always valid UTF-8
        connection.text_factory = lambda raw: raw.decode("utf-8", errors="replace")
        tables = table_names(connection)
    except sqlite3.Error as error:
        usage_error("cannot open %s: %s" % (arguments.capture, error))
    if "CUPTI_ACTIVITY_KIND_MEMCPY" not in tables:
        usage_error("the capture holds no CUPTI_ACTIVITY_KIND_MEMCPY table")

    kinds = {}
    if "ENUM_CUDA_MEMCPY_OPER" in tables:
        kinds = {row[0]: row[2] for row in connection.execute("select id, name, label from ENUM_CUDA_MEMCPY_OPER")}
    mem_kinds = {}
    if "ENUM_CUDA_MEM_KIND" in tables:
        mem_kinds = {row[0]: row[2] for row in connection.execute("select id, name, label from ENUM_CUDA_MEM_KIND")}
    strings = {}
    if "StringIds" in tables:
        strings = {row[0]: row[1] for row in connection.execute("select id, value from StringIds")}
    api_by_correlation = {}
    if "CUPTI_ACTIVITY_KIND_RUNTIME" in tables:
        for correlation, name_id in connection.execute(
                "select correlationId, nameId from CUPTI_ACTIVITY_KIND_RUNTIME where correlationId is not null"):
            api_by_correlation[correlation] = strings.get(name_id, str(name_id))
    kernels = []
    if "CUPTI_ACTIVITY_KIND_KERNEL" in tables:
        kernels = [(start, end, strings.get(short, str(short))) for start, end, short in connection.execute(
            "select start, end, shortName from CUPTI_ACTIVITY_KIND_KERNEL order by start")]

    def neighbors(start, end):
        before = "-"
        after = "-"
        for k_start, k_end, name in kernels:
            if k_end <= start:
                before = name
            elif k_start >= end:
                after = name
                break
        return before, after

    columns = ("start_ns", "end_ns", "kind", "bytes", "src_kind", "dst_kind", "stream", "api", "kernel_before",
               "kernel_after", "embedding_sized", "row_multiple")
    rows = []
    summary = {}
    for start, end, stream, correlation, nbytes, kind, src_kind, dst_kind in connection.execute(
            "select start, end, streamId, correlationId, bytes, copyKind, srcKind, dstKind "
            "from CUPTI_ACTIVITY_KIND_MEMCPY order by start"):
        kind_name = kinds.get(kind, str(kind))
        sized = nbytes in sizes
        # a staging copy split into pieces or merged with a neighbor would
        # still move a whole number of rows, so that class is named too
        row_multiple = (arguments.row_bytes > 0 and nbytes >= arguments.min_bytes
                        and nbytes % arguments.row_bytes == 0)
        summary.setdefault(kind_name, [0, 0, 0, 0])
        summary[kind_name][0] += 1
        summary[kind_name][1] += nbytes
        if sized:
            summary[kind_name][2] += 1
        if row_multiple:
            summary[kind_name][3] += 1
        if nbytes >= arguments.min_bytes or sized:
            before, after = neighbors(start, end)
            rows.append((start, end, kind_name, nbytes, mem_kinds.get(src_kind, str(src_kind)),
                         mem_kinds.get(dst_kind, str(dst_kind)), stream,
                         api_by_correlation.get(correlation, "-"), before, after, "yes" if sized else "no",
                         "yes" if row_multiple else "no"))

    out = open(arguments.out, "w", encoding="utf-8") if arguments.out else sys.stdout
    out.write("\t".join(columns) + "\n")
    for row in rows:
        out.write("\t".join(str(v) for v in row) + "\n")
    if arguments.out:
        out.close()
    for kind_name in sorted(summary):
        count, total, sized, multiple = summary[kind_name]
        print("copy_kind=%s count=%d bytes=%d embedding_sized=%d row_multiple=%d" % (
            kind_name.replace(" ", "_"), count, total, sized, multiple))
    print("embedding_sized_dtoh=%d" % summary.get("Device-to-Host", [0, 0, 0])[2])
    print("embedding_sized_htod=%d" % summary.get("Host-to-Device", [0, 0, 0])[2])
    print("embedding_sized_dtod=%d" % summary.get("Device-to-Device", [0, 0, 0])[2])
    print("listed_copies=%d" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
