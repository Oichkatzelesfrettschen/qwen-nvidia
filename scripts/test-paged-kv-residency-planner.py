#!/usr/bin/env python3
"""Hold paged-kv-residency-planner.py to the served 2B layout.

Every case uses the layout the P1 record admitted: six attention layers,
K rows of 544 bytes and V rows of 288, 65536 cells, a 2 MiB unit, one or
three streams. The cases are the ones evidence/ada/paged-kv-residency/README.md
names for P2-B: growth across a unit boundary and across a padding boundary,
a sequence removed while another still holds the unit, tail reclamation and
regrowth with zero-initialization, restore across a boundary, K-shift and
cross-stream copy as whole-tensor requirements, the in-flight hold released
by quiescence alone, and interior holes retained below the high-water mark.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "paged-kv-residency-planner.py")
G = 2097152
K_ROW, V_ROW, DEPTH = 544, 288, 65536
LAYERS = (3, 7, 11, 15, 19, 23)

spec = importlib.util.spec_from_file_location("planner", SCRIPT)
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)

failures = 0


def report(name, ok, detail=""):
    global failures
    print(f"{name}={'accepted' if ok else 'rejected'}{(' ' + detail) if detail else ''}")
    if not ok:
        failures += 1


def layout_dict(n_stream=1, depth=DEPTH):
    tensors = []
    offset = 0
    for il in LAYERS:
        for operand, row in (("k", K_ROW), ("v", V_ROW)):
            tensors.append({"name": f"cache_{operand}_l{il}", "offset": offset, "row_bytes": row})
            offset += -(-row * depth * n_stream // G) * G
    return {"event": "layout", "unit_bytes": G, "kv_size": depth, "n_stream": n_stream, "tensors": tensors}


def make(n_stream=1, depth=DEPTH, **kw):
    return planner.Planner(planner.Layout.from_dict(layout_dict(n_stream, depth)), **kw)


def units_per_layer_for_rows(h):
    return -(-K_ROW * h // G) + -(-V_ROW * h // G)


# 1. The layout arithmetic: units from byte intervals, rows crossing a boundary.
lay = planner.Layout.from_dict(layout_dict())
k3 = lay.tensors[0]
report("layout_unit_count", lay.unit_count == 6 * (17 + 9), str(lay.unit_count))
# Row 3855 of K spans bytes 2096720..2097264, both sides of the first boundary.
report("row_crossing_boundary_needs_both_units",
       lay.rows_units(k3, 0, 3855, 3856) == {0, 1})
report("row_inside_unit_needs_one", lay.rows_units(k3, 0, 0, 1) == {0})
report("cells_per_unit_is_not_an_integer", (G % K_ROW) != 0 and (G % V_ROW) != 0)

# 2. Growth across the 256-row padding boundary and across a unit boundary.
p = make()
r = p.apply({"event": "ubatch", "streams": [{"cells": list(range(0, 200))}]})
report("first_pass_envelope_is_256", r["note"] == "n_kv=256")
report("first_pass_requires_one_unit_per_tensor", r["required"] == 12, str(r["required"]))
report("shadow_mode_keeps_every_unit_mapped", r["mapped"] == lay.unit_count)
report("shadow_mode_names_reclaimable_tails", r["reclaimable"] == lay.unit_count - 12, str(r["reclaimable"]))
r = p.apply({"event": "ubatch", "streams": [{"cells": list(range(200, 300))}]})
report("padding_boundary_moves_envelope_to_512", r["note"] == "n_kv=512")
# 3855 K rows fill unit 0; row 3855 crosses into unit 1 of every K tensor.
r = p.apply({"event": "ubatch", "streams": [{"cells": list(range(300, 3856))}]})
report("unit_boundary_growth_adds_second_k_unit", r["required"] == 6 * (2 + 1), str(r["required"]))
report("attention_envelope_is_padded", r["note"] == "n_kv=4096")

# 3. Standing envelope: after quiescence the padded prefix is still required.
r = p.apply({"event": "quiesce"})
report("quiesce_retires_inflight", r["inflight"] == 0)
report("quiesce_keeps_standing_envelope", r["attention"] == 6 * (2 + 1), str(r["attention"]))
report("quiesce_proposes_tail_only", r["reclaimable"] == lay.unit_count - 18, str(r["reclaimable"]))

# 4. The M(h) table of the contract, from the planner's own arithmetic.
for h, mib in ((4096, 36), (32768, 168), (65536, 312)):
    q = make()
    q.apply({"event": "ubatch", "streams": [{"cells": list(range(0, h))}]})
    r = q.apply({"event": "quiesce"})
    backing_mib = (lay.unit_count - r["reclaimable"]) * G // (1024 * 1024)
    report(f"backing_at_{h}_rows_is_{mib}_mib", backing_mib == mib, str(backing_mib))

# 5. A sequence removed while another still holds the unit keeps it live.
p = make()
p.apply({"event": "ubatch", "streams": [{"seq": 0, "cells": list(range(0, 100))}]})
p.apply({"event": "ubatch", "streams": [{"seq": 1, "cells": list(range(100, 200))}]})
p.apply({"event": "quiesce"})
r = p.apply({"event": "seq_rm", "seq": 0, "all": True})
report("shared_unit_survives_one_sequence_removal", r["live"] == 12 and r["reclaimable"] == lay.unit_count - 12)
r = p.apply({"event": "seq_rm", "seq": 1, "all": True})
report("empty_cache_holds_no_live_unit", r["live"] == 0 and r["attention"] == 0)
r = p.apply({"event": "quiesce"})
report("empty_cache_is_fully_reclaimable", r["reclaimable"] == lay.unit_count)

# 6. Interior holes stay backed below the high-water mark.
p = make()
p.apply({"event": "ubatch", "streams": [{"seq": 0, "cells": list(range(0, 8000))}]})
p.apply({"event": "quiesce"})
r = p.apply({"event": "seq_rm", "seq": 0, "cells": list(range(3000, 7000))})
report("interior_hole_keeps_envelope", r["note"] == "seq=0" and r["attention"] == 6 * (3 + 2), str(r["attention"]))
p2 = make()
p2.apply({"event": "ubatch", "streams": [{"seq": 0, "cells": list(range(0, 20000))}]})
p2.apply({"event": "seq_rm", "seq": 0, "cells": list(range(4000, 19000))})
r = p2.apply({"event": "quiesce"})
# live rows 0..4000 and 19000..20000; envelope [0, 20224) covers the hole, so
# nothing between is reclaimable and the interior count is zero here; drop the
# tail sequence entirely and the hole becomes real.
p2.apply({"event": "seq_rm", "seq": 0, "cells": list(range(19000, 20000))})
r = p2.apply({"event": "quiesce"})
report("envelope_shrinks_with_live_rows", r["attention"] == 6 * (2 + 1), str(r["attention"]))
p3 = make()
p3.apply({"event": "ubatch", "streams": [{"seq": 0, "cells": [0, 30000]}]})
r = p3.apply({"event": "quiesce"})
# Live rows 0 and 30000: get_n_kv pads the envelope to [0, 30208), so every
# unit between the two rows is an attention requirement rather than a mere
# interior retention. The envelope subsumes interior holes under the pinned
# padding rule, which is why interior_retained reads zero and the units are
# held by attention; the interior class stays as the guard for a padding rule
# that no longer starts at row 0.
units_between = 6 * (-(-K_ROW * 30208 // G) + -(-V_ROW * 30208 // G))
report("interior_hole_is_inside_the_envelope",
       r["interior_retained"] == 0 and r["attention"] == units_between
       and r["reclaimable"] == lay.unit_count - units_between,
       f"interior={r['interior_retained']} attention={r['attention']} reclaimable={r['reclaimable']}")

# 7. Commit-tails mode: reclaim, regrow, commit with zero-init, accounting.
p = make(commit_tails=True)
p.apply({"event": "ubatch", "streams": [{"cells": list(range(0, 100))}]})
r = p.apply({"event": "quiesce"})
report("commit_tails_releases_at_quiesce", r["released"] == lay.unit_count - 12 and r["mapped"] == 12)
report("released_bytes_counted", r["physical_released_bytes"] == (lay.unit_count - 12) * G
       and r["physical_allocated_bytes"] == 12 * G and r["physical_mapped_bytes"] == 12 * G)
r = p.apply({"event": "ubatch", "streams": [{"cells": list(range(100, 4000))}]})
report("regrowth_commits_missing_units", r["committed"] == 6 and r["mapped"] == 18 and "fault" not in r, str(r["committed"]))
report("allocated_tracks_commit", r["physical_allocated_bytes"] == 18 * G)
p = make(commit_tails=True, retain_pool=4)
p.apply({"event": "ubatch", "streams": [{"cells": list(range(0, 100))}]})
r = p.apply({"event": "quiesce"})
report("retained_pool_is_cached_not_released",
       r["physical_retained_unmapped_bytes"] == 4 * G
       and r["physical_released_bytes"] == (lay.unit_count - 12 - 4) * G
       and r["physical_allocated_bytes"] == 16 * G)
r = p.apply({"event": "ubatch", "streams": [{"cells": list(range(100, 4000))}]})
report("commit_draws_from_pool_first", r["physical_retained_unmapped_bytes"] == 0 and r["physical_allocated_bytes"] == 18 * G)

# 8. Shadow mode never changes a mapping and never faults on a mapped unit.
p = make()
p.apply({"event": "ubatch", "streams": [{"cells": list(range(0, 100))}]})
r = p.apply({"event": "quiesce"})
report("shadow_mode_releases_nothing", r["released"] == 0 and r["mapped"] == lay.unit_count)

# 9. Restore across a unit boundary commits the destination before it is live.
p = make(commit_tails=True)
p.apply({"event": "ubatch", "streams": [{"cells": list(range(0, 10))}]})
p.apply({"event": "quiesce"})
r = p.apply({"event": "restore", "seq": 2, "cells": list(range(3800, 3900))})
report("restore_commits_destination_units", r["committed"] > 0 and r["maintenance"] > 0 and "fault" not in r)
report("restore_destination_is_live", r["live"] == r["required"] or r["live"] > 12)

# 10. K-shift and cross-stream copy are whole-tensor requirements.
p = make(n_stream=3, commit_tails=True)
p.apply({"event": "ubatch", "streams": [{"stream": 0, "cells": list(range(0, 100))}]})
p.apply({"event": "quiesce"})
r = p.apply({"event": "k_shift"})
k_units = sum(len(u) for t, s, u in p.layout.regions() if t["operand"] == "K")
report("k_shift_requires_every_k_unit", r["maintenance"] == k_units and r["whole_operation_commit"] == "yes", str(r["maintenance"]))
p.apply({"event": "quiesce"})
r = p.apply({"event": "stream_copy", "src": 0, "dst": 2})
both = sum(len(u) for t, s, u in p.layout.regions() if s in (0, 2))
report("stream_copy_requires_both_whole_streams", r["maintenance"] == both, str(r["maintenance"]))
report("stream_copy_copies_live_state", p.used_max_p1(2) == 100)
r = p.apply({"event": "quiesce"})
report("copied_stream_holds_its_envelope", r["attention"] == 2 * 12, str(r["attention"]))

# 11. Clear resets live state and memsets the resident set alone.
p = make(commit_tails=True)
p.apply({"event": "ubatch", "streams": [{"cells": list(range(0, 5000))}]})
p.apply({"event": "quiesce"})
r = p.apply({"event": "clear"})
report("clear_touches_resident_units_only", r["maintenance"] == r["mapped"] and r["live"] == 0)

# 12. In-flight units are held until quiescence, whatever the live state does.
p = make(commit_tails=True)
p.apply({"event": "ubatch", "streams": [{"seq": 0, "cells": list(range(0, 5000))}]})
r = p.apply({"event": "seq_rm", "seq": 0, "all": True})
report("inflight_holds_units_after_removal", r["inflight"] == 18 and r["reclaimable"] == lay.unit_count - 18)
r = p.apply({"event": "quiesce"})
report("quiesce_releases_the_held_units", r["released"] == lay.unit_count)

# 13. Refusals: misaligned offset, overlap, out-of-range cell, unknown event, bad stream.
def refused(fn, needle):
    try:
        fn()
    except planner.PlannerFault as fault:
        return needle in str(fault)
    return False

bad = layout_dict()
bad["tensors"][1]["offset"] += 1
report("misaligned_offset_refused", refused(lambda: planner.Layout.from_dict(bad), "unit multiple"))
bad = layout_dict()
bad["tensors"][1]["offset"] = bad["tensors"][0]["offset"]
report("overlap_refused", refused(lambda: planner.Layout.from_dict(bad), "overlaps"))
report("cell_out_of_range_refused", refused(lambda: make().apply({"event": "ubatch", "streams": [{"cells": [DEPTH]}]}), "outside"))
report("unknown_event_refused", refused(lambda: make().apply({"event": "evict"}), "unknown event"))
report("bad_stream_refused", refused(lambda: make().apply({"event": "seq_rm", "stream": 5, "all": True}), "stream"))
report("stream_copy_to_self_refused", refused(lambda: make(n_stream=2).apply({"event": "stream_copy", "src": 1, "dst": 1}), "src equals dst"))
bad = layout_dict()
bad["tensors"][0]["name"] = "key_l3"
report("unresolved_operand_refused", refused(lambda: planner.Layout.from_dict(bad), "no K or V operand"))
bad = layout_dict()
bad["tensors"][0]["operand"] = "Q"
report("foreign_operand_refused", refused(lambda: planner.Layout.from_dict(bad), "no K or V operand"))

# 14. The command line: reports written, summary line, log-derived layout, refusal status.
with tempfile.TemporaryDirectory() as work:
    events = os.path.join(work, "events.jsonl")
    with open(events, "w") as handle:
        handle.write(json.dumps(layout_dict()) + "\n")
        handle.write(json.dumps({"event": "ubatch", "streams": [{"cells": list(range(0, 600))}]}) + "\n")
        handle.write(json.dumps({"event": "quiesce"}) + "\n")
    out = os.path.join(work, "shadow")
    run = subprocess.run([sys.executable, SCRIPT, events, "--out", out], capture_output=True, text=True)
    report("cli_shadow_runs", run.returncode == 0 and "residency_planner=planned mode=shadow" in run.stdout, run.stdout.strip() + run.stderr.strip())
    report("cli_writes_reports", all(os.path.exists(os.path.join(out, f)) for f in ("events.tsv", "units.tsv", "events.jsonl")))
    with open(os.path.join(out, "units.tsv")) as handle:
        rows = handle.read().splitlines()
    report("units_report_names_holders", rows[0] == "unit\tstate\tholder\tregions" and rows[1].split("\t")[2] != "-" and "cache_k_l3:stream0" in rows[1])
    run = subprocess.run([sys.executable, SCRIPT, events, "--out", os.path.join(work, "commit"), "--commit-tails"], capture_output=True, text=True)
    report("cli_commit_tails_runs", run.returncode == 0 and "mode=commit-tails" in run.stdout and "physical_released_bytes=%d" % ((lay.unit_count - 12) * G) in run.stdout, run.stdout.strip())
    log = os.path.join(work, "server.log")
    with open(log, "w") as handle:
        offset = 0
        for il in LAYERS:
            for operand, row in (("k", K_ROW), ("v", V_ROW)):
                nbytes = row * DEPTH
                padded = -(-nbytes // G) * G
                handle.write("ggml_backend_cuda_buffer_init_tensor: paged_kv_tensor name=cache_%s_l%d type=q8_0 ne0=512 ne1=%d ne2=1"
                             " row_bytes=%d nbytes=%d alloc_bytes=%d padded_bytes=%d offset=%d unit_bytes=%d start_aligned=yes extent_aligned=yes\n"
                             % (operand, il, DEPTH, row, nbytes, nbytes, padded, offset, G))
                offset += padded
    with open(events, "w") as handle:
        handle.write(json.dumps({"event": "ubatch", "streams": [{"cells": list(range(0, 600))}]}) + "\n")
    run = subprocess.run([sys.executable, SCRIPT, events, "--out", os.path.join(work, "fromlog"), "--layout-from-log", log], capture_output=True, text=True)
    report("cli_layout_from_log", run.returncode == 0 and "units=156" in run.stdout, run.stdout.strip() + run.stderr.strip())
    with open(events, "w") as handle:
        handle.write(json.dumps({"event": "ubatch", "streams": [{"cells": [1]}]}) + "\n")
    run = subprocess.run([sys.executable, SCRIPT, events, "--out", os.path.join(work, "nolayout")], capture_output=True, text=True)
    report("cli_refuses_without_layout", run.returncode == 1 and "first event must be the layout" in run.stderr)
    # A log whose tensors disagree on geometry, or whose nbytes contradicts
    # row * cells * streams, or whose tensors fail to cover the reservation,
    # is refused rather than planned at the last tensor's extent.
    with open(log) as handle:
        good = handle.read()
    with open(events, "w") as handle:
        handle.write(json.dumps({"event": "ubatch", "streams": [{"cells": [1]}]}) + "\n")
    shrunk = good.replace("name=cache_k_l3 type=q8_0 ne0=512 ne1=%d" % DEPTH,
                          "name=cache_k_l3 type=q8_0 ne0=512 ne1=%d" % (DEPTH // 2), 1)
    with open(log, "w") as handle:
        handle.write(shrunk)
    run = subprocess.run([sys.executable, SCRIPT, events, "--out", os.path.join(work, "shrunk"), "--layout-from-log", log], capture_output=True, text=True)
    report("log_with_disagreeing_geometry_refused", run.returncode == 1 and ("is not row" in run.stderr or "disagree" in run.stderr), run.stderr.strip()[-160:])
    with open(log, "w") as handle:
        handle.write("ggml_backend_cuda_paged_kv_alloc_buffer: paged_kv_buffer device=0 requested_bytes=1 virtual_reserved_bytes=%d"
                     " physical_mapped_bytes=%d unit_bytes=%d granularity_minimum=%d granularity_recommended=%d access=device_rw\n"
                     % (G * 200, G * 200, G, G, G) + good)
    run = subprocess.run([sys.executable, SCRIPT, events, "--out", os.path.join(work, "uncovered"), "--layout-from-log", log], capture_output=True, text=True)
    report("log_whose_tensors_fail_to_cover_the_reservation_refused", run.returncode == 1 and "reserved" in run.stderr, run.stderr.strip()[-160:])

print("test_paged_kv_residency_planner=%s failures=%d" % ("accepted" if failures == 0 else "rejected", failures))
sys.exit(1 if failures else 0)
