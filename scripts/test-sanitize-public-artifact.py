#!/usr/bin/env python3
"""Exercise publication copies and the tracked-file refusal boundary."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("sanitize-public-artifact.py")
SPEC = importlib.util.spec_from_file_location("publication", SCRIPT)
PUBLICATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLICATION)


class PublicationTest(unittest.TestCase):
    def test_home_paths_and_escaped_windows_paths(self):
        for prefix in ("home", "Users"):
            source = "/" + prefix + "/alice/work/result.log"
            self.assertEqual(PUBLICATION.sanitize(source), "$HOME/work/result.log")
        for separator in (chr(92), chr(92) * 2):
            source = "C:" + separator + "Users" + separator + "alice" + separator + "result"
            self.assertEqual(PUBLICATION.sanitize(source), "$HOME" + separator + "result")

    def test_public_placeholders_and_relative_fixture_paths_survive(self):
        text = "$HOME/work $SCRATCH/log $work_directory/home/file hostname=qwen-laptop"
        self.assertEqual(PUBLICATION.sanitize(text), text)

    def test_identity_fields_are_redacted_in_json_and_assignments(self):
        for key in ("username", "user_name", "hostname", "host_name"):
            for source in (f'{key}=private-node', f'"{key}": "private-node"'):
                self.assertEqual(PUBLICATION.sanitize(source), source.replace("private-node", "redacted"))

    def test_copy_preserves_raw_bytes_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "raw", Path(directory) / "public"
            raw = ("/" + "home/alice/result\n").encode()
            source.write_bytes(raw)
            PUBLICATION.copy_sanitized(source, target)
            self.assertEqual(source.read_bytes(), raw)
            self.assertEqual(target.read_text(), "$HOME/result\n")
            with self.assertRaises(ValueError):
                PUBLICATION.copy_sanitized(source, target)
            with self.assertRaises(ValueError):
                PUBLICATION.copy_sanitized(source, source)

    def test_binary_and_invalid_utf8_copy_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "raw", Path(directory) / "public"
            for payload in (b"\0binary", b"\xff"):
                source.write_bytes(payload)
                with self.assertRaises(ValueError):
                    PUBLICATION.copy_sanitized(source, target)
                self.assertFalse(target.exists())

    def test_check_reads_tracked_binary_strings_and_hides_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
            subprocess.run(["git", "init", "-q", directory], check=True, env=environment)
            path = root / "capture.log"
            private = "/" + "home/private-person/result"
            path.write_bytes(b"\xff\0" + private.encode())
            subprocess.run(["git", "-C", directory, "add", "-f", "capture.log"], check=True, env=environment)
            result = subprocess.run(["python3", str(SCRIPT), "--check"], cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("capture.log", result.stderr)
            self.assertNotIn("private-person", result.stderr + result.stdout)
            path.write_bytes(b"\xff\0$HOME/result")
            result = subprocess.run(["python3", str(SCRIPT), "--check"], cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_force_added_local_artifact_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
            subprocess.run(["git", "init", "-q", directory], check=True, env=environment)
            path = root / ".local-artifacts" / "run.log"
            path.parent.mkdir()
            path.write_text("harmless bytes\n")
            subprocess.run(["git", "-C", directory, "add", "-f", str(path)], check=True, env=environment)
            result = subprocess.run(["python3", str(SCRIPT), "--check"], cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("must stay untracked", result.stderr)


if __name__ == "__main__":
    unittest.main()
