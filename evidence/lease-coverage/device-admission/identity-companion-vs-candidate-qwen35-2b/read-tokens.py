import json
import sys

response_path, expected = sys.argv[1], int(sys.argv[2])
with open(response_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
actual_predicted = payload.get("tokens_predicted")
if type(actual_predicted) is not int or actual_predicted != expected:
    sys.stderr.write("server predicted count differs from the requested count\n")
    raise SystemExit(1)
tokens = payload.get("tokens")
if not isinstance(tokens, list) or not tokens:
    sys.stderr.write("response carries no token array\n")
    raise SystemExit(1)
for token_id in tokens:
    if type(token_id) is not int:
        sys.stderr.write("token array holds a non-integer entry\n")
        raise SystemExit(1)
if len(tokens) != expected:
    sys.stderr.write(
        f"token array holds {len(tokens)} of {expected} predicted tokens\n")
    raise SystemExit(1)
for token_id in tokens:
    print(token_id)
