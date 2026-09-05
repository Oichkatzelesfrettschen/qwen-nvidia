#!/usr/bin/env python3
"""Join one media placement run into per-fixture placement and contract rows.

run-media-decode-placement.sh writes placement.tsv per vision row, one
key=value line per decode arm and per preprocessing comparison, and one
transfers.tsv per backend policy from the Nsight capture of the decode-only
pass. This reads them together and states, per fixture: the codec the
bitstream declares, which nvImageCodec extension took it under each policy,
whether the device decode reproduces the stb_image decode the served path
performs, which memory copies the library made to reach the device target,
and whether any CV-CUDA resize reproduces the projector's own preprocessing.

The decode rows are a property of the bitstream and the library rather than
of the projector, so the rows of every model directory are required to
agree digest for digest; a disagreement is a refusal rather than a table.

usage: summarize-media-decode-placement.py RUN_DIRECTORY
"""

import csv
import os
import sys

POLICIES = ("any", "gpu", "hw", "hybrid", "cpu")


def parse_placement(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            row = {"kind": fields[0]}
            for field in fields[1:]:
                key, _, value = field.partition("=")
                row[key] = value
            rows.append(row)
    return rows


def parse_transfers(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run = sys.argv[1]
    models = sorted(name for name in os.listdir(run)
                    if os.path.isfile(os.path.join(run, name, "placement.tsv")))
    if not models:
        sys.exit("no placement.tsv under %s" % run)
    placements = {model: parse_placement(os.path.join(run, model, "placement.tsv")) for model in models}
    refusals = []

    # every model directory ends on the probe's completion line and carries
    # the same decode rows, digest for digest
    def decode_key(row):
        return (row.get("image"), row.get("policy"))

    for model in models:
        terminal = [r for r in placements[model] if r["kind"].startswith("media_placement=")]
        if not terminal or terminal[-1]["kind"] != "media_placement=completed":
            refusals.append("%s did not end on media_placement=completed" % model)
    reference = {decode_key(r): r for r in placements[models[0]] if r["kind"] == "decode"}
    for model in models[1:]:
        rows = {decode_key(r): r for r in placements[model] if r["kind"] == "decode"}
        if set(rows) != set(reference):
            refusals.append("decode row set differs between %s and %s" % (models[0], model))
        for key, row in rows.items():
            other = reference.get(key)
            if other is None:
                continue
            if other.get("digest") != row.get("digest") or other.get("status") != row.get("status"):
                refusals.append("decode row differs between %s and %s for %s" % (models[0], model, key))

    first = placements[models[0]]
    images = []
    stb = {}
    for row in first:
        if row["kind"] == "reference_decode":
            images.append(row["image"])
            stb[row["image"]] = row
    transfers = {policy: parse_transfers(os.path.join(run, "nsys", policy, "transfers.tsv")) for policy in POLICIES}
    # The capture pass decodes the fixtures in the order the probe printed
    # them, one policy per capture, and the probe reads every successful
    # decode back once, so the copies of a capture partition in time order:
    # each fixture's interval ends at its own readback of decoded_bytes, and
    # the host-to-device copies inside the interval are what the library
    # moved for it. Byte counts alone would conflate fixtures of one size.
    attributed = {}
    for policy, table in transfers.items():
        if table is None:
            continue
        ordered = sorted(table, key=lambda t: int(t["start_ns"]))
        cursor = 0
        for image in images:
            row = reference.get((image, policy))
            if row is None or row["status"] != "success":
                continue
            decoded = int(stb[image]["decoded_bytes"])
            uploads = []
            readback = False
            while cursor < len(ordered):
                copy = ordered[cursor]
                cursor += 1
                if copy["kind"] == "Host-to-Device":
                    uploads.append(int(copy["bytes"]))
                elif copy["kind"] == "Device-to-Host" and int(copy["bytes"]) == decoded:
                    readback = True
                    break
            if not readback:
                refusals.append("no readback of %d bytes for %s under policy %s in the capture" % (decoded, image, policy))
            attributed[(image, policy)] = uploads
        if cursor < len(ordered):
            leftover = ordered[cursor:]
            attributed[("*", policy)] = [int(t["bytes"]) for t in leftover]

    out_path = os.path.join(run, "placement-summary.tsv")
    columns = ["image", "codec", "encoded_bytes", "decoded_bytes", "width", "height"]
    for policy in POLICIES:
        columns += ["%s_status" % policy, "%s_extensions" % policy, "%s_vs_stb" % policy, "%s_max_abs" % policy,
                    "%s_htod_decoded" % policy, "%s_htod_encoded" % policy, "%s_htod_other" % policy]
    columns += ["placement", "device_decoder", "device_vs_stb"]
    for model in models:
        columns += ["%s_entries" % model, "%s_best_op" % model, "%s_best_differing_fraction" % model,
                    "%s_best_max_abs_u8" % model, "%s_contract" % model]
    lines = []
    for image in images:
        line = {"image": image}
        ref = stb[image]
        line["encoded_bytes"] = ref["encoded_bytes"]
        line["decoded_bytes"] = ref["decoded_bytes"]
        line["width"] = ref["width"]
        line["height"] = ref["height"]
        encoded = int(ref["encoded_bytes"])
        decoded = int(ref["decoded_bytes"])
        codec = "-"
        device_decoder = "-"
        device_vs_stb = "n/a"
        for policy in POLICIES:
            row = reference.get((image, policy))
            if row is None:
                refusals.append("missing decode row %s %s" % (image, policy))
                continue
            codec = row.get("codec", codec)
            line["%s_status" % policy] = row["status"]
            line["%s_extensions" % policy] = row.get("decoder", "-")
            line["%s_vs_stb" % policy] = row["vs_stb_identical"]
            line["%s_max_abs" % policy] = row["vs_stb_max_abs"]
            table = transfers.get(policy)
            if table is None and row["status"] != "success":
                # nothing decoded under the policy, so the capture holds no copy table
                line["%s_htod_decoded" % policy] = line["%s_htod_encoded" % policy] = line["%s_htod_other" % policy] = "0"
            elif table is None:
                refusals.append("no transfer table for policy %s though %s decoded under it" % (policy, image))
                line["%s_htod_decoded" % policy] = line["%s_htod_encoded" % policy] = line["%s_htod_other" % policy] = "not_run"
            elif row["status"] != "success":
                line["%s_htod_decoded" % policy] = line["%s_htod_encoded" % policy] = line["%s_htod_other" % policy] = "0"
            else:
                uploads = attributed.get((image, policy), [])
                line["%s_htod_decoded" % policy] = str(sum(1 for b in uploads if b == decoded))
                line["%s_htod_encoded" % policy] = str(sum(1 for b in uploads if b == encoded))
                line["%s_htod_other" % policy] = ",".join(str(b) for b in uploads if b not in (decoded, encoded)) or "0"
            if policy in ("gpu", "hw", "hybrid") and row["status"] == "success" and device_decoder == "-":
                device_decoder = "%s:%s" % (policy, row.get("decoder", "-"))
                device_vs_stb = row["vs_stb_identical"]
        line["codec"] = codec
        any_row = reference.get((image, "any"))
        cpu_row = reference.get((image, "cpu"))
        if any_row is None or any_row["status"] != "success":
            refusals.append("the unrestricted policy failed to decode %s" % image)
            line["placement"] = "undecodable"
        elif device_decoder != "-":
            line["placement"] = "device_decoder"
        elif cpu_row is not None and cpu_row["status"] == "success":
            line["placement"] = "cpu_decoder_upload"
        else:
            line["placement"] = "unclassified"
        line["device_decoder"] = device_decoder
        line["device_vs_stb"] = device_vs_stb
        for model in models:
            entries = [r for r in placements[model] if r["kind"] == "preproc" and r["image"] == image]
            compares = [r for r in placements[model] if r["kind"] == "preproc_compare" and r["image"] == image]
            line["%s_entries" % model] = entries[0]["entries"] if entries else "-"
            measured = [r for r in compares if r.get("result") in ("identical", "differs")]
            if not measured:
                reason = compares[0].get("reason", "absent") if compares else "absent"
                line["%s_best_op" % model] = "not_run:%s" % reason
                line["%s_best_differing_fraction" % model] = "-"
                line["%s_best_max_abs_u8" % model] = "-"
                line["%s_contract" % model] = "not_measured"
                continue
            best = min(measured, key=lambda r: (float(r["differing_fraction"]), int(r["max_abs_u8"])))
            line["%s_best_op" % model] = best["op"]
            line["%s_best_differing_fraction" % model] = best["differing_fraction"]
            line["%s_best_max_abs_u8" % model] = best["max_abs_u8"]
            line["%s_contract" % model] = "identical" if best["result"] == "identical" else "separate"
        lines.append(line)

    with open(out_path, "w", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, delimiter="\t", restval="-", lineterminator="\n")
        writer.writeheader()
        for line in lines:
            writer.writerow(line)

    for policy in POLICIES:
        leftover = attributed.get(("*", policy))
        if leftover:
            refusals.append("policy %s capture holds %d copies after the last attributed readback" % (policy, len(leftover)))
    for line in lines:
        print("fixture\t%s\tcodec=%s\tplacement=%s\tdevice_decoder=%s\tdevice_vs_stb=%s\tcpu_vs_stb=%s\tcpu_htod_decoded=%s\thybrid_htod_other=%s\t%s" % (
            line["image"], line["codec"], line["placement"], line["device_decoder"], line["device_vs_stb"],
            line.get("cpu_vs_stb", "-"), line.get("cpu_htod_decoded", "-"), line.get("hybrid_htod_other", "-"),
            "\t".join("%s_contract=%s(%s)" % (m, line["%s_contract" % m], line["%s_best_op" % m]) for m in models)))
    for refusal in refusals:
        print("refused\t%s" % refusal)
    print("media_placement_summary=%s\tfixtures=%d\trefusals=%d" % ("refused" if refusals else "completed", len(lines), len(refusals)))
    return 1 if refusals else 0


if __name__ == "__main__":
    sys.exit(main())
