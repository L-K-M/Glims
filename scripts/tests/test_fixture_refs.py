"""Exercise fixture-script paths in a disposable fake engine tree."""
import ast
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(__file__).resolve().parents[2]


class FixtureReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glims-fixture-refs-")
        self.addCleanup(self.temporary.cleanup)
        # Also exercise paths that cannot be interpolated into a Python literal.
        self.root = Path(self.temporary.name) / "repo's path"
        scripts = self.root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("engine-common.sh", "make-fixtures.sh", "make-qmask-fixture.sh"):
            shutil.copy2(SOURCE_ROOT / "scripts" / name, scripts / name)
        (scripts / "engine.env").write_text('ENGINE_SETS="safe:x:y victim:x:y"\n')
        self.engine = self.root / "_engine"

    def fake_engine(self, ref):
        console = self.engine / "install" / ref / "bin" / "gimp-console"
        console.parent.mkdir(parents=True, exist_ok=True)
        console.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
if "--version" in sys.argv:
    print("fixture test engine")
    raise SystemExit(0)
out = pathlib.Path(os.environ["GLIMS_FIXTURE_DIR"])
for name in ("composite.xcf", "composite.png", "text-units.xcf", "qmask-name.xcf"):
    (out / name).write_bytes(b"fixture")
(out / "invocation.json").write_text(json.dumps({
    "batch": sys.argv[sys.argv.index("-b") + 1],
    "script": os.environ.get("GLIMS_FIXTURE_SCRIPT"),
}))
''')
        console.chmod(0o755)
        return console

    def run_script(self, name, ref):
        return subprocess.run(["/bin/bash", str(self.root / "scripts" / name), ref],
                              capture_output=True, text=True, timeout=15)

    def test_traversal_is_refused_before_deleting_anything(self):
        for script, prefix in (("make-fixtures.sh", ""), ("make-qmask-fixture.sh", "qmask-")):
            with self.subTest(script=script):
                # Both the install preflight and the rm path resolve in this
                # fake tree. Unfixed scripts delete only this test's sentinel.
                self.fake_engine("safe")
                victim = self.engine / "install" / "victim"
                self.fake_engine("victim")
                marker = victim / "must-survive"
                marker.write_text("unrelated engine build")
                (self.engine / "fixture-work" / f"{prefix}safe").mkdir(parents=True, exist_ok=True)
                result = self.run_script(script, "safe/../../install/victim")
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(marker.exists(), "invalid ref deleted another engine's install tree")

    def test_unknown_ref_is_refused_even_with_an_installed_console(self):
        self.fake_engine("unlisted")
        for script in ("make-fixtures.sh", "make-qmask-fixture.sh"):
            with self.subTest(script=script):
                result = self.run_script(script, "unlisted")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "Engine/tests/fixtures/invocation.json").exists())

    def test_known_ref_works_with_spaces_and_quotes_in_the_repository_path(self):
        self.fake_engine("safe")
        for script, program in (("make-fixtures.sh", "make-fixtures.py"),
                                ("make-qmask-fixture.sh", "make-qmask-fixture.py")):
            with self.subTest(script=script):
                result = self.run_script(script, "safe")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                invocation = json.loads((self.root / "Engine/tests/fixtures/invocation.json").read_text())
                ast.parse(invocation["batch"])
                self.assertEqual(invocation["script"], str(self.root / "Engine/tests" / program))


if __name__ == "__main__":
    unittest.main()
