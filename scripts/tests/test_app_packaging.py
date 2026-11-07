"""Exercise packaging argument/preflight behavior without compiling an engine."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppPackagingTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="glims-package-test-")
        self.root = Path(self.work.name)
        (self.root / "scripts").mkdir()
        for name in ("build-app.sh", "engine.env"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        # If preflight succeeds, stop at Swift. No test should build or modify
        # a real bundle or engine; this marks that the chosen mode reached it.
        tools = self.root / "tools"
        tools.mkdir()
        swift = tools / "swift"
        swift.write_text("#!/bin/sh\necho reached-swift >&2\nexit 42\n")
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])

    def tearDown(self):
        self.work.cleanup()

    def run_build(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/build-app.sh"), *args],
                              env=self.env, capture_output=True, text=True)

    def test_normal_build_requires_engine_before_compiling(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Glims needs its image engine", result.stderr)
        self.assertNotIn("reached-swift", result.stderr)
        self.assertFalse((self.root / "dist/Glims.app").exists())

    def test_normal_build_selects_pinned_engine(self):
        pinned = (ROOT / "scripts/engine.env").read_text().split('ENGINE_SETS="')[1].split(':')[0]
        (self.root / "_engine/install" / pinned).mkdir(parents=True)
        adapter = self.root / "_engine/adapter" / pinned / "libglimsengine.dylib"
        adapter.parent.mkdir(parents=True)
        adapter.touch()
        result = self.run_build()
        self.assertEqual(result.returncode, 42)
        self.assertIn("reached-swift", result.stderr)

    def test_shell_only_is_explicit(self):
        result = self.run_build("--shell-only")
        self.assertEqual(result.returncode, 42)
        self.assertIn("reached-swift", result.stderr)

    def test_mutually_exclusive_options_in_both_orders(self):
        for args in [("--shell-only", "--engine", "master"),
                     ("--engine", "master", "--shell-only")]:
            with self.subTest(args=args):
                self.assertEqual(self.run_build(*args).returncode, 2)

    def test_explicit_engine_is_checked(self):
        result = self.run_build("--engine", "missing-test-engine")
        self.assertEqual(result.returncode, 1)
        self.assertIn("build-engine.sh missing-test-engine", result.stderr)


if __name__ == "__main__":
    unittest.main()
