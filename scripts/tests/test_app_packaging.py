"""Exercise packaging argument/preflight behavior without compiling an engine."""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppPackagingTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="glims-package-test-")
        self.root = Path(self.work.name)
        (self.root / "scripts").mkdir()
        for name in ("build-app.sh", "check-bundle.sh", "engine.env"):
            shutil.copy2(ROOT / "scripts" / name, self.root / "scripts" / name)
        # If preflight succeeds, stop at Swift. No test should build or modify
        # a real bundle or engine; this marks that the chosen mode reached it.
        tools = self.root / "tools"
        tools.mkdir()
        swift = tools / "swift"
        swift.write_text("#!/bin/sh\necho reached-swift >&2\nexit 42\n")
        swift.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])
        self.env.pop("GLIMS_ADAPTER_ROOT", None)

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

    def test_custom_adapter_root_is_used_for_preflight(self):
        pinned = (ROOT / "scripts/engine.env").read_text().split('ENGINE_SETS="')[1].split(':')[0]
        (self.root / "_engine/install" / pinned).mkdir(parents=True)
        custom = self.root / "branch-adapters"
        adapter = custom / pinned / "libglimsengine.dylib"
        adapter.parent.mkdir(parents=True)
        adapter.touch()
        self.env["GLIMS_ADAPTER_ROOT"] = str(custom)
        result = self.run_build()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("reached-swift", result.stderr)
        self.assertFalse((self.root / "_engine/adapter").exists())

    def test_relative_adapter_root_is_rejected_before_building(self):
        self.env["GLIMS_ADAPTER_ROOT"] = "relative-adapters"
        result = self.run_build()
        self.assertEqual(result.returncode, 2)
        self.assertIn("absolute directory", result.stderr)
        self.assertNotIn("reached-swift", result.stderr)
        self.assertEqual(self.run_build("--shell-only").returncode, 42)

    def test_bundle_sandbox_denies_isolated_adapter_outputs(self):
        app = self.root / "dist/Glims.app"
        (app / "Contents/Frameworks").mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        (app / "Contents/Frameworks/libglimsengine.dylib").touch()
        outputs = self.root / "isolated-adapters"
        runner = outputs / "test-engine/glims-engine-tests"
        runner.parent.mkdir(parents=True)
        secret = outputs / "development-only"
        secret.write_text("must not be readable by the bundled app")
        source = ("#!/bin/sh\nif cat " + shlex.quote(str(secret))
                  + " >/dev/null 2>&1; then echo 'FAIL development output was readable'; exit 1; fi\n"
                  + "echo 'ok development output denied'\n")
        runner.write_text(source)
        runner.chmod(0o755)
        duotone = runner.parent / "glims-duotone-preservation-tests"
        duotone.write_text(source)
        duotone.chmod(0o755)
        duotone_export = runner.parent / "glims-duotone-export-tests"
        duotone_export.write_text(source)
        duotone_export.chmod(0o755)
        composite = runner.parent / "glims-psd-composite-tests"
        composite.write_text(source)
        composite.chmod(0o755)
        executable = app / "Contents/MacOS/Glims"
        executable.write_text(source)
        executable.chmod(0o755)
        self.env["GLIMS_ADAPTER_ROOT"] = str(outputs)
        result = subprocess.run(["bash", str(self.root / "scripts/check-bundle.sh"), str(app)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 checks passed", result.stdout)

    def test_bundle_check_propagates_duotone_failure(self):
        app = self.root / "dist/Glims.app"
        (app / "Contents/Frameworks").mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        (app / "Contents/Frameworks/libglimsengine.dylib").touch()
        outputs = self.root / "isolated-adapters"
        outputs.mkdir()
        runners = outputs / "test-engine"
        runners.mkdir()
        for name, content in (("glims-engine-tests", "#!/bin/sh\necho 'ok engine'\n"),
                              ("glims-duotone-preservation-tests", "#!/bin/sh\necho 'FAIL duotone'\nexit 1\n"),
                              ("glims-duotone-export-tests", "#!/bin/sh\necho 'ok duotone export'\n"),
                              ("glims-psd-composite-tests", "#!/bin/sh\necho 'ok composite'\n")):
            path = runners / name
            path.write_text(content)
            path.chmod(0o755)
        executable = app / "Contents/MacOS/Glims"
        executable.write_text("#!/bin/sh\necho 'ok app'\n")
        executable.chmod(0o755)
        self.env["GLIMS_ADAPTER_ROOT"] = str(outputs)
        result = subprocess.run(["bash", str(self.root / "scripts/check-bundle.sh"), str(app)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Duotone preservation checks failed", result.stdout)

    def test_bundle_check_propagates_duotone_export_failure(self):
        app = self.root / "dist/Glims.app"
        (app / "Contents/Frameworks").mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        (app / "Contents/Frameworks/libglimsengine.dylib").touch()
        runners = self.root / "isolated-adapters/test-engine"
        runners.mkdir(parents=True)
        for name in ("glims-engine-tests", "glims-duotone-preservation-tests", "glims-duotone-export-tests", "glims-psd-composite-tests"):
            path = runners / name
            path.write_text("#!/bin/sh\necho 'FAIL export'\nexit 1\n" if name == "glims-duotone-export-tests" else "#!/bin/sh\necho 'ok'\n")
            path.chmod(0o755)
        executable = app / "Contents/MacOS/Glims"
        executable.write_text("#!/bin/sh\necho 'ok app'\n")
        executable.chmod(0o755)
        self.env["GLIMS_ADAPTER_ROOT"] = str(runners.parent)
        result = subprocess.run(["bash", str(self.root / "scripts/check-bundle.sh"), str(app)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Duotone export checks failed", result.stdout)

    def test_bundle_check_propagates_psd_composite_failure(self):
        app = self.root / "dist/Glims.app"
        (app / "Contents/Frameworks").mkdir(parents=True)
        (app / "Contents/MacOS").mkdir()
        (app / "Contents/Frameworks/libglimsengine.dylib").touch()
        runners = self.root / "isolated-adapters/test-engine"
        runners.mkdir(parents=True)
        for name in ("glims-engine-tests", "glims-duotone-preservation-tests", "glims-duotone-export-tests", "glims-psd-composite-tests"):
            path = runners / name
            path.write_text("#!/bin/sh\necho 'FAIL composite'\nexit 1\n" if name == "glims-psd-composite-tests" else "#!/bin/sh\necho 'ok'\n")
            path.chmod(0o755)
        executable = app / "Contents/MacOS/Glims"
        executable.write_text("#!/bin/sh\necho 'ok app'\n")
        executable.chmod(0o755)
        self.env["GLIMS_ADAPTER_ROOT"] = str(runners.parent)
        result = subprocess.run(["bash", str(self.root / "scripts/check-bundle.sh"), str(app)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Photoshop composite checks failed", result.stdout)

    def test_shell_only_is_explicit(self):
        result = self.run_build("--shell-only")
        self.assertEqual(result.returncode, 42)
        self.assertIn("reached-swift", result.stderr)

    def test_failed_build_keeps_previous_app_and_cleans_staging(self):
        app = self.root / "dist/Glims.app"
        app.mkdir(parents=True)
        marker = app / "previous-version"
        marker.write_text("keep")
        self.assertEqual(self.run_build("--shell-only").returncode, 42)
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(list((self.root / "dist").iterdir()), [app])

    def allow_successful_assembly(self):
        resources = self.root / "Resources"
        resources.mkdir()
        for name in ("Info.plist", "AppIcon.icns", "Third-Party-Notices.txt"):
            (resources / name).write_text("fixture")
        (self.root / "LICENSE").write_text("fixture")
        notices = self.root / "scripts/third-party-notices.sh"
        notices.write_text("#!/bin/sh\nexit 0\n")
        notices.chmod(0o755)
        tools = self.root / "tools"
        binary = tools / "Glims"
        binary.write_text("new executable")
        swift = tools / "swift"
        swift.write_text("#!/bin/sh\ncase \" $* \" in *--show-bin-path*) printf '%s\\n' "
                         + shlex.quote(str(tools)) + ";; esac\nexit 0\n")
        signing = tools / "codesign"
        signing.write_text("#!/bin/sh\nexit 0\n")
        signing.chmod(0o755)
    def test_success_publishes_complete_app_without_nesting(self):
        self.allow_successful_assembly()
        app = self.root / "dist/Glims.app"
        app.mkdir(parents=True)
        (app / "old-version").touch()
        result = self.run_build("--shell-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((app / "Contents/MacOS/Glims").read_text(), "new executable")
        self.assertFalse((app / "old-version").exists())
        self.assertFalse((app / "Glims.app").exists())
        self.assertEqual(list((self.root / "dist").iterdir()), [app])

    def test_normal_build_contains_the_engine(self):
        self.allow_successful_assembly()
        pinned = (ROOT / "scripts/engine.env").read_text().split('ENGINE_SETS="')[1].split(':')[0]
        (self.root / "_engine/install" / pinned).mkdir(parents=True)
        adapter = self.root / "_engine/adapter" / pinned / "libglimsengine.dylib"
        adapter.parent.mkdir(parents=True)
        adapter.touch()
        rebuild = self.root / "scripts/build-adapter.sh"
        rebuild.write_text("#!/bin/sh\nexit 0\n")
        rebuild.chmod(0o755)
        bundler = self.root / "scripts/bundle-engine.py"
        bundler.write_text("import pathlib, sys\n"
                           "target = pathlib.Path(sys.argv[1]) / 'Contents/Frameworks'\n"
                           "target.mkdir()\n"
                           "(target / 'libglimsengine.dylib').write_text('engine')\n")
        compiler = self.root / "tools/xcrun"
        compiler.write_text("#!/usr/bin/env python3\nimport pathlib, sys\n"
                            "target = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])\n"
                            "target.write_text('#!/bin/sh\\nexit 0\\n')\n"
                            "target.chmod(0o755)\n")
        compiler.chmod(0o755)
        prepare = self.root / "scripts/prepare-engine-startup.py"
        prepare.write_text("import pathlib, sys\n"
                           "contents = pathlib.Path(sys.argv[1]) / 'Contents'\n"
                           "assert (contents / 'MacOS/glims-font-cache').is_file()\n"
                           "assert (contents / 'Frameworks/libglimsengine.dylib').is_file()\n"
                           "target = contents / 'Resources/Engine-Startup'\n"
                           "target.mkdir()\n"
                           "(target / 'pluginrc').write_text('registry')\n")
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.root / "dist/Glims.app"
        self.assertEqual((app / "Contents/Frameworks/libglimsengine.dylib").read_text(), "engine")
        self.assertTrue(os.access(app / "Contents/MacOS/glims-font-cache", os.X_OK))
        self.assertEqual((app / "Contents/Resources/Engine-Startup/pluginrc").read_text(), "registry")
        # A failed cache-generation step must not publish a partial app.
        marker = app / "previous-version"
        marker.write_text("keep")
        prepare.write_text("raise SystemExit(42)\n")
        self.assertEqual(self.run_build().returncode, 42)
        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(list((self.root / "dist").iterdir()), [app])

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
