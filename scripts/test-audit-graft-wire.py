"""Calibrate clipping and focal-span reports against positive and negative wires."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys


SPECIFICATION = importlib.util.spec_from_file_location(
    "audit", Path(__file__).with_name("audit-graft-wire.py")
)
AUDIT = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(AUDIT)


class WireAuditTests(unittest.TestCase):
    def test_clipped_targets_and_span_preferences(self):
        nodes = [{"id": "a.c#" + name, "path": "a.c", "kind": "function",
                  "span": span, "signature": "int " + name + "(void)"}
                 for name, span in (("full", "L1-L3"), ("partial", "L5-L15"),
                                    ("absent", "L20-L30"))]
        request = {
            "tool_choice": {"type": "function", "function": {"name": "record_symbols"}},
            "messages": [{"content": "FILE: a.c\n\n1\tint full(void) {\n"
                          "7\treturn 0;\n8\t... (truncated)\n\nTARGETS (3):\n"
                          "- id=a.c#full | function | lines L1-L3\n"
                          "- id=a.c#partial | function | lines L5-L15\n"
                          "- id=a.c#absent | function | lines L20-L30"}],
        }
        response = {"choices": [{"message": {"tool_calls": [{"function": {
            "name": "record_symbols", "arguments": json.dumps({"symbols": [
                {"id": "a.c#full", "crux_start": 2, "crux_end": 2},
                {"id": "a.c#partial", "crux_start": 5, "crux_end": 15},
                {"id": "a.c#absent", "crux_start": 0, "crux_end": 0},
            ]})}}]}}]}
        with tempfile.TemporaryDirectory() as temporary_directory:
            graph = Path(temporary_directory) / "graph.json"
            graph.write_text(json.dumps({"nodes": nodes}))
            result = AUDIT.audit_request(request, response, graph)
        self.assertEqual(result["source_end"], 7)
        self.assertEqual(result["source_coverage"], {
            "full": ["a.c#full"], "partial": ["a.c#partial"], "absent": ["a.c#absent"]})
        self.assertEqual(result["over_eight_lines"], ["a.c#partial"])
        self.assertEqual(result["whole_gradeable_definition"], ["a.c#partial"])
        self.assertEqual(result["unparsed_calls"], 0)

    def test_non_symbol_request_is_separate(self):
        self.assertIsNone(AUDIT.audit_request({"messages": []}, {}, Path("unused")))

    def test_interrupted_capture_stays_incomplete(self):
        request = {
            "tool_choice": {"type": "function", "function": {"name": "record_symbols"}},
            "messages": [{"content": "FILE: a.c\n\n1\tint f(void);\n\nTARGETS (1):\n"
                          "- id=a.c#f | function | lines L1-L1"}],
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            arm = Path(temporary_directory)
            (arm / "graph/.graph").mkdir(parents=True)
            (arm / "graph/.graph/wiring.json").write_text(json.dumps({"nodes": [{
                "id": "a.c#f", "path": "a.c", "kind": "function", "span": "L1-L1",
                "signature": "int f(void);"}]}))
            (arm / "requests.json").write_text(json.dumps([{"request_id": 0, "started": 1.0}]))
            (arm / "wire-0000.request.json").write_text(json.dumps(request))
            output = arm / "audit.json"
            subprocess.run([sys.executable, str(Path(__file__).with_name("audit-graft-wire.py")),
                            str(arm), str(output)], check=True, capture_output=True)
            result = json.loads(output.read_text())[0]
        self.assertEqual(result["status"], "capture_incomplete")
        self.assertFalse(result["capture_complete"])
        self.assertEqual(result["tool_call_count"], 0)


if __name__ == "__main__":
    unittest.main()
