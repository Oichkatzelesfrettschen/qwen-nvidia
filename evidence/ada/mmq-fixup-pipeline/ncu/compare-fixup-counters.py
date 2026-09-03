import csv, re, statistics, sys, io

WANT = {
    "stall long_scoreboard": "smsp__average_warps_issue_stalled_long_scoreboard_per_issue_active.ratio",
    "stall wait":            "smsp__average_warps_issue_stalled_wait_per_issue_active.ratio",
    "duration us":           "gpu__time_duration.sum",
    "dram throughput pct":   "gpu__dram_throughput.avg.pct_of_peak_sustained_elapsed",
    "dram bytes":            "dram__bytes.sum",
    "l2 hit pct":            "lts__t_sector_hit_rate.pct",
    "issue active pct":      "smsp__issue_active.avg.pct_of_peak_sustained_active",
    "achieved occupancy":    "sm__warps_active.avg.pct_of_peak_sustained_active",
    "registers":             "launch__registers_per_thread",
    "waves per sm":          "launch__waves_per_multiprocessor",
}

def load(path):
    rows = list(csv.reader(io.open(path, encoding="utf-8")))
    head, out = rows[0], []
    idx = {name: i for i, name in enumerate(head)}
    for r in rows[2:]:
        if not r or len(r) != len(head):
            continue
        out.append({name: r[i] for name, i in idx.items()})
    return out

def num(v):
    try:
        return float(v.replace(",", ""))
    except Exception:
        return None

def group(rows):
    g = {}
    for r in rows:
        k = r.get("Kernel Name", "")
        m = re.search(r"mul_mat_q_stream_k_fixup<(\d+), (\d+), (\d+)>", k)
        if not m:
            continue
        g.setdefault("fixup<t%s,J%s,fb%s>" % (m.group(1), m.group(2), m.group(3)), []).append(r)
    return g

arms = {a: group(load("evidence/ada/mmq-fixup-pipeline/ncu/%s/fixup-08b-q8/counters.csv" % a))
        for a in ("control", "subject")}

keys = sorted(set(arms["control"]) | set(arms["subject"]))
print("symbol\tcounter\tcontrol\tsubject\tn_control\tn_subject")
for k in keys:
    for label, col in WANT.items():
        vals = {}
        for a in ("control", "subject"):
            rows = arms[a].get(k, [])
            xs = [num(r[col]) for r in rows if col in r and num(r[col]) is not None]
            vals[a] = (statistics.median(xs) if xs else None, len(xs))
        c, s = vals["control"], vals["subject"]
        fmt = lambda v: "-" if v is None else ("%.2f" % v)
        print("%s\t%s\t%s\t%s\t%d\t%d" % (k, label, fmt(c[0]), fmt(s[0]), c[1], s[1]))
