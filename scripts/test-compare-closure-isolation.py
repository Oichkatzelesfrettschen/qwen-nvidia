#!/usr/bin/env python3
"""Hold the closure isolation reader to fixtures whose answer is declared.

A reader that reports isolation on every input decides nothing, so one arm
builds a fixture whose changed translation unit does reach a device target and
requires the refutation, and another gives the two closures different device
code and requires the same. The three-valued verdict is what the remaining arms
hold: a device reading that did not run, and a differing source ninja traces to
no object, each leave the isolation not established rather than held, because a
positive claim needs two positive readings rather than one absent negative.

The sanitizer arm runs the reader under a HOME of its own so every fixture path
sits beneath it, which is what makes the retained rows testable against the
rule that keeps local absolute paths out of commits.
"""

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


def git(*arguments, cwd):
    subprocess.run(("git",) + arguments, cwd=cwd, check=True,
                   capture_output=True, text=True)


class ClosureFixture:
    """One build directory beside the source tree its CMakeCache names."""

    def __init__(self, root, name, source_text, diff_digest, graphs="ON",
                 module_identifier="79f023fe", instruction="NOP"):
        self.source = root / ("source-" + name)
        self.build = root / ("build-" + name)
        (self.source / "tools/server").mkdir(parents=True)
        (self.build / "bin").mkdir(parents=True)
        git("init", "-q", "-b", "main", cwd=self.source)
        git("config", "user.email", "fixture@example.invalid", cwd=self.source)
        git("config", "user.name", "fixture", cwd=self.source)
        (self.source / "tools/server/server-context.cpp").write_text("base\n")
        git("add", "-A", cwd=self.source)
        git("commit", "-q", "-m", "pin", cwd=self.source)
        (self.source / "tools/server/server-context.cpp").write_text(source_text)
        (self.build / "build-configuration.tsv").write_text(
            CONFIGURATION % (diff_digest, graphs))
        (self.build / "CMakeCache.txt").write_text(
            "CMAKE_HOME_DIRECTORY:INTERNAL=%s\n" % self.source)
        library = self.build / "bin/libggml-cuda.so.0.21.0"
        library.write_text("payload\n")
        pathlib.Path(str(library) + ".sass").write_text(
            SASS % (module_identifier, instruction))

    def write_ninja(self, edges):
        (self.build / "build.ninja").write_text(
            "".join("build %s: RULE %s\n" % (" ".join(outputs), " ".join(inputs))
                    for outputs, inputs in edges))

    def host_only_graph(self):
        self.write_ninja([
            ([OBJECT], [str(self.source / "tools/server/server-context.cpp")]),
            (["bin/libllama-server-impl.so"], [OBJECT]),
            (["bin/llama-server"], ["bin/libllama-server-impl.so"]),
            (["bin/libggml-cuda.so.0.21.0"], ["ggml/src/ggml-cuda/mmq.cu.o"]),
        ])

    def device_reaching_graph(self):
        self.write_ninja([
            ([OBJECT], [str(self.source / "tools/server/server-context.cpp")]),
            (["bin/libggml-cuda.so.0.21.0"], [OBJECT]),
        ])

    def untraced_graph(self):
        self.write_ninja([
            (["bin/libggml-cuda.so.0.21.0"], ["ggml/src/ggml-cuda/mmq.cu.o"]),
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
        return completed.returncode, completed.stdout

    def pair(self, graph="host_only_graph", **subject_arguments):
        control = ClosureFixture(self.root, "control", "base\n", "aaaa")
        subject = ClosureFixture(self.root, "subject", "base\nlease\n", "bbbb",
                                 **subject_arguments)
        for fixture in (control, subject):
            getattr(fixture, graph)()
        return control, subject

    def test_a_host_only_change_with_agreeing_device_code_holds_the_isolation(self):
        # The two closures carry distinct module identifiers, which is what the
        # real pair carries and what the normalization exists to absorb.
        control, subject = self.pair(module_identifier="1a52790f")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 0, output)
        self.assertIn("configuration_axes=1", output)
        self.assertIn("differing_sources=1", output)
        self.assertIn("device_targets_reached=0", output)
        self.assertIn("module_identifiers_normalized control=1 subject=1", output)
        self.assertIn("device_code=identical", output)
        self.assertIn("device_path_isolation=held", output)

    def test_an_unread_device_payload_leaves_the_isolation_not_established(self):
        control, subject = self.pair()
        status, output = self.run_reader(control, subject, skip_device_code=True)
        self.assertEqual(status, 4, output)
        self.assertIn("device_code=not_run reason=skip_requested", output)
        self.assertIn("device_path_isolation=not_established", output)

    def test_differing_device_code_refutes_the_isolation(self):
        control, subject = self.pair(instruction="FADD R0, R1, R2")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 1, output)
        self.assertIn("device_code=differs", output)
        self.assertIn("device_path_isolation=refuted", output)

    def test_a_change_reaching_a_device_target_refutes_the_isolation(self):
        control, subject = self.pair(graph="device_reaching_graph")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 1, output)
        self.assertNotIn("device_targets_reached=0", output)
        self.assertIn("device_path_isolation=refuted", output)

    def test_a_source_ninja_traces_to_no_object_is_not_established(self):
        control, subject = self.pair(graph="untraced_graph",
                                     module_identifier="1a52790f")
        status, output = self.run_reader(control, subject)
        self.assertEqual(status, 4, output)
        self.assertIn("untraced_sources=2", output)
        self.assertIn("device_code=identical", output)
        self.assertIn("device_path_isolation=not_established", output)

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
        self.assertIn("build_paths_equal=no", output)
        self.assertIn("artifact_byte_comparison=unavailable reason=build_paths_differ",
                      output)

    def test_the_retained_rows_carry_no_local_absolute_path(self):
        control, subject = self.pair(module_identifier="1a52790f")
        self.run_reader(control, subject)
        emitted = sorted(self.out.glob("*.tsv"))
        self.assertEqual(len(emitted), 4, emitted)
        for path in emitted:
            text = path.read_text()
            self.assertNotIn(str(self.root), text, path.name)
            self.assertNotIn("/home/", text, path.name)
        self.assertIn("$HOME", (self.out / "device-code.tsv").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
