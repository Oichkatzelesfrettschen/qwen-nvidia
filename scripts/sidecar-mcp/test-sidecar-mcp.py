#!/usr/bin/env python3
"""Hold sidecar-mcp/server.py to its boundary against the real physics service.

The physics service runs on the fake PhysX runtime under a signing key, the
child is spawned the way llama-server spawns it and driven over newline
JSON-RPC, and every grant is issued by sidecar_grant the way the broker
issues it. The arms: the listing names one tool bounded by the ledger row;
a call under a matching grant completes with the GPU proof and a result
digest and spends the grant; the same grant replayed meets the ledger; a
geometry grant, a grant for another count, and a grant for another runtime
each refuse at the child ahead of the service; an argument outside the
schema refuses by name; a call against an absent socket reports the service
unavailable without spending the grant; and the geometry lane lists its own
tool from its own ledger.
"""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS / "web-mcp"))
sys.path.insert(0, str(SCRIPTS))
import sidecar_grant  # noqa: E402

CHILD = SCRIPTS / "sidecar-mcp" / "server.py"
PHYSICS_SERVICE = SCRIPTS / "physics-service.py"
FAKE_PHYSX = SCRIPTS / "test-fixtures" / "fake-physx-runtime.sh"
PHYSICS_LEDGER = (
    "# profile_id\tscene\ttimestep_s\tmax_steps\tgravity_y\tgpu_dynamics\tgpu_broadphase\ttimeout_s\texecution_policy\tdevice_index\n"
    "physics-d6-test\td6-chain-4\t0.0166667\t600\t9.81\tyes\tyes\t5\tvalidator-gated\t0\n"
)
GEOMETRY_LEDGER = (
    "# profile_id\tscene\tquery_set\tmax_rays\ttimeout_s\texecution_policy\tdevice_index\n"
    "geometry-cube-test\tcube-and-plane\torbit\t4096\t3\tvalidator-gated\t0\n"
)


class ChildSession:
    def __init__(self, environment):
        self.process = subprocess.Popen([sys.executable, str(CHILD)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=environment, text=True)
        self.identifier = 0

    def request(self, method, params=None):
        self.identifier += 1
        message = {"jsonrpc": "2.0", "id": self.identifier, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        return json.loads(self.process.stdout.readline())

    def call(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        try:
            self.process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.communicate()


def tool_text(reply):
    result = reply.get("result") or {}
    content = result.get("content") or [{}]
    return content[0].get("text", ""), bool(result.get("isError"))


def main():
    failures = []

    def check(condition, description):
        print(("ok " if condition else "FAIL ") + description)
        if not condition:
            failures.append(description)

    with tempfile.TemporaryDirectory() as directory:
        state = pathlib.Path(directory)
        (state / "physics").mkdir()
        (state / "physics" / "profiles.tsv").write_text(PHYSICS_LEDGER)
        (state / "geometry").mkdir()
        (state / "geometry" / "profiles.tsv").write_text(GEOMETRY_LEDGER)
        key_path = state / "token.key"
        key_path.write_text("k" * 48 + "\n")
        key_path.chmod(0o600)
        runtime_directory = state / "runtime"
        runtime_directory.mkdir()
        runtime = runtime_directory / "fake-physx-runtime.sh"
        runtime.write_bytes(FAKE_PHYSX.read_bytes())
        runtime.chmod(0o755)
        (runtime_directory / "fake-mode").write_text("ok\n")
        socket_path = state / "physics" / "physics-service.sock"
        service = subprocess.Popen(
            [sys.executable, str(PHYSICS_SERVICE), "--state-dir", str(state / "physics"),
             "--profiles", str(state / "physics" / "profiles.tsv"), "--runtime", str(runtime), "--lease-wait-s", "0.5"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "QWEN_GPU_COMPUTE_LEASE": str(state / "vulkan-workload.lock"),
                 "QWEN_SIDECAR_TOKEN_KEY_FILE": str(key_path), "QWEN_SIDECAR_LANGUAGE_PROFILE": "fast-text"})
        line = service.stdout.readline()
        if not line.startswith("listening"):
            raise SystemExit("service did not announce: %r %s" % (line, service.stderr.read()))
        runtime_sha256 = line.split("runtime_sha256=")[1].split()[0]
        try:
            environment = {**os.environ, "QWEN_SIDECAR_SERVICE": "physics", "QWEN_SIDECAR_PROFILE": "physics-d6-test",
                           "QWEN_SIDECAR_LANGUAGE_PROFILE": "fast-text", "QWEN_SIDECAR_TOKEN_KEY_FILE": str(key_path),
                           "QWEN_SIDECAR_STATE_DIR": str(state / "mcp-state"), "QWEN_SIDECAR_SERVICE_SOCKET": str(socket_path),
                           "QWEN_SIDECAR_PROFILES": str(state / "physics" / "profiles.tsv"),
                           "QWEN_SIDECAR_RUNTIME_SHA256": runtime_sha256, "QWEN_SIDECAR_MCP_TIMEOUT_S": "20"}

            def issue(**overrides):
                fields = {"context": sidecar_grant.SIDECAR_CLAIM_CONTEXT, "service": "physics",
                          "language_profile": "fast-text", "sidecar_profile": "physics-d6-test",
                          "runtime_sha256": runtime_sha256, "scene": "d6-chain-4", "count": 60,
                          "count_ceiling": 600, "conversation_generation": 1}
                fields.update(overrides)
                return sidecar_grant.issue_sidecar_grant(str(key_path), sidecar_grant.parse_sidecar_request(fields), 300)

            child = ChildSession(environment)
            try:
                listing = child.request("tools/list")
                tools = (listing.get("result") or {}).get("tools") or []
                check(len(tools) == 1 and tools[0]["name"] == "simulate_rigid", "the physics child lists simulate_rigid")
                schema = tools[0]["inputSchema"]["properties"] if tools else {}
                check(schema.get("count", {}).get("maximum") == 600 and schema.get("profile_id", {}).get("enum") == ["physics-d6-test"],
                      "the listing carries the ledger row's ceiling and profile")
                check(schema.get("profile_id", {}).get("x_scene") == "d6-chain-4"
                      and schema.get("profile_id", {}).get("x_runtime_sha256") == runtime_sha256,
                      "the listing carries the scene and runtime digest the grant binds")

                grant = issue()
                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 60, "authorization": grant}))
                summary = json.loads(text) if not is_error else {}
                check(not is_error and summary.get("status") == "completed", "a matching grant completes: " + text[:120])
                check(summary.get("gpu", {}).get("gpu_dynamics_active") is True, "the summary carries the GPU proof")
                check(summary.get("runtime_sha256") == runtime_sha256 and len(summary.get("result_sha256", "")) == 64,
                      "the summary names the runtime and digests the result")
                check(summary.get("steps") == 60 and summary.get("joints", 0) >= 1, "the summary carries the count and the joint count")

                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 60, "authorization": grant}))
                check(is_error and "spent" in text, "the same grant replayed refuses as spent: " + text[:100])

                geometry_grant = issue(service="geometry", sidecar_profile="geometry-cube-test", scene="cube-and-plane", count=60, count_ceiling=4096)
                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 60, "authorization": geometry_grant}))
                check(is_error and "service" in text, "a geometry grant refuses at the physics child: " + text[:100])
                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 61, "authorization": issue()}))
                check(is_error and "arguments differ" in text, "a count differing from the approved one refuses")
                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 60, "authorization": issue(runtime_sha256="cd" * 32)}))
                check(is_error and "runtime" in text, "a grant for another runtime refuses")
                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 60, "authorization": issue(), "seed": 1}))
                check(is_error and "seed" in text, "an argument outside the schema refuses by name")
                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 601, "authorization": issue()}))
                check(is_error and "[1, 600]" in text, "a count over the ledger ceiling refuses before the grant is read")
                reply = child.call("ray_query", {"profile_id": "physics-d6-test", "count": 60, "authorization": issue()})
                check("error" in reply and "unknown tool" in reply["error"]["message"], "the other lane's tool is unknown here")
            finally:
                child.close()

            absent = ChildSession({**environment, "QWEN_SIDECAR_SERVICE_SOCKET": str(state / "absent.sock")})
            try:
                unspent = issue()
                text, is_error = tool_text(absent.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 60, "authorization": unspent}))
                check(is_error and "unreachable" in text, "an absent service reports unavailable")
            finally:
                absent.close()
            child = ChildSession(environment)
            try:
                text, is_error = tool_text(child.call("simulate_rigid", {"profile_id": "physics-d6-test", "count": 60, "authorization": unspent}))
                check(not is_error, "the grant an absent service left unspent still completes")
            finally:
                child.close()

            geometry = ChildSession({**environment, "QWEN_SIDECAR_SERVICE": "geometry", "QWEN_SIDECAR_PROFILE": "geometry-cube-test",
                                     "QWEN_SIDECAR_PROFILES": str(state / "geometry" / "profiles.tsv")})
            try:
                listing = geometry.request("tools/list")
                tools = (listing.get("result") or {}).get("tools") or []
                check(len(tools) == 1 and tools[0]["name"] == "ray_query"
                      and tools[0]["inputSchema"]["properties"]["count"]["maximum"] == 4096,
                      "the geometry child lists ray_query bounded by its ledger")
            finally:
                geometry.close()
        finally:
            service.terminate()
            try:
                service.wait(timeout=10)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait()
        time.sleep(0.2)

    if failures:
        print("sidecar_mcp=rejected failures=%d" % len(failures), file=sys.stderr)
        sys.exit(1)
    print("sidecar_mcp=accepted")


if __name__ == "__main__":
    main()
