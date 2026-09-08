#!/usr/bin/env python3
"""Drive the compiled router caller with subprocess-only model children."""

import concurrent.futures
import importlib.util
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

TEST_FIXTURES = pathlib.Path(__file__).resolve().parent / "test-fixtures"
attribution_spec = importlib.util.spec_from_file_location(
    "router_attribution_continuity", TEST_FIXTURES / "router_attribution_continuity.py"
)
assert attribution_spec is not None and attribution_spec.loader is not None
attribution_module = importlib.util.module_from_spec(attribution_spec)
attribution_spec.loader.exec_module(attribution_module)
exercise_attribution = attribution_module.exercise


ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_BINARY = pathlib.Path(os.environ["QWEN_ROUTER_FIXTURE_SERVER"])


def request(port, model, marker, delay=0):
    req = urllib.request.Request(
        "http://127.0.0.1:%d/completion" % port,
        data=json.dumps({"model": model}).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Approval-Id": "approval-" + marker,
            "X-Artifact-Id": "artifact-" + marker,
            "X-Tool-Result-Id": "tool-" + marker,
            "X-Fixture-Delay": str(delay),
        },
    )
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.load(response)


def main():
    mode = os.environ.get("QWEN_ROUTER_CALLER_MODE", "control")
    local_temporary_root = ROOT / ".local-artifacts" / "test-tmp"
    local_temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=local_temporary_root) as temporary:
        work = pathlib.Path(temporary)
        state = work / "state"
        executable = work / "llama-server"
        preset = work / "preset.ini"
        preset.write_text("[old-model]\nmodel=/fixture/old.gguf\nalias=old-model\n"
                          "[new-model]\nmodel=/fixture/new.gguf\nalias=new-model\n")
        shutil.copy2(SOURCE_BINARY, executable)
        environment = dict(os.environ, QWEN_GPU_ADMISSION_BARRIER=str(state))
        subprocess.run([str(ROOT / "scripts/qwen-drain-controller.sh"), "status"],
                       env=environment, stdout=subprocess.DEVNULL, check=True)
        environment["QWEN_GPU_ADMISSION_IDENTITY"] = (state / "admission.identity").read_text().strip()
        environment["QWEN_ROUTER_RETIRE_COMMAND"] = str(ROOT / "scripts/qwen-router-orderly-retire.py")
        if mode == "partial-output":
            environment["QWEN_ROUTER_RETIRE_COMMAND"] = str(
                ROOT / "scripts/test-fixtures/partial-router-retirement.py"
            )
            environment["QWEN_ROUTER_RETIREMENT_TIMEOUT_MS"] = "300"
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        events = work / "child-events.tsv"
        environment["QWEN_FAKE_CHILD_EVENTS"] = str(events)
        if mode == "missing-proof":
            environment["QWEN_FAKE_TEARDOWN_PROOF"] = "absent"
        router_log = work / "router.log"
        log_stream = router_log.open("w+")
        process = subprocess.Popen(
            [str(executable), "--host", "127.0.0.1", "--port", str(port),
             "--models-preset", str(preset), "--models-max", "1", "--offline", "--no-webui"],
            env=environment, text=True, stdout=log_stream, stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    urllib.request.urlopen("http://127.0.0.1:%d/health" % port, timeout=.2).close()
                    break
                except Exception:
                    time.sleep(.05)
            else:
                raise AssertionError("router listener did not become ready")
            replacement = executable.with_suffix(".new")
            shutil.copy2(ROOT / "scripts/test-fixtures/fake-router-child.py", replacement)
            replacement.chmod(0o755)
            replacement.replace(executable)

            if mode == "attribution":
                attribution_result = exercise_attribution(port, events)
                urllib.request.urlopen(
                    "http://127.0.0.1:%d/health" % port, timeout=2
                ).close()
                old_reply = new_reply = None
                old_done = new_done = 0
            else:
                attribution_result = None
            if mode != "attribution":
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    old = pool.submit(request, port, "old-model", "approval-old", .5)
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        if events.exists() and "old-model\trequest_start" in events.read_text():
                            break
                        time.sleep(.02)
                    else:
                        raise AssertionError("old request never reached the child")
                    holder = None
                    holder_marker = work / "holder-started"
                    if mode == "holder":
                        holder = subprocess.Popen([
                            str(ROOT / "scripts/qwen-drain-controller.sh"), "admit", "--",
                            "sh", "-c", "touch \"$1\"; sleep 2", "holder", str(holder_marker),
                        ], env=environment, stdout=subprocess.DEVNULL)
                        deadline = time.monotonic() + 2
                        while time.monotonic() < deadline and not holder_marker.exists():
                            time.sleep(.01)
                        assert holder_marker.exists(), "sidecar holder did not acquire admission"
                    new = pool.submit(request, port, "new-model", "artifact-new")
                    old_reply = old.result(timeout=15)
                    old_done = time.monotonic()
                    if mode in ("missing-proof", "partial-output"):
                        try:
                            new.result(timeout=15)
                        except Exception:
                            new_reply = None
                        else:
                            raise AssertionError("missing teardown proof admitted replacement")
                    else:
                        new_reply = new.result(timeout=15)
                    new_done = time.monotonic()
                    if holder is not None:
                        assert holder.poll() is not None, "replacement started before sidecar holder drained"
                        holder.wait(timeout=3)
                assert {key: old_reply[key] for key in ("model", "approval", "artifact", "tool_result")} == {
                    "model": "old-model", "approval": "approval-approval-old",
                    "artifact": "artifact-approval-old", "tool_result": "tool-approval-old"}
                if mode not in ("missing-proof", "partial-output"):
                    assert {key: new_reply[key] for key in ("model", "approval", "artifact", "tool_result")} == {
                        "model": "new-model", "approval": "approval-artifact-new",
                        "artifact": "artifact-artifact-new", "tool_result": "tool-artifact-new"}
                assert old_done <= new_done
                urllib.request.urlopen("http://127.0.0.1:%d/health" % port, timeout=2).close()
        finally:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=20)
            log_stream.flush()
            log_stream.close()
            output = router_log.read_text()
        required = [
            "router_child_generation model=old-model",
            "router_child_retirement model=old-model",
            "teardown_exclusion=orderly",
        ]
        if mode in ("missing-proof", "partial-output"):
            assert "router_child_generation model=new-model" not in output
            if mode == "partial-output":
                assert "orderly retirement command reached its deadline" in output
                print("router_retirement_caller=accepted partial_output_bounded=yes listener_survived=yes")
            else:
                print("router_retirement_caller=accepted missing_proof_latched=yes listener_survived=yes")
            return
        required.append("router_child_generation model=new-model")
        event_rows = [line.split("\t") for line in events.read_text().splitlines()]
        event_order = {(model, name): int(stamp) for stamp, model, name in event_rows}
        assert (
            event_order[("old-model", "request_terminal")]
            < event_order[("old-model", "generation_exit")]
        ), "retiring child exited before its accepted request reached a terminal state"
        assert (
            event_order[("old-model", "generation_exit")]
            < event_order[("new-model", "generation_ready")]
        ), "replacement generation started before retiring child exited"
        for value in required:
            assert value in output, value
        positions = [output.index(value) for value in required]
        assert positions == sorted(positions), positions
        attribution = attribution_result or "attribution=separate_mode"
        print("router_retirement_caller=accepted mode=%s active_request_wait=yes listener_survived=yes %s" %
              (mode, attribution))


if __name__ == "__main__":
    main()
