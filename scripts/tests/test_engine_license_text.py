"""Require component license text before publishing the bundled notices."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("bundle_engine", Path(__file__).parents[1] / "bundle-engine.py")
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)


class EngineLicenseTextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glims-engine-notices-")
        self.root = Path(self.temp.name)
        sources = self.root / "sources"
        for project in ("gimp", "gegl", "babl"):
            directory = sources / project
            directory.mkdir(parents=True)
            (directory / "COPYING").write_text(project + " fixture license text\n")
        self.bundler = bundle.Bundler(str(self.root / "App.app"),
                                      str(self.root / "engine/install/GIMP_TEST"),
                                      str(self.root / "prefix"), "adapter", str(sources))
        self.notices = Path(self.bundler.path("Resources", "Engine-Notices.txt"))
        self.notices.parent.mkdir(parents=True)
        self.ports = {"fixture": ("1.2.3", "MIT", "https://example.invalid/fixture")}
        self.distfiles = ""

    def tearDown(self):
        self.temp.cleanup()

    def run_fixture_command(self, *args):
        if args[0] == "git":
            return "fixture-v1\n"
        if args[-3:] == ("-q", "distfiles", "fixture"):
            return self.distfiles
        self.fail("Unexpected fixture command: " + repr(args))

    def test_missing_component_license_refuses_without_publishing_notices(self):
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command), \
             mock.patch.object(bundle, "_open_aom_license") as network:
            with self.assertRaisesRegex(SystemExit, r"fixture 1\.2\.3.*license text"):
                self.bundler.write_notices()
            self.assertFalse(self.notices.exists())
            network.assert_not_called()

    def test_missing_component_license_preserves_existing_notices(self):
        previous = "Previous complete notices\n"
        self.notices.write_text(previous)
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
            with self.assertRaisesRegex(SystemExit, r"fixture 1\.2\.3.*license text"):
                self.bundler.write_notices()
        self.assertEqual(self.notices.read_text(), previous)

    def test_whitespace_notice_cache_cannot_substitute_for_license_text(self):
        cache = self.root / "engine/cache/notices/fixture-1.2.3.txt"
        cache.parent.mkdir(parents=True)
        cache.write_text(" \n\t")
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
            with self.assertRaisesRegex(SystemExit, r"fixture 1\.2\.3.*license text"):
                self.bundler.write_notices()
        self.assertFalse(self.notices.exists())

    def test_installed_license_and_cached_notice_keep_the_same_text(self):
        text = "Fixture license text\nCopyright fixture author\n"
        license_file = self.root / "prefix/share/doc/fixture/LICENSE"
        license_file.parent.mkdir(parents=True)
        license_file.write_text(text)
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
            self.assertEqual(self.bundler.write_notices(), 4)
            first = self.notices.read_text()
            self.assertIn("--- LICENSE\n\n" + text + "\n", first)
            self.assertNotIn("No license file found", first)
            license_file.unlink()
            self.assertEqual(self.bundler.write_notices(), 4)
            self.assertEqual(self.notices.read_text(), first)

    def test_archive_license_is_copied_into_notices(self):
        text = b"Archived fixture license\n"
        archive = self.root / "fixture.tar.gz"
        with tarfile.open(archive, "w:gz") as handle:
            entry = tarfile.TarInfo("fixture-1.2.3/LICENSE")
            entry.size = len(text)
            handle.addfile(entry, io.BytesIO(text))
        self.distfiles = "[fixture.tar.gz] " + str(archive) + "\n"
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
            self.assertEqual(self.bundler.write_notices(), 4)
        self.assertIn("--- fixture-1.2.3/LICENSE\n\n" + text.decode() + "\n", self.notices.read_text())

    def test_blank_installed_license_refuses_without_caching_its_heading(self):
        license_file = self.root / "prefix/share/doc/fixture/LICENSE"
        license_file.parent.mkdir(parents=True)
        cache = self.root / "engine/cache/notices/fixture-1.2.3.txt"
        for text in ("", " \n\t"):
            with self.subTest(text=text):
                license_file.write_text(text)
                cache.unlink(missing_ok=True)
                with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
                     mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
                    with self.assertRaisesRegex(SystemExit, r"fixture 1\.2\.3.*license text"):
                        self.bundler.write_notices()
                self.assertFalse(self.notices.exists())
                self.assertFalse(cache.exists())

    def test_blank_archive_license_refuses_without_caching_its_heading(self):
        archive = self.root / "fixture.tar.gz"
        cache = self.root / "engine/cache/notices/fixture-1.2.3.txt"
        for text in (b"", b" \n\t"):
            with self.subTest(text=text):
                with tarfile.open(archive, "w:gz") as handle:
                    entry = tarfile.TarInfo("fixture-1.2.3/LICENSE")
                    entry.size = len(text)
                    handle.addfile(entry, io.BytesIO(text))
                self.distfiles = "[fixture.tar.gz] " + str(archive) + "\n"
                cache.unlink(missing_ok=True)
                with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
                     mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
                    with self.assertRaisesRegex(SystemExit, r"fixture 1\.2\.3.*license text"):
                        self.bundler.write_notices()
                self.assertFalse(self.notices.exists())
                self.assertFalse(cache.exists())

    def test_header_only_legacy_cache_cannot_substitute_for_license_body(self):
        cache = self.root / "engine/cache/notices/fixture-1.2.3.txt"
        cache.parent.mkdir(parents=True)
        previous = "--- LICENSE\n\n\n\n--- COPYING\n\n \n"
        cache.write_text(previous)
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
            with self.assertRaisesRegex(SystemExit, r"fixture 1\.2\.3.*license text"):
                self.bundler.write_notices()
        self.assertFalse(self.notices.exists())
        self.assertEqual(cache.read_text(), previous)

    def test_header_only_legacy_cache_can_recover_from_installed_text(self):
        cache = self.root / "engine/cache/notices/fixture-1.2.3.txt"
        cache.parent.mkdir(parents=True)
        cache.write_text("--- LICENSE\n\n\n\n")
        license_file = self.root / "prefix/share/doc/fixture/LICENSE"
        license_file.parent.mkdir(parents=True)
        license_file.write_text("Recovered fixture license\n")
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
            self.assertEqual(self.bundler.write_notices(), 4)
        self.assertIn("--- LICENSE\n\nRecovered fixture license\n\n", self.notices.read_text())
        self.assertEqual(cache.read_text(), "--- LICENSE\n\nRecovered fixture license\n\n")

    def test_blank_docs_and_archive_fall_through_to_a_valid_archive(self):
        license_file = self.root / "prefix/share/doc/fixture/LICENSE"
        license_file.parent.mkdir(parents=True)
        license_file.write_text(" \n")
        archives = []
        for name, text in (("empty", b" \n"), ("valid", b"Valid archived license\n")):
            archive = self.root / (name + ".tar.gz")
            with tarfile.open(archive, "w:gz") as handle:
                entry = tarfile.TarInfo(name + "/LICENSE")
                entry.size = len(text)
                handle.addfile(entry, io.BytesIO(text))
            archives.append("[" + name + ".tar.gz] " + str(archive) + "\n")
        self.distfiles = "".join(archives)
        with mock.patch.object(self.bundler, "port_info", return_value=self.ports), \
             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
            self.assertEqual(self.bundler.write_notices(), 4)
        self.assertIn("--- valid/LICENSE\n\nValid archived license\n\n", self.notices.read_text())
        cache = self.root / "engine/cache/notices/fixture-1.2.3.txt"
        self.assertEqual(cache.read_text(), "--- valid/LICENSE\n\nValid archived license\n\n")

    def test_missing_or_blank_core_license_preserves_existing_notices(self):
        previous = "Previous complete notices\n"
        for project, title in (("gimp", "GIMP"), ("gegl", "GEGL"), ("babl", "babl")):
            license_file = self.root / "sources" / project / "COPYING"
            original = license_file.read_text()
            for text in (None, "", " \n\t"):
                with self.subTest(project=project, text=text):
                    self.notices.write_text(previous)
                    if text is None:
                        license_file.unlink()
                    else:
                        license_file.write_text(text)
                    try:
                        with mock.patch.object(self.bundler, "port_info", return_value={}), \
                             mock.patch.object(bundle, "run", side_effect=self.run_fixture_command):
                            with self.assertRaisesRegex(SystemExit, title + r" fixture-v1.*license text"):
                                self.bundler.write_notices()
                        self.assertEqual(self.notices.read_text(), previous)
                    finally:
                        license_file.write_text(original)
