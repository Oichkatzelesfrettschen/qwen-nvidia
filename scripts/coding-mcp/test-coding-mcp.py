#!/usr/bin/env python3
"""Drive the coding MCP child over stdio against a live coding-agent
service: the listing states the configured profile's bounds, the six tools
run one full worktree-edit-test-diff-finish chain, and the refusals reach
the model as isError results rather than transport failures."""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

MCP_DIRECTORY = pathlib.Path(__file__).parent.resolve()
SCRIPTS = MCP_DIRECTORY.parent
sys.path.insert(0, str(SCRIPTS))

harness_module = __import__("test-coding-agent-service")

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


class McpChild:
    def __init__(self, environment):
        self.process = subprocess.Popen(
            [sys.executable, str(MCP_DIRECTORY / "server.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
            env=environment)
        self.identifier = 0

    def request(self, method, params=None):
        self.identifier += 1
        message = {"jsonrpc": "2.0", "id": self.identifier,
                   "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())

    def call(self, name, arguments):
        return self.request("tools/call",
                            {"name": name, "arguments": arguments})

    def stop(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)


def result_text(reply):
    return reply["result"]["content"][0]["text"]


def is_error(reply):
    return reply.get("result", {}).get("isError") is True


def main():
    import os
    root = pathlib.Path(tempfile.mkdtemp(prefix="coding-mcp-test."))
    harness = harness_module.Harness(root)
    environment = dict(os.environ)
    environment.update({
        "QWEN_CODING_SERVICE_SOCKET": str(harness.socket_path),
        "QWEN_CODING_PROFILE": "code-test",
        "QWEN_CODING_PROFILES_TSV": str(harness.profiles),
    })
    child = McpChild(environment)
    try:
        run_suite(harness, child)
    finally:
        child.stop()
        harness.stop()
        shutil.rmtree(root, ignore_errors=True)
    if failures:
        print("coding_mcp=rejected failed=%d of=%d"
              % (len(failures), checks), file=sys.stderr)
        return 1
    print("coding_mcp=accepted checks=%d" % checks)
    return 0


def run_suite(harness, child):
    initialized = child.request("initialize", {"protocolVersion": "x"})
    check("initialize", initialized["result"]["serverInfo"]["name"]
          == "code")

    listing = child.request("tools/list")
    tools = {t["name"]: t for t in listing["result"]["tools"]}
    check("six_tools_listed", sorted(tools) == [
        "code_apply_patch", "code_finish", "code_inspect", "code_plan",
        "code_review_diff", "code_run_tests"], sorted(tools))
    check("listing_states_profile_bounds",
          "at most 8 changed files, 65536 patch bytes"
          in tools["code_plan"]["description"],
          tools["code_plan"]["description"])
    check("plan_schema_pins_model",
          tools["code_plan"]["inputSchema"]["properties"]["model_id"]
          ["enum"] == ["qwenseer-2b"])

    request = {
        "instruction": "perform the edit behavior",
        "workspace_id": "test-repo",
        "profile_id": "code-test",
        "model_id": "qwenseer-2b",
        "base_commit": harness.behaviors["edit"],
    }
    grant = harness.grant({"action": "open_job",
                           "workspace_id": request["workspace_id"],
                           "profile_id": request["profile_id"],
                           "model_id": request["model_id"],
                           "base_commit": request["base_commit"],
                           "instruction": request["instruction"]})
    planned = child.call("code_plan", dict(request, authorization=grant))
    check("code_plan_opens_and_plans", not is_error(planned),
          json.dumps(planned)[:200])
    payload = json.loads(result_text(planned))
    job_id = payload["job_id"]
    check("plan_text_returned", "plan:" in payload["plan"])

    inspected = child.call("code_inspect",
                           {"job_id": job_id, "path": "README"})
    check("code_inspect_reads_file", not is_error(inspected)
          and "base for edit" in json.loads(
              result_text(inspected))["content"])

    applied = child.call("code_apply_patch", {"job_id": job_id})
    check("code_apply_patch", not is_error(applied)
          and "hello.txt" in json.loads(
              result_text(applied))["changed_files"])

    tested = child.call("code_run_tests", {"job_id": job_id})
    check("code_run_tests", not is_error(tested)
          and "test-profile-ran" in json.loads(result_text(tested))["log"])

    reviewed = child.call("code_review_diff", {"job_id": job_id})
    check("code_review_diff", not is_error(reviewed)
          and "+hello from the fixture agent"
          in json.loads(result_text(reviewed))["patch"])

    finished = child.call("code_finish", {"job_id": job_id})
    check("code_finish_exports", not is_error(finished)
          and json.loads(result_text(finished))["result_tree"])

    unknown_tool = child.call("code_shell", {"job_id": job_id})
    check("generic_shell_tool_absent",
          "error" in unknown_tool
          and "unknown tool" in unknown_tool["error"]["message"])

    unknown_argument = child.call("code_review_diff",
                                  {"job_id": job_id, "command": "ls"})
    check("unknown_argument_refused", is_error(unknown_argument)
          and "does not read" in result_text(unknown_argument))

    ungrunted = child.call("code_plan", dict(request,
                                             authorization={"claim": {}}))
    check("ungranted_open_refused", is_error(ungrunted)
          and "refused" in result_text(ungrunted))

    missing = child.call("code_apply_patch", {})
    check("missing_job_id_refused", is_error(missing))


if __name__ == "__main__":
    sys.exit(main())
