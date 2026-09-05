#!/usr/bin/env python3
"""Hold read-nsys-embd-transfers.py to a synthetic Nsight Systems export.

A capture holding one device-to-host copy at an embedding size, one
host-to-device copy at a slice size, one device-to-device copy at the
embedding size, and one unrelated large copy reads three embedding-sized
copies split by kind, names the runtime call and the neighboring kernels of
each, and lists the unrelated copy by its size alone. A capture without the
memcpy table is a usage error.
"""

import os
import sqlite3
import subprocess
import sys
import tempfile

READER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "read-nsys-embd-transfers.py")
EMBD = 88 * 2048 * 4
SLICE = 32 * 2048 * 4


def build(path):
    connection = sqlite3.connect(path)
    connection.executescript("""
    create table StringIds (id integer primary key, value text);
    create table ENUM_CUDA_MEMCPY_OPER (id integer, name text, label text);
    create table ENUM_CUDA_MEM_KIND (id integer, name text, label text);
    create table CUPTI_ACTIVITY_KIND_RUNTIME (start integer, end integer, correlationId integer, nameId integer);
    create table CUPTI_ACTIVITY_KIND_KERNEL (start integer, end integer, shortName integer);
    create table CUPTI_ACTIVITY_KIND_MEMCPY (start integer, end integer, streamId integer, correlationId integer,
        bytes integer, copyKind integer, srcKind integer, dstKind integer);
    """)
    connection.executemany("insert into StringIds values (?, ?)", [
        (1, "cudaMemcpyAsync"), (2, "cudaMemcpy2DAsync"), (3, "proj_kernel"), (4, "llm_kernel"), (5, "other_kernel")])
    connection.executemany("insert into ENUM_CUDA_MEMCPY_OPER values (?, ?, ?)", [
        (1, "CUDA_MEMCPY_KIND_HTOD", "Host-to-Device"), (2, "CUDA_MEMCPY_KIND_DTOH", "Device-to-Host"),
        (8, "CUDA_MEMCPY_KIND_DTOD", "Device-to-Device")])
    connection.executemany("insert into ENUM_CUDA_MEM_KIND values (?, ?, ?)", [
        (0, "P", "Pageable"), (1, "PI", "Pinned"), (2, "D", "Device")])
    connection.executemany("insert into CUPTI_ACTIVITY_KIND_RUNTIME values (?, ?, ?, ?)", [
        (100, 110, 11, 1), (200, 210, 12, 1), (300, 310, 13, 1), (400, 410, 14, 2)])
    connection.executemany("insert into CUPTI_ACTIVITY_KIND_KERNEL values (?, ?, ?)", [
        (50, 90, 3), (150, 190, 5), (250, 290, 4), (350, 390, 4)])
    connection.executemany("insert into CUPTI_ACTIVITY_KIND_MEMCPY values (?, ?, ?, ?, ?, ?, ?, ?)", [
        (120, 130, 7, 11, EMBD, 2, 2, 0),     # projector output to the host
        (220, 230, 7, 12, SLICE, 1, 1, 2),    # one slice staged to the device
        (320, 330, 7, 13, EMBD, 8, 2, 2),     # the device handoff copy
        (420, 430, 7, 14, 5000000, 2, 2, 0),  # an unrelated large copy
        (440, 441, 7, None, 512, 1, 0, 2)])   # a small copy under the listing floor
    connection.commit()
    connection.close()


def main():
    failures = []

    def expect(condition, message):
        if not condition:
            failures.append(message)

    with tempfile.TemporaryDirectory() as directory:
        capture = os.path.join(directory, "capture.sqlite")
        build(capture)
        out = os.path.join(directory, "copies.tsv")
        completed = subprocess.run([sys.executable, READER, capture, "--sizes", "%d,%d" % (EMBD, SLICE), "--out", out],
                                   capture_output=True, text=True)
        expect(completed.returncode == 0, "reader failed: %s %s" % (completed.stdout, completed.stderr))
        summary = dict(line.split("=", 1) for line in completed.stdout.splitlines() if "=" in line and not line.startswith("copy_kind"))
        expect(summary.get("embedding_sized_dtoh") == "1", "dtoh count %s" % summary.get("embedding_sized_dtoh"))
        expect(summary.get("embedding_sized_htod") == "1", "htod count %s" % summary.get("embedding_sized_htod"))
        expect(summary.get("embedding_sized_dtod") == "1", "dtod count %s" % summary.get("embedding_sized_dtod"))
        expect(summary.get("listed_copies") == "4", "listed copies %s" % summary.get("listed_copies"))
        with open(out, encoding="utf-8") as handle:
            rows = [line.split("\t") for line in handle.read().splitlines()]
        columns = rows[0]
        by = {name: columns.index(name) for name in columns}
        first = rows[1]
        expect(first[by["api"]] == "cudaMemcpyAsync", "api of the first copy %s" % first[by["api"]])
        expect(first[by["kernel_before"]] == "proj_kernel" and first[by["kernel_after"]] == "other_kernel",
               "neighbors of the first copy %s %s" % (first[by["kernel_before"]], first[by["kernel_after"]]))
        expect(first[by["src_kind"]] == "Device" and first[by["dst_kind"]] == "Pageable", "memory kinds of the first copy")
        expect(rows[4][by["embedding_sized"]] == "no" and rows[4][by["api"]] == "cudaMemcpy2DAsync", "the unrelated copy")

        empty = os.path.join(directory, "empty.sqlite")
        sqlite3.connect(empty).close()
        completed = subprocess.run([sys.executable, READER, empty, "--sizes", "1"], capture_output=True, text=True)
        expect(completed.returncode == 2, "a capture without the memcpy table is a usage error")

    for failure in failures:
        print("FAIL: " + failure)
    print("test-read-nsys-embd-transfers: %d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
