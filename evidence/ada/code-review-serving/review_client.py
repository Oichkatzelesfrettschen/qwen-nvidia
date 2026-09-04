#!/usr/bin/env python3
"""Send a review prompt to the local llama.cpp server and print the reply."""
import json, sys, urllib.request

URL = "http://127.0.0.1:18086/v1/chat/completions"
SYSTEM = (
    "You are an adversarial code reviewer for a Mesa GPU driver.\n"
    "Judge whether the code does what its callers NEED, not merely whether it "
    "is internally consistent. A rule that always refuses, a branch that can "
    "never run, a check that cannot fire, or a guard that blocks the very case "
    "it exists to permit is a DEFECT even though the code is self-consistent.\n"
    "Ground every defect in the code shown. Never invent one. If the code "
    "serves its callers, answer CLEAN.\n"
    "Answer in under 150 words. First line exactly: VERDICT: DEFECT or "
    "VERDICT: CLEAN."
)

def ask(prompt, max_tokens=700):
    body = json.dumps({
        "messages": [{"role": "system", "content": SYSTEM},
                     {"role": "user", "content": prompt}],
        "temperature": 0.1, "max_tokens": max_tokens,
    }).encode()
    req = urllib.request.Request(URL, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        out = json.load(r)["choices"][0]["message"]["content"]
    # the distill emits a reasoning block; the verdict is what follows it
    if "</think>" in out:
        out = out.split("</think>", 1)[1]
    return out.strip()

if __name__ == "__main__":
    print(ask(sys.stdin.read()))
