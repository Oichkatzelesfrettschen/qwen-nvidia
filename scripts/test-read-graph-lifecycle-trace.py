#!/usr/bin/env python3
"""read-graph-lifecycle-trace.py against a synthetic trace and cycle records.

The fixture builds two measured cycles after a warm-up in the fixed arm and
one in the permuted arm, with a topology that recurs in T0 and T3, a T1
prefill topology that never replays, and a T2 width-2 topology that replays
after one direct execution and one capture. The reader has to assign every
row to its phase, count the warmup resets where the recorder marked them,
name the recurring digests, and put the lifecycle fraction where the
arithmetic of the fixture places it.
"""

import json
import pathlib
import subprocess
import sys
import tempfile

HEADER = ("graph_ordinal\tt_begin_ns\tkey\tkey_ordinal\ttopology_digest\tpointer_digest\tn_nodes"
          "\tn_tokens\tn_outputs\tn_kv\tn_rs"
          "\tenabled\tcompatible\tproperties_changed\tchange_reason\tchange_node\tchange_op\tchange_name\tchange_categories"
          "\twarmup_before\twarmup_after\taction\texecutable\thost_us\tdevice_ms\n")


def row(ordinal, t, digest, n_tokens, n_outputs, action, executable, warm_before, warm_after, device_ms, reason="none", cats="-"):
    changed = "1" if reason != "none" else "0"
    return "\t".join(str(v) for v in (
        ordinal, t, "0x1", 1, digest, "p%d" % ordinal, 1000, n_tokens, n_outputs, 256, 2,
        1, 1, changed, reason, 5 if changed == "1" else -1, "MUL_MAT" if changed == "1" else "-",
        "kq" if changed == "1" else "-", cats,
        warm_before, warm_after, action, executable, 100, "%.4f" % device_ms)) + "\n"


def build(directory):
    directory = pathlib.Path(directory)
    rows = []
    cycles = {"fixed": [], "permuted": []}
    ordinal = 0
    t = 1_000_000_000_000

    def add(step, *fields, **named):
        nonlocal ordinal, t
        rows.append(row(ordinal, t, *fields, **named))
        ordinal += 1
        t += step
    for arm, slot_a, slot_b, n_cycles in (("fixed", 0, 1, 3), ("permuted", 1, 0, 2)):
        for cycle in range(n_cycles):
            t0 = t
            # T0: A alone, digest D1 replays (a reset at the start where the cycle before ended in T3 with D1 direct)
            for _ in range(4):
                add(5_000_000, "D1", 1, 1, "replay", "none", 1, 1, 4.0)
            t1 = t
            # T1: B prefill beside A: new digest D2, warmup reset, direct
            add(35_000_000, "D2", 257, 2, "direct", "none", 1, 0, 30.0, "structure", "shape,src_shape")
            t2 = t
            # T2: width-2 decode: D3 direct then capture then replays
            add(7_000_000, "D3", 2, 2, "direct", "none", 0, 0, 6.0, "structure", "shape")
            add(7_000_000, "D3", 2, 2, "capture", "instantiate", 0, 1, 6.5)
            for _ in range(3):
                add(5_500_000, "D3", 2, 2, "replay", "none", 1, 1, 5.0)
            t3 = t
            # T3: A alone again: D1 returns, reset, direct, capture, replays
            add(6_000_000, "D1", 1, 1, "direct", "none", 1, 0, 5.0, "structure", "shape")
            add(6_000_000, "D1", 1, 1, "capture", "instantiate", 0, 1, 5.2)
            for _ in range(3):
                add(5_000_000, "D1", 1, 1, "replay", "none", 1, 1, 4.0)
            t_end = t
            cycles[arm].append({
                "cycle": cycle, "warmup": cycle == 0, "slot_a": slot_a, "slot_b": slot_b,
                "phases_ns": {"T0_begin": t0, "T1_begin": t1, "T2_begin": t2, "T3_begin": t3, "T3_end": t_end},
                "a": {"reply_sha256": "aaaaaaaaaaaa"}, "b": {"reply_sha256": "bbbbbbbbbbbb"},
                "error": "",
            })
            t += 500_000_000
    (directory / "graph-lifecycle.tsv").write_text(HEADER + "".join(rows))
    for arm, records in cycles.items():
        (directory / arm).mkdir()
        for record in records:
            (directory / arm / ("cycle-%d.json" % record["cycle"])).write_text(json.dumps(record))


def main():
    reader = pathlib.Path(__file__).resolve().parent / "read-graph-lifecycle-trace.py"
    failures = 0

    def check(name, ok):
        nonlocal failures
        print("%s %s" % ("ok  " if ok else "FAIL", name))
        failures += 0 if ok else 1

    with tempfile.TemporaryDirectory() as tmp:
        build(tmp)
        result = subprocess.run([sys.executable, str(reader), tmp], capture_output=True, text=True)
        check("reader exits 0", result.returncode == 0)
        values = {}
        for line in result.stdout.splitlines():
            key, _, value = line.partition("=")
            values.setdefault(key, []).append(value)
        one = {k: v[-1] for k, v in values.items()}
        check("warm-up cycles set aside", one.get("fixed_cycles_measured") == "2" and one.get("permuted_cycles_measured") == "1")
        # three measured cycles, each with 15 rows
        check("every measured row assigned", one.get("rows_measured") == str(3 * 15))
        check("T1 resets counted", one.get("fixed_T1_resets") == "2" and one.get("permuted_T1_resets") == "1")
        check("T3 resets counted", one.get("fixed_T3_resets") == "2")
        check("transition resets warmup", one.get("transition_resets_warmup") == "yes")
        check("reset triggers name the shape change", any("reason=structure" in v and "phase=T1" in v for v in values.get("reset_trigger", [])))
        check("D1 and D3 recur, D2 recurs too across cycles", one.get("topology_digests_measured") == "3" and one.get("topology_digests_recurring") == "3")
        check("episodes: T1+T2 merge into one, T3 one, per cycle", one.get("reset_episodes") == "6")
        # the T1 reset opens an episode that runs through the T2 direct row, so
        # episodes alternate two direct rows and one
        check("median direct per episode", one.get("episode_direct_median") == "1.5")
        # overhead: D3 direct 6.0 + capture 6.5 over replay 5.0 -> 2.5 per cycle; D1 direct 5.0 + capture 5.2 over 4.0 -> 2.2
        # D2 never replays: excess_max = max over D1 ((5.1-4.0)/5.1), D3 ((6.25-5.0)/6.25=0.2) -> D1: 0.2157
        excess = float(one["direct_over_replay_excess_max"])
        check("excess max from D1", abs(excess - (5.1 - 4.0) / 5.1) < 1e-3)
        measured = float(one["overhead_measured_ms"])
        check("measured overhead sums both digests", abs(measured - 3 * (2.5 + 2.2)) < 1e-6)
        bounded = float(one["overhead_bounded_ms"])
        check("bounded overhead scales the prefill row", abs(bounded - 3 * 30.0 * excess) < 1e-2)
        denominator = float(one["mixed_service_denominator_ms"])
        per_cycle = (4 * 5 + 35 + 7 + 7 + 3 * 5.5 + 6 + 6 + 3 * 5)
        check("denominator is the whole interval", abs(denominator - 3 * per_cycle) < 1e-6)
        fraction = float(one["lifecycle_fraction"])
        check("fraction is overhead over denominator", abs(fraction - (measured + bounded) / denominator) < 1e-4)
        check("decision follows the floor", one.get("decision", "").startswith("build") == (fraction >= 0.051))
        check("n-only key: 1 token/1 output maps to one digest here", one.get("n_only_key") == "unrefuted")
        check("reply identity slot invariant", one.get("a_reply_slot_invariant") == "yes")
        check("phased TSV written", pathlib.Path(tmp, "graph-lifecycle-phased.tsv").exists())
        check("recurrence TSV written", pathlib.Path(tmp, "topology-recurrence.tsv").exists())
    print("test-read-graph-lifecycle-trace: %s" % ("all checks passed" if failures == 0 else "%d failed" % failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
