import base64
import http.client
import json
import socket
import sys
import time

# request SHAPE PREDICT OUT IMAGE_DIR LARGE_DIR: one greedy /completion of the named shape.
# reply RESPONSE OUT: the reply token ids and timings, refused on a short array.
# cancel SHAPE DELAY PORT PREDICT OUT IMAGE_DIR LARGE_DIR: send the request, close the connection after DELAY seconds.
SHAPES = {
    # (images, prompt with one <__media__> per image)
    "single": (("bars.png",), "<__media__>\nDescribe what this image shows, naming every label and number you can read."),
    "pair-adjacent": (("compare-a.png", "compare-b.png"),
                      "<__media__><__media__>\nTwo images are shown. How many discs does each hold?"),
    "pair-text": (("bars.png", "shapes.png"),
                  "First image:\n<__media__>\nSecond image:\n<__media__>\nDescribe each image, naming every label and number you can read."),
    "large": (("bars-large.png",), "<__media__>\nDescribe what this image shows, naming every label and number you can read."),
    "large-pair-text": (("bars-large.png", "shapes-large.png"),
                        "First image:\n<__media__>\nSecond image:\n<__media__>\nDescribe each image, naming every label and number you can read."),
}


def build(shape, predict, image_directory, large_directory):
    images, prompt = SHAPES[shape]
    encoded = []
    for name in images:
        directory = large_directory if name.endswith("-large.png") else image_directory
        with open(directory + "/" + name, "rb") as handle:
            encoded.append(base64.b64encode(handle.read()).decode("ascii"))
    return {
        "prompt": {"prompt_string": "<|im_start|>user\n" + prompt + "<|im_end|>\n<|im_start|>assistant\n",
                   "multimodal_data": encoded},
        "n_predict": predict,
        "temperature": 0,
        "top_k": 1,
        "seed": 1,
        "cache_prompt": False,
        "return_tokens": True,
        "samplers": ["top_k"],
    }


command = sys.argv[1]
if command == "request":
    shape, predict, out, image_directory, large_directory = sys.argv[2:7]
    json.dump(build(shape, int(predict), image_directory, large_directory), open(out, "w", encoding="utf-8"))
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
elif command == "cancel":
    shape, delay, port, predict, out, image_directory, large_directory = sys.argv[2:9]
    request = build(shape, int(predict), image_directory, large_directory)
    # an abandoned request has to outlive its client, so it ignores EOS
    request["ignore_eos"] = True
    body = json.dumps(request).encode("utf-8")
    connection = http.client.HTTPConnection("127.0.0.1", int(port), timeout=600)
    started = time.monotonic()
    connection.putrequest("POST", "/completion")
    connection.putheader("Content-Type", "application/json")
    connection.putheader("Content-Length", str(len(body)))
    connection.endheaders()
    connection.send(body)
    time.sleep(float(delay))
    received = 0
    try:
        connection.sock.setblocking(False)
        received = len(connection.sock.recv(65536))
    except (BlockingIOError, socket.error):
        received = 0
    connection.close()
    json.dump({"shape": shape, "delay_s": float(delay), "elapsed_s": round(time.monotonic() - started, 4),
               "bytes_received_before_close": received}, open(out, "w", encoding="utf-8"))
else:
    raise SystemExit("unknown command %s" % command)
