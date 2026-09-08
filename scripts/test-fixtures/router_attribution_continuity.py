#!/usr/bin/env python3
"""Exercise request attribution across a capacity-one child replacement."""

import concurrent.futures
import json
import pathlib
import subprocess
import time
import urllib.error
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parent.parent.parent


def post(port, model, request_id, page_state=None, delay=0):
    page_state = page_state or {"messages": [], "attribution": {"request_id": request_id}}
    attribution = dict(page_state["attribution"], request_id=request_id)
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/completion",
        data=json.dumps({"model": model, "attribution": attribution,
                         "messages": page_state["messages"]}).encode(),
        headers={"Content-Type": "application/json", "X-Fixture-Delay": str(delay)},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"error": raw.decode("utf-8", errors="replace")}
        return error.code, payload


def exercise(port, events_path):
    page_state = json.loads(subprocess.check_output(
        ["node", str(ROOT / "scripts/test-router-attribution-page-state.mjs")], text=True
    ))
    baseline_old_starts = (events_path.read_text().count("old-model\trequest_start")
                           if events_path.exists() else 0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        old = pool.submit(post, port, "old-model", "request-retained", page_state, 0.4)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if (events_path.exists() and
                    events_path.read_text().count("old-model\trequest_start") > baseline_old_starts):
                break
            time.sleep(0.02)
        else:
            raise AssertionError("attribution request never reached old child")
        replacement = pool.submit(post, port, "new-model", "request-new")
        old_status, old_payload = old.result(timeout=15)
        new_status, new_payload = replacement.result(timeout=15)
    assert old_status == 200
    assert new_status == 200, (new_status, new_payload)
    assert old_payload["attribution"] == page_state["attribution"]
    assert old_payload["messages"] == page_state["messages"]

    continued_status, continued = post(port, "new-model", "request-retained", page_state)
    assert continued_status == 200
    assert continued["attribution"]["request_id"] == "request-retained"
    assert continued["messages"] == page_state["messages"]
    assert page_state["cross_request_result"] == "refused_by_conversation_generation"
    return "approval_metadata=retained artifact=retained tool_call_id=retained cross_request=refused"
