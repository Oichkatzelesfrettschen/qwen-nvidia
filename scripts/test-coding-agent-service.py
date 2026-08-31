#!/usr/bin/env python3
"""Admit the coding-agent service without the device, the model, or the
qwen-coder principal: the service runs as the current user against a
temporary mirror root, the fake coding agent stands in for the pinned
runtime, and each job's behavior is selected by the base commit it was
approved over. The suite covers the happy worktree-edit-test-diff-teardown
chain and the negatives the containment relies on; the checks that need
the real principal (uid separation, sudo denial, network egress) are
reported not-run here and belong to the on-appliance admission."""

import hashlib
import hmac
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

SCRIPTS = pathlib.Path(__file__).parent.resolve()
GRANT_FIELDS = [
    "action", "workspace_id", "repository_identity", "base_commit",
    "model_id", "profile_id", "instruction_sha256", "allowed_test_profile",
    "maximum_files_changed", "maximum_patch_bytes", "maximum_job_seconds",
    "conversation_generation", "expiry_epoch", "nonce",
]

failures = []
checks = 0


def check(name, condition, detail=""):
    global checks
    checks += 1
    if condition:
        print("check=%s outcome=pass" % name)
    else:
        failures.append(name)
        print("check=%s outcome=FAIL detail=%s" % (name, detail),
              file=sys.stderr)


def not_run(name, reason):
    print("check=%s outcome=not-run detail=%s" % (name, reason))


def git(repo, *arguments, check_exit=True):
    result = subprocess.run(["git", "-C", str(repo)] + list(arguments),
                            capture_output=True, text=True)
    if check_exit and result.returncode != 0:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


class Harness:
    def __init__(self, root):
        self.root = root
        self.repo = root / "authoritative"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "test")
        git(self.repo, "config", "user.email", "test@example.invalid")
        self.behaviors = {}
        for behavior in ["edit", "many-files", "big-patch", "sleep-trap",
                         "daemon", "push", "home-probe", "symlink"]:
            (self.repo / "FIXTURE_BEHAVIOR").write_text(behavior + "\n")
            (self.repo / "README").write_text("base for %s\n" % behavior)
            git(self.repo, "add", "-A")
            git(self.repo, "commit", "-q", "-m", "behavior %s" % behavior)
            self.behaviors[behavior] = git(self.repo, "rev-parse", "HEAD")

        self.principal_home = root / "principal-home"
        for sub in ["repos", "worktrees", "tmp"]:
            (self.principal_home / sub).mkdir(parents=True)
        self.bundle_dir = root / "bundles"
        self.state_dir = root / "state"
        self.key_file = root / "grant.key"
        self.key_file.write_bytes(b"test-grant-key")
        self.key_file.chmod(0o600)

        authorities = root / "authorities"
        authorities.mkdir()
        self.profiles = authorities / "coding-profiles.tsv"
        self.profiles.write_text(
            "# profile_id\tmodel_id\truntime_id\tworkspace_id\t"
            "maximum_context\tmaximum_reply_tokens\tmaximum_files_changed\t"
            "maximum_patch_bytes\tmaximum_job_seconds\t"
            "allowed_test_profile\tnetwork_policy\texecution_policy\n"
            "code-test\tqwenseer-2b\tqwen-code\ttest-repo\t32768\t8192\t"
            "8\t65536\t120\tfixture-echo\tloopback-llama\tvalidator-gated\n"
            "code-refused\tqwenseer-2b\tqwen-code\ttest-repo\t32768\t8192\t"
            "8\t65536\t120\tfixture-echo\tloopback-llama\trefused\n"
            "code-short\tqwenseer-2b\tqwen-code\ttest-repo\t32768\t8192\t"
            "8\t65536\t3\tfixture-echo\tloopback-llama\tvalidator-gated\n")
        self.workspaces = authorities / "coding-workspaces.tsv"
        self.workspaces.write_text(
            "# workspace_id\trepository_path\tmirror\ttest_profile\n"
            "test-repo\t%s\ttest-repo.git\tfixture-echo\n" % self.repo)
        self.models = authorities / "coding-models.tsv"
        self.models.write_text(
            "# model_id\trole\tminimum_validated_depth\tmax_reply_tokens\n"
            "qwenseer-2b\tfast-coder\t32768\t8192\n")
        self.quarantine = authorities / "coding-quarantine.tsv"
        self.quarantine.write_text(
            "# id\tscope\tsubject\tfailure_class\tfirst_evidence\t"
            "reason_record\n")
        self.registry = authorities / "models.tsv"
        self.registry.write_text(
            "# id\tvalidated_filled_depth\n"
            "qwenseer-2b\t65536\n")
        self.runtimes = authorities / "coding-runtimes.tsv"
        self.runtimes.write_text(
            "# id\tversion\tupstream_repository\trelease_tag\tasset_name\t"
            "asset_bytes\tasset_sha256\tinstall_directory\texecutable\t"
            "execution_policy\tvalidation_evidence\n"
            "qwen-code\t0.22.3\tQwenLM/qwen-code\tv0.22.3\ta.tar.gz\t1\t"
            + "0" * 64 + "\tv0.22.3\tqwen-code/bin/qwen\trefused\t-\n")

        self.socket_path = self.state_dir / "agent.sock"
        self.process = subprocess.Popen(
            [sys.executable, str(SCRIPTS / "coding-agent-service.py"),
             "--state-dir", str(self.state_dir),
             "--socket", str(self.socket_path),
             "--profiles", str(self.profiles),
             "--workspaces", str(self.workspaces),
             "--models", str(self.models),
             "--quarantine", str(self.quarantine),
             "--registry", str(self.registry),
             "--runtimes", str(self.runtimes),
             "--grant-key-file", str(self.key_file),
             "--principal", "current",
             "--principal-home", str(self.principal_home),
             "--bundle-dir", str(self.bundle_dir),
             "--agent-command",
             str(SCRIPTS / "test-fixtures" / "fake-coding-agent.sh")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.time() + 15
        while not self.socket_path.exists():
            if time.time() > deadline or self.process.poll() is not None:
                raise RuntimeError("service did not listen: %s"
                                   % self.process.stdout.read())
            time.sleep(0.1)

    def request(self, payload):
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(150)
        connection.connect(str(self.socket_path))
        connection.sendall((json.dumps(payload) + "\n").encode())
        reply = connection.makefile().readline()
        connection.close()
        return json.loads(reply)

    def grant(self, request, **overrides):
        claim = {
            "action": "open_job",
            "workspace_id": request["workspace_id"],
            "repository_identity": "test-repo",
            "base_commit": request["base_commit"],
            "model_id": request["model_id"],
            "profile_id": request["profile_id"],
            "instruction_sha256": hashlib.sha256(
                request["instruction"].encode()).hexdigest(),
            "allowed_test_profile": "fixture-echo",
            "maximum_files_changed": "8",
            "maximum_patch_bytes": "65536",
            "maximum_job_seconds":
                "3" if request["profile_id"] == "code-short" else "120",
            "conversation_generation": "1",
            "expiry_epoch": str(time.time() + 300),
            "nonce": os.urandom(8).hex(),
        }
        claim.update(overrides)
        message = "\n".join("%s=%s" % (field, claim[field])
                            for field in GRANT_FIELDS)
        signature = hmac.new(b"test-grant-key", message.encode(),
                             hashlib.sha256).hexdigest()
        return {"claim": claim, "signature": signature}

    def open_job(self, behavior, profile_id="code-test", **grant_overrides):
        request = {
            "action": "open_job",
            "workspace_id": "test-repo",
            "profile_id": profile_id,
            "model_id": "qwenseer-2b",
            "base_commit": self.behaviors[behavior],
            "instruction": "perform the %s behavior" % behavior,
        }
        request["grant"] = self.grant(request, **grant_overrides)
        return self.request(request)

    def stop(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()


def main():
    root = pathlib.Path(tempfile.mkdtemp(prefix="coding-agent-test."))
    harness = Harness(root)
    try:
        run_suite(harness)
    finally:
        harness.stop()
        shutil.rmtree(root, ignore_errors=True)
    if failures:
        print("coding_agent_service=rejected failed=%d of=%d"
              % (len(failures), checks), file=sys.stderr)
        return 1
    print("coding_agent_service=accepted checks=%d" % checks)
    return 0


def run_suite(harness):
    # Happy chain: open, inspect, plan, apply, tests, review, finish.
    opened = harness.open_job("edit")
    check("open_job_accepted", opened.get("ok"), json.dumps(opened))
    job_id = opened["result"]["job_id"]
    worktree = pathlib.Path(opened["result"]["worktree"])
    check("worktree_created", worktree.is_dir())
    check("worktree_under_principal_home",
          str(worktree).startswith(str(harness.principal_home)))

    listing = harness.request({"action": "inspect", "job_id": job_id,
                               "path": "."})
    check("inspect_lists_worktree", listing.get("ok")
          and "README" in listing["result"]["entries"], json.dumps(listing))

    plan = harness.request({"action": "plan", "job_id": job_id})
    check("plan_runs_agent", plan.get("ok")
          and "plan:" in plan["result"]["plan"], json.dumps(plan))

    applied = harness.request({"action": "apply_patch", "job_id": job_id})
    check("apply_patch_within_bounds", applied.get("ok")
          and "hello.txt" in applied["result"]["changed_files"],
          json.dumps(applied))

    tests = harness.request({"action": "run_tests", "job_id": job_id})
    check("run_tests_allowed_profile", tests.get("ok")
          and "test-profile-ran" in tests["result"]["log"],
          json.dumps(tests))

    review = harness.request({"action": "review_diff", "job_id": job_id})
    check("review_diff_carries_patch", review.get("ok")
          and "+hello from the fixture agent" in review["result"]["patch"],
          json.dumps(review)[:200])

    finished = harness.request({"action": "finish", "job_id": job_id})
    check("finish_exports_artifacts", finished.get("ok"))
    export = pathlib.Path(finished["result"]["export"])
    expected = ["patch.diff", "diffstat.txt", "changed-files.txt",
                "test.log", "events.jsonl", "base-commit", "result-tree"]
    check("export_complete",
          all((export / name).is_file() for name in expected))
    check("worktree_removed_after_finish", not worktree.exists())
    check("authoritative_repo_untouched",
          git(harness.repo, "status", "--porcelain") == "")
    late = harness.request({"action": "apply_patch", "job_id": job_id})
    check("finished_job_refuses_actions",
          not late.get("ok") and late["error"] == "job_not_open")

    # Grant negatives: tamper, replay, expiry, binding changes.
    refused = harness.open_job("edit", profile_id="code-refused")
    check("refused_profile_rejected", not refused.get("ok")
          and refused["error"] == "execution_refused")

    tampered = harness.open_job("edit", model_id="qwen25-coder-7b")
    check("grant_model_change_rejected", not tampered.get("ok")
          and tampered["error"] == "grant_binding_mismatch")

    wrong_base = harness.open_job("edit",
                                  base_commit=harness.behaviors["push"])
    check("grant_base_commit_change_rejected", not wrong_base.get("ok")
          and wrong_base["error"] == "grant_binding_mismatch")

    wrong_ws = harness.open_job("edit", workspace_id="other-repo")
    check("grant_workspace_change_rejected", not wrong_ws.get("ok"),
          json.dumps(wrong_ws))

    expired = harness.open_job("edit",
                               expiry_epoch=str(time.time() - 10))
    check("grant_expiry_rejected", not expired.get("ok")
          and expired["error"] == "grant_expired")

    request = {
        "action": "open_job", "workspace_id": "test-repo",
        "profile_id": "code-test", "model_id": "qwenseer-2b",
        "base_commit": harness.behaviors["edit"],
        "instruction": "perform the edit behavior",
    }
    grant = harness.grant(request)
    request["grant"] = grant
    first = harness.request(request)
    replay = harness.request(request)
    check("grant_replay_rejected", first.get("ok") and not replay.get("ok")
          and replay["error"] == "grant_replayed")
    harness.request({"action": "cancel",
                     "job_id": first["result"]["job_id"]})

    unsigned = dict(request)
    unsigned["instruction"] = "perform a different instruction"
    changed = harness.request(unsigned)
    check("grant_instruction_change_rejected", not changed.get("ok")
          and changed["error"] in ("grant_binding_mismatch",
                                   "grant_replayed"))

    # Path containment: traversal, absolute, and symlink escape.
    opened = harness.open_job("symlink")
    job_id = opened["result"]["job_id"]
    harness.request({"action": "apply_patch", "job_id": job_id})
    traversal = harness.request({"action": "inspect", "job_id": job_id,
                                 "path": "../../../etc/passwd"})
    check("traversal_refused", not traversal.get("ok")
          and traversal["error"] == "traversal_refused")
    absolute = harness.request({"action": "inspect", "job_id": job_id,
                                "path": "/etc/passwd"})
    check("absolute_path_refused", not absolute.get("ok")
          and absolute["error"] == "absolute_path_refused")
    escape = harness.request({"action": "inspect", "job_id": job_id,
                              "path": "escape-link"})
    check("symlink_escape_refused", not escape.get("ok")
          and escape["error"] == "path_escapes_worktree",
          json.dumps(escape))
    harness.request({"action": "cancel", "job_id": job_id})

    # Bound enforcement: file count and patch bytes reset the worktree.
    opened = harness.open_job("many-files")
    job_id = opened["result"]["job_id"]
    over_files = harness.request({"action": "apply_patch",
                                  "job_id": job_id})
    check("files_over_bound_refused", not over_files.get("ok")
          and over_files["error"] == "files_changed_over_bound")
    review = harness.request({"action": "review_diff", "job_id": job_id})
    check("over_bound_worktree_reset", review.get("ok")
          and review["result"]["patch"] == "", json.dumps(review)[:200])
    harness.request({"action": "cancel", "job_id": job_id})

    opened = harness.open_job("big-patch")
    job_id = opened["result"]["job_id"]
    over_bytes = harness.request({"action": "apply_patch",
                                  "job_id": job_id})
    check("patch_bytes_over_bound_refused", not over_bytes.get("ok")
          and over_bytes["error"] == "patch_bytes_over_bound")
    harness.request({"action": "cancel", "job_id": job_id})

    # Deadline: a SIGTERM-trapping agent dies on the SIGKILL escalation.
    opened = harness.open_job("sleep-trap", profile_id="code-short")
    job_id = opened["result"]["job_id"]
    started = time.time()
    timed = harness.request({"action": "plan", "job_id": job_id})
    elapsed = time.time() - started
    check("deadline_kills_term_resistant_child", not timed.get("ok")
          and timed["error"] in ("job_timed_out", "job_deadline_passed")
          and elapsed < 30, "%s in %.1fs" % (json.dumps(timed), elapsed))
    harness.request({"action": "cancel", "job_id": job_id})

    # Cancellation during execution kills the group; late results refused.
    opened = harness.open_job("sleep-trap")
    job_id = opened["result"]["job_id"]
    result_box = {}

    def run_plan():
        result_box["plan"] = harness.request({"action": "plan",
                                              "job_id": job_id})

    thread = threading.Thread(target=run_plan)
    thread.start()
    time.sleep(1.0)
    cancelled = harness.request({"action": "cancel", "job_id": job_id})
    thread.join(timeout=20)
    check("cancel_during_execution", cancelled.get("ok")
          and not thread.is_alive(), json.dumps(cancelled))
    late = harness.request({"action": "review_diff", "job_id": job_id})
    check("late_result_after_cancel_refused", not late.get("ok"))

    # git push from inside the worktree has no destination and no
    # credentials, and the authoritative repository stays clean.
    opened = harness.open_job("push")
    job_id = opened["result"]["job_id"]
    harness.request({"action": "apply_patch", "job_id": job_id})
    pushed = harness.request({"action": "inspect", "job_id": job_id,
                              "path": "push.txt"})
    check("git_push_refused_no_destination", pushed.get("ok")
          and "push refused" in pushed["result"]["content"],
          json.dumps(pushed)[:200])
    check("authoritative_repo_still_clean",
          git(harness.repo, "status", "--porcelain") == "")
    harness.request({"action": "cancel", "job_id": job_id})

    # The agent's HOME is the worktree, so user credentials are outside
    # its resolution path even before uid separation.
    opened = harness.open_job("home-probe")
    job_id = opened["result"]["job_id"]
    harness.request({"action": "apply_patch", "job_id": job_id})
    home = harness.request({"action": "inspect", "job_id": job_id,
                            "path": "home.txt"})
    check("agent_home_is_worktree", home.get("ok")
          and home["result"]["content"].strip()
          == str(pathlib.Path(opened["result"]["worktree"])),
          json.dumps(home)[:200])
    ssh = harness.request({"action": "inspect", "job_id": job_id,
                           "path": "ssh.txt"})
    check("no_ssh_state_reachable", ssh.get("ok")
          and "no ssh state" in ssh["result"]["content"])
    harness.request({"action": "cancel", "job_id": job_id})

    # Residue: after every job above ends, the worktree root is empty.
    time.sleep(0.5)
    leftover = list((harness.principal_home / "worktrees").iterdir())
    check("no_worktree_residue", leftover == [], str(leftover))
    bundles = (list(harness.bundle_dir.iterdir())
               if harness.bundle_dir.exists() else [])
    check("no_bundle_residue", bundles == [], str(bundles))

    not_run("uid_separation", "requires the qwen-coder principal path")
    not_run("sudo_denied_for_principal",
            "requires the qwen-coder principal path")
    not_run("external_network_refused",
            "requires the uid-scoped egress rule on the appliance")


if __name__ == "__main__":
    sys.exit(main())
