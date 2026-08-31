#!/usr/bin/env python3
"""Replay every request the page makes across one coding chain, with each
refusal the design relies on provoked once.

The driver speaks to the router port and the broker origin alone, the way
the browser does: the tool listing, the workspace resolution, the plan
grant and the plan, the apply grant over the reviewed plan hash and the
apply, the tests, the diff review, and the finish, then the negatives -- a
replayed plan grant, an apply without a grant, an apply grant over a
foreign plan hash, a replayed apply grant, a foreign job id, and a late
result after cancellation. The exported patch is verified independently:
it must apply cleanly to the base commit and reproduce the reported result
tree in a temporary index against the authoritative repository. Each check
prints one `name<TAB>accepted|refused<TAB>detail` line for the harness
summary."""

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

CODE_TOOL_NAMES = [
    "code_plan", "code_inspect", "code_apply_patch", "code_run_tests",
    "code_review_diff", "code_finish", "code_cancel", "code_workspace",
]

failures = 0


def check(name, ok, detail=""):
    global failures
    if not ok:
        failures += 1
    print("%s\t%s\t%s" % (name, "accepted" if ok else "refused",
                          str(detail).replace("\t", " ").replace("\n", "; ")))


class Chain:
    def __init__(self, arguments):
        self.router = arguments.router
        self.broker = arguments.broker
        self.model = arguments.model
        self.repo = arguments.workspace_repo
        self.out = pathlib.Path(arguments.out)
        self.api_key = pathlib.Path(
            arguments.api_key_file).read_text().splitlines()[0].strip()
        self.session_secret = None

    def http(self, url, body=None, headers=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data)
        request.add_header("Authorization", "Bearer " + self.api_key)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=900) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.loads(error.read())
            except ValueError:
                return error.code, {}

    def tool(self, name, params):
        """One POST /tools; returns (parsed result or None, refusal text)."""
        status, payload = self.http(self.router + "/tools", {
            "model": self.model, "tool": name, "params": params,
            "stream": False})
        if isinstance(payload, dict) and isinstance(
                payload.get("error"), str):
            return None, payload["error"]
        text = (payload or {}).get("plain_text_response")
        if status != 200 or not isinstance(text, str):
            return None, "HTTP %s with no result text" % status
        try:
            return json.loads(text), ""
        except ValueError:
            return {"text": text}, ""

    def grant(self, path, fields):
        if self.session_secret is None:
            status, payload = self.http(
                self.broker + "/session", headers={"Origin": self.router})
            if status != 200:
                raise RuntimeError("broker session refused: %s" % payload)
            self.session_secret = payload["session_secret"]
        status, payload = self.http(
            self.broker + path, fields,
            headers={"Origin": self.router,
                     "X-Qwen-Web-Session": self.session_secret})
        if status != 200:
            return None, str(payload.get("error", status))
        return payload["authorization"], ""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--router", required=True)
    parser.add_argument("--broker", required=True)
    parser.add_argument("--api-key-file", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--workspace-repo", required=True)
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()
    chain = Chain(arguments)

    status, listing = chain.http(
        "%s/tools?model=%s&autoload=true" % (chain.router, chain.model))
    listed = {entry.get("tool") for entry in listing} \
        if isinstance(listing, list) else set()
    check("coding_tools_listed", set(CODE_TOOL_NAMES) <= listed,
          ",".join(sorted(listed)))

    workspace, refusal = chain.tool("code_workspace", {})
    head = subprocess.run(["git", "-C", chain.repo, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    check("coding_workspace_resolves_head",
          workspace is not None and workspace.get("base_commit") == head,
          refusal or json.dumps(workspace)[:160])
    if workspace is None:
        return 1

    instruction = ("set VALUE to 42 in declared-value.txt and update "
                   "check-value.sh")
    instruction_sha256 = hashlib.sha256(instruction.encode()).hexdigest()
    plan_fields = {
        "workspace_id": workspace["workspace_id"],
        "repository_identity": workspace["repository_identity"],
        "base_commit": workspace["base_commit"],
        "model_id": workspace["model_id"],
        "profile_id": workspace["profile_id"],
        "instruction_sha256": instruction_sha256,
        "allowed_test_profile": workspace["allowed_test_profile"],
        "maximum_files_changed": workspace["maximum_files_changed"],
        "maximum_patch_bytes": workspace["maximum_patch_bytes"],
        "maximum_job_seconds": workspace["maximum_job_seconds"],
        "conversation_generation": "0",
    }
    plan_grant, refusal = chain.grant("/grant-code-plan", plan_fields)
    check("coding_plan_granted", plan_grant is not None, refusal)
    if plan_grant is None:
        return 1
    plan_params = {
        "instruction": instruction,
        "workspace_id": workspace["workspace_id"],
        "repository_identity": workspace["repository_identity"],
        "profile_id": workspace["profile_id"],
        "model_id": workspace["model_id"],
        "base_commit": workspace["base_commit"],
        "conversation_generation": "0",
        "authorization": plan_grant,
    }
    planned, refusal = chain.tool("code_plan", plan_params)
    check("coding_plan_opened", planned is not None
          and planned.get("job_id") and len(
              str(planned.get("plan_sha256", ""))) == 64,
          refusal or json.dumps(planned)[:160])
    if planned is None:
        return 1
    job_id = planned["job_id"]
    plan_sha256 = planned["plan_sha256"]
    (chain.out / "plan.json").write_text(json.dumps(planned, indent=1))

    _, refusal = chain.tool("code_plan", plan_params)
    check("coding_plan_grant_replay_refused", "grant_replayed" in refusal,
          refusal)

    inspected, refusal = chain.tool(
        "code_inspect", {"job_id": job_id, "path": "declared-value.txt"})
    check("coding_inspect_reads_file", inspected is not None
          and "VALUE=41" in inspected.get("content", ""), refusal)

    _, refusal = chain.tool("code_apply_patch", {"job_id": job_id})
    check("coding_apply_without_grant_refused", "grant_missing" in refusal,
          refusal)

    apply_fields = {
        "job_id": job_id,
        "plan_sha256": plan_sha256,
        "instruction_sha256": instruction_sha256,
        "model_id": workspace["model_id"],
        "profile_id": workspace["profile_id"],
        "conversation_generation": "0",
    }
    foreign_grant, _ = chain.grant(
        "/grant-code-apply", dict(apply_fields, plan_sha256="0" * 64))
    _, refusal = chain.tool("code_apply_patch", {
        "job_id": job_id, "authorization": foreign_grant})
    check("coding_apply_foreign_plan_hash_refused",
          "grant_binding_mismatch" in refusal, refusal)

    apply_grant, refusal = chain.grant("/grant-code-apply", apply_fields)
    check("coding_apply_granted", apply_grant is not None, refusal)
    applied, refusal = chain.tool("code_apply_patch", {
        "job_id": job_id, "authorization": apply_grant})
    changed = (applied or {}).get("changed_files") or []
    check("coding_apply_admitted",
          applied is not None and "declared-value.txt" in changed
          and "check-value.sh" in changed,
          refusal or json.dumps(applied)[:160])

    _, refusal = chain.tool("code_apply_patch", {
        "job_id": job_id, "authorization": apply_grant})
    check("coding_apply_grant_replay_refused", "grant_replayed" in refusal,
          refusal)

    tested, refusal = chain.tool("code_run_tests", {"job_id": job_id})
    check("coding_tests_pass_on_edited_worktree", tested is not None
          and tested.get("returncode") == 0
          and "declared-value-check=pass value=42" in tested.get("log", ""),
          refusal or json.dumps(tested)[:160])

    reviewed, refusal = chain.tool("code_review_diff", {"job_id": job_id})
    patch = (reviewed or {}).get("patch", "")
    check("coding_review_diff_carries_edit",
          "-VALUE=41" in patch and "+VALUE=42" in patch, refusal)
    (chain.out / "patch.diff").write_text(patch)

    _, refusal = chain.tool("code_inspect",
                            {"job_id": "job-0-deadbeef", "path": "."})
    check("coding_foreign_job_refused", "unknown_job" in refusal, refusal)

    finished, refusal = chain.tool("code_finish", {"job_id": job_id})
    check("coding_finish_exports_identity", finished is not None
          and finished.get("export_id") == job_id
          and len(str(finished.get("result_tree", ""))) == 40
          and finished.get("patch_sha256")
          == hashlib.sha256(patch.encode()).hexdigest(),
          refusal or json.dumps(finished)[:200])
    if finished is None:
        return 1
    (chain.out / "finish.json").write_text(json.dumps(finished, indent=1))

    # Independent reproduction: the exported patch applies cleanly to the
    # base commit and produces the reported result tree in a temporary
    # index against the authoritative repository.
    with tempfile.TemporaryDirectory(prefix="coding-admission-tree.") as td:
        environment = dict(os.environ,
                           GIT_INDEX_FILE=os.path.join(td, "index"))
        patch_path = os.path.join(td, "patch.diff")
        pathlib.Path(patch_path).write_text(patch)
        clean = subprocess.run(
            ["git", "-C", chain.repo, "apply", "--check", patch_path],
            capture_output=True, text=True)
        check("coding_patch_applies_cleanly_to_base", clean.returncode == 0,
              clean.stderr.strip())
        subprocess.run(["git", "-C", chain.repo, "read-tree",
                        head + "^{tree}"], capture_output=True,
                       env=environment)
        subprocess.run(["git", "-C", chain.repo, "apply", "--cached",
                        patch_path], capture_output=True, env=environment)
        reproduced = subprocess.run(
            ["git", "-C", chain.repo, "write-tree"], capture_output=True,
            text=True, env=environment).stdout.strip()
    check("coding_result_tree_reproduced",
          reproduced == finished["result_tree"],
          "%s vs %s" % (reproduced, finished["result_tree"]))

    _, refusal = chain.tool("code_review_diff", {"job_id": job_id})
    check("coding_finished_job_refuses_late_actions",
          "job_not_open" in refusal, refusal)

    # A second job stands in for Clear-during-execution: the cancellation
    # kills and removes it, and a late result is refused rather than
    # appended.
    plan_fields_second = dict(plan_fields, conversation_generation="1")
    second_grant, _ = chain.grant("/grant-code-plan", plan_fields_second)
    second, refusal = chain.tool("code_plan", dict(
        plan_params, conversation_generation="1",
        authorization=second_grant))
    check("coding_second_job_opened", second is not None, refusal)
    if second is not None:
        cancelled, refusal = chain.tool(
            "code_cancel", {"job_id": second["job_id"]})
        check("coding_cancel_admitted", cancelled is not None
              and cancelled.get("state") == "cancelled", refusal)
        _, refusal = chain.tool("code_review_diff",
                                {"job_id": second["job_id"]})
        check("coding_late_result_after_cancel_refused",
              "job_not_open" in refusal, refusal)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
