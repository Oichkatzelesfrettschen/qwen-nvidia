#!/usr/bin/env python3
# gpu-ownership: an HTTP client of a server run-graph-lifecycle-trace.sh owns; opens no device context
"""Drive one mixed-service transition through a llama-server, several times.

Each cycle runs the four-phase state machine a served workload passes through
when a second request joins a running one and leaves again:

    T0  slot A decodes alone
    T1  slot B enters with an uncached prefill while A stays live
    T2  A and B decode together
    T3  B finishes and A decodes alone again

A's request streams so the client sees each generated token as it arrives, and
B is sent once A has streamed `--trigger-tokens` tokens. A's prompt is sent with
`cache_prompt` on and B's with it off, so after the first cycle A's own prefill
is a restored checkpoint and B's prefill is the fixed uncached pass the phase
names. Every request pins its slot through `id_slot`, samples greedily, and
ignores end-of-sequence, so each cycle carries the same prompts, the same slot
identities, and the same token counts; a `--slot-a`/`--slot-b` swap is the
permutation control.

The output directory holds one `cycle-N.json` per cycle with the wall-clock
nanoseconds of the four phase boundaries, both requests' server timings, the
per-token arrival times, and the SHA-256 of each reply's token ids, which is
the correctness observation a later comparison reads. The first cycle is the
warm-up that fills A's prompt cache and is labeled so.
"""

import argparse
import hashlib
import http.client
import json
import pathlib
import sys
import threading
import time


def stream_completion(port, body, timeout, tokens, arrivals, on_first_token=None):
    """POST /completion with stream on, appending ids and arrival times to the
    caller's lists as they stream so a watcher can read progress; returns the
    final record."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    final = None
    try:
        connection.request("POST", "/completion", body=json.dumps(body),
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            payload = response.read()
            return {"error": {"status": response.status, "body": payload[:400].decode("utf-8", "replace")}}
        buffer = b""
        while True:
            chunk = response.read1(65536) if hasattr(response, "read1") else response.read(65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n\n" in buffer:
                event, buffer = buffer.split(b"\n\n", 1)
                for line in event.split(b"\n"):
                    if not line.startswith(b"data: "):
                        continue
                    record = json.loads(line[6:])
                    if "error" in record:
                        return record
                    ids = record.get("tokens") or []
                    if ids:
                        now = time.time_ns()
                        if not tokens and on_first_token is not None:
                            on_first_token(now)
                        tokens.extend(ids)
                        arrivals.extend([now] * len(ids))
                    if record.get("stop"):
                        final = record
        return final if final is not None else {"error": "stream ended without a stop record"}
    finally:
        connection.close()


def request_body(prompt_tokens, slot, predict, cached):
    return {
        "prompt": prompt_tokens,
        "id_slot": slot,
        "n_predict": predict,
        "temperature": 0,
        "ignore_eos": True,
        "stream": True,
        "cache_prompt": cached,
        "return_tokens": True,
    }


def digest(ids):
    return hashlib.sha256(json.dumps(ids).encode()).hexdigest()[:12]


def run_cycle(args, prompt_a, prompt_b, cycle):
    a_state = {"sent": None, "first": None, "done": None, "tokens": [], "arrivals": [], "record": None}
    b_state = {"sent": None, "first": None, "done": None, "tokens": [], "arrivals": [], "record": None}
    trigger = threading.Event()

    def a_worker():
        a_state["sent"] = time.time_ns()

        def first(now):
            a_state["first"] = now
        a_state["record"] = stream_completion(args.port, request_body(prompt_a, args.slot_a, args.predict_a, True),
                                              args.timeout, a_state["tokens"], a_state["arrivals"], first)
        a_state["done"] = time.time_ns()
        trigger.set()

    # The trigger is A's streamed token count rather than a delay, so B enters
    # at the same point of A's reply in every cycle whatever the rate.
    def a_watch():
        while not trigger.is_set():
            if len(a_state["arrivals"]) >= args.trigger_tokens:
                trigger.set()
                return
            time.sleep(0.002)

    thread_a = threading.Thread(target=a_worker)
    thread_a.start()
    watcher = threading.Thread(target=a_watch)
    watcher.start()
    trigger.wait()
    watcher.join()
    if a_state["done"] is not None and len(a_state["arrivals"]) < args.trigger_tokens:
        return {"cycle": cycle, "error": "A finished ahead of the trigger: %s" % json.dumps(a_state["record"])[:300]}

    b_state["sent"] = time.time_ns()

    def b_first(now):
        b_state["first"] = now
    b_state["record"] = stream_completion(args.port, request_body(prompt_b, args.slot_b, args.predict_b, False),
                                          args.timeout, b_state["tokens"], b_state["arrivals"], b_first)
    b_state["done"] = time.time_ns()
    thread_a.join()

    def summary(state, predict):
        record = state["record"] or {}
        timings = record.get("timings") or {}
        problem = ""
        if "error" in record:
            problem = "server error: %s" % json.dumps(record["error"])[:200]
        elif timings.get("predicted_n") != predict:
            problem = "predicted_n %s where %s was asked" % (timings.get("predicted_n"), predict)
        elif len(state["tokens"]) != predict:
            problem = "%d streamed ids where %d were asked" % (len(state["tokens"]), predict)
        return {
            "sent_ns": state["sent"], "first_token_ns": state["first"], "done_ns": state["done"],
            "prompt_n": timings.get("prompt_n"), "prompt_ms": timings.get("prompt_ms"),
            "predicted_n": timings.get("predicted_n"), "predicted_ms": timings.get("predicted_ms"),
            "cache_n": timings.get("cache_n"),
            "reply_sha256": digest(state["tokens"]), "tokens": state["tokens"],
            "arrivals_ns": state["arrivals"], "problem": problem,
        }

    a_summary = summary(a_state, args.predict_a)
    b_summary = summary(b_state, args.predict_b)
    return {
        "cycle": cycle,
        "warmup": cycle == 0,
        "slot_a": args.slot_a, "slot_b": args.slot_b,
        "phases_ns": {
            "T0_begin": a_summary["sent_ns"],
            "T1_begin": b_summary["sent_ns"],
            "T2_begin": b_summary["first_token_ns"],
            "T3_begin": b_summary["done_ns"],
            "T3_end": a_summary["done_ns"],
        },
        "a": a_summary, "b": b_summary,
        "error": a_summary["problem"] or b_summary["problem"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--prompt-a", required=True, help="JSON token-id array for slot A")
    parser.add_argument("--prompt-b", required=True, help="JSON token-id array for slot B")
    parser.add_argument("--slot-a", type=int, default=0)
    parser.add_argument("--slot-b", type=int, default=1)
    parser.add_argument("--predict-a", type=int, default=128)
    parser.add_argument("--predict-b", type=int, default=32)
    parser.add_argument("--trigger-tokens", type=int, default=24,
                        help="B is sent once A has streamed this many tokens")
    parser.add_argument("--cycles", type=int, default=6, help="including the warm-up cycle 0")
    parser.add_argument("--settle-seconds", type=float, default=0.5)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=float, default=600.0)
    args = parser.parse_args()

    prompt_a = json.loads(pathlib.Path(args.prompt_a).read_text())
    prompt_b = json.loads(pathlib.Path(args.prompt_b).read_text())
    for name, prompt in (("A", prompt_a), ("B", prompt_b)):
        if not isinstance(prompt, list) or not prompt:
            sys.exit("prompt %s holds no token ids" % name)
    if args.slot_a == args.slot_b:
        sys.exit("A and B need two slots")
    if args.trigger_tokens < 1 or args.trigger_tokens >= args.predict_a:
        sys.exit("the trigger has to fall inside A's reply")
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    failures = 0
    for cycle in range(args.cycles):
        result = run_cycle(args, prompt_a, prompt_b, cycle)
        (output / ("cycle-%d.json" % cycle)).write_text(json.dumps(result, indent=1))
        if result.get("error"):
            failures += 1
            print("cycle=%d error=%s" % (cycle, result["error"]))
            break
        a, b = result["a"], result["b"]
        print("cycle=%d warmup=%s a_prompt_n=%s a_reply=%s b_prompt_n=%s b_reply=%s mixed_ms=%.1f" % (
            cycle, result["warmup"], a["prompt_n"], a["reply_sha256"], b["prompt_n"], b["reply_sha256"],
            (result["phases_ns"]["T3_end"] - result["phases_ns"]["T0_begin"]) / 1e6))
        time.sleep(args.settle_seconds)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
