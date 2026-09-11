#!/usr/bin/env python3
"""Exercise acceptance and refusal cases for the AUR retention checker."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIRECTORY.parent
CHECKER = SCRIPT_DIRECTORY / "check-aur-llama-cpp-cuda-retention.py"
EVIDENCE_RELATIVE = Path("evidence/ada/aur-llama-cpp-cuda-stale-flags")


class RetentionCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        local_temporary_root = REPOSITORY_ROOT / ".local-artifacts" / "tmp"
        local_temporary_root.mkdir(parents=True, exist_ok=True)
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="aur-retention-", dir=local_temporary_root
        )
        self.fixture_root = Path(self.temporary_directory.name)
        fixture_evidence = self.fixture_root / EVIDENCE_RELATIVE
        fixture_evidence.parent.mkdir(parents=True)
        shutil.copytree(REPOSITORY_ROOT / EVIDENCE_RELATIVE, fixture_evidence)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_checker(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), "--root", str(self.fixture_root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_registered_record_is_accepted(self) -> None:
        result = self.run_checker()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("aur_llama_cpp_cuda_retention=accepted", result.stdout)

    def test_digest_mutation_is_rejected(self) -> None:
        identity_path = self.fixture_root / EVIDENCE_RELATIVE / "source-identity.tsv"
        identity_text = identity_path.read_text(encoding="utf-8")
        identity_path.write_text(
            identity_text.replace("41dd78ee", "01dd78ee", 1), encoding="utf-8"
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("registered identity tuple changed", result.stdout)

    def test_duplicate_identity_row_is_rejected(self) -> None:
        identity_path = self.fixture_root / EVIDENCE_RELATIVE / "source-identity.tsv"
        identity_lines = identity_path.read_text(encoding="utf-8").splitlines()
        identity_path.write_text(
            "\n".join(identity_lines + [identity_lines[1]]) + "\n",
            encoding="utf-8",
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("registered identity tuple changed", result.stdout)

    def test_missing_decision_row_is_rejected(self) -> None:
        decision_path = self.fixture_root / EVIDENCE_RELATIVE / "decision.tsv"
        decision_lines = decision_path.read_text(encoding="utf-8").splitlines()
        decision_path.write_text(
            "\n".join(decision_lines[:-1]) + "\n", encoding="utf-8"
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusal denominator changed", result.stdout)

    def test_admitted_decision_is_rejected(self) -> None:
        decision_path = self.fixture_root / EVIDENCE_RELATIVE / "decision.tsv"
        decision_text = decision_path.read_text(encoding="utf-8")
        decision_path.write_text(
            decision_text.replace("\trefused\n", "\tadmitted\n", 1),
            encoding="utf-8",
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not refused", result.stdout)

    def test_decision_observation_mutation_is_rejected(self) -> None:
        decision_path = self.fixture_root / EVIDENCE_RELATIVE / "decision.tsv"
        decision_text = decision_path.read_text(encoding="utf-8")
        decision_path.write_text(
            decision_text.replace(
                "the option is absent from the cached newer llama.cpp source",
                "the option is present in the cached newer llama.cpp source",
                1,
            ),
            encoding="utf-8",
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("registered decision rows changed", result.stdout)


if __name__ == "__main__":
    unittest.main()
