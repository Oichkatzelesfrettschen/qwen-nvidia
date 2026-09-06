#!/usr/bin/env python3
"""Hold read-serialized-review-timeline.py to the sequence it claims to read."""
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "timeline", os.path.join(HERE, "read-serialized-review-timeline.py"))
timeline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(timeline)

LANGUAGE = "4242, /opt/qwen/bin/llama-server, 2900 MiB"
RUNTIME = "5151, /opt/qwen/sd/bin/sd-cli, 1200 MiB"
REVIEWER = "6161, /opt/qwen/bin/llama-server, 1300 MiB"


def sample(stamp, lease, clients, memory):
    rows = ["%s\t%s\tclient\t%s" % (stamp, lease, client) for client in clients]
    rows.append("%s\t%s\tmemory\t%s MiB" % (stamp, lease, memory))
    rows.append("%s\t%s\ttick" % (stamp, lease))
    return rows


def serialized_sequence():
    rows = []
    rows += sample(100.0, "free", [LANGUAGE], 4700)
    rows += sample(100.1, "held", [LANGUAGE, RUNTIME], 5900)
    rows += sample(100.2, "held", [LANGUAGE, RUNTIME], 6100)
    rows += sample(100.3, "free", [LANGUAGE], 4700)
    rows += sample(100.4, "free", [LANGUAGE], 4700)
    rows += sample(100.5, "free", [LANGUAGE, REVIEWER], 5200)
    rows += sample(100.6, "free", [LANGUAGE, REVIEWER], 6000)
    rows += sample(100.7, "free", [LANGUAGE, REVIEWER], 6000)
    rows += sample(100.8, "free", [LANGUAGE], 4700)
    return rows


def write(rows):
    handle = tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False)
    handle.write("\n".join(rows) + "\n")
    handle.close()
    return handle.name


class TimelineTest(unittest.TestCase):
    def read(self, rows):
        path = write(rows)
        try:
            return timeline.analyze(timeline.parse_rows(path), "sd-cli")
        finally:
            os.unlink(path)

    def test_a_reviewer_after_the_release_reads_serialized(self):
        result = self.read(serialized_sequence())
        self.assertEqual(result["initial_server_pids"], [4242])
        self.assertEqual(result["runtime"]["samples"], 2)
        self.assertEqual(result["runtime"]["peak_client_mib"], 1200)
        self.assertEqual(result["lease_release_after_runtime"], 100.3)
        self.assertEqual(result["reviewer"]["pids"], [6161])
        self.assertTrue(result["serialized"])
        self.assertAlmostEqual(result["reviewer_after_release_s"], 0.2)
        memory = result["device_memory_mib"]
        self.assertEqual(memory["before_generation"], 4700)
        self.assertEqual(memory["during_generation"], 6100)
        self.assertEqual(memory["during_review"], 6000)
        self.assertEqual(memory["floor_from_the_reviewers_first_sample"], 4700)

    def test_a_reviewer_seen_while_the_runtime_runs_refutes_it(self):
        rows = []
        rows += sample(100.0, "free", [LANGUAGE], 4700)
        rows += sample(100.1, "held", [LANGUAGE, RUNTIME], 5900)
        rows += sample(100.2, "held", [LANGUAGE, RUNTIME, REVIEWER], 7200)
        rows += sample(100.3, "free", [LANGUAGE, REVIEWER], 6000)
        rows += sample(100.4, "free", [LANGUAGE], 4700)
        result = self.read(rows)
        self.assertFalse(result["serialized"])

    def test_a_lease_held_during_the_review_refutes_it(self):
        # The overlap the lease exists to prevent, with the ordering check
        # passing: the reviewer appears after the runtime and after the first
        # free tick, and a later tick reads held.
        rows = []
        rows += sample(100.0, "free", [LANGUAGE], 4700)
        rows += sample(100.1, "held", [LANGUAGE, RUNTIME], 5900)
        rows += sample(100.2, "free", [LANGUAGE], 4700)
        rows += sample(100.3, "free", [LANGUAGE, REVIEWER], 6000)
        rows += sample(100.4, "held", [LANGUAGE, REVIEWER], 6000)
        rows += sample(100.5, "free", [LANGUAGE, REVIEWER], 6000)
        result = self.read(rows)
        self.assertFalse(result["serialized"])
        self.assertEqual(result["held_ticks_during_review"], 1)

    def test_the_floor_reads_every_sample_from_the_reviewers_first(self):
        rows = serialized_sequence()
        result = self.read(rows)
        self.assertEqual(result["device_memory_mib"]["floor_from_the_reviewers_first_sample"], 4700)
        self.assertEqual(result["floor_samples"], 4)

    def test_a_named_reviewer_pid_excludes_every_other_new_server(self):
        # A language child restarted mid-run appears as a new pid; naming the
        # reviewer's own pid keeps that process out of the reviewer window.
        restarted = "7171, /opt/qwen/bin/llama-server, 900 MiB"
        rows = []
        rows += sample(100.0, "free", [LANGUAGE], 4700)
        rows += sample(100.1, "held", [LANGUAGE, RUNTIME], 5900)
        rows += sample(100.2, "free", [LANGUAGE, restarted], 5000)
        rows += sample(100.3, "free", [LANGUAGE, restarted, REVIEWER], 6000)
        rows += sample(100.4, "free", [LANGUAGE, restarted, REVIEWER], 6000)
        path = write(rows)
        try:
            named = timeline.analyze(timeline.parse_rows(path), "sd-cli", reviewer_pid=6161)
            unnamed = timeline.analyze(timeline.parse_rows(path), "sd-cli")
        finally:
            os.unlink(path)
        self.assertEqual(named["reviewer"]["pids"], [6161])
        self.assertEqual(named["reviewer"]["first_seen"], 100.3)
        self.assertEqual(unnamed["reviewer"]["pids"], [6161, 7171])
        self.assertEqual(unnamed["reviewer"]["first_seen"], 100.2)

    def test_a_reviewer_seen_before_the_lease_frees_refutes_it(self):
        rows = []
        rows += sample(100.0, "free", [LANGUAGE], 4700)
        rows += sample(100.1, "held", [LANGUAGE, RUNTIME], 5900)
        rows += sample(100.2, "held", [LANGUAGE, REVIEWER], 6000)
        rows += sample(100.3, "free", [LANGUAGE, REVIEWER], 6000)
        result = self.read(rows)
        self.assertFalse(result["serialized"])

    def test_an_unobserved_runtime_is_stated_rather_than_inferred(self):
        rows = []
        rows += sample(100.0, "free", [LANGUAGE], 4700)
        rows += sample(100.1, "free", [LANGUAGE], 4700)
        rows += sample(100.2, "free", [LANGUAGE, REVIEWER], 6000)
        result = self.read(rows)
        self.assertEqual(result["runtime"], "not_observed")
        self.assertIsNone(result["serialized"])
        self.assertEqual(result["reviewer"]["samples"], 1)

    def test_an_unobserved_reviewer_is_stated_rather_than_inferred(self):
        rows = []
        rows += sample(100.0, "free", [LANGUAGE], 4700)
        rows += sample(100.1, "held", [LANGUAGE, RUNTIME], 5900)
        rows += sample(100.2, "free", [LANGUAGE], 4700)
        result = self.read(rows)
        self.assertEqual(result["reviewer"], "not_observed")
        self.assertIsNone(result["serialized"])
        self.assertEqual(result["lease_release_after_runtime"], 100.2)

    def test_the_language_child_is_every_server_in_the_first_sample(self):
        second = "4343, /opt/qwen/bin/llama-server, 100 MiB"
        rows = serialized_sequence()
        rows.insert(0, "100.0\tfree\tclient\t%s" % second)
        result = self.read(rows)
        self.assertEqual(result["initial_server_pids"], [4242, 4343])
        self.assertEqual(result["reviewer"]["pids"], [6161])

    def test_a_malformed_row_is_refused(self):
        path = write(["100.0\tfree", "100.1\tmaybe\ttick", "100.2\tfree\tunknown"])
        try:
            for bad in (["100.0\tfree"], ["100.1\tmaybe\ttick"], ["100.2\tfree\tunknown"], ["x\tfree\ttick"]):
                bad_path = write(bad)
                try:
                    with self.assertRaises(ValueError):
                        timeline.parse_rows(bad_path)
                finally:
                    os.unlink(bad_path)
        finally:
            os.unlink(path)

    def test_an_empty_file_is_refused(self):
        path = write([])
        try:
            with self.assertRaises(ValueError):
                timeline.parse_rows(path)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
