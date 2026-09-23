"""Compile the patched destroy prologue against CPU-only lease fixtures.

The prologue comes from the closure's patch; the fixture replaces lease and
device operations and requires an ownership record before synchronization.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent
PATCH_FILE = SCRIPTS.parent / "patches/llama-server-vulkan-workload-lease.patch"
OBSERVATION = '''        if (!workload_lease_held) {
            workload_lease_acquire_bounded(0);
        }
        SRV_INF("vulkan workload lease teardown: held=%s\\n",
                workload_lease_held ? "yes" : "no");'''
CONDITIONAL_OBSERVATION = '''        if (!workload_lease_held) {
            workload_lease_acquire_bounded(0);
            SRV_INF("vulkan workload lease teardown: held=%s\\n",
                    workload_lease_held ? "yes" : "no");
        }'''

FIXTURE = r'''
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

struct teardown_fixture {
    bool workload_lease_held;
    bool lease_configured;
    bool lease_available;
    int acquire_calls = 0;
    std::vector<std::string> events;

    bool workload_lease_acquire_bounded(int wait_seconds) {
        if (wait_seconds != 0) {
            throw std::runtime_error("teardown acquire must be nonblocking");
        }
        ++acquire_calls;
        if (lease_configured && lease_available) {
            workload_lease_held = true;
        }
        return !lease_configured || workload_lease_held;
    }

    void SRV_INF(const char * format, const char * ownership) {
        char record[128];
        const int length = std::snprintf(record, sizeof(record), format, ownership);
        if (length < 0 || static_cast<size_t>(length) >= sizeof(record)) {
            throw std::runtime_error("invalid ownership observation");
        }
        events.emplace_back(record);
    }

    void workload_lease_sync_device() {
        events.emplace_back("synchronize");
    }

DESTROY_PROLOGUE
        events.emplace_back("first_free");
    }
};

static bool check_case(const char * name, bool initially_held, bool configured,
                       bool available, bool expected_held, int expected_acquires) {
    teardown_fixture fixture{initially_held, configured, available, 0, {}};
    fixture.destroy();
    const std::vector<std::string> expected = {
        std::string("vulkan workload lease teardown: held=") +
            (expected_held ? "yes\n" : "no\n"),
        "synchronize", "first_free"
    };
    const bool passed = fixture.events == expected &&
                        fixture.acquire_calls == expected_acquires &&
                        fixture.workload_lease_held == expected_held;
    std::printf("%s=%s\n", name, passed ? "passed" : "failed");
    return passed;
}

int main() {
    bool passed = true;
    passed &= check_case("active_retained", true, true, false, true, 0);
    passed &= check_case("idle_reacquired", false, true, true, true, 1);
    passed &= check_case("idle_contended", false, true, false, false, 1);
    passed &= check_case("lease_unconfigured", false, false, true, false, 1);
    return passed ? 0 : 1;
}
'''


def destroy_prologue():
    """Read the postimage through synchronization and before the first free."""
    patch_lines = PATCH_FILE.read_text(encoding="utf-8").splitlines()
    first = patch_lines.index("     void destroy() {")
    last = patch_lines.index("         spec.reset();", first)
    lines = patch_lines[first:last]
    if any(line[:1] not in {"+", " ", "-"} for line in lines):
        raise AssertionError("destroy prologue crosses a patch hunk boundary")
    return "\n".join(line[1:] for line in lines if line[:1] != "-")


class TeardownObservationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = os.environ.get("QWEN_HOST_CXX")
        cls.compiler = compiler or shutil.which("g++-15") or shutil.which("g++")
        if not cls.compiler:
            raise RuntimeError("QWEN_HOST_CXX must name an available C++ compiler")
        ancestors = [path for path in SCRIPTS.parents if path.name == ".local-artifacts"]
        boundary = ancestors[-1] if ancestors else SCRIPTS.parent / ".local-artifacts"
        boundary.mkdir(exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(
            prefix="lease-teardown-observation-", dir=boundary)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)

    def run_fixture(self, prologue, name):
        source = self.directory / f"{name}.cpp"
        binary = self.directory / name
        source.write_text(FIXTURE.replace("DESTROY_PROLOGUE", prologue), encoding="utf-8")
        compilation = subprocess.run(
            [self.compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
             str(source), "-o", str(binary)],
            text=True, capture_output=True, timeout=30, check=False)
        self.assertEqual(compilation.returncode, 0, compilation.stderr)
        return subprocess.run(
            [str(binary)], text=True, capture_output=True, timeout=5, check=False)

    def test_every_destroy_reports_ownership_before_free(self):
        result = self.run_fixture(destroy_prologue(), "patched")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "active_retained=passed", "idle_reacquired=passed",
            "idle_contended=passed", "lease_unconfigured=passed"])

    def test_conditional_observation_mutation_is_rejected(self):
        prologue = destroy_prologue()
        self.assertEqual(prologue.count(OBSERVATION), 1)
        mutation = prologue.replace(OBSERVATION, CONDITIONAL_OBSERVATION)
        result = self.run_fixture(mutation, "conditional-mutation")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "active_retained=failed", "idle_reacquired=passed",
            "idle_contended=passed", "lease_unconfigured=passed"])


if __name__ == "__main__":
    unittest.main()
