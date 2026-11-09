"""AOM license discovery uses verified sources, without network or engine builds."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("bundle_engine", Path(__file__).parents[1] / "bundle-engine.py")
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)


class AomLicenseTextTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glims-aom-notices-")
        self.root = Path(self.temp.name)
        self.bundler = bundle.Bundler(str(self.root / "App.app"),
                                      str(self.root / "engine/install/GIMP_TEST"),
                                      str(self.root / "prefix"), "adapter", "sources")

    def tearDown(self):
        self.temp.cleanup()

    def test_missing_aom_license_refuses_instead_of_placeholder(self):
        with mock.patch.object(bundle, "run", return_value=""), \
             mock.patch.object(bundle, "_open_aom_license", side_effect=OSError("offline fixture")):
            with self.assertRaisesRegex(SystemExit, "AOM"):
                self.bundler.license_texts("aom", "3.15.1")

    def test_redirect_is_rejected_before_body_read_or_followup(self):
        import urllib.request
        handler = bundle._AomNoRedirect()
        parent = mock.Mock()
        handler.add_parent(parent)
        request = urllib.request.Request("https://aomedia.googlesource.com/aom/LICENSE")
        body = mock.Mock()
        body.read.side_effect = AssertionError("redirect body must not be read")
        with self.assertRaisesRegex(ValueError, "redirect refused"):
            handler.http_error_302(request, body, 302, "Found",
                                   {"location": "https://example.invalid/LICENSE"})
        body.read.assert_not_called()
        parent.open.assert_not_called()

    def synthetic_pin(self):
        import hashlib
        self.license = b"Synthetic AOM license fixture.\nCopyright fixture author.\n"
        self.commit = "1" * 40
        self.digest = hashlib.sha256(self.license).hexdigest()
        return mock.patch.dict(bundle.AOM_LICENSE_SOURCES,
                               {"3.15.1": (self.commit, self.digest)}, clear=True)

    def test_git_worktree_reads_verified_commit_and_preserves_license_bytes(self):
        work = self.root / "work"
        source = work / "aom"
        (source / ".git").mkdir(parents=True)
        (source / "LICENSE").write_text("uncommitted, unverified replacement")
        with self.synthetic_pin():
            def run(*args):
                if args[-3:] == ("-q", "work", "aom"):
                    return str(work) + "\n"
                if args[-2:] == ("rev-parse", "HEAD"):
                    return self.commit + "\n"
                if args[-2:] == ("show", self.commit + ":LICENSE"):
                    return self.license.decode("utf-8")
                self.fail("Unexpected source lookup: " + repr(args))
            with mock.patch.object(bundle, "run", side_effect=run), \
                 mock.patch.object(bundle, "_open_aom_license") as network:
                result = self.bundler.license_texts("aom", "3.15.1")
            network.assert_not_called()
            self.assertIn(self.license.decode("utf-8"), result)
            self.assertNotIn("uncommitted", result)
            self.assertIn("/+/{}/LICENSE".format(self.commit), result)
            self.assertIn(self.digest, result)
            cache = self.root / "engine/cache/notices" / ("aom-3.15.1-" + self.commit + ".LICENSE")
            self.assertEqual(cache.read_bytes(), self.license)

    def test_primary_fallback_is_immutable_bounded_and_hash_verified(self):
        import base64
        with self.synthetic_pin():
            url = "https://aomedia.googlesource.com/aom/+/" + self.commit + "/LICENSE?format=TEXT"
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.geturl.return_value = url
            response.read.return_value = base64.b64encode(self.license)
            with mock.patch.object(bundle, "run", return_value=""), \
                 mock.patch.object(bundle, "_open_aom_license", return_value=response) as network:
                result = self.bundler.license_texts("aom", "3.15.1")
            network.assert_called_once_with(url, timeout=15)
            response.read.assert_called_once_with(65537)
            self.assertIn(self.license.decode("utf-8"), result)

    def test_unknown_version_cannot_substitute_reviewed_version(self):
        with mock.patch.object(bundle, "run") as run, mock.patch.object(bundle, "_open_aom_license") as network:
            with self.assertRaisesRegex(SystemExit, "AOM 999.*reviewed"):
                self.bundler.license_texts("aom", "999")
            run.assert_not_called()
            network.assert_not_called()

    def test_wrong_git_commit_is_not_used(self):
        source = self.root / "work"
        (source / ".git").mkdir(parents=True)
        with self.synthetic_pin():
            def run(*args):
                if args[-3:] == ("-q", "work", "aom"): return str(source)
                if args[-2:] == ("rev-parse", "HEAD"): return "2" * 40
                self.fail("Wrong-commit Git contents must not be read")
            with mock.patch.object(bundle, "run", side_effect=run), \
                 mock.patch.object(bundle, "_open_aom_license", side_effect=OSError("offline fixture")):
                with self.assertRaisesRegex(SystemExit, "required LICENSE unavailable"):
                    self.bundler.license_texts("aom", "3.15.1")

    def test_wrong_license_bytes_are_refused(self):
        import base64
        with self.synthetic_pin():
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.geturl.return_value = "https://aomedia.googlesource.com/aom/+/" + self.commit + "/LICENSE?format=TEXT"
            response.read.return_value = base64.b64encode(b"different version's license")
            with mock.patch.object(bundle, "run", return_value=""), \
                 mock.patch.object(bundle, "_open_aom_license", return_value=response):
                with self.assertRaisesRegex(SystemExit, "does not match reviewed SHA-256"):
                    self.bundler.license_texts("aom", "3.15.1")

    def test_verified_cache_is_rechecked_without_git_or_network(self):
        with self.synthetic_pin():
            cache = self.root / "engine/cache/notices" / ("aom-3.15.1-" + self.commit + ".LICENSE")
            cache.parent.mkdir(parents=True)
            cache.write_bytes(self.license)
            with mock.patch.object(bundle, "run") as run, mock.patch.object(bundle, "_open_aom_license") as network:
                self.assertIn(self.license.decode(), self.bundler.license_texts("aom", "3.15.1"))
                cache.write_bytes(b"tampered cache")
                with self.assertRaisesRegex(SystemExit, "invalid notice cache"):
                    self.bundler.license_texts("aom", "3.15.1")
                run.assert_not_called()
                network.assert_not_called()

    def test_legacy_unverified_aom_cache_is_not_trusted(self):
        cache = self.root / "engine/cache/notices/aom-3.15.1.txt"
        cache.parent.mkdir(parents=True)
        cache.write_text("old unproven notice text")
        with mock.patch.object(bundle, "run", return_value=""), \
             mock.patch.object(bundle, "_open_aom_license", side_effect=OSError("offline fixture")):
            with self.assertRaisesRegex(SystemExit, "AOM"):
                self.bundler.license_texts("aom", "3.15.1")
        self.assertEqual(cache.read_text(), "old unproven notice text")

    def test_other_ports_keep_missing_text_and_installed_docs_behavior(self):
        with mock.patch.object(bundle, "run", return_value=""), mock.patch.object(bundle, "_open_aom_license") as network:
            self.assertEqual(self.bundler.license_texts("other", "1"), "")
            docs = self.root / "prefix/share/doc/other"
            docs.mkdir(parents=True)
            (docs / "LICENSE").write_text("Other license text\n")
            self.assertEqual(self.bundler.license_texts("other", "1"), "--- LICENSE\n\nOther license text\n\n")
            network.assert_not_called()
