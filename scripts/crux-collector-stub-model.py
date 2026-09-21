"""OpenAI-compatible stub that returns one chosen crux reply class.

The crux collector's acceptance rule is the object under test, so the stub
holds every other variable fixed and varies only the reply. QWEN_STUB_MODE
selects good (every requested id, summarized), blank (every requested id, no
summary), mixed (the first requested id summarized), foreign (the bare symbol
name in place of the canonical id, no summary), foreign-summarized (the bare
name, summarized) or echoed (the whole target line as the id, summarized). A
foreign mode carries an id the request never named, which is what a model
returns when it answers with the symbol rather than the node. The echoed mode
is what qwen3-4b-instruct-2507 returns on this appliance: the id followed by
the kind and span the request printed beside it.
Each record_symbols request appends one line to QWEN_STUB_LOG, which is the
measurement.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("QWEN_STUB_MODE", "blank")
LOG = os.environ["QWEN_STUB_LOG"]
ID_LINE = re.compile(r"^- id=(\S+) \|", re.M)
TARGET_LINE = re.compile(r"^- id=(.+)$", re.M)


def foreign_id(node_id):
    """Return an id the request never named.

    A canonical id is path-scoped, so dropping the path yields the bare symbol
    name a model returns when it answers with the symbol rather than the node.
    The file node carries no symbol half, so it takes an explicit marker: a
    transform that leaves any id unchanged would measure the fixture instead of
    the collector.
    """
    if "#" in node_id:
        return node_id.rsplit("#", 1)[-1]
    return node_id + "#unrequested"


def crux_arguments(user_text):
    ids = ID_LINE.findall(user_text)
    echoed = TARGET_LINE.findall(user_text) if MODE == "echoed" else []
    symbols = []
    for index, node_id in enumerate(ids):
        summarized = (MODE in ("good", "foreign-summarized", "echoed")
                      or (MODE == "mixed" and index == 0))
        if MODE == "echoed":
            answered = echoed[index]
        elif MODE.startswith("foreign"):
            answered = foreign_id(node_id)
        else:
            answered = node_id
        symbols.append({
            "id": answered,
            "summary": "Adds two integers." if summarized else "",
            "crux_start": 0,
            "crux_end": 0,
        })
    with open(LOG, "a", encoding="utf-8") as handle:
        handle.write("record_symbols\tids=%d\tsummarized=%d\n"
                     % (len(symbols), sum(1 for s in symbols if s["summary"])))
    return {"symbols": symbols}


def graph_arguments():
    return {"concepts": [], "links": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length) or b"{}")
        tools = request.get("tools") or []
        names = [(t.get("function") or {}).get("name") for t in tools]
        user_text = "".join(m.get("content") or "" for m in request.get("messages", [])
                            if m.get("role") == "user")

        if "record_symbols" in names:
            message = self.tool_message("record_symbols", crux_arguments(user_text))
        elif "record_graph" in names:
            message = self.tool_message("record_graph", graph_arguments())
        elif names:
            message = self.tool_message(names[0], {})
        else:
            message = {"role": "assistant", "content": "A sample translation unit."}

        body = json.dumps({
            "id": "stub",
            "object": "chat.completion",
            "model": request.get("model", "stub"),
            "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    @staticmethod
    def tool_message(name, arguments):
        return {
            "role": "assistant",
            "content": None,
            "tool_calls": [{
                "id": "call_0",
                "type": "function",
                "function": {"name": name, "arguments": json.dumps(arguments)},
            }],
        }


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    server.serve_forever()
