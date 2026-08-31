#!/usr/bin/env python3
"""
Check consistency between mutable current-state documentation and the
machine-readable authority surfaces. The registry, the tuple ledger, and the
quarantine ledger are the authorities; README.md and TASK_TRACKER.md are the
prose surfaces this gate holds to them, so an expectation here is derived from
a ledger rather than snapshotted into this script.
"""

import sys
import os
import pathlib
import subprocess
import re


def parse_tsv(file_path):
    rows = []
    header = None
    if not os.path.exists(file_path):
        return None, None
    with open(file_path, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, start=1):
            line_str = line.strip()
            if not line_str or line_str.startswith("#"):
                # The column header is the final comment line shaped
                # '# name\tname\t...'; later header comments replace earlier
                # ones so prose comments containing a tab do not win.
                candidate = line.lstrip("#").strip()
                if "\t" in candidate and re.match(r"^[a-z_]+\t", candidate):
                    header = [col.strip() for col in candidate.split("\t")]
                continue
            parts = [col.strip() for col in line.split("\t")]
            rows.append((line_num, parts))
    return header, rows


def rows_as_dicts(header, rows, report_error, label):
    result = []
    for lnum, parts in rows:
        if header and len(parts) == len(header):
            result.append((lnum, dict(zip(header, parts))))
        else:
            report_error(
                f"{label} row at line {lnum} has {len(parts)} fields, "
                f"expected {len(header) if header else 'a parsed header'}")
    return result


def normalize_ws(text):
    return " ".join(text.split())


def threshold_values(text, quant):
    """Every numeric value a threshold clause binds to the named quant type.

    A clause is the run of one sentence fragment that names the quant and the
    word 'threshold' or the 'at <word-number>' spelling, so a digit sitting in
    an unrelated token such as an evidence path stays out of the match.
    """
    words = {"four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
             "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
             "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16}
    values = []
    for match in re.finditer(
            rf"{quant}(?:\s+MMVQ)?\s+threshold(?:\s+(?:of|at))?\s+(\d+)\b",
            text, re.IGNORECASE):
        values.append(int(match.group(1)))
    for match in re.finditer(
            rf"{quant}\s+at\s+({'|'.join(words)})\b", text, re.IGNORECASE):
        values.append(words[match.group(1).lower()])
    return values


def main():
    repo_root = (pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1
                 else pathlib.Path(__file__).parent.parent.resolve())

    failures = []

    def report_error(msg):
        failures.append(msg)
        print(f"authority_consistency: ERROR: {msg}", file=sys.stderr)

    # 1. The underlying validators run first: the tuple ledger against the
    # registry, and the sanitization rules over the evidence tree.
    check_tuples_script = repo_root / "scripts" / "check-validated-tuples.sh"
    if check_tuples_script.exists():
        env = os.environ.copy()
        env["QWEN_MODEL_REGISTRY"] = str(repo_root / "scripts" / "models.tsv")
        env["QWEN_VALIDATED_TUPLES"] = str(
            repo_root / "scripts" / "validated-tuples.tsv")
        res = subprocess.run([str(check_tuples_script)], cwd=str(repo_root),
                             env=env, capture_output=True, text=True)
        if res.returncode != 0:
            report_error("check-validated-tuples.sh failed: "
                         f"{res.stderr.strip() or res.stdout.strip()}")
    else:
        report_error("scripts/check-validated-tuples.sh missing")

    check_nvidia_script = repo_root / "scripts" / "check-nvidia-authority.sh"
    if check_nvidia_script.exists():
        res = subprocess.run([str(check_nvidia_script), str(repo_root)],
                             cwd=str(repo_root), capture_output=True, text=True)
        if res.returncode != 0:
            report_error("check-nvidia-authority.sh failed: "
                         f"{res.stderr.strip() or res.stdout.strip()}")
    else:
        report_error("scripts/check-nvidia-authority.sh missing")

    # 2. Promotion evidence and the README's build-closure statements.
    promoted_dir = repo_root / "evidence" / "ada" / "promotion-88681bf4d161"
    rollback_dir = repo_root / "evidence" / "ada" / "promotion-31d0775c5bc6"
    diagnostic_dir = repo_root / "evidence" / "ada" / "promotion-572951d25562"

    if (not (promoted_dir / "README.md").exists()
            or not (promoted_dir / "serving-summary.tsv").exists()):
        report_error("Missing promoted configuration evidence under "
                     "evidence/ada/promotion-88681bf4d161/")
    if not (rollback_dir / "README.md").exists():
        report_error("Missing rollback configuration evidence under "
                     "evidence/ada/promotion-31d0775c5bc6/")
    if not (diagnostic_dir / "README.md").exists():
        report_error("Missing diagnostic configuration evidence under "
                     "evidence/ada/promotion-572951d25562/")

    readme_path = repo_root / "README.md"
    if not readme_path.exists():
        report_error("README.md missing")
        readme_text = ""
    else:
        readme_text = readme_path.read_text(encoding="utf-8")

    readme_norm = normalize_ws(readme_text)

    # The served-closure statement names the promoted configuration by role,
    # so a README that keeps the digest only as a rollback or historical
    # mention is rejected rather than accepted on substring presence.
    served_match = re.search(
        r"served closure is configuration `?([0-9a-f]{12})`?", readme_norm)
    if not served_match:
        report_error("README.md carries no served-closure statement naming "
                     "a configuration digest")
    elif served_match.group(1) != "88681bf4d161":
        report_error("README.md served-closure statement names "
                     f"{served_match.group(1)}, but the retained promotion "
                     "authority is 88681bf4d161")
    if "31d0775c5bc6" not in readme_text:
        report_error("README.md does not reference rollback configuration "
                     "31d0775c5bc6")
    if "572951d25562" not in readme_text:
        report_error("README.md does not reference diagnostic dual-backend "
                     "configuration 572951d25562")

    # MMVQ threshold claims: every clause binding a value to the quant type
    # must state the promoted value, so one stale clause beside one correct
    # clause still rejects.
    q6k_values = threshold_values(readme_norm, "Q6_K")
    if not q6k_values or any(v != 10 for v in q6k_values):
        report_error("README.md Q6_K MMVQ threshold clauses read "
                     f"{q6k_values or 'absent'}, expected every clause at 10")
    q80_values = threshold_values(readme_norm, "Q8_0")
    if not q80_values or any(v != 16 for v in q80_values):
        report_error("README.md Q8_0 MMVQ threshold clauses read "
                     f"{q80_values or 'absent'}, expected every clause at 16")

    # 3. Quarantine state, keyed by the subject column: a row's unique id may
    # differ from the checkpoint it removes, so membership reads column
    # `subject` rather than column `id`.
    quarantine_tsv = repo_root / "scripts" / "quarantine.tsv"
    q_header, q_rows = parse_tsv(quarantine_tsv)
    quarantined_subjects = set()
    if q_rows is None:
        report_error("scripts/quarantine.tsv missing or unreadable")
    elif not q_header or "subject" not in q_header:
        report_error("scripts/quarantine.tsv header does not name a "
                     "subject column")
    else:
        for _, row in rows_as_dicts(q_header, q_rows, report_error,
                                    "scripts/quarantine.tsv"):
            quarantined_subjects.add(row["subject"])

    if "qwen38-9b-distill" in quarantined_subjects:
        report_error("qwen38-9b-distill is a quarantine subject in "
                     "scripts/quarantine.tsv but README.md documents it as "
                     "readmitted")

    if ("quarantine.tsv excludes the 9B distill" in readme_text
            or "excludes the 9B distill from router service" in readme_text):
        report_error("README.md contains stale text claiming "
                     "qwen38-9b-distill is quarantined")

    if "ministral3-3b" not in quarantined_subjects:
        report_error("ministral3-3b is missing from the quarantine subject "
                     "set in scripts/quarantine.tsv")

    # The registry.
    models_tsv = repo_root / "scripts" / "models.tsv"
    m_header, m_rows = parse_tsv(models_tsv)
    models_dict = {}
    if m_rows is None or not m_header:
        report_error("scripts/models.tsv missing, empty, or missing column "
                     "header")
    else:
        for lnum, row in rows_as_dicts(m_header, m_rows, report_error,
                                       "scripts/models.tsv"):
            models_dict[row["id"]] = (lnum, row)

    if "qwen38-9b-distill" in models_dict:
        _, m9b = models_dict["qwen38-9b-distill"]
        if m9b.get("switch_policy") != "evict-first":
            report_error("qwen38-9b-distill in models.tsv has switch_policy "
                         f"'{m9b.get('switch_policy')}', expected "
                         "'evict-first'")
    else:
        report_error("qwen38-9b-distill missing from scripts/models.tsv")

    if "evict-first" not in readme_norm:
        report_error("README.md does not document the evict-first switch "
                     "policy for qwen38-9b-distill")
    if "QWEN_ROUTER_MAX=1" not in readme_text:
        report_error("README.md does not document the QWEN_ROUTER_MAX=1 "
                     "constraint for qwen38-9b-distill")

    evict_evidence = repo_root / "evidence" / "ada" / "evict-first-9b-readmission"
    if not (evict_evidence / "README.md").exists():
        report_error("Missing readmission evidence under "
                     "evidence/ada/evict-first-9b-readmission/")

    # 4. Validated filled depths, derived from the registry rather than
    # snapshotted here: every row claiming a numeric validated_filled_depth
    # must hold a validated CUDA tuple at that depth and its own submission
    # geometry, so a later measurement that legitimately moves both files
    # passes without editing this gate.
    expected_depths = {}
    for model_id, (lnum, row) in models_dict.items():
        depth = row.get("validated_filled_depth", "-")
        if depth.isdigit():
            expected_depths[model_id] = (depth, row.get("batch", "-"),
                                         row.get("ubatch", "-"))

    if not expected_depths:
        report_error("scripts/models.tsv claims no numeric "
                     "validated_filled_depth; the depth-validation campaign "
                     "record has no registry subject")

    tuples_tsv = repo_root / "scripts" / "validated-tuples.tsv"
    t_header, t_rows = parse_tsv(tuples_tsv)
    validated_tuples_map = {}
    if t_rows is None or not t_header:
        report_error("scripts/validated-tuples.tsv missing, empty, or "
                     "missing column header")
    else:
        for _, row in rows_as_dicts(t_header, t_rows, report_error,
                                    "scripts/validated-tuples.tsv"):
            if row.get("status") == "validated":
                validated_tuples_map.setdefault(row["model_id"], []).append(
                    (row.get("context", row.get("depth", "-")),
                     row.get("batch", "-"), row.get("ubatch", "-"),
                     row.get("backend", "-")))

    for model_id, (exp_depth, exp_batch, exp_ubatch) in expected_depths.items():
        v_list = validated_tuples_map.get(model_id, [])
        match = any(ctx == exp_depth and b == exp_batch and ub == exp_ubatch
                    and backend == "cuda"
                    for ctx, b, ub, backend in v_list)
        if not match:
            report_error("scripts/validated-tuples.tsv lacks a validated "
                         f"CUDA tuple for {model_id} at depth {exp_depth}, "
                         f"batch {exp_batch}, ubatch {exp_ubatch}")

    # 5. TASK_TRACKER.md against the ledger-derived open-work state. The
    # document is a required surface, so its absence is a failure rather than
    # a skipped section.
    task_tracker_path = repo_root / "TASK_TRACKER.md"
    if not task_tracker_path.exists():
        report_error("TASK_TRACKER.md missing")
    else:
        tt_text = task_tracker_path.read_text(encoding="utf-8")
        tt_norm = normalize_ws(tt_text)

        # Coverage is tracked per expected model for both conditions: a
        # second CUDA geometry and a validated Vulkan tuple each count only
        # when every class holds one, so one model's Vulkan arm leaves the
        # other classes' work open.
        cuda_geometries_per_model = {}
        vulkan_per_model = {}
        for model_id in expected_depths:
            v_list = validated_tuples_map.get(model_id, [])
            cuda_geometries_per_model[model_id] = len(
                {(b, ub) for ctx, b, ub, backend in v_list
                 if backend == "cuda"})
            vulkan_per_model[model_id] = sum(
                1 for ctx, b, ub, backend in v_list if backend == "vulkan")

        has_second_geometry_all_classes = all(
            count >= 2 for count in cuda_geometries_per_model.values())
        has_vulkan_all_classes = all(
            count >= 1 for count in vulkan_per_model.values())

        open_statement = ("Open extensions: a second submission geometry per "
                          "class, and the Vulkan-backend arms")
        if has_second_geometry_all_classes and has_vulkan_all_classes:
            if open_statement in tt_norm:
                report_error("TASK_TRACKER.md contains a stale open depth "
                             "work statement; the second geometry and the "
                             "Vulkan arms are complete for every class in "
                             "validated-tuples.tsv")
        else:
            if ("second submission geometry per class" not in tt_norm
                    or "Vulkan-backend arms" not in tt_norm):
                report_error("TASK_TRACKER.md missing the expected open "
                             "depth work statement")

    # 6. Serving backend.
    if "CUDA0" not in readme_text:
        report_error("README.md does not assert CUDA0 serving authority")

    if failures:
        print(f"check_authority_consistency=rejected failures={len(failures)}",
              file=sys.stderr)
        sys.exit(1)

    print("check_authority_consistency=accepted")
    sys.exit(0)


if __name__ == "__main__":
    main()
