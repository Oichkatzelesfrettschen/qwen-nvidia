#!/bin/sh
set -eu

# Reasoning length is a property of a checkpoint only across several prompts.
# One deterministic generation says what that model does with that sentence.
# This drives a fixed set against a live server and reports the distribution.

endpoint=${QWEN_ENDPOINT:-http://127.0.0.1:8080}
output_path=${1:?usage: reasoning-span-probe.sh OUTPUT_JSON}

python3 - "$endpoint" "$output_path" <<'PY'
import json, sys, time, urllib.request

endpoint, output_path = sys.argv[1], sys.argv[2]

prompts = [
    "Which is larger, 9.11 or 9.9? Answer in one sentence.",
    "A train leaves at 14:20 and arrives at 17:05. How long is the trip?",
    "If a shirt costs 40 and is discounted 25 percent, what is the price?",
    "Name the capital of Australia and explain why it is not Sydney.",
    "What is 17 percent of 350?",
]

records = []
for index, prompt in enumerate(prompts):
    body = json.dumps({
        "model": "qwen-apu",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 2048,
        "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": True},
    }).encode()
    request = urllib.request.Request(
        endpoint + "/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json"})
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=1200) as response:
        document = json.load(response)
    elapsed = time.monotonic() - started
    timings = document.get("timings", {})
    message = document["choices"][0]["message"]
    reasoning = message.get("reasoning_content") or ""
    records.append({
        "index": index,
        "prompt": prompt,
        "wall_seconds": round(elapsed, 2),
        "predicted_tokens": timings.get("predicted_n"),
        "decode_tok_per_second": timings.get("predicted_per_second"),
        "prefill_tok_per_second": timings.get("prompt_per_second"),
        "reasoning_characters": len(reasoning),
        "answer": (message.get("content") or "").strip()[:200],
    })
    print("prompt=%d tokens=%s wall=%.1fs decode=%.3f"
          % (index, timings.get("predicted_n"), elapsed,
             timings.get("predicted_per_second") or 0.0), flush=True)

tokens = [r["predicted_tokens"] for r in records if r["predicted_tokens"]]
rates = [r["decode_tok_per_second"] for r in records if r["decode_tok_per_second"]]
walls = [r["wall_seconds"] for r in records]
summary = {
    "prompt_count": len(records),
    "predicted_tokens_total": sum(tokens),
    "predicted_tokens_mean": round(sum(tokens) / len(tokens), 1),
    "predicted_tokens_min": min(tokens),
    "predicted_tokens_max": max(tokens),
    "decode_tok_per_second_mean": round(sum(rates) / len(rates), 3),
    "wall_seconds_total": round(sum(walls), 1),
    "records": records,
}
with open(output_path, "w") as handle:
    json.dump(summary, handle, indent=2)
for key in ("prompt_count", "predicted_tokens_total", "predicted_tokens_mean",
            "predicted_tokens_min", "predicted_tokens_max",
            "decode_tok_per_second_mean", "wall_seconds_total"):
    print("%s=%s" % (key, summary[key]))
PY
