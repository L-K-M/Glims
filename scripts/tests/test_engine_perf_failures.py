"""The performance verdict must not classify failed engine work as fast."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class EnginePerformanceFailures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="glims-perf-fault-")
        cls.directory = Path(cls.temporary.name)
        cls.runner = cls.directory / "perf"
        cls.library = cls.directory / "fault.dylib"
        include = str(ROOT / "Sources/CGlimsEngine/include")
        subprocess.run(["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", include, str(ROOT / "Engine/tests/engine-perf.c"),
                        "-o", str(cls.runner)], check=True)
        subprocess.run(["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-dynamiclib", "-I", include, str(ROOT / "Engine/tests/engine-perf-fault-stub.c"),
                        "-o", str(cls.library)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_fault(self, operation, occurrence):
        env = dict(os.environ, GLIMS_PERF_FAIL=operation, GLIMS_PERF_FAIL_AT=str(occurrence))
        env.pop("GLIMS_PERF_DELAY_LONG_BEGIN", None)
        return subprocess.run([str(self.runner), str(self.library), str(self.directory), "fixture.xcf"],
                              env=env, capture_output=True, text=True, timeout=30)

    def test_failed_engine_operations_never_report_a_valid_verdict(self):
        for operation, occurrence in [("info", 1), ("close", 1), ("open", 2), ("open", 3), ("render", 1),
                                      ("render", 2), ("render", 6), ("render", 249),
                                      ("render", 369), ("render", 400),
                                      ("layers", 1), ("layers", 2), ("begin", 1), ("continue", 1),
                                      ("end", 1), ("undo", 1), ("begin", 2),
                                      ("continue", 121), ("end", 2), ("undo", 2)]:
            with self.subTest(operation=operation, occurrence=occurrence):
                result = self.run_fault(operation, occurrence)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("WITHIN BUDGET:", result.stdout)
                self.assertNotIn("OVER BUDGET:", result.stdout)
                self.assertIn("failed", result.stderr.lower())

    def test_contention_samples_wait_for_the_stroke_to_begin(self):
        env = dict(os.environ, GLIMS_PERF_DELAY_LONG_BEGIN="1")
        env.pop("GLIMS_PERF_FAIL", None)
        env.pop("GLIMS_PERF_FAIL_AT", None)
        result = subprocess.run([str(self.runner), str(self.library), str(self.directory), "fixture.xcf"],
                                env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("render ran before the long stroke began", result.stderr)
        self.assertIn("viewport render while a stroke paints", result.stdout)
        self.assertRegex(result.stdout, r"(?:WITHIN|OVER) BUDGET: \d+ measurement")


if __name__ == "__main__":
    unittest.main()
