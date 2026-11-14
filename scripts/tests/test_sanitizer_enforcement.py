"""Verify the Bitmap codec runner fails when UBSan detects real undefined behavior."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SanitizerEnforcementTests(unittest.TestCase):
    def test_bitmap_runner_rejects_undefined_behavior(self):
        clang = shutil.which("clang")
        self.assertIsNotNone(clang, "the test requires clang")
        with tempfile.TemporaryDirectory(prefix="glims-ubsan-test-") as folder:
            work = Path(folder)
            (work / "scripts").mkdir()
            (work / "Engine/tests").mkdir(parents=True)
            (work / "tools").mkdir()
            shutil.copy2(ROOT / "scripts/test-bitmap-psd-codec.sh", work / "scripts")
            for name in ("bitmap-psd-codec.c", "bitmap-psd-codec.h"):
                shutil.copy2(ROOT / "Engine" / name, work / "Engine")
            source = (ROOT / "Engine/tests/bitmap-psd-codec-tests.c").read_text()
            marker = "main (void)\n{"
            self.assertEqual(source.count(marker), 1)
            source = source.replace(marker, marker +
                "\n  volatile int glims_probe = 2147483647; glims_probe += 1;\n")
            (work / "Engine/tests/bitmap-psd-codec-tests.c").write_text(source)

            # The hosted macOS image can hang when ASan starts. Exercise the
            # real runner and its UBSan options with ASan removed, preserving
            # all other compiler arguments and the actual UBSan runtime.
            wrapper = work / "tools/clang"
            wrapper.write_text("#!/usr/bin/env python3\nimport os, sys\n"
                + "args = [a.replace('-fsanitize=address,undefined', '-fsanitize=undefined') "
                  "for a in sys.argv[1:]]\n"
                + f"os.execv({clang!r}, [{clang!r}, *args])\n")
            wrapper.chmod(0o755)
            xcrun = work / "tools/xcrun"
            xcrun.write_text("#!/bin/sh\n[ \"$1\" = clang ] || exit 2\nshift\nexec clang \"$@\"\n")
            xcrun.chmod(0o755)
            env = dict(os.environ, PATH=str(work / "tools") + os.pathsep + os.environ["PATH"],
                       UBSAN_OPTIONS="halt_on_error=0")
            result = subprocess.run(["bash", str(work / "scripts/test-bitmap-psd-codec.sh"), "sanitized"],
                                    env=env, text=True, capture_output=True, timeout=120)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("runtime error: signed integer overflow", result.stderr)


if __name__ == "__main__":
    unittest.main()
