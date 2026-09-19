import json
import sys

prompt_path, predict, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(prompt_path, "r", encoding="utf-8") as handle:
    prompt_text = handle.read()
# cache_prompt off makes every request pay its own prefill, so a closure that
# changes the prefill graph is not masked by a reused KV prefix.
json.dump(
    {
        "prompt": prompt_text,
        "n_predict": predict,
        "temperature": 0,
        "top_k": 1,
        "seed": seed,
        "ignore_eos": True,
        "cache_prompt": False,
        "return_tokens": True,
        "stream": False,
    },
    sys.stdout,
)
