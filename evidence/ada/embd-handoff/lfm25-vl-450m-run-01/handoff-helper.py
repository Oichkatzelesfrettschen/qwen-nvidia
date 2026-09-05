import base64
import json
import re
import sys

# request IMAGE PREDICT OUT: one greedy /completion carrying the image.
# reply RESPONSE OUT: the reply token ids and timings, refused on a short array.
# trace SERVER_LOG OUT_TSV: the handoff lines the log holds, one row each.
command = sys.argv[1]
if command == "request":
    with open(sys.argv[2], "rb") as handle:
        encoded = base64.b64encode(handle.read()).decode("ascii")
    prompt = ("<|im_start|>user\n<__media__>\nDescribe what this image shows, "
              "naming every label and number you can read.<|im_end|>\n<|im_start|>assistant\n")
    json.dump({
        "prompt": {"prompt_string": prompt, "multimodal_data": [encoded]},
        "n_predict": int(sys.argv[3]),
        "temperature": 0,
        "top_k": 1,
        "seed": 1,
        "cache_prompt": False,
        "return_tokens": True,
        "samplers": ["top_k"],
    }, open(sys.argv[4], "w", encoding="utf-8"))
elif command == "reply":
    record = json.load(open(sys.argv[2], encoding="utf-8"))
    tokens = record.get("tokens")
    if not isinstance(tokens, list) or not tokens:
        sys.stderr.write("the reply carries no token ids\n")
        raise SystemExit(1)
    timings = record.get("timings", {})
    json.dump({"tokens": tokens, "prompt_n": timings.get("prompt_n"),
               "prompt_ms": timings.get("prompt_ms"), "predicted_n": timings.get("predicted_n"),
               "predicted_ms": timings.get("predicted_ms")}, open(sys.argv[3], "w", encoding="utf-8"))
elif command == "trace":
    clip_line = re.compile(r"clip_embd_handoff dst=(\S+) src_backend=(\S+)(?: dst_buffer=(\S+))? bytes=(\d+) digest=([0-9a-f]{16})")
    embd_line = re.compile(r"embd_handoff source=(\S+) n_tokens=(\d+) n_embd=(\d+) offset=(-?\d+) buffer=(\S+) digest=([0-9a-f]{16})")
    rows = []
    for line in open(sys.argv[2], encoding="utf-8", errors="replace"):
        match = clip_line.search(line)
        if match:
            dst, src_backend, dst_buffer, nbytes, digest = match.groups()
            rows.append(("clip", dst, src_backend, dst_buffer or "-", nbytes, "-", "-", digest))
            continue
        match = embd_line.search(line)
        if match and "clip_embd_handoff" not in line:
            source, n_tokens, n_embd, offset, buffer, digest = match.groups()
            rows.append(("graph", source, buffer, "-", str(int(n_tokens) * int(n_embd) * 4), n_tokens, offset, digest))
    with open(sys.argv[3], "w", encoding="utf-8") as out:
        out.write("kind\tplacement\tbackend\tdst_buffer\tbytes\tn_tokens\toffset\tdigest\n")
        for row in rows:
            out.write("\t".join(row) + "\n")
else:
    raise SystemExit("unknown command %s" % command)
