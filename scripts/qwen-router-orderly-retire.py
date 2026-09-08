#!/usr/bin/env python3
"""Retire one router child through the session's existing drain controller."""

import json
import os
import pathlib
import sys
import urllib.request


def refuse(reason: str) -> int:
    print("router_retirement=refused reason=%s" % reason, file=sys.stderr)
    return 1


def unload(model: str, port: str) -> int:
    request = urllib.request.Request(
        "http://127.0.0.1:%s/models/unload" % port,
        data=json.dumps({"model": model}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    key_file = os.environ.get("QWEN_ROUTER_RETIRE_API_KEY_FILE", "")
    if key_file:
        api_key = pathlib.Path(key_file).read_text(encoding="utf-8").strip()
        if not api_key:
            return refuse("api_key_file_empty")
        request.add_header("Authorization", "Bearer " + api_key)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.load(response)
    except Exception as error:
        print("router_retirement=failed reason=unload_request detail=%s" % error, file=sys.stderr)
        return 1
    if payload.get("model") != model:
        return refuse("retired_model_mismatch")
    if payload.get("exited") is not True:
        return refuse("child_exit_not_established")
    if not isinstance(payload.get("generation_port"), int) or payload["generation_port"] <= 0:
        return refuse("generation_port_missing")
    if not isinstance(payload.get("pid"), int) or payload["pid"] <= 0:
        return refuse("child_pid_missing")
    if not str(payload.get("start_time", "")).isdigit():
        return refuse("child_start_time_missing")
    exit_status = payload.get("exit_status")
    if isinstance(exit_status, bool) or not isinstance(exit_status, int) or exit_status != 0:
        return refuse("child_exit_status_not_zero")
    exclusion = payload.get("teardown_exclusion", "unattributed")
    print("retired_child model=%s generation_port=%s pid=%s start_time=%s exited=yes exit_status=%s" % (
        model, payload["generation_port"], payload["pid"], payload["start_time"],
        payload.get("exit_status", "unavailable")))
    print("teardown_exclusion=%s" % exclusion)
    if exclusion == "orderly":
        print("teardown: held=yes")
        return 0
    if exclusion == "not_established":
        print("teardown: held=no")
    # The child retirement itself completed.  The drain controller assigns its
    # distinct strict status from the missing or negative teardown reading.
    return 0


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--resume":
        script_directory = pathlib.Path(__file__).resolve().parent
        command = [
            str(script_directory / "qwen-drain-controller.sh"),
            "resume",
            "--barrier-identity",
            sys.argv[2],
        ]
        os.execvpe(command[0], command, os.environ)
        return refuse("controller_resume_exec_returned")
    if len(sys.argv) == 4 and sys.argv[1] == "--unload":
        return unload(sys.argv[2], sys.argv[3])
    if len(sys.argv) != 3 or not sys.argv[2].isdigit():
        print("usage: qwen-router-orderly-retire.py MODEL ROUTER_PORT", file=sys.stderr)
        return 2
    barrier_identity = os.environ.get("QWEN_GPU_ADMISSION_IDENTITY", "")
    if not barrier_identity:
        return refuse("barrier_identity_missing")
    script_directory = pathlib.Path(__file__).resolve().parent
    command = [
        str(script_directory / "qwen-drain-controller.sh"),
        "retire",
        "--keep-quiescing",
        "--barrier-identity",
        barrier_identity,
        "--",
        str(pathlib.Path(__file__).resolve()),
        "--unload",
        sys.argv[1],
        sys.argv[2],
    ]
    os.execvpe(command[0], command, os.environ)
    return refuse("controller_exec_returned")


if __name__ == "__main__":
    raise SystemExit(main())
