import json
import sys

response_path, expected = sys.argv[1], int(sys.argv[2])
with open(response_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
tokens = payload.get("tokens")
if not isinstance(tokens, list) or not tokens:
    sys.stderr.write("response carries no token array\n")
    raise SystemExit(1)
for token_id in tokens:
    if not isinstance(token_id, int):
        sys.stderr.write("token array holds a non-integer entry\n")
        raise SystemExit(1)
if len(tokens) != expected:
    sys.stderr.write(
        f"token array holds {len(tokens)} of {expected} predicted tokens\n")
    raise SystemExit(1)
for token_id in tokens:
    print(token_id)
