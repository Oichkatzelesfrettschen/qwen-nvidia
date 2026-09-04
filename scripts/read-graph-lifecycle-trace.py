#!/usr/bin/env python3
"""Join a CUDA graph lifecycle trace to the mixed-service phases that produced it.

`graph-lifecycle.tsv` is the recorder's output, one row per graph compute
with the wall clock it began at; `ARM/cycle-N.json` are the client's records,
each naming the wall clock of the four phase boundaries. Rows are assigned to
a phase by that clock, the warm-up cycle is set aside, and the summary answers
the five questions the campaign preregisters:

  1. whether the transition resets graph warmup, read from rows whose
     warmup_before is 1 and warmup_after is 0;
  2. which change triggers it, read from the change columns of the first row
     of every phase that carries a reset;
  3. whether topologies recur, read from the cycles each topology digest
     appears in;
  4. what a recurrence costs, counted as the direct executions, captures, and
     updates between one reset and the next replay;
  5. what fraction of the mixed-service interval that lifecycle costs.

The cost of a non-replay compute is its device span over the median replay
span of the same topology digest where that digest ever replayed; where it
never did, the span is scaled by the largest direct-over-replay excess any
digest showed, which bounds the cost from above rather than assuming the
whole compute is overhead. The denominator is the sum over measured cycles of
A's request start to A's completion, the whole mixed-service interval.

Output is key=value lines on stdout and two TSV files beside the trace:
`graph-lifecycle-phased.tsv` with every row's arm, cycle, and phase, and
`topology-recurrence.tsv` with one row per topology digest.
"""

import argparse
import json
import pathlib
import statistics
import sys

FLOOR = 0.051
PHASES = ("T0", "T1", "T2", "T3")


def read_trace(path):
    rows = []
    with open(path, encoding="utf-8") as handle:
        header = handle.readline().rstrip("\n").split("\t")
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) != len(header):
                continue
            row = dict(zip(header, fields))
            row["t_begin_ns"] = int(row["t_begin_ns"])
            row["graph_ordinal"] = int(row["graph_ordinal"])
            row["host_us"] = int(row["host_us"])
            row["device_ms"] = float(row["device_ms"]) if row["device_ms"] not in ("-", "") else None
            for key in ("n_tokens", "n_outputs", "n_kv", "n_rs"):
                row[key] = int(row[key])
            rows.append(row)
    rows.sort(key=lambda r: r["graph_ordinal"])
    return rows


def read_cycles(directory, arm):
    cycles = []
    for path in sorted(pathlib.Path(directory, arm).glob("cycle-*.json"),
                       key=lambda p: int(p.stem.split("-")[1])):
        record = json.loads(path.read_text())
        if record.get("error"):
            continue
        cycles.append(record)
    return cycles


def phase_of(t, phases):
    bounds = [phases["T0_begin"], phases["T1_begin"], phases["T2_begin"], phases["T3_begin"], phases["T3_end"]]
    if t < bounds[0] or t >= bounds[4]:
        return None
    for i, name in enumerate(PHASES):
        if bounds[i] <= t < bounds[i + 1]:
            return name
    return None


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("directory")
    parser.add_argument("--floor", type=float, default=FLOOR)
    args = parser.parse_args()
    directory = pathlib.Path(args.directory)
    rows = read_trace(directory / "graph-lifecycle.tsv")
    if not rows:
        sys.exit("the trace holds no rows")

    arms = {}
    for arm in ("fixed", "permuted"):
        if (directory / arm).is_dir():
            arms[arm] = read_cycles(directory, arm)
    if not arms:
        sys.exit("no arm directory holds cycle records")

    # phase assignment
    for row in rows:
        row["arm"], row["cycle"], row["phase"], row["warmup"] = "-", -1, "-", False
        for arm, cycles in arms.items():
            for record in cycles:
                phase = phase_of(row["t_begin_ns"], record["phases_ns"])
                if phase is not None:
                    row["arm"], row["cycle"], row["phase"], row["warmup"] = arm, record["cycle"], phase, bool(record.get("warmup"))
                    break
            if row["phase"] != "-":
                break
        row["reset"] = row["warmup_before"] == "1" and row["warmup_after"] == "0"

    phased = directory / "graph-lifecycle-phased.tsv"
    with open(phased, "w", encoding="utf-8") as handle:
        handle.write("graph_ordinal\tarm\tcycle\tphase\ttopology_digest\tn_tokens\tn_outputs\tn_kv\tn_rs\taction\texecutable\treset\tchange_reason\tchange_categories\tchange_node\tchange_op\tchange_name\thost_us\tdevice_ms\n")
        for row in rows:
            handle.write("\t".join(str(v) for v in (
                row["graph_ordinal"], row["arm"], row["cycle"], row["phase"], row["topology_digest"],
                row["n_tokens"], row["n_outputs"], row["n_kv"], row["n_rs"], row["action"], row["executable"],
                int(row["reset"]), row["change_reason"], row["change_categories"], row["change_node"],
                row["change_op"], row["change_name"], row["host_us"],
                "-" if row["device_ms"] is None else "%.4f" % row["device_ms"])) + "\n")

    measured = [r for r in rows if r["phase"] != "-" and not r["warmup"]]
    out = []

    def emit(key, value):
        out.append("%s=%s" % (key, value))

    emit("rows_total", len(rows))
    emit("rows_measured", len(measured))
    emit("rows_outside_cycles", sum(1 for r in rows if r["phase"] == "-"))
    for arm, cycles in arms.items():
        emit("%s_cycles_measured" % arm, sum(1 for c in cycles if not c.get("warmup")))

    # 1. resets per phase
    for arm in arms:
        for phase in PHASES:
            subset = [r for r in measured if r["arm"] == arm and r["phase"] == phase]
            emit("%s_%s_rows" % (arm, phase), len(subset))
            for action in ("direct", "capture", "replay", "disabled", "incompatible"):
                emit("%s_%s_%s" % (arm, phase, action), sum(1 for r in subset if r["action"] == action))
            emit("%s_%s_resets" % (arm, phase), sum(1 for r in subset if r["reset"]))
            emit("%s_%s_instantiate" % (arm, phase), sum(1 for r in subset if r["executable"] == "instantiate"))
            emit("%s_%s_update" % (arm, phase), sum(1 for r in subset if r["executable"] in ("update", "reinstantiate")))
            emit("%s_%s_digests" % (arm, phase), len({r["topology_digest"] for r in subset}))
    resets_total = sum(1 for r in measured if r["reset"])
    emit("transition_resets_warmup", "yes" if resets_total > 0 else "no")

    # 2. what triggers each reset: the reset rows' own change columns
    triggers = {}
    for r in measured:
        if r["reset"]:
            key = (r["phase"], r["change_reason"], r["change_categories"], r["change_name"])
            triggers[key] = triggers.get(key, 0) + 1
    for (phase, reason, categories, name), count in sorted(triggers.items(), key=lambda kv: -kv[1]):
        emit("reset_trigger", "phase=%s reason=%s categories=%s node=%s count=%d" % (phase, reason, categories, name, count))

    # 3. recurrence of topology digests across measured cycles
    digest_cycles = {}
    digest_rows = {}
    for r in measured:
        digest_cycles.setdefault(r["topology_digest"], set()).add((r["arm"], r["cycle"]))
        digest_rows.setdefault(r["topology_digest"], []).append(r)
    recurring = {d for d, s in digest_cycles.items() if len(s) >= 2}
    emit("topology_digests_measured", len(digest_cycles))
    emit("topology_digests_recurring", len(recurring))
    emit("topology_recurs", "yes" if recurring else "no")

    # 4. cost per recurrence: rows between a reset and the next replay
    episodes = []
    current = None
    for r in sorted(measured, key=lambda r: r["graph_ordinal"]):
        if r["reset"]:
            if current is not None:
                episodes.append(current)
            current = {"direct": 0, "capture": 0, "update": 0, "digest": r["topology_digest"], "phase": r["phase"]}
        if current is None:
            continue
        if r["action"] == "direct":
            current["direct"] += 1
        elif r["action"] == "capture":
            current["capture"] += 1
        if r["executable"] in ("update", "reinstantiate"):
            current["update"] += 1
        if r["action"] == "replay":
            episodes.append(current)
            current = None
    if current is not None:
        episodes.append(current)
    emit("reset_episodes", len(episodes))
    if episodes:
        emit("episode_direct_median", median([e["direct"] for e in episodes]))
        emit("episode_capture_median", median([e["capture"] for e in episodes]))
        emit("episode_update_median", median([e["update"] for e in episodes]))
        emit("episode_direct_max", max(e["direct"] for e in episodes))

    # 5. fraction of the mixed-service interval
    replay_median = {}
    direct_median = {}
    for digest, subset in digest_rows.items():
        replay_median[digest] = median([r["device_ms"] for r in subset if r["action"] == "replay"])
        direct_median[digest] = median([r["device_ms"] for r in subset if r["action"] in ("direct", "capture")])
    excess = [
        (direct_median[d] - replay_median[d]) / direct_median[d]
        for d in digest_rows
        if replay_median.get(d) is not None and direct_median.get(d) not in (None, 0)
    ]
    excess_max = max([0.0] + [min(1.0, max(0.0, e)) for e in excess])
    overhead_measured = 0.0
    overhead_bounded = 0.0
    unresolved = 0
    for r in measured:
        if r["action"] == "replay":
            continue
        if r["device_ms"] is None:
            unresolved += 1
            continue
        ref = replay_median.get(r["topology_digest"])
        if ref is not None:
            overhead_measured += max(0.0, r["device_ms"] - ref)
        else:
            overhead_bounded += r["device_ms"] * excess_max
    denominator_ms = 0.0
    for cycles in arms.values():
        for c in cycles:
            if not c.get("warmup"):
                denominator_ms += (c["phases_ns"]["T3_end"] - c["phases_ns"]["T0_begin"]) / 1e6
    overhead_total = overhead_measured + overhead_bounded
    fraction = overhead_total / denominator_ms if denominator_ms > 0 else float("nan")
    emit("direct_over_replay_excess_max", "%.4f" % excess_max)
    emit("overhead_measured_ms", "%.3f" % overhead_measured)
    emit("overhead_bounded_ms", "%.3f" % overhead_bounded)
    emit("overhead_unresolved_rows", unresolved)
    emit("mixed_service_denominator_ms", "%.1f" % denominator_ms)
    emit("lifecycle_fraction", "%.5f" % fraction)
    emit("floor", "%.3f" % args.floor)
    clears = fraction >= args.floor
    emit("clears_floor", "yes" if clears else "no")

    # same N to several digests refuses an N-only key
    n_to_digests = {}
    for r in measured:
        n_to_digests.setdefault((r["n_tokens"], r["n_outputs"]), set()).add(r["topology_digest"])
    ambiguous = {k: v for k, v in n_to_digests.items() if len(v) > 1}
    emit("n_only_key", "refused" if ambiguous else "unrefuted")
    for (n_tokens, n_outputs), digests in sorted(ambiguous.items()):
        emit("n_only_key_conflict", "n_tokens=%d n_outputs=%d digests=%d" % (n_tokens, n_outputs, len(digests)))

    # reply identity as an observation
    for arm, cycles in arms.items():
        for who in ("a", "b"):
            replies = {c[who]["reply_sha256"] for c in cycles if not c.get("warmup")}
            emit("%s_%s_reply_digests" % (arm, who), ",".join(sorted(replies)))
    if "fixed" in arms and "permuted" in arms:
        for who in ("a", "b"):
            fixed = {c[who]["reply_sha256"] for c in arms["fixed"] if not c.get("warmup")}
            permuted = {c[who]["reply_sha256"] for c in arms["permuted"] if not c.get("warmup")}
            emit("%s_reply_slot_invariant" % who, "yes" if fixed == permuted and len(fixed) == 1 else "no")

    if not clears:
        decision = "close: lifecycle cost under the floor"
    elif not recurring:
        decision = "close: cost clears the floor and no topology recurs"
    else:
        decision = "build topology-keyed prewarming"
    emit("decision", decision)

    with open(directory / "topology-recurrence.tsv", "w", encoding="utf-8") as handle:
        handle.write("topology_digest\tcycles\tphases\tn_tokens\tn_outputs\tdirect\tcapture\treplay\treplay_median_ms\tdirect_median_ms\n")
        for digest, subset in sorted(digest_rows.items(), key=lambda kv: -len(kv[1])):
            handle.write("\t".join(str(v) for v in (
                digest, len(digest_cycles[digest]), ",".join(sorted({r["phase"] for r in subset})),
                ",".join(sorted({str(r["n_tokens"]) for r in subset})), ",".join(sorted({str(r["n_outputs"]) for r in subset})),
                sum(1 for r in subset if r["action"] == "direct"), sum(1 for r in subset if r["action"] == "capture"),
                sum(1 for r in subset if r["action"] == "replay"),
                "-" if replay_median[digest] is None else "%.4f" % replay_median[digest],
                "-" if direct_median[digest] is None else "%.4f" % direct_median[digest])) + "\n")

    print("\n".join(out))


if __name__ == "__main__":
    main()
