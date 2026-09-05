#!/usr/bin/env python3
# gpu-ownership: reads a retained server log and opens no device context
"""Join every embedding slice the language model consumed to its source rows.

Under LLAMA_EMBD_HANDOFF_TRACE=1 the candidate patch writes, per encoded
media batch, one `mtmd_embd_batch` line naming the batch serial, the output
mode, and the tensor it holds, one `mtmd_embd_entry` line per chunk with its
row offset inside that tensor, one `clip_embd_row` line per output row with
that row's FNV-1a 64 digest, then per llama_decode one `mtmd_decode_view`
line naming the chunk rows the call carries, and per ubatch an `embd_ubatch`
line naming the batch rows it selected and an `embd_handoff` line carrying
the digest of the bytes the graph read and a `rowchain`, the FNV-1a 64 chain
over the per-row digests of exactly those bytes.

The reader rebuilds every slice from those lines: which request, image, and
chunk it belongs to, which rows of the chunk and of the tensor it names, and
the byte range those rows occupy. It recomputes the expected rowchain from
the projector's per-row digests and holds each slice to it, and it requires
the slices of every chunk to tile the chunk's rows exactly once in order. A
slice whose rows the projector never wrote, a row consumed twice, a row the
language model skipped, and a ubatch that gathered rows out of order are each
a refusal naming the slice. The byte digest per slice is what a control and a
subject arm are then compared on.

usage: read-embd-handoff-trace.py SERVER_LOG --out DIRECTORY [--expect host|device]

Writes DIRECTORY/slices.tsv and DIRECTORY/entries.tsv and prints one
key=value summary per line. Exit 0 where every check holds, 1 on a refusal,
2 on usage.
"""

import argparse
import os
import re
import sys

FNV_OFFSET = 1469598103934665603
FNV_PRIME = 1099511628211
MASK = (1 << 64) - 1

REQUEST = re.compile(r"launch_slot_: id\s+\d+ \| task (\d+) \| processing task")
BATCH = re.compile(r"mtmd_embd_batch serial=(\d+) mode=(\S+) n_entries=(\d+) n_tokens=(\d+) tensor=(\S+) data=(\S+) buffer=(\S+)")
ENTRY = re.compile(r"mtmd_embd_entry serial=(\d+) entry=(\d+) image=(\S+) row_offset=(\d+) n_tokens=(\d+)")
CLIP = re.compile(r"clip_embd_handoff dst=(\S+) src_backend=(\S+)(?: dst_buffer=(\S+))? bytes=(\d+) digest=([0-9a-f]{16})")
CLIP_ROW = re.compile(r"clip_embd_row dst=(\S+) row=(\d+) digest=([0-9a-f]{16})")
VIEW = re.compile(r"mtmd_decode_view mode=(\S+) tensor=(\S+) chunk_row_offset=(\d+) view_offset=(\d+) n_tokens=(\d+) chunk_n_tokens=(\d+)")
UBATCH = re.compile(r"embd_ubatch source=(\S+) batch_row_first=(\d+) batch_row_last=(\d+) n_tokens=(\d+) contiguous=(\S+)")
GRAPH = re.compile(r"embd_handoff source=(\S+) n_tokens=(\d+) n_embd=(\d+) offset=(-?\d+) buffer=(\S+) digest=([0-9a-f]{16}) rowchain=([0-9a-f]{16})")


def fnv1a64(data):
    digest = FNV_OFFSET
    for byte in data:
        digest ^= byte
        digest = (digest * FNV_PRIME) & MASK
    return digest


def rowchain(row_digests):
    """The chain the graph recorder computes over per-row digests, in order."""
    chain = FNV_OFFSET
    for digest in row_digests:
        chain = fnv1a64(digest.to_bytes(8, "little")) ^ ((chain * FNV_PRIME) & MASK)
    return chain


SLICE_COLUMNS = ("request", "task", "batch_serial", "mode", "entry", "image", "image_ordinal", "chunk_ordinal",
                 "slice", "tensor", "chunk_row_first", "n_tokens", "chunk_n_tokens", "tensor_row_first",
                 "byte_first", "byte_last_p1", "source", "buffer", "graph_offset", "digest", "rowchain",
                 "expected_rowchain", "rowchain_holds", "contiguous")
ENTRY_COLUMNS = ("request", "task", "batch_serial", "mode", "entry", "image", "image_ordinal", "chunk_ordinal",
                 "tensor", "data", "buffer", "row_offset", "n_tokens", "clip_dst", "clip_digest",
                 "clip_rows", "views", "slices", "coverage")


def read_log(path):
    requests = []
    batches = []
    refusals = []
    current_request = None
    current_batch = None
    pending_entry = None
    pending_ubatches = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, 1):
            match = REQUEST.search(line)
            if match:
                if pending_ubatches:
                    refusals.append("line %d: a request opens while %d ubatch(es) await a graph input" % (line_number, len(pending_ubatches)))
                    pending_ubatches = []
                current_request = {"ordinal": len(requests) + 1, "task": int(match.group(1)),
                                   "batches": [], "images": []}
                requests.append(current_request)
                current_batch = None
                pending_entry = None
                continue
            match = BATCH.search(line)
            if match:
                if current_request is None:
                    refusals.append("line %d: media batch outside any request" % line_number)
                    continue
                if pending_ubatches:
                    refusals.append("line %d: a media batch opens while %d ubatch(es) await a graph input" % (line_number, len(pending_ubatches)))
                    pending_ubatches = []
                serial, mode, n_entries, n_tokens, tensor, data, buffer = match.groups()
                current_batch = {"serial": int(serial), "mode": mode, "n_entries": int(n_entries),
                                 "n_tokens": int(n_tokens), "tensor": tensor, "data": data, "buffer": buffer,
                                 "entries": [], "clip": None, "clip_rows": [], "request": current_request,
                                 "next_entry": -1}
                batches.append(current_batch)
                current_request["batches"].append(current_batch)
                pending_entry = None
                continue
            match = ENTRY.search(line)
            if match:
                serial, entry, image, row_offset, n_tokens = match.groups()
                if current_batch is None or int(serial) != current_batch["serial"]:
                    refusals.append("line %d: entry line names serial %s outside its batch" % (line_number, serial))
                    continue
                images = current_request["images"]
                if image not in images:
                    images.append(image)
                image_ordinal = images.index(image) + 1
                chunk_ordinal = sum(1 for b in current_request["batches"] for e in b["entries"] if e["image"] == image) + 1
                current_batch["entries"].append({"entry": int(entry), "image": image, "image_ordinal": image_ordinal,
                                                 "chunk_ordinal": chunk_ordinal, "row_offset": int(row_offset),
                                                 "n_tokens": int(n_tokens), "slices": []})
                continue
            match = CLIP_ROW.search(line)
            if match:
                if current_batch is None:
                    refusals.append("line %d: projector row outside any batch" % line_number)
                    continue
                dst, row, digest = match.groups()
                if int(row) != len(current_batch["clip_rows"]):
                    refusals.append("line %d: projector row %s arrives out of order" % (line_number, row))
                current_batch["clip_rows"].append(int(digest, 16))
                continue
            match = CLIP.search(line)
            if match:
                if current_batch is None:
                    refusals.append("line %d: projector output outside any batch" % line_number)
                    continue
                dst, src_backend, dst_buffer, nbytes, digest = match.groups()
                current_batch["clip"] = {"dst": dst, "src_backend": src_backend, "dst_buffer": dst_buffer or "-",
                                         "bytes": int(nbytes), "digest": digest}
                continue
            match = VIEW.search(line)
            if match:
                mode, tensor, chunk_row_offset, view_offset, n_tokens, chunk_n_tokens = match.groups()
                if current_batch is None:
                    refusals.append("line %d: decode view outside any batch" % line_number)
                    continue
                if pending_ubatches:
                    refusals.append("line %d: decode view opens while %d ubatch(es) of the previous decode await a graph input"
                                    % (line_number, len(pending_ubatches)))
                    pending_ubatches = []
                if int(view_offset) == 0:
                    current_batch["next_entry"] += 1
                index = current_batch["next_entry"]
                if index < 0 or index >= len(current_batch["entries"]):
                    refusals.append("line %d: decode view names entry %d of a %d-entry batch"
                                    % (line_number, index, len(current_batch["entries"])))
                    pending_entry = None
                    continue
                pending_entry = current_batch["entries"][index]
                if int(chunk_n_tokens) != pending_entry["n_tokens"]:
                    refusals.append("line %d: decode view carries a %s-token chunk where entry %d holds %d"
                                    % (line_number, chunk_n_tokens, index, pending_entry["n_tokens"]))
                if mode == "device" and (tensor != current_batch["tensor"] or int(chunk_row_offset) != pending_entry["row_offset"]):
                    refusals.append("line %d: device view names %s at row %s where entry %d sits at %d of %s"
                                    % (line_number, tensor, chunk_row_offset, index, pending_entry["row_offset"],
                                       current_batch["tensor"]))
                pending_entry["view"] = {"mode": mode, "tensor": tensor, "view_offset": int(view_offset),
                                         "n_tokens": int(n_tokens)}
                pending_entry["views"] = pending_entry.get("views", 0) + 1
                continue
            match = UBATCH.search(line)
            if match:
                source, first, last, n_tokens, contiguous = match.groups()
                # llama_batch_allocr splits every ubatch of a decode ahead of
                # the first graph, so the ubatch lines queue and each graph
                # input takes the oldest
                pending_ubatches.append({"source": source, "first": int(first), "last": int(last),
                                         "n_tokens": int(n_tokens), "contiguous": contiguous, "line": line_number})
                continue
            match = GRAPH.search(line)
            if match and "clip_embd_handoff" not in line:
                source, n_tokens, n_embd, offset, buffer, digest, chain = match.groups()
                if pending_entry is None or not pending_ubatches or "view" not in pending_entry:
                    refusals.append("line %d: graph input with no decode view or ubatch ahead of it" % line_number)
                    pending_ubatches = []
                    continue
                pending_ubatch = pending_ubatches.pop(0)
                if int(n_tokens) != pending_ubatch["n_tokens"]:
                    refusals.append("line %d: graph reads %s tokens where the ubatch selected %d"
                                    % (line_number, n_tokens, pending_ubatch["n_tokens"]))
                view = pending_entry["view"]
                chunk_row_first = view["view_offset"] + pending_ubatch["first"]
                tensor_row_first = pending_entry["row_offset"] + chunk_row_first
                row_bytes = int(n_embd) * 4
                pending_entry["slices"].append({
                    "source": source, "n_tokens": int(n_tokens), "n_embd": int(n_embd), "graph_offset": int(offset),
                    "buffer": buffer, "digest": digest, "rowchain": int(chain, 16),
                    "chunk_row_first": chunk_row_first, "tensor_row_first": tensor_row_first,
                    "byte_first": tensor_row_first * row_bytes,
                    "byte_last_p1": (tensor_row_first + int(n_tokens)) * row_bytes,
                    "contiguous": pending_ubatch["contiguous"], "mode": view["mode"], "tensor": view["tensor"],
                    "line": line_number})
                continue
    if pending_ubatches:
        refusals.append("end of log: %d ubatch(es) await a graph input" % len(pending_ubatches))
    return requests, batches, refusals


def check(batches, expect):
    refusals = []
    slice_rows = []
    entry_rows = []
    counts = {"batches": len(batches), "entries": 0, "slices": 0, "split_entries": 0, "max_slices_per_entry": 0,
              "nonzero_chunk_offset_slices": 0, "nonzero_tensor_offset_slices": 0, "multi_entry_batches": 0,
              "multi_view_entries": 0, "device_batches": 0, "host_batches": 0}
    data_addresses = []
    for batch in batches:
        request = batch["request"]
        if batch["n_entries"] != len(batch["entries"]):
            refusals.append("batch %d names %d entries and lists %d" % (batch["serial"], batch["n_entries"], len(batch["entries"])))
        # the entries partition the tensor: consecutive indices, each
        # starting where the previous ended, the last ending at n_tokens
        cursor = 0
        for index, entry in enumerate(batch["entries"]):
            if entry["entry"] != index or entry["row_offset"] != cursor or entry["n_tokens"] <= 0:
                refusals.append("batch %d entry %d at row %d of %d rows breaks the partition expected at index %d row %d" % (
                    batch["serial"], entry["entry"], entry["row_offset"], entry["n_tokens"], index, cursor))
                break
            cursor += entry["n_tokens"]
        else:
            if cursor != batch["n_tokens"]:
                refusals.append("batch %d entries end at row %d of %d" % (batch["serial"], cursor, batch["n_tokens"]))
        if len(batch["clip_rows"]) != batch["n_tokens"]:
            refusals.append("batch %d projector wrote %d row digests for %d rows" % (
                batch["serial"], len(batch["clip_rows"]), batch["n_tokens"]))
        if batch["clip"] is None:
            refusals.append("batch %d carries no projector output line" % batch["serial"])
        if len(batch["entries"]) > 1:
            counts["multi_entry_batches"] += 1
        counts[batch["mode"] + "_batches"] += 1
        if batch["mode"] == "device":
            data_addresses.append(batch["data"])
        if expect == "device":
            if batch["mode"] != "device" or batch["tensor"] == "host" or "CUDA0" not in batch["buffer"]:
                refusals.append("batch %d is not a device batch on CUDA0: mode=%s tensor=%s buffer=%s" % (
                    batch["serial"], batch["mode"], batch["tensor"], batch["buffer"]))
            clip = batch["clip"] or {}
            if clip and (clip["dst"] != "device" or clip["src_backend"] != "CUDA0" or "CUDA0" not in clip["dst_buffer"]):
                refusals.append("batch %d projector output is not a device handoff: %s" % (batch["serial"], clip))
        elif expect == "host":
            if batch["mode"] != "host":
                refusals.append("batch %d is not a host batch: mode=%s" % (batch["serial"], batch["mode"]))
            clip = batch["clip"] or {}
            if clip and (clip["dst"] != "host" or clip["src_backend"] != "CUDA0"):
                refusals.append("batch %d projector output is not the host path: %s" % (batch["serial"], clip))
        for entry in batch["entries"]:
            counts["entries"] += 1
            slices = entry["slices"]
            counts["slices"] += len(slices)
            counts["max_slices_per_entry"] = max(counts["max_slices_per_entry"], len(slices))
            if len(slices) > 1:
                counts["split_entries"] += 1
            if entry.get("views", 0) > 1:
                counts["multi_view_entries"] += 1
            # coverage: the slices tile [0, n_tokens) exactly once in order
            cursor = 0
            coverage = "holds"
            for s in slices:
                if s["chunk_row_first"] != cursor:
                    coverage = "refused rows [%d, %d) expected at %d" % (s["chunk_row_first"], s["chunk_row_first"] + s["n_tokens"], cursor)
                    break
                cursor += s["n_tokens"]
            if coverage == "holds" and cursor != entry["n_tokens"]:
                coverage = "refused %d of %d rows consumed" % (cursor, entry["n_tokens"])
            if not slices:
                coverage = "refused no slice consumed"
            if coverage != "holds":
                refusals.append("batch %d entry %d coverage %s" % (batch["serial"], entry["entry"], coverage))
            for index, s in enumerate(slices, 1):
                rows = batch["clip_rows"][s["tensor_row_first"]:s["tensor_row_first"] + s["n_tokens"]]
                expected = rowchain(rows) if len(rows) == s["n_tokens"] else None
                holds = expected is not None and expected == s["rowchain"]
                if not holds:
                    refusals.append("batch %d entry %d slice %d rowchain %016x against expected %s over tensor rows [%d, %d)" % (
                        batch["serial"], entry["entry"], index, s["rowchain"],
                        "%016x" % expected if expected is not None else "absent",
                        s["tensor_row_first"], s["tensor_row_first"] + s["n_tokens"]))
                if s["contiguous"] != "yes":
                    refusals.append("batch %d entry %d slice %d gathered rows out of order" % (batch["serial"], entry["entry"], index))
                if s["mode"] == "device" and s["graph_offset"] != s["tensor_row_first"]:
                    refusals.append("batch %d entry %d slice %d views tensor row %d where the join names %d" % (
                        batch["serial"], entry["entry"], index, s["graph_offset"], s["tensor_row_first"]))
                if expect == "device" and (s["source"] != "device" or "CUDA0" not in s["buffer"]):
                    refusals.append("batch %d entry %d slice %d read from %s on %s rather than the device view" % (
                        batch["serial"], entry["entry"], index, s["source"], s["buffer"]))
                if expect == "host" and s["source"] != "host":
                    refusals.append("batch %d entry %d slice %d read from %s rather than the host upload" % (
                        batch["serial"], entry["entry"], index, s["source"]))
                if s["chunk_row_first"] > 0:
                    counts["nonzero_chunk_offset_slices"] += 1
                if s["tensor_row_first"] > 0:
                    counts["nonzero_tensor_offset_slices"] += 1
                slice_rows.append((request["ordinal"], request["task"], batch["serial"], batch["mode"], entry["entry"],
                                   entry["image"], entry["image_ordinal"], entry["chunk_ordinal"], index, s["tensor"],
                                   s["chunk_row_first"], s["n_tokens"], entry["n_tokens"], s["tensor_row_first"],
                                   s["byte_first"], s["byte_last_p1"], s["source"], s["buffer"], s["graph_offset"],
                                   s["digest"], "%016x" % s["rowchain"],
                                   "%016x" % expected if expected is not None else "-",
                                   "yes" if holds else "no", s["contiguous"]))
            clip = batch["clip"] or {"dst": "-", "digest": "-"}
            entry_rows.append((request["ordinal"], request["task"], batch["serial"], batch["mode"], entry["entry"],
                               entry["image"], entry["image_ordinal"], entry["chunk_ordinal"], batch["tensor"],
                               batch["data"], batch["buffer"], entry["row_offset"], entry["n_tokens"], clip["dst"],
                               clip["digest"], ",".join("%016x" % d for d in batch["clip_rows"][entry["row_offset"]:entry["row_offset"] + entry["n_tokens"]]),
                               entry.get("views", 0), len(slices), coverage))
    counts["device_data_addresses"] = len(set(data_addresses))
    counts["device_data_reuses"] = len(data_addresses) - len(set(data_addresses))
    return refusals, slice_rows, entry_rows, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("server_log")
    parser.add_argument("--out", required=True, help="directory for slices.tsv and entries.tsv")
    parser.add_argument("--expect", choices=("host", "device"), default=None,
                        help="hold every batch and slice to this placement")
    arguments = parser.parse_args()
    if not os.path.isfile(arguments.server_log):
        sys.stderr.write("read-embd-handoff-trace.py: not a file: %s\n" % arguments.server_log)
        return 2
    os.makedirs(arguments.out, exist_ok=True)
    requests, batches, refusals = read_log(arguments.server_log)
    check_refusals, slice_rows, entry_rows, counts = check(batches, arguments.expect)
    refusals.extend(check_refusals)
    with open(os.path.join(arguments.out, "slices.tsv"), "w", encoding="utf-8") as out:
        out.write("\t".join(SLICE_COLUMNS) + "\n")
        for row in slice_rows:
            out.write("\t".join(str(v) for v in row) + "\n")
    with open(os.path.join(arguments.out, "entries.tsv"), "w", encoding="utf-8") as out:
        out.write("\t".join(ENTRY_COLUMNS) + "\n")
        for row in entry_rows:
            out.write("\t".join(str(v) for v in row) + "\n")
    print("requests=%d" % len(requests))
    for key in sorted(counts):
        print("%s=%s" % (key, counts[key]))
    print("refusals=%d" % len(refusals))
    for refusal in refusals:
        print("refused: %s" % refusal)
    print("verdict=%s" % ("holds" if not refusals and slice_rows else "refused"))
    return 0 if not refusals and slice_rows else 1


if __name__ == "__main__":
    sys.exit(main())
