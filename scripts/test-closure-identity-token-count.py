#!/usr/bin/env python3
"""Require the identity harness to reject incomplete or misattributed token counts."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


HARNESS = Path(__file__).with_name("run-closure-identity-ab.sh").read_text()
READER = HARNESS.split('cat >"$token_reader" <<\'PYTHON\'\n', 1)[1].split("\nPYTHON", 1)[0]


class TokenCountTest(unittest.TestCase):
    def run_reader(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            response = Path(directory) / "response.json"
            response.write_text(json.dumps(payload))
            return subprocess.run(
                ["python3", "-c", READER, str(response), "3"],
                capture_output=True, text=True,
            )

    def test_matching_counts_emit_all_ids(self):
        result = self.run_reader({"tokens_predicted": 3, "tokens": [11, 12, 13]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "11\n12\n13\n")

    def test_missing_actual_count_refuses_before_output(self):
        result = self.run_reader({"tokens": [11, 12, 13]})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")

    def test_disagreeing_actual_count_refuses_full_array(self):
        result = self.run_reader({"tokens_predicted": 2, "tokens": [11, 12, 13]})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")

    def test_noninteger_actual_count_refuses(self):
        for count in ("3", 3.0, True, None):
            with self.subTest(count=count):
                result = self.run_reader({"tokens_predicted": count, "tokens": [11, 12, 13]})
                self.assertEqual(result.returncode, 1)

    def test_boolean_token_refuses(self):
        result = self.run_reader({"tokens_predicted": 3, "tokens": [11, True, 13]})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")

    def test_short_empty_or_missing_array_refuses(self):
        for tokens in ([11, 12], [], None):
            with self.subTest(tokens=tokens):
                result = self.run_reader({"tokens_predicted": 3, "tokens": tokens})
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
