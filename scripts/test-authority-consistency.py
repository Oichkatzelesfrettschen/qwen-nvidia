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
    # The fixture is the tracked authority surface, so enumeration goes
    # through git ls-files: a copytree would also carry ignored local
    # evidence directories, and tracking those in the fixture repository
    # fails check-nvidia-authority.sh on terms the real tree never commits.
    tracked = subprocess.run(
        ["git", "-C", str(src_root), "ls-files", "-z", "--",
         "README.md", "CLAUDE.md", "TASK_TRACKER.md", "scripts", "evidence"],
        capture_output=True, text=True, check=True).stdout
    for relative in filter(None, tracked.split("\0")):
        src_item = src_root / relative
        dst_item = dst_dir / relative
        dst_item.parent.mkdir(parents=True, exist_ok=True)
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

    def test_case(name, mutator_fn, expect_pass=False, expect_error=None):
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
                if code != 0 and (expect_error is None or expect_error in stderr):
                    print(f"PASS: {name} (failed as expected)")
                elif code != 0:
                    print(f"FAIL: {name} (failed without the expected error {expect_error!r})\nstderr: {stderr}", file=sys.stderr)
                    failures += 1
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

    # 11. Completion of the open depth-validation conditions for every class
    # makes the stale TASK_TRACKER claim fail. Coverage is per expected model,
    # so every row claiming a validated_filled_depth gains both a second CUDA
    # geometry and a Vulkan tuple.
    def depth_rows(tmp_path):
        models = tmp_path / "scripts" / "models.tsv"
        rows = []
        for line in models.read_text(encoding="utf-8").splitlines():
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split("\t")
            if parts[18].isdigit():
                rows.append((parts[0], parts[18]))
        return rows

    def tuple_row(model_id, depth, batch, ubatch, backend):
        return ("%s-d%s-b%s-ub%s-%s\t%s\tstandalone\t%s\t%s\t%s\tq8_0\tq4_0\ton\t1\t1\tnone\t%s\tvalidated\tevidence/depth-validation-cuda/%s/\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0\t054d1295095ec006ed2ae1c3b65d43a51aaaf5575989ace0b69f53efa4a351cd\t7.2.2-1-cachyos\t-\t610.57.04\t2026-08-31"
                % (model_id, depth, batch, ubatch, backend, model_id, depth,
                   batch, ubatch, backend, model_id))

    def mut_completed_open_depth_work(tmp_path):
        vt = tmp_path / "scripts" / "validated-tuples.tsv"
        rows = []
        for model_id, depth in depth_rows(tmp_path):
            rows.append(tuple_row(model_id, depth, "1024", "256", "cuda"))
            rows.append(tuple_row(model_id, depth, "2048", "512", "vulkan"))
        vt.write_text(vt.read_text(encoding="utf-8") + "\n".join(rows) + "\n",
                      encoding="utf-8")

    # The backend gate in check-nvidia-authority.sh also rejects the Vulkan
    # rows, so the assertion binds to the stale-tracker message itself.
    test_case("completed_open_depth_work_makes_stale_task_tracker_fail",
              mut_completed_open_depth_work, expect_pass=False,
              expect_error="still states the Vulkan arm as open work")

    # 12. Second CUDA geometries alone leave the Vulkan arms open for every
    # class. The tracker states the Vulkan arm and states no open second
    # geometry, which is what the two conditions independently require, so the
    # tree passes.
    def mut_second_geometry_without_vulkan(tmp_path):
        vt = tmp_path / "scripts" / "validated-tuples.tsv"
        rows = [tuple_row(model_id, depth, "1024", "256", "cuda")
                for model_id, depth in depth_rows(tmp_path)]
        vt.write_text(vt.read_text(encoding="utf-8") + "\n".join(rows) + "\n",
                      encoding="utf-8")

    test_case("second_geometry_without_vulkan_keeps_open_statement_valid", mut_second_geometry_without_vulkan, expect_pass=True)

    # 13. A quarantine row whose id differs from its subject still removes the
    # subject, so README text claiming readmission fails.
    def mut_quarantine_id_differs_from_subject(tmp_path):
        q = tmp_path / "scripts" / "quarantine.tsv"
        q.write_text(q.read_text(encoding="utf-8")
                     + "qwen38-9b-distill-router-load\tmodel\tqwen38-9b-distill\tdevice-lost\t-\t-\t-\t-\t-\t-\tevidence/quarantine/qwen38-9b-distill-router-load.md\tevidence/quarantine/qwen38-9b-distill-router-load.md\tevidence/quarantine/qwen38-9b-distill-router-load.md\trouter-child\n",
                     encoding="utf-8")

    test_case("quarantine_subject_differs_from_row_id_fails", mut_quarantine_id_differs_from_subject, expect_pass=False)

    # 14. TASK_TRACKER.md is a required surface; its absence fails closed.
    def mut_remove_task_tracker(tmp_path):
        (tmp_path / "TASK_TRACKER.md").unlink()

    test_case("removed_task_tracker_fails_closed", mut_remove_task_tracker, expect_pass=False)

    # 15. The served-closure statement is role-qualified: relabeling the
    # rollback digest as the served closure fails even though 88681bf4d161
    # remains present elsewhere in README.md.
    def mut_relabel_served_closure(tmp_path):
        readme = tmp_path / "README.md"
        text = readme.read_text(encoding="utf-8")
        text = text.replace("served closure is configuration `88681bf4d161`",
                            "served closure is configuration `31d0775c5bc6`")
        readme.write_text(text, encoding="utf-8")

    test_case("relabeled_served_closure_fails", mut_relabel_served_closure, expect_pass=False)

    # 16. A threshold clause changed to twelve fails even while the
    # promotion evidence path keeps the digit sixteen nearby.
    def mut_stale_q80_threshold(tmp_path):
        readme = tmp_path / "README.md"
        text = readme.read_text(encoding="utf-8")
        text = text.replace("Q8_0 at sixteen", "Q8_0 at twelve")
        text = text.replace("Q8_0 MMVQ threshold 16", "Q8_0 MMVQ threshold 12")
        readme.write_text(text, encoding="utf-8")

    test_case("stale_q80_threshold_clause_fails", mut_stale_q80_threshold, expect_pass=False)

    # --- hostile fixtures for the semantic distinctions the ledgers carry ---

    # A profile-scope quarantine removes one tuple rather than the checkpoint,
    # so reading it as a model quarantine would refuse a readmitted row.
    def mut_profile_scope_quarantine(root):
        path = root / "scripts" / "quarantine.tsv"
        lines = path.read_text().splitlines()
        header = next(i for i, x in enumerate(lines)
                      if x.lstrip("#").strip().startswith("id\t"))
        columns = len(lines[header].lstrip("#").strip().split("\t"))
        row = ["profile-9b-probe", "profile", "qwen38-9b-distill",
               "fixture", "-"]
        row += ["-"] * (columns - len(row))
        lines.append("\t".join(row[:columns]))
        path.write_text("\n".join(lines) + "\n")
    test_case("profile_scope_quarantine_is_not_a_model_quarantine",
              mut_profile_scope_quarantine, expect_pass=True)

    # A model-scope row on the same subject must still refuse.
    def mut_model_scope_quarantine(root):
        path = root / "scripts" / "quarantine.tsv"
        lines = path.read_text().splitlines()
        header = next(i for i, x in enumerate(lines)
                      if x.lstrip("#").strip().startswith("id\t"))
        columns = len(lines[header].lstrip("#").strip().split("\t"))
        row = ["model-9b-probe", "model", "qwen38-9b-distill", "fixture", "-"]
        row += ["-"] * (columns - len(row))
        lines.append("\t".join(row[:columns]))
        path.write_text("\n".join(lines) + "\n")
    test_case("model_scope_quarantine_on_readmitted_row_fails",
              mut_model_scope_quarantine, expect_pass=False,
              expect_error="model-scope quarantine")

    # A new evict-first row that no document mentions must be caught, rather
    # than the gate checking one named checkpoint.
    def mut_new_evict_first_row(root):
        path = root / "scripts" / "models.tsv"
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            if line.startswith("qwen38-4b-i1-q2k\t"):
                parts = line.split("\t")
                parts[-1] = "evict-first"
                lines[i] = "\t".join(parts)
                break
        path.write_text("\n".join(lines) + "\n")
    test_case("new_evict_first_row_absent_from_docs_fails",
              mut_new_evict_first_row, expect_pass=False,
              expect_error="does not document")

    # A registry row carrying a numeric depth but no validation class must not
    # enlarge the campaign's completion judgement.
    def mut_unrelated_numeric_depth(root):
        models = root / "scripts" / "models.tsv"
        tuples = root / "scripts" / "validated-tuples.tsv"
        lines = models.read_text().splitlines()
        target = None
        for i, line in enumerate(lines):
            if line.startswith("nanbeige42-3b\t"):
                parts = line.split("\t")
                parts[18] = "8192"
                lines[i] = "\t".join(parts)
                target = parts
                break
        if target is None:
            return
        models.write_text("\n".join(lines) + "\n")
        tl = tuples.read_text().splitlines()
        head = next(x for x in tl
                    if x.lstrip("#").strip().startswith("tuple_id\t"))
        columns = head.lstrip("#").strip().split("\t")
        row = dict.fromkeys(columns, "-")
        row.update({"tuple_id": "nanbeige42-3b-d8192-fixture",
                    "model_id": "nanbeige42-3b", "runtime_mode": "standalone",
                    "context": "8192", "batch": target[16],
                    "ubatch": target[17], "cache_k": target[7],
                    "cache_v": target[8], "flash_attention": target[9],
                    "threads": "1", "parallel": "1", "projector_state": "none",
                    "backend": "cuda", "status": "validated",
                    "evidence": "evidence/depth-validation-cuda/",
                    "measured_at": "2026-09-01"})
        tl.append("\t".join(row[c] for c in columns))
        tuples.write_text("\n".join(tl) + "\n")
    test_case("unrelated_numeric_depth_does_not_change_class_completion",
              mut_unrelated_numeric_depth, expect_pass=True)

    # A second geometry measured at a shallower depth answers a different
    # question than the campaign asks, so it must not close the extension.
    def mut_shallow_second_geometry(root):
        tuples = root / "scripts" / "validated-tuples.tsv"
        tl = tuples.read_text().splitlines()
        head = next(x for x in tl
                    if x.lstrip("#").strip().startswith("tuple_id\t"))
        columns = head.lstrip("#").strip().split("\t")
        rows = [x for x in tl if x and not x.startswith("#")]
        base = None
        for r in rows:
            d = dict(zip(columns, r.split("\t")))
            if d["model_id"] == "qwen38-2b-distill" and d["backend"] == "cuda":
                base = d
                break
        if base is None:
            return
        shallow = dict(base)
        shallow.update({"tuple_id": "qwen38-2b-distill-shallow-fixture",
                        "context": "4096", "batch": "512", "ubatch": "128"})
        # The measured second geometries are removed so the only candidate
        # left is the shallow one: with them in place the extension is closed
        # whatever this row says, and the case would assert nothing.
        tl = [x for x in tl if "-b1024-ub256\t" not in x]
        tl.append("\t".join(shallow[c] for c in columns))
        tuples.write_text("\n".join(tl) + "\n")
    test_case("shallow_second_geometry_does_not_close_the_extension",
              mut_shallow_second_geometry, expect_pass=False,
              expect_error="omits the open second geometry statement")

    # A rollback digest presented under the served-closure role must fail even
    # though the string appears in the document.
    def mut_rollback_under_served_role(root):
        readme = root / "README.md"
        readme.write_text(readme.read_text().replace(
            "served closure is configuration `88681bf4d161`",
            "served closure is configuration `31d0775c5bc6`"))
    test_case("rollback_digest_under_served_role_fails",
              mut_rollback_under_served_role, expect_pass=False,
              expect_error="served-closure statement names")

    # An ambient serving backend must not decide what the nested validator
    # admits; the checker names the backend for its child.
    def mut_none(root):
        return
    def run_with_backend(value):
        import os
        environment = dict(os.environ, QWEN_SERVING_BACKEND=value)
        with tempfile.TemporaryDirectory(prefix="test_auth_env_") as tmp_dir:
            tmp_path = pathlib.Path(tmp_dir)
            copy_repo(repo_root, tmp_path)
            checker = pathlib.Path(__file__).parent / "check-authority-consistency.py"
            return subprocess.run(
                [sys.executable, str(checker), str(tmp_path)],
                capture_output=True, text=True, env=environment).returncode
    for ambient in ("vulkan", "invalid"):
        code = run_with_backend(ambient)
        if code == 0:
            print(f"PASS: ambient_backend_{ambient}_does_not_change_result")
        else:
            print(f"FAIL: ambient_backend_{ambient}_does_not_change_result "
                  f"(exit {code})", file=sys.stderr)
            failures += 1

    # The promotion summary states an outcome rather than merely existing.
    def mut_malformed_serving_summary(root):
        path = (root / "evidence" / "ada" / "promotion-88681bf4d161"
                / "serving-summary.tsv")
        path.write_text("check\tresult\tdetail\nlaunch\taccepted\tx\n")
    test_case("incomplete_serving_summary_fails",
              mut_malformed_serving_summary, expect_pass=False,
              expect_error="omits required checks")

    def mut_serving_summary_wrong_device(root):
        path = (root / "evidence" / "ada" / "promotion-88681bf4d161"
                / "serving-summary.tsv")
        text = path.read_text().replace("CUDA0", "Vulkan0")
        path.write_text(text)
    test_case("serving_summary_naming_another_device_fails",
              mut_serving_summary_wrong_device, expect_pass=False,
              expect_error="does not name CUDA0")

    # A tracker stating a depth the registry does not claim must fail.
    def mut_stale_tracker_depth(root):
        tracker = root / "TASK_TRACKER.md"
        tracker.write_text(tracker.read_text().replace(
            "qwen25-coder-7b at 32768", "qwen25-coder-7b at 8192"))
    test_case("stale_per_model_tracker_depth_fails",
              mut_stale_tracker_depth, expect_pass=False,
              expect_error="TASK_TRACKER.md states")

    # The coding lane's three-way rule: a validator-gated profile requires an
    # admitted runtime and the model's own execution grant. Each authority is
    # mutated on its own.
    def mut_coding_runtime_refused(root):
        path = root / "scripts" / "coding-runtimes.tsv"
        path.write_text(path.read_text().replace(
            "qwen-code/bin/qwen\tvalidator-gated",
            "qwen-code/bin/qwen\trefused"))
    test_case("validator_gated_profile_with_refused_runtime_fails",
              mut_coding_runtime_refused, expect_pass=False,
              expect_error="while its runtime")

    def mut_coding_model_grant_refused(root):
        path = root / "scripts" / "models.tsv"
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            if line.startswith("qwenseer-2b\t"):
                parts = line.split("\t")
                parts[21] = "refused"
                lines[i] = "\t".join(parts)
                break
        path.write_text("\n".join(lines) + "\n")
    test_case("validator_gated_profile_without_model_grant_fails",
              mut_coding_model_grant_refused, expect_pass=False,
              expect_error="guarded_tool_execution")

    # A closure ledger naming an unreadable evidence path fails closed.
    def mut_closure_evidence_missing(root):
        path = root / "scripts" / "serving-closures.tsv"
        path.write_text(path.read_text().replace(
            "evidence/ada/promotion-572951d25562",
            "evidence/ada/promotion-absent"))
    test_case("closure_ledger_with_unreadable_evidence_fails",
              mut_closure_evidence_missing, expect_pass=False,
              expect_error="diagnostic configuration evidence")

    # The promoted row's threshold pair is what README's clauses are held
    # against, so moving the ledger value alone leaves every clause stale.
    def mut_promoted_threshold_moved(root):
        path = root / "scripts" / "serving-closures.tsv"
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            if line.startswith("promoted\t"):
                parts = line.split("\t")
                parts[8] = "11"
                lines[i] = "\t".join(parts)
        path.write_text("\n".join(lines) + "\n")
    test_case("promoted_threshold_moved_without_readme_fails",
              mut_promoted_threshold_moved, expect_pass=False,
              expect_error="expected every clause at 11")

    # A threshold outside the kernel ceiling would refuse every bare build.
    def mut_promoted_threshold_out_of_range(root):
        path = root / "scripts" / "serving-closures.tsv"
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            if line.startswith("promoted\t"):
                parts = line.split("\t")
                parts[9] = "17"
                lines[i] = "\t".join(parts)
        path.write_text("\n".join(lines) + "\n")
    test_case("promoted_threshold_out_of_range_fails",
              mut_promoted_threshold_out_of_range, expect_pass=False,
              expect_error="not an integer from 1 to 16")

    # Swapping the rollback and diagnostic digests under each other's role
    # labels leaves both identities on the page, so only a role-qualified
    # comparison rejects it.
    def mut_swapped_role_digests(root):
        path = root / "README.md"
        text = path.read_text(encoding="utf-8")
        text = (text.replace("31d0775c5bc6", "\0")
                    .replace("572951d25562", "31d0775c5bc6")
                    .replace("\0", "572951d25562"))
        path.write_text(text, encoding="utf-8")
    test_case("swapped_rollback_and_diagnostic_roles_fails",
              mut_swapped_role_digests, expect_pass=False,
              expect_error="rollback-closure statement names")

    # A role statement removed outright fails rather than falling back to the
    # presence of the digest elsewhere in the document.
    def mut_missing_rollback_statement(root):
        path = root / "README.md"
        # README wraps the role clause across a line break, so the mutation
        # names a fragment that survives the wrap rather than the whole
        # normalized statement.
        path.write_text(path.read_text(encoding="utf-8").replace(
            "rollback target", "prior build"), encoding="utf-8")
    test_case("missing_rollback_role_statement_fails",
              mut_missing_rollback_statement, expect_pass=False,
              expect_error="no rollback-closure statement")

    # The model-scope quarantine claim is a complete set, so a second
    # model-scope row the prose does not disclose rejects.
    def mut_undisclosed_model_quarantine(root):
        path = root / "scripts" / "quarantine.tsv"
        text = path.read_text(encoding="utf-8")
        template = [line for line in text.splitlines()
                    if line.startswith("ministral3-3b\t")][0]
        added = template.replace("ministral3-3b", "qwen35-08b", 2)
        path.write_text(text + added + "\n", encoding="utf-8")
    test_case("undisclosed_model_scope_quarantine_fails",
              mut_undisclosed_model_quarantine, expect_pass=False,
              expect_error="documents the model-scope quarantine set")

    # And a documented subject the ledger no longer carries is stale prose in
    # the other direction.
    def mut_documented_subject_absent_from_ledger(root):
        path = root / "scripts" / "quarantine.tsv"
        text = path.read_text(encoding="utf-8")
        kept = [line for line in text.splitlines()
                if not line.startswith("ministral3-3b\t")]
        path.write_text("\n".join(kept) + "\n", encoding="utf-8")
    test_case("documented_quarantine_subject_absent_from_ledger_fails",
              mut_documented_subject_absent_from_ledger, expect_pass=False,
              expect_error="documents the model-scope quarantine set")

    if failures:
        print(f"test_authority_consistency: REJECTED ({failures} failures)", file=sys.stderr)
        sys.exit(1)

    print("test_authority_consistency: ACCEPTED")
    sys.exit(0)

if __name__ == "__main__":
    main()
