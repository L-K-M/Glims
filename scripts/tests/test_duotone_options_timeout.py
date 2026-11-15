"""A timed-out codec runner must not leave compiler descendants running."""
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DuotoneOptionsTimeoutTests(unittest.TestCase):
    def test_timeout_stops_compiler_descendant(self):
        self.exercise_runner(interrupt=False)

    def test_termination_stops_compiler_descendant(self):
        self.exercise_runner(interrupt=True)

    def exercise_runner(self, interrupt):
        if not shutil.which("python3"):
            self.skipTest("python3 is required")
        with tempfile.TemporaryDirectory(prefix="glims-duotone-timeout-") as folder:
            work = Path(folder)
            (work / "scripts").mkdir()
            (work / "tools").mkdir()
            source = (ROOT / "scripts/test-duotone-options.sh").read_text()
            self.assertEqual(source.count("timeout=60"), 1)
            (work / "scripts/test-duotone-options.sh").write_text(source.replace("timeout=60", "timeout=0.5"))
            compiler = work / "tools/clang"
            compiler.write_text("#!/usr/bin/env python3\n"
                "import os, pathlib, subprocess, sys, time\n"
                "code = 'import pathlib,sys,time; time.sleep(1.5); pathlib.Path(sys.argv[1]).write_text(\\\"escaped\\\")'\n"
                "child = subprocess.Popen([sys.executable, '-c', code, os.environ['GLIMS_TIMEOUT_MARKER']], "
                "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
                "pathlib.Path(os.environ['GLIMS_TIMEOUT_CHILD']).write_text(str(child.pid))\n"
                "time.sleep(10)\n")
            compiler.chmod(0o755)
            xcrun = work / "tools/xcrun"
            xcrun.write_text("#!/bin/sh\n[ \"$1\" = clang ] || exit 2\nshift\nexec clang \"$@\"\n")
            xcrun.chmod(0o755)
            marker, child = work / "escaped", work / "child"
            env = dict(os.environ, PATH=str(work / "tools") + os.pathsep + os.environ["PATH"],
                       GLIMS_TIMEOUT_MARKER=str(marker), GLIMS_TIMEOUT_CHILD=str(child))
            command = ["bash", str(work / "scripts/test-duotone-options.sh"), "sanitized"]
            if interrupt:
                process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
                try:
                    deadline = time.monotonic() + 5
                    while not child.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(child.exists(), "the compiler did not start its child")
                    os.killpg(process.pid, signal.SIGTERM)
                    process.communicate(timeout=5)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
            else:
                result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertTrue(child.exists(), "the compiler did not start its child")
            time.sleep(1.8)
            self.assertFalse(marker.exists(), "the compiler descendant survived the timeout")


if __name__ == "__main__":
    unittest.main()
