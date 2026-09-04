#!/usr/bin/env python3
"""Read the KV buffer layout a server log records and hold it to the P1 claim.

The paged KV buffer type prints one ``paged_kv_buffer`` line per buffer with
the requested, virtual, and physically mapped byte counts and both driver
granularities, and one ``paged_kv_tensor`` line per K or V tensor with its
row size, byte count, padded extent, offset, and alignment verdicts. The KV
cache constructor prints ``kv_buffer_kind=`` beside each buffer it allocated,
and the recurrent store prints its own ``RS buffer size`` line. This reader
joins those lines into the memory accounting the P1 record retains and refuses
a log whose layout breaks the claim: a tensor whose start or extent misses the
mapping unit, a mapped byte count under the virtual reservation, an attention
tensor outside the paged buffer, or a recurrent tensor inside it.

Usage: read-paged-kv-layout.py LOG --expect paged_kv_vmm|device_default
       [--expect-tensors N] [--expect-names NAME,NAME,...]

``--expect-tensors`` names the tensor count an independent census of the
checkpoint predicts, and ``--expect-names`` the exact tensor names it
predicts, so a log that records fewer or other tensors than the model has
attention K and V operands is refused rather than read as complete.
"""

import argparse
import re
import sys

BUFFER_LINE = re.compile(
    r"paged_kv_buffer device=(?P<device>\d+) requested_bytes=(?P<requested>\d+)"
    r" virtual_reserved_bytes=(?P<virtual>\d+) physical_mapped_bytes=(?P<mapped>\d+)"
    r" unit_bytes=(?P<unit>\d+) granularity_minimum=(?P<minimum>\d+)"
    r" granularity_recommended=(?P<recommended>\d+) access=(?P<access>\S+)"
)
TENSOR_LINE = re.compile(
    r"paged_kv_tensor name=(?P<name>\S+) type=(?P<type>\S+) ne0=(?P<ne0>\d+) ne1=(?P<ne1>\d+)"
    r" ne2=(?P<ne2>\d+) row_bytes=(?P<row>\d+) nbytes=(?P<nbytes>\d+) alloc_bytes=(?P<alloc>\d+)"
    r" padded_bytes=(?P<padded>\d+) offset=(?P<offset>\d+) unit_bytes=(?P<unit>\d+)"
    r" start_aligned=(?P<start>yes|no) extent_aligned=(?P<extent>yes|no)"
)
KIND_LINE = re.compile(r"kv_buffer_kind=(?P<kind>\S+) buffer=(?P<buffer>\S+)")
KV_SIZE_LINE = re.compile(r"(?P<buffer>\S+) KV buffer size = +(?P<mib>[0-9.]+) MiB")
RS_SIZE_LINE = re.compile(r"(?P<buffer>\S+) RS buffer size = +(?P<mib>[0-9.]+) MiB")
KV_TENSOR_NAME = re.compile(r"^cache_[kv]_l(?P<layer>\d+)$")
# Bytes per block and elements per block, from ggml's type traits, for the
# row-size check; a type outside the table is reported rather than guessed.
TYPE_BLOCKS = {"q8_0": (34, 32), "q4_0": (18, 32), "q4_1": (20, 32), "q5_0": (22, 32),
               "q5_1": (24, 32), "f16": (2, 1), "bf16": (2, 1), "f32": (4, 1)}


def read_log(path):
    buffers, tensors, kinds, kv_sizes, rs_sizes, malformed = [], [], [], [], [], []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = BUFFER_LINE.search(line)
            if match:
                buffers.append({key: int(value) if value.isdigit() else value
                                for key, value in match.groupdict().items()})
                continue
            match = TENSOR_LINE.search(line)
            if match:
                record = match.groupdict()
                for key in ("ne0", "ne1", "ne2", "row", "nbytes", "alloc", "padded", "offset", "unit"):
                    record[key] = int(record[key])
                tensors.append(record)
                continue
            # A record line the pattern rejects is a fault rather than a
            # line to skip: a truncated or hand-edited accounting line would
            # otherwise remove a tensor from the sum it belongs to.
            if "paged_kv_buffer " in line or "paged_kv_tensor " in line:
                malformed.append(line.rstrip("\n"))
                continue
            match = KIND_LINE.search(line)
            if match:
                kinds.append(match.groupdict())
                continue
            match = KV_SIZE_LINE.search(line)
            if match:
                kv_sizes.append(match.groupdict())
                continue
            match = RS_SIZE_LINE.search(line)
            if match:
                rs_sizes.append(match.groupdict())
    return buffers, tensors, kinds, kv_sizes, rs_sizes, malformed


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("--expect", required=True, choices=("paged_kv_vmm", "device_default"))
    parser.add_argument("--expect-tensors", type=int, default=None)
    parser.add_argument("--expect-names", default=None)
    arguments = parser.parse_args()

    buffers, tensors, kinds, kv_sizes, rs_sizes, malformed = read_log(arguments.log)
    faults = []
    rows = []
    if malformed:
        faults.append("%d accounting lines match no record pattern" % len(malformed))

    def add(key, value):
        rows.append((key, value))

    add("expected_kind", arguments.expect)
    add("kv_buffer_kind_lines", len(kinds))
    kind_values = sorted({record["kind"] for record in kinds})
    add("kv_buffer_kinds", ",".join(kind_values) if kind_values else "-")
    if not kinds:
        faults.append("the log carries no kv_buffer_kind line, so no KV cache constructor ran")
    elif kind_values != [arguments.expect]:
        faults.append("kv_buffer_kind reads %s where %s was expected" % (",".join(kind_values), arguments.expect))
    add("kv_size_lines", len(kv_sizes))
    add("rs_size_lines", len(rs_sizes))
    # One KV cache constructor prints one size line and one kind line for the
    # same buffer, so the two have to agree in count and in buffer name; a
    # log with neither or with a kind line naming another buffer than the
    # one sized is a different run than the one claimed.
    if len(kv_sizes) != 1 or len(kinds) != 1:
        faults.append("expected exactly one KV buffer size line and one kv_buffer_kind line, found %d and %d"
                      % (len(kv_sizes), len(kinds)))
    elif kv_sizes[0]["buffer"] != kinds[0]["buffer"]:
        faults.append("the KV buffer size line names %s where the kind line names %s"
                      % (kv_sizes[0]["buffer"], kinds[0]["buffer"]))
    if not rs_sizes:
        faults.append("the log carries no RS buffer size line, so the recurrent store is unaccounted")
    add("paged_buffer_lines", len(buffers))
    add("paged_tensor_lines", len(tensors))

    if arguments.expect == "device_default":
        if buffers or tensors:
            faults.append("a device_default arm records %d paged buffers and %d paged tensors"
                          % (len(buffers), len(tensors)))
        for key in ("kv_logical_bytes", "kv_virtual_reserved_bytes", "kv_physical_mapped_bytes",
                    "kv_alignment_padding_bytes", "vmm_granularity_minimum", "vmm_granularity_recommended",
                    "unit_bytes"):
            add(key, "n/a")
    else:
        if len(buffers) != 1:
            faults.append("expected exactly one paged KV buffer, found %d" % len(buffers))
        if not tensors:
            faults.append("no paged_kv_tensor line, so no tensor was placed in the paged buffer")
        virtual = sum(record["virtual"] for record in buffers)
        mapped = sum(record["mapped"] for record in buffers)
        requested = sum(record["requested"] for record in buffers)
        logical = sum(record["nbytes"] for record in tensors)
        padded = sum(record["padded"] for record in tensors)
        units = {record["unit"] for record in buffers} | {record["unit"] for record in tensors}
        minima = {record["minimum"] for record in buffers}
        recommended = {record["recommended"] for record in buffers}
        add("kv_logical_bytes", logical)
        add("kv_requested_bytes", requested)
        add("kv_virtual_reserved_bytes", virtual)
        add("kv_physical_mapped_bytes", mapped)
        add("kv_alignment_padding_bytes", virtual - logical)
        # The KV buffer size line is the constructor's own view of the same
        # buffer to two decimals of a MiB, and the two have to agree.
        for size_record in kv_sizes:
            printed_mib = float(size_record["mib"])
            if abs(printed_mib - virtual / 1048576.0) > 0.01:
                faults.append("the KV buffer size line reads %.2f MiB where the reservation is %.2f MiB"
                              % (printed_mib, virtual / 1048576.0))
        add("kv_tensor_padded_bytes", padded)
        add("unit_bytes", ",".join(str(value) for value in sorted(units)) or "-")
        add("vmm_granularity_minimum", ",".join(str(value) for value in sorted(minima)) or "-")
        add("vmm_granularity_recommended", ",".join(str(value) for value in sorted(recommended)) or "-")
        add("memory_saved_bytes", 0)
        if len(units) != 1:
            faults.append("the buffer and tensor lines name %d distinct mapping units" % len(units))
        unit = next(iter(units)) if units else 0
        if unit <= 0 or any(record["minimum"] <= 0 or record["recommended"] <= 0 for record in buffers):
            faults.append("a mapping unit or granularity reads zero")
        if arguments.expect_tensors is not None and len(tensors) != arguments.expect_tensors:
            faults.append("the log records %d paged tensors where the census predicts %d"
                          % (len(tensors), arguments.expect_tensors))
        if arguments.expect_names is not None:
            expected_names = sorted(name for name in arguments.expect_names.split(",") if name)
            found_names = sorted(record["name"] for record in tensors)
            if expected_names != found_names:
                faults.append("the paged tensor names differ from the census: missing %s, extra %s"
                              % (",".join(sorted(set(expected_names) - set(found_names))) or "-",
                                 ",".join(sorted(set(found_names) - set(expected_names))) or "-"))
        # The buffer record names the device and the kind record names the
        # buffer; a paged buffer on device N is the buffer "CUDA<N>".
        for kind in kinds:
            if buffers and kind["buffer"] != "CUDA%d" % buffers[0]["device"]:
                faults.append("the kind line names buffer %s where the paged buffer sits on device %d"
                              % (kind["buffer"], buffers[0]["device"]))
        # Coverage: the allocator's requested size is the sum of every padded
        # extent, so a tensor whose record is absent leaves a gap the sum
        # cannot close, and each record's own geometry has to agree with its
        # type and shape.
        if buffers and padded != requested:
            faults.append("padded tensor extents sum to %d where the buffer requested %d" % (padded, requested))
        names = [record["name"] for record in tensors]
        if len(set(names)) != len(names):
            faults.append("a tensor name repeats in the paged buffer")
        for record in tensors:
            if min(record["ne0"], record["ne1"], record["ne2"], record["row"], record["nbytes"]) <= 0:
                faults.append("tensor %s records a zero dimension or byte count" % record["name"])
                continue
            blocks = TYPE_BLOCKS.get(record["type"])
            if blocks is None:
                faults.append("tensor %s has a type outside the row-size table: %s" % (record["name"], record["type"]))
                continue
            block_bytes, block_elements = blocks
            # The CUDA buffer type pads a quantized row whose ne0 is not a
            # multiple of 512 by one padding row's worth of bytes and leaves
            # every other tensor at ggml_nbytes, so alloc_bytes is determined
            # by the type and ne0 rather than free to vary.
            if block_elements > 1 and record["ne0"] % 512 != 0:
                expected_alloc = record["nbytes"] + (512 - record["ne0"] % 512) // block_elements * block_bytes
            else:
                expected_alloc = record["nbytes"]
            if record["alloc"] != expected_alloc:
                faults.append("tensor %s alloc_bytes=%d disagrees with the backend padding rule (%d)"
                              % (record["name"], record["alloc"], expected_alloc))
            if record["ne0"] % block_elements != 0 or record["row"] != record["ne0"] // block_elements * block_bytes:
                faults.append("tensor %s row_bytes=%d disagrees with type %s at ne0=%d"
                              % (record["name"], record["row"], record["type"], record["ne0"]))
            if record["nbytes"] != record["row"] * record["ne1"] * record["ne2"]:
                faults.append("tensor %s nbytes=%d disagrees with row_bytes * ne1 * ne2" % (record["name"], record["nbytes"]))
            if record["nbytes"] > record["alloc"]:
                faults.append("tensor %s nbytes exceeds alloc_bytes" % record["name"])
            if unit and record["padded"] != -(-record["alloc"] // unit) * unit:
                faults.append("tensor %s padded_bytes is not alloc_bytes rounded to the unit" % record["name"])
        # Every attention layer carries both operands, since the cache
        # allocates K and V of one layer together.
        per_layer = {}
        for record in tensors:
            match = KV_TENSOR_NAME.match(record["name"])
            if match:
                per_layer.setdefault(int(match.group("layer")), set()).add(record["name"][6])
        odd = [layer for layer, operands in per_layer.items() if operands != {"k", "v"}]
        if odd:
            faults.append("layers without both K and V in the paged buffer: %s" % ",".join(str(layer) for layer in sorted(odd)))
        if buffers and any(record["mapped"] != record["virtual"] for record in buffers):
            faults.append("physical_mapped_bytes differs from virtual_reserved_bytes on a fully backed buffer")
        if buffers and any(record["mapped"] < record["requested"] for record in buffers):
            faults.append("physical_mapped_bytes falls under requested_bytes")
        if buffers and any(record["access"] != "device_rw" for record in buffers):
            faults.append("a paged buffer records access other than device_rw")
        if unit and any(record["minimum"] % unit != 0 or unit % record["minimum"] != 0 for record in buffers):
            faults.append("the mapping unit is not the driver's minimum granularity")
        if unit and virtual % unit != 0:
            faults.append("the virtual reservation is not a whole number of mapping units")
        if padded > virtual:
            faults.append("padded tensor extents exceed the virtual reservation")
        misaligned = [record["name"] for record in tensors
                      if record["start"] != "yes" or record["extent"] != "yes"
                      or (unit and (record["offset"] % unit != 0 or record["padded"] % unit != 0))]
        add("tensors_misaligned", ",".join(misaligned) if misaligned else "-")
        if misaligned:
            faults.append("tensors misaligned to the mapping unit: %s" % ",".join(misaligned))
        foreign = [record["name"] for record in tensors if not KV_TENSOR_NAME.match(record["name"])]
        add("tensors_outside_attention_kv", ",".join(foreign) if foreign else "-")
        if foreign:
            faults.append("tensors outside the attention KV set sit in the paged buffer: %s" % ",".join(foreign))
        layers = sorted({int(KV_TENSOR_NAME.match(record["name"]).group("layer"))
                         for record in tensors if KV_TENSOR_NAME.match(record["name"])})
        add("attention_layers", ",".join(str(layer) for layer in layers) if layers else "-")
        add("attention_layer_count", len(layers))
        # Every offset plus padded extent must stay inside the reservation and
        # no two extents may overlap, which is what "one mapping unit inside
        # one tensor" means at the buffer level.
        spans = sorted((record["offset"], record["offset"] + record["padded"], record["name"]) for record in tensors)
        for (left_start, left_end, left_name), (right_start, _right_end, right_name) in zip(spans, spans[1:]):
            if right_start < left_end:
                faults.append("tensor extents overlap: %s and %s" % (left_name, right_name))
        if spans and spans[-1][1] > virtual:
            faults.append("a tensor extent ends past the virtual reservation")
        for record in tensors:
            row_crosses = record["row"] and unit and unit % record["row"] != 0
            add("tensor:%s" % record["name"],
                "type=%s row_bytes=%d nbytes=%d padded_bytes=%d offset=%d rows_per_unit=%s"
                % (record["type"], record["row"], record["nbytes"], record["padded"], record["offset"],
                   ("%d" % (unit // record["row"])) if (unit and record["row"] and not row_crosses)
                   else ("%.3f_rows_cross_unit" % (unit / record["row"]) if record["row"] and unit else "-")))

    add("faults", len(faults))
    add("verdict", "layout_holds" if not faults else "layout_refused")
    for key, value in rows:
        print("%s\t%s" % (key, value))
    for fault in faults:
        print("fault\t%s" % fault)
    return 0 if not faults else 1


if __name__ == "__main__":
    sys.exit(main())
