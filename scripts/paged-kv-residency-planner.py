#!/usr/bin/env python3
"""Shadow residency planner for the paged attention KV cache (P2-B).

The planner takes the layout of one paged KV buffer -- the mapping unit,
the cell count and stream count, and one offset and row size per tensor --
and an event stream describing what the cache does: ubatch writes, sequence
removal, state restore, cross-stream copy, K-shift, clear, and quiescence.
It computes, per mapping unit, the five requirement classes of
evidence/ada/paged-kv-residency/README.md (live state, attention, writes,
maintenance, in flight), explains every retained unit, and proposes releases
at a quiescence event alone, in tails alone: a unit below the high-water
requirement of a stream region stays backed whatever its cells hold.

Units come from byte intervals. Rows [a, b) of stream s of a tensor at
offset o with row size r over S cells occupy [o + s*r*S + a*r, o + s*r*S + b*r),
and the units are floor(lo / G) through floor((hi - 1) / G). A row crossing
a unit boundary requires both units. No integer cells-per-unit exists here.

The default mode changes no mapping: every unit stays mapped and the report
names what would be reclaimable. --commit-tails simulates P2-C over the same
events: reclaimable tails are unmapped at quiescence, and a later requirement
on an unmapped unit commits it (from the retained pool first, then a new
allocation) with zero-initialization before the operation runs. The five
accounting quantities are carried per event; a unit unmapped into the pool is
cached memory, counted as held.

Usage:
  paged-kv-residency-planner.py EVENTS.jsonl --out DIR [--commit-tails]
      [--retain-pool UNITS] [--layout-from-log SERVER_LOG]
"""

import argparse
import json
import os
import re
import sys

ATTENTION_PAD = 256
CLASSES = ("live", "attention", "writes", "maintenance", "inflight")

TENSOR_LINE = re.compile(
    r"paged_kv_tensor name=(?P<name>\S+) type=(?P<type>\S+) ne0=(?P<ne0>\d+) ne1=(?P<ne1>\d+)"
    r" ne2=(?P<ne2>\d+) row_bytes=(?P<row>\d+) nbytes=(?P<nbytes>\d+) alloc_bytes=(?P<alloc>\d+)"
    r" padded_bytes=(?P<padded>\d+) offset=(?P<offset>\d+) unit_bytes=(?P<unit>\d+)")


class PlannerFault(Exception):
    """A layout or event the planner refuses; the message names the rule."""


def units_of(lo, hi, unit):
    if hi <= lo:
        return set()
    return set(range(lo // unit, (hi - 1) // unit + 1))


class Layout:
    def __init__(self, unit_bytes, kv_size, n_stream, tensors):
        for name, value in (("unit_bytes", unit_bytes), ("kv_size", kv_size), ("n_stream", n_stream)):
            if not isinstance(value, int) or value <= 0:
                raise PlannerFault(f"layout {name} must be a positive integer: {value!r}")
        self.unit = unit_bytes
        self.kv_size = kv_size
        self.n_stream = n_stream
        self.tensors = []
        seen = set()
        for t in tensors:
            name = t.get("name")
            offset = t.get("offset")
            row = t.get("row_bytes")
            if not isinstance(name, str) or not name:
                raise PlannerFault("layout tensor without a name")
            if name in seen:
                raise PlannerFault(f"layout names {name} twice")
            seen.add(name)
            if not isinstance(offset, int) or offset < 0 or offset % unit_bytes:
                raise PlannerFault(f"tensor {name} offset {offset!r} is not a unit multiple")
            if not isinstance(row, int) or row <= 0:
                raise PlannerFault(f"tensor {name} row_bytes {row!r} is not positive")
            operand = t.get("operand") or ("K" if "_k_" in name else "V" if "_v_" in name else "?")
            self.tensors.append({"name": name, "offset": offset, "row_bytes": row,
                                 "operand": operand, "nbytes": row * kv_size * n_stream})
        self.tensors.sort(key=lambda t: t["offset"])
        end = 0
        for t in self.tensors:
            if t["offset"] < end:
                raise PlannerFault(f"tensor {t['name']} overlaps the tensor before it")
            end = t["offset"] + t["nbytes"]
        self.total_bytes = -(-end // unit_bytes) * unit_bytes if end else 0
        self.unit_count = self.total_bytes // unit_bytes
        if self.unit_count == 0:
            raise PlannerFault("layout holds no tensor")

    def region(self, tensor, stream):
        base = tensor["offset"] + stream * tensor["row_bytes"] * self.kv_size
        return base, base + tensor["row_bytes"] * self.kv_size

    def rows_units(self, tensor, stream, a, b):
        base, _ = self.region(tensor, stream)
        r = tensor["row_bytes"]
        return units_of(base + a * r, base + b * r, self.unit)

    def cells_units(self, tensor, stream, cells):
        out = set()
        for a, b in runs(cells):
            out |= self.rows_units(tensor, stream, a, b)
        return out

    def regions(self):
        for t in self.tensors:
            for s in range(self.n_stream):
                lo, hi = self.region(t, s)
                yield t, s, units_of(lo, hi, self.unit)

    @classmethod
    def from_dict(cls, d):
        return cls(d.get("unit_bytes"), d.get("kv_size"), d.get("n_stream"), d.get("tensors") or [])

    @classmethod
    def from_log(cls, path):
        tensors = []
        unit = kv = ns = None
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                m = TENSOR_LINE.search(line)
                if not m:
                    continue
                unit = int(m.group("unit"))
                kv = int(m.group("ne1"))
                ns = int(m.group("ne2"))
                tensors.append({"name": m.group("name"), "offset": int(m.group("offset")),
                                "row_bytes": int(m.group("row"))})
        if not tensors:
            raise PlannerFault(f"no paged_kv_tensor line in {path}")
        return cls(unit, kv, ns, tensors)


def runs(cells):
    out = []
    for c in sorted(set(cells)):
        if out and out[-1][1] == c:
            out[-1][1] = c + 1
        else:
            out.append([c, c + 1])
    return [(a, b) for a, b in out]


def check_cells(layout, cells, what):
    if not isinstance(cells, list) or not cells:
        raise PlannerFault(f"{what}: cells must be a non-empty list")
    for c in cells:
        if not isinstance(c, int) or c < 0 or c >= layout.kv_size:
            raise PlannerFault(f"{what}: cell {c!r} outside [0, {layout.kv_size})")


def check_stream(layout, s, what):
    if not isinstance(s, int) or s < 0 or s >= layout.n_stream:
        raise PlannerFault(f"{what}: stream {s!r} outside [0, {layout.n_stream})")


class Planner:
    def __init__(self, layout, commit_tails=False, retain_pool=0):
        self.layout = layout
        self.commit_tails = commit_tails
        self.retain_pool = retain_pool
        n = layout.unit_count
        self.mapped = set(range(n))
        self.pool_units = 0
        self.released_units = 0
        self.allocated_units = n
        # cells[stream][cell] -> set of sequence ids holding it
        self.cells = [dict() for _ in range(layout.n_stream)]
        self.inflight = set()
        self.records = []
        self.last_holders = {}

    # --- requirement helpers -------------------------------------------------
    def live_units(self):
        out = set()
        for s in range(self.layout.n_stream):
            held = [c for c, seqs in self.cells[s].items() if seqs]
            if not held:
                continue
            for t in self.layout.tensors:
                out |= self.layout.cells_units(t, s, held)
        return out

    def used_max_p1(self, s):
        held = [c for c, seqs in self.cells[s].items() if seqs]
        return max(held) + 1 if held else 0

    def n_kv(self, streams):
        pad = ATTENTION_PAD
        result = 0
        for s in streams:
            padded = max(pad, -(-self.used_max_p1(s) // pad) * pad)
            result = max(result, min(self.layout.kv_size, padded))
        return result

    def standing_attention_units(self):
        """The padded envelope every stream holding cells reads from row 0.

        A graph built for a stream reads [0, n_kv) of that stream on every
        replay until the live set moves, so the envelope is a standing
        requirement rather than one that exists inside a pass alone.
        """
        out = set()
        for s in range(self.layout.n_stream):
            if self.used_max_p1(s) == 0:
                continue
            n_kv = self.n_kv((s,))
            for t in self.layout.tensors:
                out |= self.layout.rows_units(t, s, 0, n_kv)
        return out

    def whole(self, tensor_filter=None, streams=None):
        out = set()
        for t, s, units in self.layout.regions():
            if tensor_filter and not tensor_filter(t):
                continue
            if streams is not None and s not in streams:
                continue
            out |= units
        return out

    # --- events ----------------------------------------------------------------
    def apply(self, event):
        kind = event.get("event")
        req = {c: set() for c in CLASSES}
        note = "-"
        if kind == "ubatch":
            entries = event.get("streams")
            if not isinstance(entries, list) or not entries:
                raise PlannerFault("ubatch: streams must be a non-empty list")
            streams = []
            for e in entries:
                s = e.get("stream", 0)
                check_stream(self.layout, s, "ubatch")
                check_cells(self.layout, e.get("cells"), "ubatch")
                seq = e.get("seq", 0)
                for c in e["cells"]:
                    self.cells[s].setdefault(c, set()).add(seq)
                for t in self.layout.tensors:
                    req["writes"] |= self.layout.cells_units(t, s, e["cells"])
                streams.append(s)
            n_kv = self.n_kv(streams)
            for s in streams:
                for t in self.layout.tensors:
                    req["attention"] |= self.layout.rows_units(t, s, 0, n_kv)
            note = f"n_kv={n_kv}"
            self.inflight |= req["writes"] | req["attention"]
        elif kind == "seq_rm":
            s = event.get("stream", 0)
            check_stream(self.layout, s, "seq_rm")
            seq = event.get("seq", 0)
            if event.get("all"):
                targets = list(self.cells[s])
            else:
                check_cells(self.layout, event.get("cells"), "seq_rm")
                targets = event["cells"]
            for c in targets:
                self.cells[s].get(c, set()).discard(seq)
            note = f"seq={seq}"
        elif kind == "restore":
            s = event.get("stream", 0)
            check_stream(self.layout, s, "restore")
            check_cells(self.layout, event.get("cells"), "restore")
            seq = event.get("seq", 0)
            for t in self.layout.tensors:
                req["maintenance"] |= self.layout.cells_units(t, s, event["cells"])
            for c in event["cells"]:
                self.cells[s].setdefault(c, set()).add(seq)
            self.inflight |= req["maintenance"]
            note = f"seq={seq}"
        elif kind == "stream_copy":
            src, dst = event.get("src"), event.get("dst")
            check_stream(self.layout, src, "stream_copy")
            check_stream(self.layout, dst, "stream_copy")
            if src == dst:
                raise PlannerFault("stream_copy: src equals dst")
            req["maintenance"] |= self.whole(streams=(src, dst))
            self.cells[dst] = {c: set(seqs) for c, seqs in self.cells[src].items()}
            self.inflight |= req["maintenance"]
            note = "whole_streams"
        elif kind == "k_shift":
            req["maintenance"] |= self.whole(tensor_filter=lambda t: t["operand"] == "K")
            self.inflight |= req["maintenance"]
            note = "whole_k_tensors"
        elif kind == "clear":
            self.cells = [dict() for _ in range(self.layout.n_stream)]
            req["maintenance"] |= set(self.mapped)
            self.inflight |= req["maintenance"]
            note = "memset_resident"
        elif kind == "save":
            s = event.get("stream", 0)
            check_stream(self.layout, s, "save")
            note = "live_ranges_only"
        elif kind == "quiesce":
            self.inflight = set()
            note = "inflight_retired"
        else:
            raise PlannerFault(f"unknown event: {kind!r}")

        req["live"] = self.live_units()
        req["attention"] |= self.standing_attention_units()
        req["inflight"] = set(self.inflight)
        required = set().union(*req.values())

        committed = set()
        whole_commit = kind in ("stream_copy", "k_shift")
        if self.commit_tails:
            committed = required - self.mapped
            for _ in committed:
                if self.pool_units:
                    self.pool_units -= 1
                else:
                    self.allocated_units += 1
            self.mapped |= committed

        holders, interior, tail = self.classify(req)
        reclaimable = tail
        released = set()
        if kind == "quiesce" and self.commit_tails:
            released = set(reclaimable)
            self.mapped -= released
            for _ in released:
                if self.pool_units < self.retain_pool:
                    self.pool_units += 1
                else:
                    self.allocated_units -= 1
                    self.released_units += 1
        self.last_holders = {u: (holders.get(u) or interior.get(u) or "tail") for u in self.mapped}

        unit = self.layout.unit
        record = {
            "index": len(self.records),
            "event": kind,
            "note": note,
            "live": len(req["live"]), "attention": len(req["attention"]),
            "writes": len(req["writes"]), "maintenance": len(req["maintenance"]),
            "inflight": len(req["inflight"]), "required": len(required),
            "mapped": len(self.mapped), "interior_retained": len(interior),
            "reclaimable": len(reclaimable), "committed": len(committed),
            "released": len(released),
            "whole_operation_commit": "yes" if (whole_commit and committed) else "no",
            "virtual_reserved_bytes": self.layout.total_bytes,
            "physical_allocated_bytes": self.allocated_units * unit,
            "physical_mapped_bytes": len(self.mapped) * unit,
            "physical_retained_unmapped_bytes": self.pool_units * unit,
            "physical_released_bytes": self.released_units * unit,
            "released_units": sorted(released),
            "committed_units": sorted(committed),
            "reclaimable_units": sorted(reclaimable),
        }
        if kind != "quiesce" and required - self.mapped:
            record["fault"] = "required_unit_unmapped"
        self.records.append(record)
        return record

    def classify(self, req):
        """Return (holders, interior, tail) over mapped units.

        holders maps a required unit to the comma-joined requirement classes
        holding it; interior maps an unrequired mapped unit below the
        high-water requirement of some region it intersects to that region;
        tail is the set of mapped units above every high-water mark of every
        region they intersect and held by nothing.
        """
        holders = {}
        for c in CLASSES:
            for u in req[c]:
                holders[u] = f"{holders[u]},{c}" if u in holders else c
        interior = {}
        tail = set()
        required = set(holders)
        for t, s, units in self.layout.regions():
            touched = units & required
            high = max(touched) if touched else None
            for u in sorted(units):
                if u not in self.mapped or u in required:
                    continue
                if high is not None and u < high:
                    interior.setdefault(u, f"interior:{t['name']}:stream{s}")
        for u in self.mapped:
            if u not in required and u not in interior:
                tail.add(u)
        return holders, interior, tail


def write_reports(planner, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    columns = ["index", "event", "note", "live", "attention", "writes", "maintenance", "inflight",
               "required", "mapped", "interior_retained", "reclaimable", "committed", "released",
               "whole_operation_commit", "virtual_reserved_bytes", "physical_allocated_bytes",
               "physical_mapped_bytes", "physical_retained_unmapped_bytes", "physical_released_bytes",
               "fault"]
    with open(os.path.join(out_dir, "events.tsv"), "w", encoding="utf-8") as handle:
        handle.write("\t".join(columns) + "\n")
        for r in planner.records:
            handle.write("\t".join(str(r.get(c, "-")) for c in columns) + "\n")
    with open(os.path.join(out_dir, "units.tsv"), "w", encoding="utf-8") as handle:
        handle.write("unit\tstate\tholder\tregions\n")
        regions = {}
        for t, s, units in planner.layout.regions():
            for u in units:
                regions.setdefault(u, []).append(f"{t['name']}:stream{s}")
        for u in range(planner.layout.unit_count):
            state = "mapped" if u in planner.mapped else "unmapped"
            holder = planner.last_holders.get(u, "-")
            handle.write(f"{u}\t{state}\t{holder}\t{','.join(regions.get(u, []))}\n")
    with open(os.path.join(out_dir, "events.jsonl"), "w", encoding="utf-8") as handle:
        for r in planner.records:
            handle.write(json.dumps(r, sort_keys=True) + "\n")


def load_events(path):
    events = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise PlannerFault(f"{path}:{number}: {error}") from error
    if not events:
        raise PlannerFault(f"{path}: no events")
    return events


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("events")
    parser.add_argument("--out", required=True)
    parser.add_argument("--commit-tails", action="store_true")
    parser.add_argument("--retain-pool", type=int, default=0)
    parser.add_argument("--layout-from-log")
    args = parser.parse_args(argv)
    if args.retain_pool < 0:
        parser.error("--retain-pool takes a non-negative unit count")
    try:
        events = load_events(args.events)
        if args.layout_from_log:
            layout = Layout.from_log(args.layout_from_log)
        else:
            if events[0].get("event") != "layout":
                raise PlannerFault("first event must be the layout, or pass --layout-from-log")
            layout = Layout.from_dict(events.pop(0))
        if events and events[0].get("event") == "layout":
            raise PlannerFault("layout given twice")
        planner = Planner(layout, commit_tails=args.commit_tails, retain_pool=args.retain_pool)
        for event in events:
            planner.apply(event)
    except PlannerFault as fault:
        print(f"residency_planner=refused fault={fault}", file=sys.stderr)
        return 1
    write_reports(planner, args.out)
    faults = sum(1 for r in planner.records if "fault" in r)
    last = planner.records[-1]
    print("residency_planner=%s mode=%s events=%d units=%d mapped=%d reclaimable=%d "
          "physical_allocated_bytes=%d physical_mapped_bytes=%d physical_retained_unmapped_bytes=%d "
          "physical_released_bytes=%d faults=%d"
          % ("refused" if faults else "planned", "commit-tails" if args.commit_tails else "shadow",
             len(planner.records), layout.unit_count, last["mapped"], last["reclaimable"],
             last["physical_allocated_bytes"], last["physical_mapped_bytes"],
             last["physical_retained_unmapped_bytes"], last["physical_released_bytes"], faults))
    return 1 if faults else 0


if __name__ == "__main__":
    sys.exit(main())
