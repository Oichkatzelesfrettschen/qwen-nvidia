#!/usr/bin/env python3
"""
Deterministic fixture tests for scripts/check-authority-consistency.py.
"""

import sys
import pathlib
import shutil
import tempfile
import subprocess

def run_checker(target_repo):
    checker_path = pathlib.Path(__file__).parent / "check-authority-consistency.py"
    res = subprocess.run(
        [sys.executable, str(checker_path), str(target_repo)],
        capture_output=True,
        text=True
    )
    return res.returncode, res.stdout, res.stderr

def copy_repo(src_root, dst_dir):
    # Copy essential repository files needed for consistency checks
    for item in ["README.md", "CLAUDE.md", "TASK_TRACKER.md", "scripts", "evidence"]:
        src_item = src_root / item
        dst_item = dst_dir / item
        if src_item.is_dir():
            shutil.copytree(src_item, dst_item)
        elif src_item.is_file():
            shutil.copy2(src_item, dst_item)

    # Initialize a git repo in dst_dir so scripts that query git work properly
    subprocess.run(["git", "init", "-q"], cwd=str(dst_dir), check=True)
    subprocess.run(["git", "config", "user.name", "test"], cwd=str(dst_dir), check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=str(dst_dir), check=True)
    subprocess.run(["git", "add", "."], cwd=str(dst_dir), check=True)
    subprocess.run(["git", "commit", "-q", "-m", "initial test commit"], cwd=str(dst_dir), check=True)

def main():
    repo_root = pathlib.Path(__file__).parent.parent.resolve()
    failures = 0

    def test_case(name, mutator_fn, expect_pass=False):
        nonlocal failures
        with tempfile.TemporaryDirectory(prefix="test_auth_consist_") as tmp_dir:
            tmp_path = pathlib.Path(tmp_dir)
            copy_repo(repo_root, tmp_path)
            if mutator_fn:
                mutator_fn(tmp_path)
            code, stdout, stderr = run_checker(tmp_path)
            if expect_pass:
                if code == 0:
                    print(f"PASS: {name}")
                else:
                    print(f"FAIL: {name} (expected pass, got exit code {code})\nstderr: {stderr}\nstdout: {stdout}", file=sys.stderr)
                    failures += 1
            else:
                if code != 0:
                    print(f"PASS: {name} (failed as expected)")
                else:
                    print(f"FAIL: {name} (expected failure, got exit code 0)", file=sys.stderr)
                    failures += 1

    # 1. Clean current tree passes
    test_case("clean_current_tree_passes", None, expect_pass=True)

    # 2. Stale production promotion reference fails
    def mut_stale_promotion(tmp_path):
        readme = tmp_path / "README.md"
        text = readme.read_text(encoding="utf-8")
        text = text.replace("88681bf4d161", "000000000000")
        readme.write_text(text, encoding="utf-8")

    test_case("stale_production_promotion_reference_fails", mut_stale_promotion, expect_pass=False)

    # 3. Missing referenced promotion evidence fails
    def mut_missing_evidence(tmp_path):
        ev_dir = tmp_path / "evidence" / "ada" / "promotion-88681bf4d161"
        if ev_dir.exists():
            shutil.rmtree(ev_dir)

    test_case("missing_referenced_promotion_evidence_fails", mut_missing_evidence, expect_pass=False)

    # 4. Stale Q8_0 or Q6_K promoted threshold claim fails
    def mut_stale_threshold(tmp_path):
        readme = tmp_path / "README.md"
        text = readme.read_text(encoding="utf-8")
        text = text.replace("Q6_K at ten", "Q6_K at eight").replace("Q6_K MMVQ threshold 10", "Q6_K MMVQ threshold 8")
        readme.write_text(text, encoding="utf-8")

    test_case("stale_threshold_claim_fails", mut_stale_threshold, expect_pass=False)

    # 5. Documentation still claiming the 9B is quarantined fails
    def mut_stale_9b_quarantine(tmp_path):
        readme = tmp_path / "README.md"
        text = readme.read_text(encoding="utf-8")
        text += "\nquarantine.tsv excludes the 9B distill from router service.\n"
        readme.write_text(text, encoding="utf-8")

    test_case("doc_claiming_9b_quarantined_fails", mut_stale_9b_quarantine, expect_pass=False)

    # 6. Changed 9B switch_policy against stale documentation fails
    def mut_changed_9b_switch_policy(tmp_path):
        models = tmp_path / "scripts" / "models.tsv"
        text = models.read_text(encoding="utf-8")
        text = text.replace("\tevict-first\n", "\tlru\n")
        models.write_text(text, encoding="utf-8")

    test_case("changed_9b_switch_policy_fails", mut_changed_9b_switch_policy, expect_pass=False)

    # 7. Changed validated depth against stale documentation fails
    def mut_changed_validated_depth(tmp_path):
        models = tmp_path / "scripts" / "models.tsv"
        text = models.read_text(encoding="utf-8")
        lines = text.splitlines()
        new_lines = []
        for line in lines:
            if line.startswith("qwen38-2b-distill\t"):
                parts = line.split("\t")
                parts[18] = "32768"
                new_lines.append("\t".join(parts))
            else:
                new_lines.append(line)
        models.write_text("\n".join(new_lines) + "\n", encoding="utf-8")

    test_case("changed_validated_depth_fails", mut_changed_validated_depth, expect_pass=False)

    # 8. Changed batch/ubatch geometry against stale documentation fails
    def mut_changed_geometry(tmp_path):
        models = tmp_path / "scripts" / "models.tsv"
        text = models.read_text(encoding="utf-8")
        lines = text.splitlines()
        new_lines = []
        for line in lines:
            if line.startswith("qwen38-2b-distill\t"):
                parts = line.split("\t")
                parts[16] = "1024"
                new_lines.append("\t".join(parts))
            else:
                new_lines.append(line)
        models.write_text("\n".join(new_lines) + "\n", encoding="utf-8")

    test_case("changed_geometry_fails", mut_changed_geometry, expect_pass=False)

    # 9. Removed required authority input fails closed
    def mut_remove_quarantine_tsv(tmp_path):
        q = tmp_path / "scripts" / "quarantine.tsv"
        if q.exists():
            q.unlink()

    test_case("removed_authority_input_fails_closed", mut_remove_quarantine_tsv, expect_pass=False)

    # 10. Malformed authority input propagates failure from existing validator
    def mut_malformed_validated_tuples(tmp_path):
        vt = tmp_path / "scripts" / "validated-tuples.tsv"
        text = vt.read_text(encoding="utf-8")
        text += "\nmalformed_tuple_id\tmodel_id\tonly_three_fields\n"
        vt.write_text(text, encoding="utf-8")

    test_case("malformed_authority_input_propagates_failure", mut_malformed_validated_tuples, expect_pass=False)

    # 11. Completion of previously open depth-validation condition makes stale TASK_TRACKER claim fail
    def mut_completed_open_depth_work(tmp_path):
        vt = tmp_path / "scripts" / "validated-tuples.tsv"
        text = vt.read_text(encoding="utf-8")
        new_rows = [
            "qwen38-2b-distill-d65536-b1024-ub256\tqwen38-2b-distill\tstandalone\t65536\t1024\t256\tq8_0\tq4_0\ton\t1\t1\tnone\tcuda\tvalidated\tevidence/depth-validation-cuda/qwen38-2b-distill/\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0\t054d1295095ec006ed2ae1c3b65d43a51aaaf5575989ace0b69f53efa4a351cd\t7.2.2-1-cachyos\t-\t610.57.04\t2026-08-31",
            "qwen35-08b-d65536-b1024-ub256\tqwen35-08b\tstandalone\t65536\t1024\t256\tq8_0\tq4_0\ton\t1\t1\tnone\tcuda\tvalidated\tevidence/depth-validation-cuda/qwen35-08b/\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0\t054d1295095ec006ed2ae1c3b65d43a51aaaf5575989ace0b69f53efa4a351cd\t7.2.2-1-cachyos\t-\t610.57.04\t2026-08-31",
            "qwen38-4b-distill-d32768-b1024-ub256\tqwen38-4b-distill\tstandalone\t32768\t1024\t256\tq8_0\tq4_0\ton\t1\t1\tnone\tcuda\tvalidated\tevidence/depth-validation-cuda/qwen38-4b-distill/\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0\t054d1295095ec006ed2ae1c3b65d43a51aaaf5575989ace0b69f53efa4a351cd\t7.2.2-1-cachyos\t-\t610.57.04\t2026-08-31",
            "qwen38-9b-distill-d24576-b1024-ub256\tqwen38-9b-distill\tstandalone\t24576\t1024\t256\tq8_0\tq4_0\ton\t1\t1\tnone\tcuda\tvalidated\tevidence/depth-validation-cuda/qwen38-9b-distill/\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0\t054d1295095ec006ed2ae1c3b65d43a51aaaf5575989ace0b69f53efa4a351cd\t7.2.2-1-cachyos\t-\t610.57.04\t2026-08-31",
            "qwen38-2b-distill-d65536-vulkan\tqwen38-2b-distill\tstandalone\t65536\t2048\t512\tq8_0\tq4_0\ton\t1\t1\tnone\tvulkan\tvalidated\tevidence/depth-validation-cuda/qwen38-2b-distill/\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0\t054d1295095ec006ed2ae1c3b65d43a51aaaf5575989ace0b69f53efa4a351cd\t7.2.2-1-cachyos\t-\t610.57.04\t2026-08-31"
        ]
        vt.write_text(text + "\n" + "\n".join(new_rows) + "\n", encoding="utf-8")

    test_case("completed_open_depth_work_makes_stale_task_tracker_fail", mut_completed_open_depth_work, expect_pass=False)

    if failures:
        print(f"test_authority_consistency: REJECTED ({failures} failures)", file=sys.stderr)
        sys.exit(1)

    print("test_authority_consistency: ACCEPTED")
    sys.exit(0)

if __name__ == "__main__":
    main()
