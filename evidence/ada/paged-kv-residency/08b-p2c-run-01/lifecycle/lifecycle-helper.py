import json
import sys

# cut-prompt ROWS OUT: a prompt of ROWS tokens through the server's tokenizer,
# by round-tripping a repeated paragraph through /tokenize and /detokenize.
# request PROMPT_FILE PREDICT OUT: a greedy cached completion request.
# tokens RESPONSE PREDICT OUT: the reply token ids, refused on a short array.
# prompt_n RESPONSE: the prompt tokens the server evaluated for the request.
command = sys.argv[1]
if command == "tokenize-body":
    text = open(sys.argv[2], encoding="utf-8").read()
    json.dump({"content": text, "add_special": False, "with_pieces": False}, sys.stdout)
elif command == "cut-tokens":
    rows = int(sys.argv[3])
    tokens = json.load(open(sys.argv[2], encoding="utf-8"))["tokens"]
    if len(tokens) < rows:
        sys.stderr.write("the source text tokenizes to %d tokens, under %d\n" % (len(tokens), rows))
        raise SystemExit(1)
    json.dump({"tokens": tokens[:rows]}, sys.stdout)
elif command == "detokenized-text":
    sys.stdout.write(json.load(open(sys.argv[2], encoding="utf-8"))["content"])
elif command == "request":
    prompt_text = open(sys.argv[2], encoding="utf-8").read()
    json.dump({"prompt": prompt_text, "n_predict": int(sys.argv[3]), "temperature": 0, "top_k": 1, "seed": 1,
               "ignore_eos": True, "cache_prompt": True, "return_tokens": True, "stream": False}, sys.stdout)
elif command == "tokens":
    payload = json.load(open(sys.argv[2], encoding="utf-8"))
    expected = int(sys.argv[3])
    tokens = payload.get("tokens")
    if not isinstance(tokens, list) or len(tokens) != expected or any(not isinstance(t, int) for t in tokens):
        sys.stderr.write("the reply carries %s of %d tokens\n" % (len(tokens) if isinstance(tokens, list) else "no", expected))
        raise SystemExit(1)
    for t in tokens:
        print(t)
elif command == "prompt_n":
    payload = json.load(open(sys.argv[2], encoding="utf-8"))
    print(payload.get("timings", {}).get("prompt_n", payload.get("tokens_evaluated", "-")))
else:
    raise SystemExit("unknown command")
