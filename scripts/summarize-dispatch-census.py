#!/usr/bin/env python3
"""Join the census rows of every arm to the requests that produced them.

run-cuda-dispatch-census.sh retains one census.tsv per arm, one row per
distinct mat-mul shape per graph compute, and one requests.tsv naming each
request's wall-clock window. A row belongs to the request whose window holds
its graph timestamp; a row outside every window ran at load or between
requests and is kept under the request id `outside`. The phase is read from
the row itself: a src0 named `v.*` is the vision encoder, `mm.*` the projector,
ne11 above one a prefill, ne11 of one a decode. A graph_replay row records a
CUDA graph relaunch, which repeats the population its capture recorded and
dispatches nothing through the hooks, so replays are counted beside dispatch
launches rather than added to them.

Outputs, all TSV: <arm>/phases.tsv, <arm>/cublas-shapes.tsv, and the run-wide
census-summary.tsv and cublas-shapes.tsv.
"""

import csv
import os
import sys
from collections import defaultdict


def read_tsv(path):
    with open(path, encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def phase_of(row, request_label):
    name = row["src0_name"]
    if row["path"] == "graph_replay":
        return "graph_replay"
    if row["path"] == "no_mat_mul":
        return "no_mat_mul"
    if name.startswith("v."):
        return "vision_encoder"
    if name.startswith("mm."):
        return "projector"
    try:
        ne11 = int(row["ne11"])
    except ValueError:
        ne11 = 0
    image = "image" in request_label
    if ne11 > 1:
        return "llm_prefill_from_image_embeddings" if image else "text_prefill"
    return "post_image_decode" if image else "text_decode"


def summarize_arm(arm_directory, arm_name):
    census_path = os.path.join(arm_directory, "census.tsv")
    requests_path = os.path.join(arm_directory, "requests.tsv")
    if not (os.path.isfile(census_path) and os.path.isfile(requests_path)):
        return [], []
    requests = read_tsv(requests_path)
    windows = []
    for request in requests:
        try:
            windows.append((int(request["t_start_ns"]), int(request["t_end_ns"]),
                            request["request_id"], request["label"]))
        except ValueError:
            continue

    def locate(t_ns):
        for start, end, request_id, label in windows:
            if start <= t_ns <= end:
                return request_id, label
        return "outside", "outside"

    phases = defaultdict(lambda: {"shapes": set(), "launches": 0, "graphs": set(), "replays": 0})
    cublas_rows = []
    for row in read_tsv(census_path):
        try:
            t_ns = int(row["t_ns"])
            launches = int(row["launches"])
        except ValueError:
            continue
        request_id, label = locate(t_ns)
        phase = phase_of(row, label)
        key = (request_id, label, phase, row["path"], row["detail"],
               row["src0_type"], row["src1_type"], row["dst_type"], row["mode"])
        entry = phases[key]
        entry["graphs"].add(row["graph_index"])
        if row["path"] == "graph_replay":
            entry["replays"] += launches
        else:
            entry["launches"] += launches
            entry["shapes"].add((row["src0_name"], row["ne00"], row["ne01"], row["ne02"],
                                 row["ne03"], row["ne10"], row["ne11"], row["ne12"], row["ne13"]))
        if row["path"] == "cuBLAS":
            cublas_rows.append({"arm": arm_name, "request": request_id, "label": label,
                                "phase": phase, **row})

    phase_rows = []
    for key in sorted(phases):
        entry = phases[key]
        request_id, label, phase, path, detail, t0, t1, td, mode = key
        phase_rows.append({
            "arm": arm_name, "request": request_id, "label": label, "phase": phase,
            "path": path, "detail": detail, "src0_type": t0, "src1_type": t1,
            "dst_type": td, "mode": mode, "graphs": len(entry["graphs"]),
            "distinct_shapes": len(entry["shapes"]), "dispatch_launches": entry["launches"],
            "graph_replays": entry["replays"]})
    return phase_rows, cublas_rows


def write_tsv(path, rows, fields):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t",
                                lineterminator="\n", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main():
    if len(sys.argv) != 2:
        print("usage: summarize-dispatch-census.py OUTPUT_DIRECTORY", file=sys.stderr)
        return 2
    output_directory = sys.argv[1]
    phase_fields = ["arm", "request", "label", "phase", "path", "detail", "src0_type",
                    "src1_type", "dst_type", "mode", "graphs", "distinct_shapes",
                    "dispatch_launches", "graph_replays"]
    cublas_fields = ["arm", "request", "label", "phase", "graph_index", "mode", "op", "path",
                     "detail", "src0_name", "dst_name", "src0_type", "src1_type", "dst_type",
                     "ne00", "ne01", "ne02", "ne03", "ne10", "ne11", "ne12", "ne13",
                     "nb01", "nb02", "nb03", "nb11", "nb12", "nb13", "src0_contiguous",
                     "src1_contiguous", "src0_transposed", "batch_count", "launches"]
    summary_rows = []
    all_cublas = []
    for entry in sorted(os.listdir(output_directory)):
        arm_directory = os.path.join(output_directory, entry)
        if not os.path.isdir(arm_directory):
            continue
        phase_rows, cublas_rows = summarize_arm(arm_directory, entry)
        if not phase_rows:
            continue
        write_tsv(os.path.join(arm_directory, "phases.tsv"), phase_rows, phase_fields)
        write_tsv(os.path.join(arm_directory, "cublas-shapes.tsv"), cublas_rows, cublas_fields)
        totals = defaultdict(int)
        by_path = defaultdict(int)
        replays = 0
        for row in phase_rows:
            if row["request"] == "outside":
                continue
            totals["launches"] += row["dispatch_launches"]
            by_path[row["path"]] += row["dispatch_launches"]
            replays += row["graph_replays"]
        cublas = by_path.get("cuBLAS", 0)
        summary_rows.append({
            "arm": entry, "dispatch_launches": totals["launches"],
            "mmvq": by_path.get("MMVQ", 0), "mmq": by_path.get("MMQ", 0),
            "mmvf": by_path.get("MMVF", 0), "mmf": by_path.get("MMF", 0),
            "cublas": cublas,
            "cublas_share": f"{cublas / totals['launches']:.4f}" if totals["launches"] else "-",
            "cublas_distinct_shapes": len({(r["src0_name"], r["ne00"], r["ne01"], r["ne10"],
                                            r["ne11"], r["ne12"], r["ne13"])
                                           for r in cublas_rows if r["request"] != "outside"}),
            "graph_replays": replays})
        all_cublas.extend(cublas_rows)
    write_tsv(os.path.join(output_directory, "census-summary.tsv"), summary_rows,
              ["arm", "dispatch_launches", "mmvq", "mmq", "mmvf", "mmf", "cublas",
               "cublas_share", "cublas_distinct_shapes", "graph_replays"])
    write_tsv(os.path.join(output_directory, "cublas-shapes.tsv"), all_cublas, cublas_fields)
    for row in summary_rows:
        print("\t".join(str(row[k]) for k in ("arm", "dispatch_launches", "mmvq", "mmq",
                                               "mmvf", "mmf", "cublas", "cublas_share",
                                               "cublas_distinct_shapes", "graph_replays")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
