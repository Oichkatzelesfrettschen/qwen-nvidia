#!/usr/bin/env python3
"""Send one burst of N identical completion requests and validate every reply.

A burst is N requests carrying one token-id prompt, one reply length, greedy
sampling, and `ignore_eos`, each pinned to its own slot through `id_slot`, so
the server holds N decoding slots for the whole reply and the request index
is the slot id. The N connections are opened and the bodies are written from
N threads released by one barrier, so the requests leave inside the time a
thread takes to wake rather than the time N processes take to start; the
wall-clock window from the barrier to the last reply is retained beside the
server's own timings.

Admission is one of two shapes. `cold` sends the prompt uncached, so the
burst's prompts enter the server's next batches and, above `n_batch / prompt
tokens` slots, some members decode beside the others' prefill. `primed` first
sends one request per slot in sequence with `cache_prompt` and a one-token
reply, so every slot holds the prompt from a prefill it ran alone, and the
burst then reuses each slot's cache: the server evaluates the final prompt
token per slot, N tokens in one batch, and every member reaches its first
decode pass together. Which shape a burst had is read back from the server
log by read-server-decode-iterations.py rather than assumed here.

Every reply is validated before the burst is accepted: HTTP 200, no `error`
key, `timings.predicted_n` equal to the requested length, a `tokens` list of
that length, and `timings.prompt_n` equal to the prompt length under `cold`
or at most two under `primed`. One failing reply fails the burst, because a
rate over N-1 replies is not the rate the arm asked for.
"""

import argparse
import http.client
import json
import pathlib
import sys
import threading
import time


def post(port, body, timeout):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request("POST", "/completion", body=json.dumps(body),
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def request_body(prompt_tokens, slot, predict, cached):
    return {
        "prompt": prompt_tokens,
        "id_slot": slot,
        "n_predict": predict,
        "temperature": 0,
        "ignore_eos": True,
        "stream": False,
        "cache_prompt": cached,
        "return_tokens": True,
    }


def validate(record, predict, prompt_length, admission):
    if "error" in record:
        return "server error: %s" % json.dumps(record["error"])[:200]
    timings = record.get("timings") or {}
    if timings.get("predicted_n") != predict:
        return "predicted_n %s where %s was asked" % (timings.get("predicted_n"), predict)
    tokens = record.get("tokens")
    if not isinstance(tokens, list) or len(tokens) != predict:
        return "tokens holds %s ids where %s were asked" % (
            len(tokens) if isinstance(tokens, list) else "no", predict)
    prompt_n = timings.get("prompt_n")
    if admission == "cold" and prompt_n != prompt_length:
        return "prompt_n %s where the uncached prompt holds %s" % (prompt_n, prompt_length)
    if admission == "primed" and not (isinstance(prompt_n, int) and prompt_n <= 2):
        return "prompt_n %s where a primed slot evaluates at most two" % prompt_n
    return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--level", type=int, required=True)
    parser.add_argument("--predict", type=int, required=True)
    parser.add_argument("--prompt-tokens", required=True,
                        help="JSON file holding the prompt as a token-id array")
    parser.add_argument("--output", required=True)
    parser.add_argument("--admission", choices=("cold", "primed"), default="primed")
    parser.add_argument("--timeout", type=float, default=600.0)
    args = parser.parse_args()

    prompt_tokens = json.loads(pathlib.Path(args.prompt_tokens).read_text())
    if not isinstance(prompt_tokens, list) or not prompt_tokens:
        sys.exit("the prompt file holds no token ids")
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)

    if args.admission == "primed":
        for slot in range(args.level):
            status, payload = post(args.port, request_body(prompt_tokens, slot, 1, True),
                                   args.timeout)
            record = json.loads(payload) if status == 200 else {}
            if status != 200 or "error" in record:
                sys.exit("priming slot %d answered %s: %s" % (slot, status, payload[:200]))
            (output / ("prime-%d.json" % slot)).write_bytes(payload)

    results = [None] * args.level
    barrier = threading.Barrier(args.level + 1)

    def worker(slot):
        body = request_body(prompt_tokens, slot, args.predict,
                            args.admission == "primed")
        barrier.wait()
        try:
            results[slot] = post(args.port, body, args.timeout)
        except Exception as error:  # noqa: BLE001 -- recorded as the failure
            results[slot] = (0, str(error).encode())

    threads = [threading.Thread(target=worker, args=(slot,)) for slot in range(args.level)]
    for thread in threads:
        thread.start()
    start = time.time()
    barrier.wait()
    for thread in threads:
        thread.join()
    end = time.time()
    (output / "window.txt").write_text("%.6f %.6f\n" % (start, end))

    failures = []
    for slot, (status, payload) in enumerate(results):
        (output / ("request-%d.json" % slot)).write_bytes(payload)
        if status != 200:
            failures.append("slot %d answered HTTP %s" % (slot, status))
            continue
        try:
            record = json.loads(payload)
        except ValueError:
            failures.append("slot %d answered no JSON" % slot)
            continue
        reason = validate(record, args.predict, len(prompt_tokens), args.admission)
        if reason:
            failures.append("slot %d: %s" % (slot, reason))
    (output / "validation.txt").write_text(
        "burst=%s level=%d admission=%s failures=%d\n%s" % (
            "accepted" if not failures else "rejected", args.level, args.admission,
            len(failures), "".join(line + "\n" for line in failures)))
    if failures:
        sys.exit("\n".join(failures))


if __name__ == "__main__":
    main()
