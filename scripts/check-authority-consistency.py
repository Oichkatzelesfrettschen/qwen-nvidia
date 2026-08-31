#!/usr/bin/env python3
"""
Check consistency between mutable current-state documentation and machine-readable authority surfaces.
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
                # Header might be in a comment line starting with '# id\t' or '# tuple_id\t'
                if line.startswith("# id\t") or line.startswith("#\tid\t") or line.startswith("#tuple_id\t") or line.startswith("# tuple_id\t") or line.startswith("#id\t"):
                    header_line = line.lstrip("#").strip()
                    header = [col.strip() for col in header_line.split("\t")]
                continue
            parts = [col.strip() for col in line.split("\t")]
            rows.append((line_num, parts))
    return header, rows

def normalize_ws(text):
    return " ".join(text.split())

def main():
    repo_root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).parent.parent.resolve()

    failures = []

    def report_error(msg):
        failures.append(msg)
        print(f"authority_consistency: ERROR: {msg}", file=sys.stderr)

    # 1. Run underlying validator scripts
    check_tuples_script = repo_root / "scripts" / "check-validated-tuples.sh"
    if check_tuples_script.exists():
        env = os.environ.copy()
        env["QWEN_MODEL_REGISTRY"] = str(repo_root / "scripts" / "models.tsv")
        env["QWEN_VALIDATED_TUPLES"] = str(repo_root / "scripts" / "validated-tuples.tsv")
        res = subprocess.run([str(check_tuples_script)], cwd=str(repo_root), env=env, capture_output=True, text=True)
        if res.returncode != 0:
            report_error(f"check-validated-tuples.sh failed: {res.stderr.strip() or res.stdout.strip()}")
    else:
        report_error("scripts/check-validated-tuples.sh missing")

    check_nvidia_script = repo_root / "scripts" / "check-nvidia-authority.sh"
    if check_nvidia_script.exists():
        res = subprocess.run([str(check_nvidia_script), str(repo_root)], cwd=str(repo_root), capture_output=True, text=True)
        if res.returncode != 0:
            report_error(f"check-nvidia-authority.sh failed: {res.stderr.strip() or res.stdout.strip()}")
    else:
        report_error("scripts/check-nvidia-authority.sh missing")

    # 2. Verify promotion evidence & README.md references
    promoted_dir = repo_root / "evidence" / "ada" / "promotion-88681bf4d161"
    rollback_dir = repo_root / "evidence" / "ada" / "promotion-31d0775c5bc6"
    diagnostic_dir = repo_root / "evidence" / "ada" / "promotion-572951d25562"

    if not (promoted_dir / "README.md").exists() or not (promoted_dir / "serving-summary.tsv").exists():
        report_error("Missing promoted configuration evidence under evidence/ada/promotion-88681bf4d161/")
    if not (rollback_dir / "README.md").exists():
        report_error("Missing rollback configuration evidence under evidence/ada/promotion-31d0775c5bc6/")
    if not (diagnostic_dir / "README.md").exists():
        report_error("Missing diagnostic configuration evidence under evidence/ada/promotion-572951d25562/")

    readme_path = repo_root / "README.md"
    if not readme_path.exists():
        report_error("README.md missing")
        readme_text = ""
    else:
        readme_text = readme_path.read_text(encoding="utf-8")

    readme_norm = normalize_ws(readme_text)

    if "88681bf4d161" not in readme_text:
        report_error("README.md does not reference promoted configuration 88681bf4d161")
    if "31d0775c5bc6" not in readme_text:
        report_error("README.md does not reference rollback configuration 31d0775c5bc6")
    if "572951d25562" not in readme_text:
        report_error("README.md does not reference diagnostic dual-backend configuration 572951d25562")

    # Verify MMVQ thresholds in README.md
    if not re.search(r"Q6_K\b[^\n.]{1,80}(?:10|ten)", readme_text, re.IGNORECASE):
        report_error("README.md does not accurately declare Q6_K MMVQ threshold of 10")
    if not re.search(r"Q8_0\b[^\n.]{1,80}(?:16|sixteen)", readme_text, re.IGNORECASE):
        report_error("README.md does not accurately declare Q8_0 MMVQ threshold of 16")

    # 3. Verify Quarantine state
    quarantine_tsv = repo_root / "scripts" / "quarantine.tsv"
    q_header, q_rows = parse_tsv(quarantine_tsv)
    if q_rows is None:
        report_error("scripts/quarantine.tsv missing or unreadable")
        quarantined_ids = set()
    else:
        quarantined_ids = {parts[0] for _, parts in q_rows if parts}

    if "qwen38-9b-distill" in quarantined_ids:
        report_error("qwen38-9b-distill is present in scripts/quarantine.tsv but should be readmitted")

    if "quarantine.tsv excludes the 9B distill" in readme_text or "excludes the 9B distill from router service" in readme_text:
        report_error("README.md contains stale text claiming qwen38-9b-distill is quarantined")

    if "ministral3-3b" not in quarantined_ids:
        report_error("ministral3-3b is missing from active quarantine set in scripts/quarantine.tsv")

    # Read models.tsv
    models_tsv = repo_root / "scripts" / "models.tsv"
    m_header, m_rows = parse_tsv(models_tsv)
    if m_rows is None or not m_header:
        report_error("scripts/models.tsv missing, empty, or missing column header")
        models_dict = {}
    else:
        models_dict = {}
        for lnum, parts in m_rows:
            if len(parts) == len(m_header):
                d = dict(zip(m_header, parts))
                models_dict[d["id"]] = (lnum, d)
            else:
                report_error(f"scripts/models.tsv row at line {lnum} has {len(parts)} fields, expected {len(m_header)}")

    if "qwen38-9b-distill" in models_dict:
        _, m9b = models_dict["qwen38-9b-distill"]
        if m9b.get("switch_policy") != "evict-first":
            report_error(f"qwen38-9b-distill in models.tsv has switch_policy '{m9b.get('switch_policy')}', expected 'evict-first'")
    else:
        report_error("qwen38-9b-distill missing from scripts/models.tsv")

    if "switch_policy=evict-first" not in readme_norm and "evict-first" not in readme_norm:
        report_error("README.md does not document evict-first switch policy for qwen38-9b-distill")
    if "QWEN_ROUTER_MAX=1" not in readme_text:
        report_error("README.md does not document QWEN_ROUTER_MAX=1 constraint for qwen38-9b-distill")

    evict_evidence = repo_root / "evidence" / "ada" / "evict-first-9b-readmission"
    if not (evict_evidence / "README.md").exists():
        report_error("Missing readmission evidence under evidence/ada/evict-first-9b-readmission/")

    # 4. Validated filled depths
    expected_depths = {
        "qwen38-2b-distill": ("65536", "2048", "512"),
        "qwen35-08b": ("65536", "2048", "512"),
        "qwen38-4b-distill": ("32768", "2048", "512"),
        "qwen38-9b-distill": ("24576", "2048", "512")
    }

    for model_id, (exp_depth, exp_batch, exp_ubatch) in expected_depths.items():
        if model_id not in models_dict:
            report_error(f"{model_id} missing from models.tsv")
            continue
        _, row_data = models_dict[model_id]
        if row_data.get("validated_filled_depth") != exp_depth:
            report_error(f"{model_id} in models.tsv has validated_filled_depth '{row_data.get('validated_filled_depth')}', expected '{exp_depth}'")
        if row_data.get("batch") != exp_batch:
            report_error(f"{model_id} in models.tsv has batch '{row_data.get('batch')}', expected '{exp_batch}'")
        if row_data.get("ubatch") != exp_ubatch:
            report_error(f"{model_id} in models.tsv has ubatch '{row_data.get('ubatch')}', expected '{exp_ubatch}'")

    # Check validated-tuples.tsv
    tuples_tsv = repo_root / "scripts" / "validated-tuples.tsv"
    t_header, t_rows = parse_tsv(tuples_tsv)
    validated_tuples_map = {}
    if t_rows is not None:
        for lnum, parts in t_rows:
            if len(parts) >= 15:
                model_id = parts[1]
                ctx = parts[3]
                batch = parts[4]
                ubatch = parts[5]
                backend = parts[12]
                status = parts[13]
                if status == "validated":
                    validated_tuples_map.setdefault(model_id, []).append((ctx, batch, ubatch, backend))

    for model_id, (exp_depth, exp_batch, exp_ubatch) in expected_depths.items():
        v_list = validated_tuples_map.get(model_id, [])
        match = any(ctx == exp_depth and b == exp_batch and ub == exp_ubatch and backend == "cuda" for ctx, b, ub, backend in v_list)
        if not match:
            report_error(f"scripts/validated-tuples.tsv lacks validated CUDA tuple for {model_id} at depth {exp_depth}, batch {exp_batch}, ubatch {exp_ubatch}")

    # 5. Derive open depth work and verify TASK_TRACKER.md
    task_tracker_path = repo_root / "TASK_TRACKER.md"
    if task_tracker_path.exists():
        tt_text = task_tracker_path.read_text(encoding="utf-8")
        tt_norm = normalize_ws(tt_text)

        # Count distinct geometries and vulkan validations per expected class
        cuda_geometries_per_model = {}
        vulkan_validations = 0
        for model_id in expected_depths:
            v_list = validated_tuples_map.get(model_id, [])
            cuda_geoms = {(b, ub) for ctx, b, ub, backend in v_list if backend == "cuda"}
            cuda_geometries_per_model[model_id] = len(cuda_geoms)
            vulkan_validations += sum(1 for ctx, b, ub, backend in v_list if backend == "vulkan")

        has_second_geometry_all_classes = all(count >= 2 for count in cuda_geometries_per_model.values())
        has_vulkan_validation = vulkan_validations > 0

        # If all classes have second geometry and Vulkan validation, but TASK_TRACKER claims open work is second geometry and Vulkan arms, TASK_TRACKER is stale!
        if has_second_geometry_all_classes and has_vulkan_validation:
            if "Open extensions: a second submission geometry per class, and the Vulkan-backend arms" in tt_norm:
                report_error("TASK_TRACKER.md contains stale open depth work statement; second geometry and Vulkan validation are already complete in validated-tuples.tsv")
        else:
            if "second submission geometry per class" not in tt_norm or "Vulkan-backend arms" not in tt_norm:
                report_error("TASK_TRACKER.md missing expected open depth work statement")

    # 6. Serving Backend assertions
    if "CUDA0" not in readme_text:
        report_error("README.md does not assert CUDA0 serving authority")

    if failures:
        print(f"check_authority_consistency=rejected failures={len(failures)}", file=sys.stderr)
        sys.exit(1)

    print("check_authority_consistency=accepted")
    sys.exit(0)

if __name__ == "__main__":
    main()
