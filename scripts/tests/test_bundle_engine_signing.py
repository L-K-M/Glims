"""Bundler.sign must propagate CODE_SIGN_IDENTITY into every inner Mach-O and
nested-app codesign command, keeping ad hoc '-' when it is unset or empty.
Pure mocked-command tests: no codesign, no build, a synthetic app tree."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "bundle-engine.py"
SPEC = importlib.util.spec_from_file_location("bundle_engine", SCRIPT)
bundle_engine = importlib.util.module_from_spec(SPEC)
import sys
sys.modules[SPEC.name] = bundle_engine
SPEC.loader.exec_module(bundle_engine)

MACHO = b"\xcf\xfa\xed\xfe" + b"\0" * 60
IDENTITY = "Apple Development"


class BundlerSignTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glims-sign-test-")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        app = root / "Glims.app"
        contents = app / "Contents"
        # Loose Mach-O files in every scanned top-level folder, the main
        # executable (excluded from inner signing), a non-Mach-O file, and
        # nested .app bundles at two depths under Contents/lib.
        self.macho_paths = []
        for relative in ("lib/libtest.dylib", "MacOS/python3", "Frameworks/libglimsengine.dylib",
                         "lib/Python.framework/Versions/3.13/Python.app/Contents/MacOS/Python"):
            path = contents / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(MACHO)
            self.macho_paths.append(str(path))
        main = contents / "MacOS/Glims"
        main.write_bytes(MACHO)
        typelib = contents / "lib/girepository-1.0/test.typelib"
        typelib.parent.mkdir(parents=True, exist_ok=True)
        typelib.write_text("not a Mach-O")
        self.app_paths = []
        for relative in ("lib/Python.framework/Versions/3.13/Python.app",
                         "lib/Helpers/Deep.app"):
            path = contents / relative
            path.mkdir(parents=True, exist_ok=True)
            self.app_paths.append(str(path))
        self.bundler = bundle_engine.Bundler(str(app), str(root / "install"), str(root / "prefix"),
                                             str(root / "adapter.dylib"), str(root / "sources"))

    def sign(self, env, fail=False):
        """Run Bundler.sign with a recording fake for run(); returns calls."""
        calls = []

        def fake_run(*args, **kwargs):
            calls.append(args)
            if fail:
                raise SystemExit(f"{' '.join(args[:2])} ... failed:\ncodesign error")
            return ""

        with mock.patch.dict(os.environ):
            for key, value in env.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
            with mock.patch.object(bundle_engine, "run", fake_run):
                try:
                    self.bundler.sign()
                finally:
                    self.calls = calls
        return calls

    def assert_identity(self, calls, expected_identity):
        self.assertTrue(calls, "no codesign command ran")
        for args in calls:
            self.assertEqual(args[:4], ("codesign", "--force", "--sign", expected_identity),
                             f"wrong identity in {args}")
        signed = [args[4] for args in calls]
        self.assertEqual(sorted(signed), sorted(self.macho_paths + self.app_paths))
        # Inner-first order: every loose Mach-O is signed before any nested app.
        macho_indexes = [i for i, args in enumerate(calls) if args[4] in self.macho_paths]
        app_indexes = [i for i, args in enumerate(calls) if args[4] in self.app_paths]
        self.assertTrue(macho_indexes and app_indexes)
        self.assertLess(max(macho_indexes), min(app_indexes))

    def test_explicit_identity_signs_every_macho_and_nested_app(self):
        calls = self.sign({"CODE_SIGN_IDENTITY": IDENTITY})
        self.assert_identity(calls, IDENTITY)

    def test_unset_identity_keeps_ad_hoc(self):
        calls = self.sign({"CODE_SIGN_IDENTITY": None})
        self.assert_identity(calls, "-")

    def test_empty_identity_keeps_ad_hoc(self):
        calls = self.sign({"CODE_SIGN_IDENTITY": ""})
        self.assert_identity(calls, "-")

    def test_signing_failure_propagates(self):
        with self.assertRaises(SystemExit) as caught:
            self.sign({"CODE_SIGN_IDENTITY": IDENTITY}, fail=True)
        self.assertIn("codesign", str(caught.exception))
        # The failure stops the sequence: no nested app is signed afterwards.
        self.assertEqual(len(self.calls), 1)
        self.assertIn(self.calls[0][4], self.macho_paths)


if __name__ == "__main__":
    unittest.main()
