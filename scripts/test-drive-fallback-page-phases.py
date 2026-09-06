#!/usr/bin/env python3
"""Every wait the page driver performs leaves its name behind.

A refusal reported as a bare TimeoutError names the exception. A refusal
reported with the phase names which of the driver's waits the page never
reached, which is what separates a page that never loaded from a page that
loaded and never proposed. These arms drive `wait_for` against a fake socket,
so the timeline is exercised without a browser, a router, or the device.
"""

import importlib.util
import pathlib
import sys
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parent / "web-mcp" / "drive-fallback-page.py"
_spec = importlib.util.spec_from_file_location("drive_fallback_page", MODULE_PATH)
driver = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(driver)


class FakeSocket:
    """A socket that answers a fixed number of polls falsely, then truly."""

    def __init__(self, false_answers=0, raises=None):
        self.false_answers = false_answers
        self.raises = raises
        self.calls = 0

    def evaluate(self, _expression):
        self.calls += 1
        if self.raises is not None:
            raise self.raises
        if self.calls <= self.false_answers:
            return False
        return "value"


class PhaseTimelineTest(unittest.TestCase):
    def setUp(self):
        driver.phase_timeline_reset()

    def test_a_completed_wait_records_its_phase_and_budget(self):
        value = driver.wait_for(FakeSocket(), "expression", 5, "the page to load")
        self.assertEqual(value, "value")
        summary = driver.phase_timeline_summary()
        self.assertEqual(summary["last_completed_phase"], "the page to load")
        self.assertIsNone(summary["pending_phase"])
        self.assertEqual(summary["phases"][0]["deadline_s"], 5)
        self.assertEqual(summary["phases"][0]["outcome"], "completed")

    def test_a_timed_out_wait_stays_pending_with_its_deadline(self):
        with self.assertRaises(TimeoutError):
            driver.wait_for(FakeSocket(false_answers=1000), "expression", 0,
                            "the coding plan approval dialog")
        summary = driver.phase_timeline_summary()
        self.assertIsNone(summary["last_completed_phase"])
        self.assertEqual(summary["pending_phase"], "the coding plan approval dialog")
        self.assertEqual(summary["pending_phase_deadline_s"], 0)
        self.assertEqual(summary["phases"][0]["outcome"], "timed_out")

    def test_the_last_completed_phase_names_how_far_the_run_got(self):
        driver.wait_for(FakeSocket(), "expression", 5, "the page to load")
        driver.wait_for(FakeSocket(), "expression", 5, "the page to select a model")
        with self.assertRaises(TimeoutError):
            driver.wait_for(FakeSocket(false_answers=1000), "expression", 0,
                            "the coding plan approval dialog")
        summary = driver.phase_timeline_summary()
        self.assertEqual(summary["last_completed_phase"], "the page to select a model")
        self.assertEqual(summary["pending_phase"], "the coding plan approval dialog")
        self.assertEqual(len(summary["phases"]), 3)

    def test_a_raising_wait_is_told_apart_from_a_timeout(self):
        with self.assertRaises(RuntimeError):
            driver.wait_for(FakeSocket(raises=RuntimeError("page threw")),
                            "expression", 5, "the turn to end")
        summary = driver.phase_timeline_summary()
        self.assertEqual(summary["phases"][0]["outcome"], "raised")
        self.assertEqual(summary["pending_phase"], "the turn to end")

    def test_a_recovered_timeout_stops_being_pending_once_a_later_wait_returns(self):
        """The image path catches the artifact-fetch timeout and continues.

        Reporting that recovered timeout as pending would name a phase the run
        passed, so the pending field follows the last wait while the timeline
        keeps the timeout.
        """
        with self.assertRaises(TimeoutError):
            driver.wait_for(FakeSocket(false_answers=1000), "expression", 0,
                            "the artifact fetch to resolve")
        driver.wait_for(FakeSocket(), "expression", 5, "the Review button to appear")
        driver.wait_for(FakeSocket(), "expression", 5, "the review to settle")
        summary = driver.phase_timeline_summary()
        self.assertEqual(summary["last_completed_phase"], "the review to settle")
        self.assertIsNone(summary["pending_phase"])
        self.assertIsNone(summary["pending_phase_deadline_s"])
        self.assertEqual(
            [record["outcome"] for record in summary["phases"]],
            ["timed_out", "completed", "completed"])

    def test_a_wait_that_returns_on_the_last_permitted_poll_completes(self):
        """A run finishing against its budget is a completion, not a timeout.

        wait_for polls while the clock is under the deadline and sleeps half a
        second between polls, so a two-second budget permits polls at 0.0,
        0.5, 1.0, and 1.5. The socket answers falsely through the first three,
        which puts the answer on the last poll the budget allows and the
        record on the boundary rather than comfortably inside it.
        """
        socket = FakeSocket(false_answers=3)
        value = driver.wait_for(socket, "expression", 2, "the turn to end")
        self.assertEqual(value, "value")
        self.assertEqual(socket.calls, 4)
        record = driver.phase_timeline_summary()["phases"][0]
        self.assertEqual(record["outcome"], "completed")
        self.assertEqual(record["deadline_s"], 2)
        self.assertGreaterEqual(record["elapsed_s"], 1.4)
        self.assertLess(record["elapsed_s"], record["deadline_s"])

    def test_a_phase_name_carrying_a_newline_stays_on_one_line(self):
        """One phase name is built from --model rather than from a literal.

        The classifier reads a line-oriented format with sed, so a value
        carrying a newline would present its tail as another key.
        """
        with self.assertRaises(TimeoutError):
            driver.wait_for(FakeSocket(false_answers=1000), "expression", 0,
                            "the page to select --model a\nstate=report_missing")
        pending = driver.phase_timeline_summary()["pending_phase"]
        self.assertIn("\n", pending)
        self.assertEqual(" ".join(str(pending).split()),
                         "the page to select --model a state=report_missing")

    def test_the_timeline_resets_between_runs(self):
        driver.wait_for(FakeSocket(), "expression", 5, "the page to load")
        driver.phase_timeline_reset()
        summary = driver.phase_timeline_summary()
        self.assertEqual(summary["phases"], [])
        self.assertIsNone(summary["last_completed_phase"])


if __name__ == "__main__":
    result = unittest.main(argv=[sys.argv[0], "-v"], exit=False).result
    print("drive_fallback_page_phases=%s tests=%s" %
          ("accepted" if result.wasSuccessful() else "refused", result.testsRun))
    sys.exit(0 if result.wasSuccessful() else 1)
