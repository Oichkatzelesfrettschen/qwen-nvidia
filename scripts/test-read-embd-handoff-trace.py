#!/usr/bin/env python3
"""Hold read-embd-handoff-trace.py to synthetic server logs.

A device log with one two-entry batch whose second entry splits across two
llama_decode calls and four ubatches reads every slice joined to its tensor
rows with the rowchain holding and coverage complete. The same log with a
ubatch removed, a rowchain altered, a ubatch gathered out of order, a view at
the wrong tensor row, or a host slice under --expect device is refused with
the slice named. A host log with the same structure holds under --expect host.
"""

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util  # noqa: E402

READER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "read-embd-handoff-trace.py")
spec = importlib.util.spec_from_file_location("reader", READER)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

N_EMBD = 8


def row_digest(row):
    return reader.fnv1a64(("row-%d" % row).encode())


def synthetic_log(mode, ubatch=32, n_batch=64, drop_slice=False, bad_chain=False, out_of_order=False, wrong_view_row=False,
                  overlap=False, dangling=False):
    """One request, one batch of two entries (40 and 100 rows)."""
    entries = ((0, 40, "imgA"), (40, 100, "imgB"))
    if overlap:
        # the second entry restarts at row 0 over the first entry's rows
        entries = ((0, 40, "imgA"), (0, 100, "imgB"))
    n_tokens = 140
    tensor = "mtmd_embd_dev" if mode == "device" else "host"
    buffer = "CUDA0" if mode == "device" else "host"
    lines = ["0.00.001 I slot launch_slot_: id  0 | task 7 | processing task, is_child = 0\n",
             "0.00.002 I mtmd_embd_batch serial=1 mode=%s n_entries=2 n_tokens=%d tensor=%s data=0x1000 buffer=%s\n" % (mode, n_tokens, tensor, buffer)]
    for index, (offset, count, image) in enumerate(entries):
        lines.append("0.00.003 I mtmd_embd_entry serial=1 entry=%d image=%s row_offset=%d n_tokens=%d\n" % (index, image, offset, count))
    if mode == "device":
        lines.append("0.00.004 I clip_embd_handoff dst=device src_backend=CUDA0 dst_buffer=CUDA0 bytes=%d digest=00000000deadbeef\n" % (n_tokens * N_EMBD * 4))
    else:
        lines.append("0.00.004 I clip_embd_handoff dst=host src_backend=CUDA0 bytes=%d digest=00000000deadbeef\n" % (n_tokens * N_EMBD * 4))
    for row in range(n_tokens):
        lines.append("0.00.005 I clip_embd_row dst=%s row=%d digest=%016x\n" % (mode, row, row_digest(row)))
    slice_index = 0
    for offset, count, _ in entries:
        for view_offset in range(0, count, n_batch):
            view_n = min(n_batch, count - view_offset)
            chunk_row_offset = offset if mode == "device" else 0
            lines.append("0.00.006 I mtmd_decode_view mode=%s tensor=%s chunk_row_offset=%d view_offset=%d n_tokens=%d chunk_n_tokens=%d\n"
                         % (mode, tensor, chunk_row_offset if not wrong_view_row else chunk_row_offset + 1, view_offset, view_n, count))
            # the allocator logs every ubatch of the decode, then the graphs run
            graph_lines = []
            for first in range(0, view_n, ubatch):
                n = min(ubatch, view_n - first)
                slice_index += 1
                if drop_slice and slice_index == 4:
                    continue
                tensor_row = offset + view_offset + first
                chain = reader.rowchain([row_digest(r) for r in range(tensor_row, tensor_row + n)])
                if bad_chain and slice_index == 3:
                    chain ^= 1
                lines.append("0.00.007 I embd_ubatch source=%s batch_row_first=%d batch_row_last=%d n_tokens=%d contiguous=%s\n"
                             % (mode, first, first + n - 1, n, "no" if out_of_order and slice_index == 2 else "yes"))
                graph_lines.append("0.00.008 I embd_handoff source=%s n_tokens=%d n_embd=%d offset=%d buffer=%s digest=%016x rowchain=%016x\n"
                                   % (mode, n, N_EMBD, tensor_row if mode == "device" else 0, buffer,
                                      reader.fnv1a64(b"bytes-%d" % slice_index), chain))
            lines.extend(graph_lines)
    if dangling:
        lines.append("0.00.008 I embd_ubatch source=%s batch_row_first=0 batch_row_last=0 n_tokens=1 contiguous=yes\n" % mode)
    lines.append("0.00.009 I slot      release: id  0 | task 7 | stop processing: n_tokens = 200, truncated = 0\n")
    return "".join(lines)


def run(log_text, expect):
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "server.log")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(log_text)
        arguments = [sys.executable, READER, path, "--out", os.path.join(directory, "out")]
        if expect:
            arguments += ["--expect", expect]
        completed = subprocess.run(arguments, capture_output=True, text=True)
        slices = ""
        slices_path = os.path.join(directory, "out", "slices.tsv")
        if os.path.exists(slices_path):
            with open(slices_path, encoding="utf-8") as handle:
                slices = handle.read()
        return completed.returncode, completed.stdout, slices


def summary_value(stdout, key):
    for line in stdout.splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1]
    return None


def main():
    failures = []

    def expect(condition, message):
        if not condition:
            failures.append(message)

    status, stdout, slices = run(synthetic_log("device"), "device")
    expect(status == 0, "device log refused: %s" % stdout)
    expect(summary_value(stdout, "slices") == "6", "device log slices %s" % summary_value(stdout, "slices"))
    expect(summary_value(stdout, "split_entries") == "2", "split entries %s" % summary_value(stdout, "split_entries"))
    expect(summary_value(stdout, "nonzero_chunk_offset_slices") == "4", "nonzero chunk offsets %s" % summary_value(stdout, "nonzero_chunk_offset_slices"))
    expect(summary_value(stdout, "nonzero_tensor_offset_slices") == "5", "nonzero tensor offsets %s" % summary_value(stdout, "nonzero_tensor_offset_slices"))
    expect(summary_value(stdout, "multi_entry_batches") == "1", "multi-entry batches %s" % summary_value(stdout, "multi_entry_batches"))
    expect(summary_value(stdout, "multi_view_entries") == "1", "multi-view entries %s" % summary_value(stdout, "multi_view_entries"))
    rows = [line.split("\t") for line in slices.splitlines()[1:]]
    columns = slices.splitlines()[0].split("\t")
    by = {name: columns.index(name) for name in columns}
    expect([r[by["tensor_row_first"]] for r in rows] == ["0", "32", "40", "72", "104", "136"], "tensor rows %s" % [r[by["tensor_row_first"]] for r in rows])
    expect([r[by["chunk_row_first"]] for r in rows] == ["0", "32", "0", "32", "64", "96"], "chunk rows %s" % [r[by["chunk_row_first"]] for r in rows])
    expect([r[by["byte_first"]] for r in rows][2] == str(40 * N_EMBD * 4), "byte range of the second entry")
    expect(all(r[by["rowchain_holds"]] == "yes" for r in rows), "every rowchain holds")
    expect([r[by["image_ordinal"]] for r in rows] == ["1", "1", "2", "2", "2", "2"], "image ordinals")

    status, stdout, _ = run(synthetic_log("host"), "host")
    expect(status == 0, "host log refused: %s" % stdout)
    expect(summary_value(stdout, "host_batches") == "1", "host batch count")

    status, stdout, _ = run(synthetic_log("host"), "device")
    expect(status == 1 and "not a device batch" in stdout, "host log accepted under --expect device: %s" % stdout)

    status, stdout, _ = run(synthetic_log("device", drop_slice=True), "device")
    expect(status == 1 and "coverage refused rows" in stdout, "dropped slice accepted: %s" % stdout)

    status, stdout, _ = run(synthetic_log("device", bad_chain=True), "device")
    expect(status == 1 and "slice 1 rowchain" in stdout, "altered rowchain accepted: %s" % stdout)

    status, stdout, _ = run(synthetic_log("device", out_of_order=True), "device")
    expect(status == 1 and "gathered rows out of order" in stdout, "out-of-order gather accepted: %s" % stdout)

    status, stdout, _ = run(synthetic_log("device", wrong_view_row=True), "device")
    expect(status == 1 and "device view names" in stdout, "wrong view row accepted: %s" % stdout)

    status, stdout, _ = run(synthetic_log("device", overlap=True), "device")
    expect(status == 1 and "breaks the partition" in stdout, "overlapping entries accepted: %s" % stdout)

    status, stdout, _ = run(synthetic_log("device", dangling=True), "device")
    expect(status == 1 and "await a graph input" in stdout, "dangling ubatch accepted: %s" % stdout)

    status, stdout, _ = run("0.00.001 I nothing here\n", None)
    expect(status == 1 and summary_value(stdout, "verdict") == "refused", "empty log accepted")

    for failure in failures:
        print("FAIL: " + failure)
    print("test-read-embd-handoff-trace: %d failure(s)" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
