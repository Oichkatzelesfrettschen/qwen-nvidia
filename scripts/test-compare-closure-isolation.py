#!/usr/bin/env python3
"""Hold the closure isolation reader to fixtures whose answer is declared.

A reader that reports isolation on every input decides nothing, so arms build
fixtures whose changed translation unit does reach a device target and whose
two closures carry different device code, and require the refutation. The
three-valued verdict is what the remaining arms hold: an unread device payload,
an untraced source, a graph carrying syntax the parser does not evaluate, a
source tree whose contents no longer match the digest its build recorded, and a
disassembly that exited zero having printed no function each leave the
isolation not established rather than held.

The sanitizer arm runs the reader under a HOME of its own and also plants a
path outside it, since a sanitizer that only rewrites the home prefix passes
the first check and leaks the second.
"""

import hashlib
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
READER = HERE / "compare-closure-isolation.py"

CONFIGURATION = """configuration_schema\t2
actual_commit\tf280b26983ad0fdb705a0d9ebf0503e76f2899b0
source_diff_sha256\t%s
arch\t89-real
graphs\t%s
"""

# The stub prints the text file beside the library it is asked to disassemble,
# so a fixture declares its own device code the way the real payload carries it.
CUOBJDUMP_STUB = """#!/bin/sh
set -eu
[ "$1" = -sass ] || exit 2
cat "$2.sass"
"""

SASS = """\tcode for sm_89
\t\tFunction : _Z1kIXadL_ZN42_INTERNAL_%s_11_binbcast_cuEEE
        /*0000*/                   IMAD.MOV.U32 R1, RZ, RZ, c[0x0][0x28] ;
        /*0010*/                   %s ;
"""

OBJECT = "tools/server/CMakeFiles/server-context.dir/server-context.cpp.o"
DEVICE_OBJECT = "tools/server/CMakeFiles/server-context.dir/second.cpp.o"
SOURCE = "tools/server/server-context.cpp"


def git(*arguments, cwd):
    subprocess.run(("git",) + arguments, cwd=cwd, check=True,
                   capture_output=True, text=True)


class ClosureFixture:
    """One build directory beside the source tree its CMakeCache names."""

    def __init__(self, root, name, source_text, graphs="ON",
                 module_identifier="79f023fe", instruction="NOP",
                 sass=SASS, extra_files=(), source=None, digest_override=None):
        self.source = source or (root / ("source-" + name))
        self.build = root / ("build-" + name)
        if source is None:
            (self.source / "tools/server").mkdir(parents=True)
            git("init", "-q", "-b", "main", cwd=self.source)
            git("config", "user.email", "fixture@example.invalid", cwd=self.source)
            git("config", "user.name", "fixture", cwd=self.source)
            for relative in (SOURCE,) + tuple(extra_files):
                (self.source / relative).write_text("base\n")
            git("add", "-A", cwd=self.source)
            git("commit", "-q", "-m", "pin", cwd=self.source)
            (self.source / SOURCE).write_text(source_text)
        self.build.mkdir()
        (self.build / "bin").mkdir()
        (self.build / "build-configuration.tsv").write_text(
            CONFIGURATION % (digest_override or self.diff_digest(), graphs))
        (self.build / "CMakeCache.txt").write_text(
            "CMAKE_HOME_DIRECTORY:INTERNAL=%s\n" % self.source)
        library = self.build / "bin/libggml-cuda.so.0.21.0"
        library.write_text("payload\n")
        pathlib.Path(str(library) + ".sass").write_text(
            sass % (module_identifier, instruction) if "%s" in sass else sass)

    def diff_digest(self):
        completed = subprocess.run(
            ["git", "-C", str(self.source), "diff", "--binary", "HEAD", "--"],
            capture_output=True, check=True)
        return hashlib.sha256(completed.stdout).hexdigest()

    def modify(self, relative, text):
        (self.source / relative).write_text(text)
        (self.build / "build-configuration.tsv").write_text(
            CONFIGURATION % (self.diff_digest(), "ON"))

    def write_ninja(self, text):
        (self.build / "build.ninja").write_text(text)

    def edges(self, pairs):
        self.write_ninja("".join(
            "build %s: RULE %s\n" % (" ".join(outputs), " ".join(inputs))
            for outputs, inputs in pairs))

    def host_only_graph(self):
        self.edges([
            ([OBJECT], [str(self.source / SOURCE)]),
            (["bin/libllama-server-impl.so"], [OBJECT]),
            (["bin/llama-server"], ["bin/libllama-server-impl.so"]),
            (["bin/libggml-cuda.so.0.21.0"], ["ggml/src/ggml-cuda/mmq.cu.o"]),
        ])

    def device_reaching_graph(self):
        self.edges([
            ([OBJECT], [str(self.source / SOURCE)]),
            (["bin/libggml-cuda.so.0.21.0"], [OBJECT]),
        ])

    def untraced_graph(self):
        self.edges([(["bin/libggml-cuda.so.0.21.0"],
                     ["ggml/src/ggml-cuda/mmq.cu.o"])])

    def unevaluated_graph(self):
        self.host_only_graph()
        with (self.build / "build.ninja").open("a") as handle:
            handle.write("build ${workdir}tools/ui/assets: RULE tools/ui/ui.cpp\n")

    def relative_second_object_graph(self):
        """One object named by absolute path, a second by relative path."""
        self.edges([
            ([OBJECT], [str(self.source / SOURCE)]),
            (["bin/libllama-server-impl.so"], [OBJECT]),
            ([DEVICE_OBJECT], [SOURCE]),
            (["bin/libggml-cuda.so.0.21.0"], [DEVICE_OBJECT]),
        ])


class CompareClosureIsolationTest(unittest.TestCase):

    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self._temporary.name)
        self.addCleanup(self._temporary.cleanup)
        self.out = self.root / "out"
        self.cuobjdump = self.root / "cuobjdump"
        self.cuobjdump.write_text(CUOBJDUMP_STUB)
        self.cuobjdump.chmod(0o755)

    def run_reader(self, control, subject, skip_device_code=False):
        command = [sys.executable, str(READER), str(control.build),
                   str(subject.build), "--out", str(self.out),
                   "--cuobjdump", str(self.cuobjdump)]
        if skip_device_code:
            command.append("--skip-device-code")
        completed = subprocess.run(command, capture_output=True, text=True,
                                   env={"PATH": "/usr/bin:/bin",
                                        "HOME": str(self.root)})
        return completed.returncode, completed.stdout + completed.stderr

    def pair(self, graph="host_only_graph", control_arguments=None,
             **subject_arguments):
        control = ClosureFixture(self.root, "control", "base\n",
                                 **(control_arguments or {}))
        subject = ClosureFixture(self.root, "subject", "base\nlease\n",
                                 **subject_arguments)
        for fixture in (control, subject):
            getattr(fixture, graph)()
        return control, subject

    def test_a_host_only_change_with_agreeing_device_code_holds_the_isolation(self):
        control, subject = self.pair(module_identifier="1a52790f")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 0, output)
        self.assertIn("configuration_axes=1", output)
        self.assertIn("differing_sources=1", output)
        self.assertIn("device_targets_reached=0", output)
        self.assertIn("source_binding closure=control", output)
        self.assertIn("match=yes", output)
        self.assertIn("device_code=identical", output)
        self.assertIn("device_path_isolation=held", output)

    def test_an_unread_device_payload_leaves_the_isolation_not_established(self):
        control, subject = self.pair()
        status, output = self.run_reader(control, subject, skip_device_code=True)
        self.assertEqual(status, 4, output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_a_disassembly_carrying_no_function_is_not_a_device_reading(self):
        control, subject = self.pair(sass="\n", control_arguments={"sass": "\n"})
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("control_functions=0", output)
        self.assertIn("device_code=unavailable", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_differing_device_code_refutes_the_isolation(self):
        control, subject = self.pair(instruction="FADD R0, R1, R2")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 1, output)
        self.assertIn("device_code=differs", output)
        self.assertIn("device_path_isolation=refuted", output)

    def test_two_distinct_module_identifiers_stay_distinct(self):
        # One placeholder for every identifier would merge these two symbols
        # and hide the instruction difference between them.
        collide = ("\t\tFunction : _ZN42_INTERNAL_aaaaaaaa_11_binbcast_cuE\n"
                   "        /*0000*/  %s ;\n"
                   "\t\tFunction : _ZN42_INTERNAL_bbbbbbbb_8_unary_cuE\n"
                   "        /*0000*/  NOP ;\n")
        control = ClosureFixture(self.root, "control", "base\n",
                                 sass=collide % "NOP")
        subject = ClosureFixture(self.root, "subject", "base\nlease\n",
                                 sass=collide % "FADD R0, R1, R2")
        for fixture in (control, subject):
            fixture.host_only_graph()
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 1, output)
        self.assertIn("device_code=differs", output)

    def test_two_identifiers_naming_one_unit_leave_the_reading_unresolved(self):
        # Both map to the placeholder their shared unit derives, so a call site
        # naming one where the other side names the other digests identically.
        shared = ("\t\tFunction : _ZN42_INTERNAL_%s_11_binbcast_cuE\n"
                  "        /*0000*/  NOP ;\n"
                  "\t\tFunction : _ZN42_INTERNAL_%s_11_binbcast_cuE\n"
                  "        /*0000*/  NOP ;\n") % ("aaaaaaaa", "cccccccc")
        control = ClosureFixture(self.root, "control", "base\n", sass=shared)
        subject = ClosureFixture(self.root, "subject", "base\nlease\n",
                                 sass=shared)
        for fixture in (control, subject):
            fixture.host_only_graph()
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("injective=no", output)
        self.assertIn("device_code=unresolved_identifiers", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_graphs_disagreeing_away_from_bin_are_not_established(self):
        # A consumer closure is compared whole; comparing reachable artifacts
        # alone would call these two graphs equal.
        control, subject = self.pair(module_identifier="1a52790f")
        with (subject.build / "build.ninja").open("a") as handle:
            handle.write("build other/extra.stamp: RULE %s\n" % OBJECT)
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("graph_disagreements=1", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_a_change_reaching_a_device_target_refutes_the_isolation(self):
        control, subject = self.pair(graph="device_reaching_graph")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 1, output)
        self.assertNotIn("device_targets_reached=0", output)
        self.assertIn("device_path_isolation=refuted", output)

    def test_a_second_object_named_by_relative_path_is_traced_too(self):
        control, subject = self.pair(graph="relative_second_object_graph",
                                     module_identifier="1a52790f")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 1, output)
        self.assertIn(DEVICE_OBJECT, output)
        self.assertIn("device_path_isolation=refuted", output)

    def test_a_source_ninja_traces_to_no_object_is_not_established(self):
        control, subject = self.pair(graph="untraced_graph",
                                     module_identifier="1a52790f")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("untraced_sources=2", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_an_edge_the_parser_cannot_evaluate_is_not_established(self):
        control, subject = self.pair(graph="unevaluated_graph",
                                     module_identifier="1a52790f")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("edges_unevaluated=1", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_a_source_tree_that_moved_since_its_build_is_not_established(self):
        control, subject = self.pair(module_identifier="1a52790f")
        (subject.source / SOURCE).write_text("base\nlease\nlater\n")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("source_binding closure=subject", output)
        self.assertIn("match=no", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_two_builds_naming_one_source_tree_are_not_established(self):
        control = ClosureFixture(self.root, "control", "base\nlease\n")
        subject = ClosureFixture(self.root, "subject", "unused\n",
                                 source=control.source,
                                 digest_override="b" * 64)
        for fixture in (control, subject):
            fixture.host_only_graph()
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("source_paths_equal=yes", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_a_differing_path_carrying_a_space_is_counted(self):
        spaced = "tools/server/has space.cpp"
        control = ClosureFixture(self.root, "control", "base\n",
                                 extra_files=(spaced,))
        subject = ClosureFixture(self.root, "subject", "base\nlease\n",
                                 extra_files=(spaced,))
        subject.modify(spaced, "changed\n")
        for fixture in (control, subject):
            fixture.host_only_graph()
        _, output = self.run_reader(control, subject, skip_device_code=True)
        self.assertIn("differing_sources=2", output)

    def test_a_second_configuration_axis_ends_the_run(self):
        control, subject = self.pair(graphs="OFF")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 1, output)
        self.assertIn("configuration_axes=2", output)
        self.assertIn("comparison_refused reason=configuration_axes_not_source_alone",
                      output)
        self.assertNotIn("device_path_isolation=", output)

    def test_differing_build_paths_report_the_byte_comparison_unavailable(self):
        control, subject = self.pair(module_identifier="1a52790f")
        _, output = self.run_reader(control, subject)
        self.assertIn("source_paths_equal=no", output)
        self.assertIn("artifact_byte_comparison=unavailable reason=build_paths_differ",
                      output)

    def test_the_retained_rows_carry_no_absolute_path(self):
        control, subject = self.pair(module_identifier="1a52790f")
        # An absolute path outside HOME is what a home-prefix sanitizer misses.
        with (subject.build / "build.ninja").open("a") as handle:
            handle.write("build /opt/private/host.o: RULE %s\n"
                         % (subject.source / SOURCE))
        self.run_reader(control, subject)
        emitted = sorted(self.out.glob("*.tsv"))
        self.assertEqual(len(emitted), 4, emitted)
        for path in emitted:
            text = path.read_text()
            self.assertNotIn(str(self.root), text, path.name)
            self.assertNotIn("/opt/private", text, path.name)
        self.assertIn("$HOME", (self.out / "device-code.tsv").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
