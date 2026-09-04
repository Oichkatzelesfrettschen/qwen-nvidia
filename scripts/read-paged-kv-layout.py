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


def read_log(path):
    buffers, tensors, kinds, kv_sizes, rs_sizes = [], [], [], [], []
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
    return buffers, tensors, kinds, kv_sizes, rs_sizes


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("--expect", required=True, choices=("paged_kv_vmm", "device_default"))
    arguments = parser.parse_args()

    buffers, tensors, kinds, kv_sizes, rs_sizes = read_log(arguments.log)
    faults = []
    rows = []

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
        add("kv_tensor_padded_bytes", padded)
        add("unit_bytes", ",".join(str(value) for value in sorted(units)) or "-")
        add("vmm_granularity_minimum", ",".join(str(value) for value in sorted(minima)) or "-")
        add("vmm_granularity_recommended", ",".join(str(value) for value in sorted(recommended)) or "-")
        add("memory_saved_bytes", 0)
        if len(units) != 1:
            faults.append("the buffer and tensor lines name %d distinct mapping units" % len(units))
        unit = next(iter(units)) if units else 0
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
