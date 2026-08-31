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
    # Bare names compose with the section's `code` key into code_plan and
    # so on at the router; finish and cancel are browser-session controls.
    check("seven_bare_tools_listed", sorted(tools) == [
        "apply_patch", "cancel", "finish", "inspect", "plan",
        "review_diff", "run_tests"], sorted(tools))
    check("listing_states_profile_bounds",
          "at most 8 changed files, 65536 patch bytes"
          in tools["plan"]["description"],
          tools["plan"]["description"])
    check("plan_schema_pins_model",
          tools["plan"]["inputSchema"]["properties"]["model_id"]
          ["enum"] == ["qwenseer-2b"])
    check("plan_schema_requires_browser_fields",
          set(tools["plan"]["inputSchema"]["required"]) >= {
              "repository_identity", "conversation_generation",
              "authorization"})
    check("session_controls_marked",
          tools["finish"]["description"].startswith("Browser-session")
          and tools["cancel"]["description"].startswith("Browser-session"))

    request = {
        "instruction": "perform the edit behavior",
        "workspace_id": "test-repo",
        "repository_identity": "test-repo",
        "profile_id": "code-test",
        "model_id": "qwenseer-2b",
        "base_commit": harness.behaviors["edit"],
        "conversation_generation": "1",
    }
    grant = harness.grant({"action": "open_job",
                           "workspace_id": request["workspace_id"],
                           "profile_id": request["profile_id"],
                           "model_id": request["model_id"],
                           "base_commit": request["base_commit"],
                           "instruction": request["instruction"]})
    planned = child.call("plan", dict(request, authorization=grant))
    check("plan_opens_and_plans", not is_error(planned),
          json.dumps(planned)[:200])
    payload = json.loads(result_text(planned))
    job_id = payload["job_id"]
    check("plan_text_returned", "plan:" in payload["plan"])

    inspected = child.call("inspect",
                           {"job_id": job_id, "path": "README"})
    check("inspect_reads_file", not is_error(inspected)
          and "base for edit" in json.loads(
              result_text(inspected))["content"])

    paged = child.call("inspect",
                       {"job_id": job_id, "path": "README", "offset": 9})
    check("inspect_offset_forwarded", not is_error(paged)
          and json.loads(result_text(paged))["content"] == "edit\n",
          json.dumps(paged)[:200])

    applied = child.call("apply_patch", {"job_id": job_id})
    check("apply_patch", not is_error(applied)
          and "hello.txt" in json.loads(
              result_text(applied))["changed_files"])

    tested = child.call("run_tests", {"job_id": job_id})
    check("run_tests", not is_error(tested)
          and "test-profile-ran" in json.loads(result_text(tested))["log"])

    reviewed = child.call("review_diff", {"job_id": job_id})
    check("review_diff", not is_error(reviewed)
          and "+hello from the fixture agent"
          in json.loads(result_text(reviewed))["patch"])

    finished = child.call("finish", {"job_id": job_id})
    finish_payload = json.loads(result_text(finished))
    check("finish_exports", not is_error(finished)
          and finish_payload["result_tree"]
          and finish_payload["patch_sha256"])
    check("finish_returns_no_absolute_path",
          "export" not in finish_payload
          and finish_payload["export_id"] == job_id)

    second = harness.open_job("edit")
    cancelled = child.call("cancel",
                           {"job_id": second["result"]["job_id"]})
    check("cancel_reaches_service", not is_error(cancelled)
          and json.loads(result_text(cancelled))["state"] == "cancelled",
          json.dumps(cancelled)[:200])

    unknown_tool = child.call("code_shell", {"job_id": job_id})
    check("generic_shell_tool_absent",
          "error" in unknown_tool
          and "unknown tool" in unknown_tool["error"]["message"])

    unknown_argument = child.call("review_diff",
                                  {"job_id": job_id, "command": "ls"})
    check("unknown_argument_refused", is_error(unknown_argument)
          and "does not read" in result_text(unknown_argument))

    ungrunted = child.call("plan", dict(request,
                                        authorization={"claim": {}}))
    check("ungranted_open_refused", is_error(ungrunted)
          and "refused" in result_text(ungrunted))

    missing = child.call("apply_patch", {})
    check("missing_job_id_refused", is_error(missing))


if __name__ == "__main__":
    sys.exit(main())
