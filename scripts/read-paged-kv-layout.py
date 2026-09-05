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
       [--expect-residency full|tails] [--expect-tensors N]
       [--expect-names NAME,NAME,...] [--expect-layout NAME=TYPE:NE0,...]
       [--expect-cells N] [--max-allocated-bytes N]
       [--max-latency-median-us N] [--max-latency-p95-us N]

``--expect-residency`` names the policy the paged buffer ran under. ``full``
is the P1 and P2-A boundary, where allocated equals mapped equals reserved
at allocation and no transaction line follows. ``tails`` is P2-C: the
buffer allocates with nothing backed, every ``paged_kv_residency`` line is a
commit or reclaim transaction that changed a unit, every one reads ``ok``,
retained-unmapped stays zero, and the reader reports the largest and the
final allocated figure, the cumulative released figure, and the per-op
latency quantiles; ``--max-allocated-bytes`` and the two latency bounds
turn the preregistered P2-C floors into refusals.

``--expect-tensors`` names the tensor count an independent census of the
checkpoint predicts, ``--expect-names`` the exact tensor names, and
``--expect-layout`` each tensor's type and row width, so a log that records
fewer, other, or differently shaped tensors than the model has attention K
and V operands is refused rather than read as complete. The cell count and
stream count of every tensor are held to the constructor's own size line,
and ``--expect-cells`` binds that count to a value the caller knows.
"""

import argparse
import re
import sys

BUFFER_LINE = re.compile(
    r"paged_kv_buffer device=(?P<device>\d+) requested_bytes=(?P<requested>\d+)"
    r" virtual_reserved_bytes=(?P<virtual>\d+) physical_mapped_bytes=(?P<mapped>\d+)"
    r" unit_bytes=(?P<unit>\d+) granularity_minimum=(?P<minimum>\d+)"
    r" granularity_recommended=(?P<recommended>\d+) access=(?P<access>\S+)"
    r"(?: units=(?P<units>\d+) physical_allocated_bytes=(?P<allocated>\d+)"
    r" physical_retained_unmapped_bytes=(?P<retained>\d+) physical_released_bytes=(?P<released>\d+))?"
    r"(?: residency=(?P<residency>\S+))?\s*$"
)
# One line per transaction that changed a unit or refused, from
# ggml_backend_cuda_paged_kv_require; the fields after op= and result= are
# key=value pairs the reader takes whole.
RESIDENCY_LINE = re.compile(r"paged_kv_residency op=(?P<op>commit|reclaim|destroy) (?P<rest>.*)$")
RESIDENCY_VIOLATION = re.compile(r"paged_kv_residency violation ")
TENSOR_LINE = re.compile(
    r"paged_kv_tensor name=(?P<name>\S+) type=(?P<type>\S+) ne0=(?P<ne0>\d+) ne1=(?P<ne1>\d+)"
    r" ne2=(?P<ne2>\d+) row_bytes=(?P<row>\d+) nbytes=(?P<nbytes>\d+) alloc_bytes=(?P<alloc>\d+)"
    r" padded_bytes=(?P<padded>\d+) offset=(?P<offset>\d+) unit_bytes=(?P<unit>\d+)"
    r" start_aligned=(?P<start>yes|no) extent_aligned=(?P<extent>yes|no)\s*$"
)
KIND_LINE = re.compile(r"kv_buffer_kind=(?P<kind>\S+) buffer=(?P<buffer>\S+)(?: residency=(?P<residency>\S+))?")
KV_SIZE_LINE = re.compile(r"(?P<buffer>\S+) KV buffer size = +(?P<mib>[0-9.]+) MiB")
# llama_kv_cache's own summary: cells, layers, and n_seq_max/n_stream.
KV_CELLS_LINE = re.compile(
    r"llama_kv_cache: size = +[0-9.]+ MiB \( *(?P<cells>\d+) cells, +(?P<layers>\d+) layers, +(?P<seqs>\d+)/(?P<streams>\d+) seqs\)"
)
RS_SIZE_LINE = re.compile(r"(?P<buffer>\S+) RS buffer size = +(?P<mib>[0-9.]+) MiB")
KV_TENSOR_NAME = re.compile(r"^cache_[kv]_l(?P<layer>\d+)$")
# Bytes per block and elements per block, from ggml's type traits, for the
# row-size check; a type outside the table is reported rather than guessed.
TYPE_BLOCKS = {"q8_0": (34, 32), "q4_0": (18, 32), "q4_1": (20, 32), "q5_0": (22, 32),
               "q5_1": (24, 32), "f16": (2, 1), "bf16": (2, 1), "f32": (4, 1)}


def read_log(path):
    buffers, tensors, kinds, kv_sizes, rs_sizes, malformed, cells = [], [], [], [], [], [], []
    transactions, violations = [], 0
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if RESIDENCY_VIOLATION.search(line):
                violations += 1
                continue
            match = RESIDENCY_LINE.search(line)
            if match:
                # Every transaction record carries its result, the published
                # count, the five quantities, and its latency as non-negative
                # integers, each once; a record missing or misspelling one of
                # them is malformed rather than a sample to skip, since a
                # bound computed over an empty series would hold by default.
                record = {"op": match.group("op")}
                duplicate = False
                for pair in match.group("rest").split():
                    key, _, value = pair.partition("=")
                    if key in record:
                        duplicate = True
                    record[key] = int(value) if value.isdigit() else value
                required = ("result", "units_published", "physical_allocated_bytes", "physical_mapped_bytes",
                            "physical_retained_unmapped_bytes", "physical_released_bytes", "latency_us")
                numeric = required[1:] + (("units_changed",) if record.get("result") == "ok" and record["op"] != "destroy" else ())
                if duplicate or record.get("result") not in ("ok", "refused") \
                        or any(key not in record for key in required) \
                        or any(not isinstance(record.get(key), int) for key in numeric):
                    malformed.append(line.rstrip("\n"))
                    continue
                transactions.append(record)
                continue
            match = BUFFER_LINE.search(line)
            if match:
                # The four unit-accounting fields arrive with the P2 allocation
                # boundary; a P1 log carries none of them and reads None.
                buffers.append({key: (int(value) if value.isdigit() else value) if value is not None else None
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
            if "paged_kv_buffer " in line or "paged_kv_tensor " in line or "paged_kv_residency " in line:
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
            match = KV_CELLS_LINE.search(line)
            if match:
                cells.append({key: int(value) for key, value in match.groupdict().items()})
                continue
            match = RS_SIZE_LINE.search(line)
            if match:
                rs_sizes.append(match.groupdict())
    return buffers, tensors, kinds, kv_sizes, rs_sizes, malformed, cells, transactions, violations


def quantile(values, fraction):
    """Nearest-rank quantile: the ceil(fraction * n)-th smallest value, so a p95
    over twelve samples is the twelfth and one slow transaction among eleven
    fast ones reads as the slow one. An empty list reads None."""
    if not values:
        return None
    ordered = sorted(values)
    rank = -(-int(fraction * 1000000) * len(ordered) // 1000000)
    return ordered[max(0, min(len(ordered) - 1, rank - 1))]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("--expect", required=True, choices=("paged_kv_vmm", "device_default"))
    parser.add_argument("--expect-tensors", type=int, default=None)
    parser.add_argument("--expect-names", default=None)
    parser.add_argument("--expect-layout", default=None)
    parser.add_argument("--expect-cells", type=int, default=None)
    parser.add_argument("--expect-streams", type=int, default=None)
    parser.add_argument("--expect-residency", default="full", choices=("full", "tails"))
    parser.add_argument("--max-allocated-bytes", type=int, default=None)
    parser.add_argument("--max-latency-median-us", type=int, default=None)
    parser.add_argument("--max-latency-p95-us", type=int, default=None)
    arguments = parser.parse_args()

    buffers, tensors, kinds, kv_sizes, rs_sizes, malformed, cells, transactions, violations = read_log(arguments.log)
    tails = arguments.expect == "paged_kv_vmm" and arguments.expect_residency == "tails"
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
    if len(cells) != 1:
        faults.append("expected exactly one llama_kv_cache size line naming cells and streams, found %d" % len(cells))
    add("kv_cells", cells[0]["cells"] if len(cells) == 1 else "-")
    add("kv_streams", cells[0]["streams"] if len(cells) == 1 else "-")
    if arguments.expect_cells is not None and (len(cells) != 1 or cells[0]["cells"] != arguments.expect_cells):
        faults.append("the cache reports %s cells where %d were expected"
                      % (cells[0]["cells"] if len(cells) == 1 else "no", arguments.expect_cells))
    if arguments.expect_streams is not None and (len(cells) != 1 or cells[0]["streams"] != arguments.expect_streams):
        faults.append("the cache reports %s streams where %d were expected"
                      % (cells[0]["streams"] if len(cells) == 1 else "no", arguments.expect_streams))
    add("paged_buffer_lines", len(buffers))
    add("paged_tensor_lines", len(tensors))
    add("residency_transaction_lines", len(transactions))
    add("residency_violations", violations)
    if violations:
        faults.append("%d paged KV residency violations: a host access reached an unbacked unit" % violations)

    if arguments.expect == "device_default":
        if buffers or tensors or transactions:
            faults.append("a device_default arm records %d paged buffers, %d paged tensors, and %d transactions"
                          % (len(buffers), len(tensors), len(transactions)))
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
        policies = sorted({record.get("residency") or "-" for record in buffers} | {record.get("residency") or "-" for record in kinds})
        add("residency_policy", ",".join(policies) if policies else "-")
        if arguments.expect_residency == "tails" and policies != ["tails"]:
            faults.append("residency reads %s where tails was expected" % ",".join(policies))
        if arguments.expect_residency == "full" and any(policy not in ("full", "-") for policy in policies):
            faults.append("residency reads %s where full was expected" % ",".join(policies))
        if tails:
            # Under the tails policy the buffer allocates with nothing backed
            # and every unit it holds afterwards was committed by a
            # transaction, so what it saves is the reservation less what the
            # last transaction left allocated; the largest figure any
            # transaction reported is what the envelope cost at its widest.
            refused = [record for record in transactions if record.get("result") != "ok"]
            commits = [record for record in transactions if record["op"] == "commit" and record.get("result") == "ok"]
            reclaims = [record for record in transactions if record["op"] == "reclaim" and record.get("result") == "ok"]
            add("residency_commits", len(commits))
            add("residency_reclaims", len(reclaims))
            add("residency_refusals", len(refused))
            if refused:
                faults.append("%d residency transactions refused: %s" % (
                    len(refused), "; ".join("%s at %s" % (record["op"], record.get("step", "?")) for record in refused[:4])))
            if not commits:
                faults.append("a tails arm records no committed transaction, so no request reached the cache")
            allocated_series = [record["physical_allocated_bytes"] for record in transactions if "physical_allocated_bytes" in record]
            mapped_series = [record["physical_mapped_bytes"] for record in transactions if "physical_mapped_bytes" in record]
            retained_series = [record["physical_retained_unmapped_bytes"] for record in transactions if "physical_retained_unmapped_bytes" in record]
            released_series = [record["physical_released_bytes"] for record in transactions if "physical_released_bytes" in record]
            add("kv_physical_allocated_max_bytes", max(allocated_series) if allocated_series else "-")
            add("kv_physical_allocated_final_bytes", allocated_series[-1] if allocated_series else "-")
            add("kv_physical_mapped_final_bytes", mapped_series[-1] if mapped_series else "-")
            add("kv_physical_released_final_bytes", released_series[-1] if released_series else "-")
            add("memory_saved_bytes", virtual - allocated_series[-1] if allocated_series else "-")
            if any(a != m for a, m in zip(allocated_series, mapped_series)):
                faults.append("allocated and mapped disagree on a transaction line, so a unit is held unmapped")
            if any(value != 0 for value in retained_series):
                faults.append("physical_retained_unmapped_bytes is nonzero, which this engine never produces")
            if any(later < earlier for earlier, later in zip(released_series, released_series[1:])):
                faults.append("physical_released_bytes decreased between transactions")
            if allocated_series and any(value > virtual for value in allocated_series):
                faults.append("a transaction reports more allocated than reserved")
            if arguments.max_allocated_bytes is not None and allocated_series and max(allocated_series) > arguments.max_allocated_bytes:
                faults.append("physical_allocated_bytes peaked at %d over the %d bound"
                              % (max(allocated_series), arguments.max_allocated_bytes))
            for op, records in (("commit", commits), ("reclaim", reclaims)):
                latencies = [record["latency_us"] for record in records]
                median = quantile(latencies, 0.5)
                p95 = quantile(latencies, 0.95)
                add("%s_latency_us_median" % op, median if median is not None else "-")
                add("%s_latency_us_p95" % op, p95 if p95 is not None else "-")
                add("%s_latency_us_max" % op, max(latencies) if latencies else "-")
                if arguments.max_latency_median_us is not None and median is not None and median > arguments.max_latency_median_us:
                    faults.append("%s latency median %d us over the %d us bound" % (op, median, arguments.max_latency_median_us))
                if arguments.max_latency_p95_us is not None and p95 is not None and p95 > arguments.max_latency_p95_us:
                    faults.append("%s latency p95 %d us over the %d us bound" % (op, p95, arguments.max_latency_p95_us))
        else:
            add("memory_saved_bytes", 0)
            if transactions:
                faults.append("%d residency transactions under the full policy, which changes no unit" % len(transactions))
        if len(units) != 1:
            faults.append("the buffer and tensor lines name %d distinct mapping units" % len(units))
        unit = next(iter(units)) if units else 0
        # Under the P2 allocation boundary every unit carries its own handle
        # and the whole reservation stays backed until a residency policy
        # exists, so allocated equals mapped equals reserved, nothing is
        # retained unmapped, nothing is released, and the unit count is the
        # reservation divided by the unit.
        unit_accounted = [record for record in buffers if record.get("units") is not None]
        add("unit_accounting", "present" if unit_accounted else "absent")
        if unit_accounted:
            allocated = sum(record["allocated"] for record in unit_accounted)
            retained = sum(record["retained"] for record in unit_accounted)
            released = sum(record["released"] for record in unit_accounted)
            unit_count = sum(record["units"] for record in unit_accounted)
            add("kv_physical_allocated_bytes", allocated)
            add("kv_physical_retained_unmapped_bytes", retained)
            add("kv_physical_released_bytes", released)
            add("kv_units", unit_count)
            if len(unit_accounted) != len(buffers):
                faults.append("%d of %d buffer lines carry unit accounting" % (len(unit_accounted), len(buffers)))
            if tails:
                if allocated != 0 or mapped != 0:
                    faults.append("physical_allocated_bytes %d or physical_mapped_bytes %d is nonzero at allocation"
                                  " under the tails policy, so the buffer backed units before any requirement" % (allocated, mapped))
            elif allocated != mapped or allocated != virtual:
                faults.append("physical_allocated_bytes %d, physical_mapped_bytes %d, and the reservation %d disagree"
                              " under a fully backed boundary" % (allocated, mapped, virtual))
            if retained != 0 or released != 0:
                faults.append("retained_unmapped %d or released %d is nonzero under a fully backed boundary"
                              % (retained, released))
            if unit > 0 and unit_count * unit != virtual:
                faults.append("%d units of %d bytes do not cover the %d-byte reservation" % (unit_count, unit, virtual))
        else:
            for key in ("kv_physical_allocated_bytes", "kv_physical_retained_unmapped_bytes",
                        "kv_physical_released_bytes", "kv_units"):
                add(key, "n/a")
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
        if arguments.expect_layout is not None:
            expected_layout = {}
            for entry in arguments.expect_layout.split(","):
                if not entry:
                    continue
                name, _, shape = entry.partition("=")
                type_name, _, ne0 = shape.partition(":")
                expected_layout[name] = (type_name, int(ne0))
            for record in tensors:
                expected = expected_layout.get(record["name"])
                if expected is None:
                    faults.append("tensor %s has no layout in the census" % record["name"])
                elif (record["type"], record["ne0"]) != expected:
                    faults.append("tensor %s reads %s:%d where the census predicts %s:%d"
                                  % (record["name"], record["type"], record["ne0"], expected[0], expected[1]))
        if len(cells) == 1:
            for record in tensors:
                if record["ne1"] != cells[0]["cells"] or record["ne2"] != cells[0]["streams"]:
                    faults.append("tensor %s spans ne1=%d ne2=%d where the cache holds %d cells over %d streams"
                                  % (record["name"], record["ne1"], record["ne2"], cells[0]["cells"], cells[0]["streams"]))
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
        if not tails and buffers and any(record["mapped"] != record["virtual"] for record in buffers):
            faults.append("physical_mapped_bytes differs from virtual_reserved_bytes on a fully backed buffer")
        if tails and not unit_accounted:
            faults.append("a tails arm needs the unit accounting fields on the buffer line")
        if unit and buffers and any(record["virtual"] != -(-record["requested"] // unit) * unit for record in buffers):
            faults.append("virtual_reserved_bytes is not requested_bytes rounded up to the unit")
        if not tails and buffers and any(record["mapped"] < record["requested"] for record in buffers):
            faults.append("physical_mapped_bytes falls under requested_bytes")
        if buffers and any(record["access"] != "device_rw" for record in buffers):
            faults.append("a paged buffer records access other than device_rw")
        if unit and any(record["minimum"] <= 0 or record["minimum"] % unit != 0 or unit % record["minimum"] != 0
                        for record in buffers):
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
