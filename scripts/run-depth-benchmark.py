#!/usr/bin/env python3
"""Submit an exact-token long-context prefill and fixed decode request."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

QUERY = (
    "\nFINAL RETRIEVAL QUESTION\n"
    "Return only the exact value paired with key ORBITAL-CEDAR-7319 in the "
    "authoritative retrieval record near the beginning.\nANSWER:"
)
MAXIMUM_PROMPT_TOKENS = 24_000


def post_json(base_url: str, endpoint: str, payload: dict[str, Any], timeout: int) -> Any:
    headers = {"Content-Type": "application/json"}
    # The server rejects an unauthenticated caller once it holds an API key
    # file. The key arrives through the environment so it stays out of the
    # process arguments that /proc exposes to every account on the host.
    api_key = os.environ.get("QWEN_API_KEY", "")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(
        base_url + endpoint,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("base_url")
    parser.add_argument("corpus", type=Path)
    parser.add_argument("prompt_tokens", type=int)
    parser.add_argument("decode_tokens", type=int)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    parsed_url = urllib.parse.urlparse(arguments.base_url)
    if parsed_url.scheme != "http" or parsed_url.hostname not in {"127.0.0.1", "localhost"}:
        parser.error("base_url must use HTTP on localhost")
    if arguments.prompt_tokens < 4096:
        parser.error("prompt_tokens must be at least 4096")
    if arguments.prompt_tokens > MAXIMUM_PROMPT_TOKENS:
        parser.error(
            f"prompt_tokens exceeds operational maximum of {MAXIMUM_PROMPT_TOKENS}"
        )
    if arguments.decode_tokens < 1:
        parser.error("decode_tokens must be positive")
    return arguments


def require_process_policy() -> None:
    affinity = os.sched_getaffinity(0)
    if affinity != {0}:
        raise RuntimeError(f"client affinity must be CPU 0, found {sorted(affinity)}")
    if os.getpriority(os.PRIO_PROCESS, 0) != 19:
        raise RuntimeError("client nice value must be 19")


def main() -> None:
    arguments = parse_arguments()
    require_process_policy()
    corpus_bytes = arguments.corpus.read_bytes()
    corpus_text = corpus_bytes.decode("utf-8")
    if "key=ORBITAL-CEDAR-7319" not in corpus_text:
        raise RuntimeError("authoritative retrieval record is missing")

    corpus_tokens = post_json(
        arguments.base_url,
        "/tokenize",
        {"content": corpus_text, "add_special": False, "parse_special": True},
        timeout=600,
    )["tokens"]
    query_tokens = post_json(
        arguments.base_url,
        "/tokenize",
        {"content": QUERY, "add_special": False, "parse_special": True},
        timeout=60,
    )["tokens"]
    prefix_tokens = arguments.prompt_tokens - len(query_tokens)
    if prefix_tokens < 2048:
        raise RuntimeError("query leaves fewer than 2048 corpus tokens")
    if len(corpus_tokens) < prefix_tokens:
        raise RuntimeError(
            f"corpus has {len(corpus_tokens)} tokens but {prefix_tokens} are required"
        )
    prompt = corpus_tokens[:prefix_tokens] + query_tokens
    if len(prompt) != arguments.prompt_tokens:
        raise RuntimeError("constructed prompt token count does not match target")

    request_payload = {
        "prompt": prompt,
        "n_predict": arguments.decode_tokens,
        "temperature": 0.0,
        "seed": 1,
        "ignore_eos": True,
        "repeat_penalty": 1.0,
        "cache_prompt": False,
        "stream": False,
        "timings_per_token": False,
    }
    started_utc = datetime.now(timezone.utc).isoformat()
    completion = post_json(
        arguments.base_url, "/completion", request_payload, timeout=21_600
    )
    completed_utc = datetime.now(timezone.utc).isoformat()

    if completion.get("truncated"):
        raise RuntimeError("server truncated the benchmark prompt")
    if completion.get("tokens_evaluated") != arguments.prompt_tokens:
        raise RuntimeError(
            "server token count mismatch: "
            f"expected {arguments.prompt_tokens}, "
            f"found {completion.get('tokens_evaluated')}"
        )
    timings = completion.get("timings", {})
    if timings.get("predicted_n") != arguments.decode_tokens:
        raise RuntimeError(
            "fixed decode depth mismatch: "
            f"expected {arguments.decode_tokens}, found {timings.get('predicted_n')}"
        )

    retained_result = {
        "benchmark": {
            "started_utc": started_utc,
            "completed_utc": completed_utc,
            "corpus_sha256": hashlib.sha256(corpus_bytes).hexdigest(),
            "corpus_tokens_available": len(corpus_tokens),
            "prompt_tokens_requested": arguments.prompt_tokens,
            "query_tokens": len(query_tokens),
            "decode_tokens_requested": arguments.decode_tokens,
            "cache_prompt": False,
        },
        "response": completion,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=arguments.output.parent, delete=False
    ) as temporary_file:
        json.dump(retained_result, temporary_file, ensure_ascii=False, indent=2)
        temporary_file.write("\n")
        temporary_path = Path(temporary_file.name)
    temporary_path.replace(arguments.output)
    print(
        json.dumps(
            {
                "output": str(arguments.output),
                "prompt_tokens": timings.get("prompt_n"),
                "prefill_tokens_per_second": timings.get("prompt_per_second"),
                "decode_tokens": timings.get("predicted_n"),
                "decode_tokens_per_second": timings.get("predicted_per_second"),
                "content": completion.get("content"),
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
