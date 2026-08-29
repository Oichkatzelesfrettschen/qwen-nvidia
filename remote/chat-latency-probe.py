#!/usr/bin/env python3
"""Measure what a chat user waits for: first token, then token cadence."""

from __future__ import annotations

import argparse
import json
import time
import urllib.request

PROMPT = (
    "You are helping test a small language model. In two or three sentences, "
    "explain why a laptop with an integrated GPU generates text more slowly "
    "than a desktop with a discrete graphics card."
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("base_url")
    parser.add_argument("--decode-tokens", type=int, default=128)
    parser.add_argument("--reasoning", action="store_true")
    parser.add_argument("--prompt", default=PROMPT)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    payload = {
        "model": "qwen-apu",
        "messages": [{"role": "user", "content": arguments.prompt}],
        "max_tokens": arguments.decode_tokens,
        "temperature": 0.0,
        "seed": 1,
        "stream": True,
        "stream_options": {"include_usage": True},
        "cache_prompt": False,
        "chat_template_kwargs": {"enable_thinking": arguments.reasoning},
    }
    if not arguments.reasoning:
        payload["reasoning_budget"] = 0

    request = urllib.request.Request(
        arguments.base_url + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    started = time.monotonic()
    first_token_at = None
    token_count = 0
    timings = None
    text = []

    with urllib.request.urlopen(request, timeout=3600) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8").strip()
            if not line.startswith("data: "):
                continue
            body = line[6:]
            if body == "[DONE]":
                break
            try:
                chunk = json.loads(body)
            except json.JSONDecodeError:
                continue
            if chunk.get("timings"):
                timings = chunk["timings"]
            choices = chunk.get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            piece = delta.get("content") or delta.get("reasoning_content") or ""
            if piece:
                if first_token_at is None:
                    first_token_at = time.monotonic()
                token_count += 1
                text.append(piece)

    finished = time.monotonic()
    # The decode rate excludes the wait for the first token, so it reports the
    # cadence a reader sees once text starts rather than averaging the stall in.
    decode_seconds = finished - (first_token_at or finished)
    result = {
        "time_to_first_token_s": round((first_token_at or finished) - started, 3),
        "total_s": round(finished - started, 3),
        "stream_chunks": token_count,
        "decode_chunks_per_s": (
            round((token_count - 1) / decode_seconds, 3)
            if token_count > 1 and decode_seconds > 0 else None
        ),
        "server_prompt_n": (timings or {}).get("prompt_n"),
        "server_prompt_per_second": (timings or {}).get("prompt_per_second"),
        "server_predicted_n": (timings or {}).get("predicted_n"),
        "server_predicted_per_second": (timings or {}).get("predicted_per_second"),
        "reply_head": "".join(text)[:80],
    }
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
