"""Offline source packaging fixtures; only temporary synthetic Git repositories."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "collect-core-sources.py"
SPEC = importlib.util.spec_from_file_location("collect_core_sources", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = collector
SPEC.loader.exec_module(collector)


class CoreSourceCollectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glims-core-source-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repos = {}
        self.revisions = {}
        for name in ("gimp", "gegl", "babl", "glims"):
            repo = self.new_repo(name)
            if name == "glims":
                for relative in collector.GLIMS_PATHS:
                    target = repo / relative
                    if relative in {"Engine", "Sources/CGlimsEngine", "scripts"}:
                        target /= "recipe.txt"
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text("committed build recipe\n")
                (repo / "not-selected.txt").write_text("outside the recipe selection\n")
            else:
                (repo / "source.c").write_text(f"/* committed {name} source */\n")
                (repo / "COPYING").write_text("fixture license\n")
            self.repos[name] = repo
            self.revisions[name] = self.commit(repo)
        self.components = {name: (self.repos[name], self.revisions[name]) for name in ("gimp", "gegl", "babl")}
        self.glims = (self.repos["glims"], self.revisions["glims"])

    def git(self, repo, *args):
        environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_AUTHOR_DATE="2001-02-03T04:05:06+00:00",
                           GIT_COMMITTER_DATE="2001-02-03T04:05:06+00:00")
        result = subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture",
                                 "-c", "user.email=fixture@example.invalid", *args],
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def new_repo(self, name):
        repo = self.root / (name + " repo")
        repo.mkdir()
        self.git(repo, "init", "--template=", "--initial-branch=main")
        return repo

    def commit(self, repo):
        self.git(repo, "add", "--all")
        self.git(repo, "commit", "-m", "Synthetic source fixture")
        return self.git(repo, "rev-parse", "HEAD")

    def add_gitlink(self, parent, name, commit):
        # No checkout/fetch/submodule update, even in the fixture. A gitlink
        # plus explicit mapping is enough to test exact-object recursion.
        self.git(parent, "update-index", "--add", "--cacheinfo", f"160000,{commit},{name}")
        self.git(parent, "commit", "-m", "Synthetic gitlink")
        return self.git(parent, "rev-parse", "HEAD")

    def collect(self, name="result.tar", modules=None):
        output = self.root / name
        collector.collect(self.components, self.glims, modules or {}, output)
        return output

    def contents(self, path):
        with tarfile.open(path) as archive:
            manifest = json.load(archive.extractfile("manifest.json"))
            files = {m.name: archive.extractfile(m).read() for m in archive if m.isfile()}
            links = {m.name: m.linkname for m in archive if m.issym()}
        return manifest, files, links

    def collect_cli(self, name="cli-result.tar"):
        output = self.root / name
        command = [sys.executable, "-I", "-B", str(SCRIPT)]
        for component in ("gimp", "gegl", "babl"):
            repo, revision = self.components[component]
            command += ["--" + component, str(repo), revision]
        command += ["--glims", str(self.glims[0]), self.glims[1], "--output", str(output)]
        result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=120)
        return result, output

    def test_committed_payload_recipe_selection_hashes_and_incomplete_scope(self):
        output = self.collect()
        manifest, files, _ = self.contents(output)
        self.assertIs(manifest["corresponding_source_complete"], False)
        self.assertEqual(manifest["source_delivery"], "local_collection_only")
        self.assertIn("MacPorts dependency source and conditional patches", manifest["not_collected"])
        self.assertEqual([c["name"] for c in manifest["components"]], ["gimp", "gegl", "babl", "glims"])
        self.assertEqual(files["sources/gimp/source.c"], b"/* committed gimp source */\n")
        self.assertIn("build/glims/Engine/recipe.txt", files)
        self.assertNotIn("build/glims/not-selected.txt", files)
        for record in manifest["files"]:
            self.assertEqual(record["sha256"], hashlib.sha256(files[record["path"]]).hexdigest())
            self.assertEqual(record["size"], len(files[record["path"]]))
        self.assertFalse(any("/.git/" in name for name in files))

    def test_nested_gitlinks_export_exact_parent_pins(self):
        data = self.new_repo("data")
        nested = self.new_repo("nested")
        (nested / "nested.txt").write_text("pinned nested data\n")
        nested_pin = self.commit(nested)
        (data / "data.txt").write_text("pinned data\n")
        self.commit(data)
        data_pin = self.add_gitlink(data, "more", nested_pin)
        gimp_pin = self.add_gitlink(self.repos["gimp"], "gimp-data", data_pin)
        self.components["gimp"] = (self.repos["gimp"], gimp_pin)
        (nested / "nested.txt").write_text("newer unselected data\n")
        self.commit(nested)
        output = self.collect(modules={"gimp/gimp-data": data, "gimp/gimp-data/more": nested})
        manifest, files, _ = self.contents(output)
        self.assertEqual(files["sources/gimp/gimp-data/more/nested.txt"], b"pinned nested data\n")
        pins = {c["name"]: c["commit"] for c in manifest["components"]}
        self.assertEqual(pins["gimp/gimp-data"], data_pin)
        self.assertEqual(pins["gimp/gimp-data/more"], nested_pin)

    def test_missing_submodule_mapping_refuses_without_publishing(self):
        self.components["gimp"] = (self.repos["gimp"], self.add_gitlink(self.repos["gimp"], "data", "1" * 40))
        with self.assertRaisesRegex(collector.CollectionError, "Missing explicit local submodule mapping"):
            self.collect()
        self.assertFalse((self.root / "result.tar").exists())

    def test_mapped_submodule_missing_exact_commit_refuses_offline(self):
        self.components["gimp"] = (self.repos["gimp"], self.add_gitlink(self.repos["gimp"], "data", "1" * 40))
        with self.assertRaises(collector.CollectionError):
            self.collect(modules={"gimp/data": self.repos["babl"]})
        self.assertFalse((self.root / "result.tar").exists())

    def test_unused_submodule_mapping_refuses(self):
        with self.assertRaisesRegex(collector.CollectionError, "Unused submodule mapping"):
            self.collect(modules={"gimp/typo": self.repos["babl"]})

    def test_safe_symlink_is_preserved_without_following(self):
        (self.repos["gegl"] / "alias").symlink_to("source.c")
        self.components["gegl"] = (self.repos["gegl"], self.commit(self.repos["gegl"]))
        manifest, _, links = self.contents(self.collect())
        self.assertEqual(links["sources/gegl/alias"], "source.c")
        record = next(f for f in manifest["files"] if f["path"] == "sources/gegl/alias")
        self.assertEqual(record["type"], "symlink")
        self.assertEqual(record["sha256"], hashlib.sha256(b"source.c").hexdigest())

    def test_escaping_symlink_refuses_atomically(self):
        (self.repos["gegl"] / "escape").symlink_to("../../../outside")
        self.components["gegl"] = (self.repos["gegl"], self.commit(self.repos["gegl"]))
        with self.assertRaisesRegex(collector.CollectionError, "symlink escapes"):
            self.collect()
        self.assertFalse((self.root / "result.tar").exists())
        self.assertFalse(list(self.root.glob(".glims-core-sources-*")))

    def test_absolute_symlink_refuses(self):
        (self.repos["babl"] / "escape").symlink_to(self.root / "outside")
        self.components["babl"] = (self.repos["babl"], self.commit(self.repos["babl"]))
        with self.assertRaisesRegex(collector.CollectionError, "Unsafe source symlink"):
            self.collect()

    def test_working_changes_are_recorded_and_never_exported(self):
        index = self.repos["gimp"] / ".git/index"
        before = (index.read_bytes(), index.stat().st_mtime_ns)
        (self.repos["gimp"] / "source.c").write_text("working tree is different\n")
        manifest, files, _ = self.contents(self.collect())
        self.assertEqual(files["sources/gimp/source.c"], b"/* committed gimp source */\n")
        self.assertTrue(manifest["components"][0]["tracked_worktree_dirty"])
        self.assertEqual((index.read_bytes(), index.stat().st_mtime_ns), before)

    def test_archive_attributes_cannot_drop_or_substitute_committed_files(self):
        repo = self.repos["gimp"]
        (repo / ".gitattributes").write_text("source.c export-ignore\nversion.txt export-subst\n")
        (repo / "version.txt").write_text("$Format:%H$\n")
        pin = self.commit(repo)
        (repo / ".git/info").mkdir(exist_ok=True)
        (repo / ".git/info/attributes").write_text("COPYING export-ignore\n")
        self.components["gimp"] = (repo, pin)
        _, files, _ = self.contents(self.collect())
        self.assertIn("sources/gimp/source.c", files)
        self.assertIn("sources/gimp/COPYING", files)
        self.assertEqual(files["sources/gimp/version.txt"], b"$Format:%H$\n")

    def test_existing_output_and_input_overlap_are_refused(self):
        output = self.root / "exists.tar"
        output.write_bytes(b"keep me")
        with self.assertRaisesRegex(collector.CollectionError, "already exists"):
            collector.collect(self.components, self.glims, {}, output)
        self.assertEqual(output.read_bytes(), b"keep me")
        for output in (self.repos["gimp"] / "result.tar", self.repos["gimp"] / ".git/result.tar"):
            with self.assertRaisesRegex(collector.CollectionError, "outside every input"):
                collector.collect(self.components, self.glims, {}, output)
            self.assertFalse(output.exists())

    def test_symlinked_output_parent_cannot_bypass_overlap(self):
        alias = self.root / "output-alias"
        alias.symlink_to(self.repos["gegl"], target_is_directory=True)
        with self.assertRaisesRegex(collector.CollectionError, "outside every input"):
            collector.collect(self.components, self.glims, {}, alias / "result.tar")
        self.assertFalse((alias / "result.tar").exists())

    def test_external_symlinked_object_store_is_also_an_input(self):
        objects = self.repos["gimp"] / ".git/objects"
        external = self.root / "external-objects"
        objects.rename(external)
        objects.symlink_to(external, target_is_directory=True)
        output = external / "result.tar"
        with self.assertRaisesRegex(collector.CollectionError, "outside every input"):
            collector.collect(self.components, self.glims, {}, output)
        self.assertFalse(output.exists())

    def test_external_alternate_store_cannot_receive_output(self):
        objects = self.repos["gimp"] / ".git/objects"
        external = self.root / "alternate-objects"
        objects.rename(external)
        (objects / "info").mkdir(parents=True)
        (objects / "info/alternates").write_text(str(external) + "\n")
        output = external / "result.tar"
        with self.assertRaises(collector.CollectionError):
            collector.collect(self.components, self.glims, {}, output)
        self.assertFalse(output.exists())

    def test_publication_race_does_not_overwrite_the_winner(self):
        original = os.link

        def race(source, destination):
            Path(destination).write_bytes(b"winner")
            return original(source, destination)

        with mock.patch.object(collector.os, "link", side_effect=race):
            with self.assertRaisesRegex(collector.CollectionError, "appeared during collection"):
                self.collect()
        self.assertEqual((self.root / "result.tar").read_bytes(), b"winner")
        self.assertFalse(list(self.root.glob(".glims-core-sources-*")))

    def test_missing_required_glims_recipe_is_a_refusal(self):
        (self.repos["glims"] / "LICENSE").unlink()
        self.glims = (self.repos["glims"], self.commit(self.repos["glims"]))
        with self.assertRaisesRegex(collector.CollectionError, "lacks required build input: LICENSE"):
            self.collect()

    def test_recursive_and_payload_limits_are_refusals(self):
        with mock.patch.object(collector, "MAX_NODES", 2):
            with self.assertRaisesRegex(collector.CollectionError, "recursion exceeds"):
                self.collect()
        with mock.patch.object(collector, "MAX_SOURCE_BYTES", 1):
            with self.assertRaisesRegex(collector.CollectionError, "payload exceeds"):
                self.collect()
        self.assertFalse((self.root / "result.tar").exists())

    def test_configured_filters_are_not_executed(self):
        sentinel = self.root / "filter-ran"
        self.git(self.repos["gimp"], "config", "filter.fixture.clean", f"touch '{sentinel}'")
        with self.assertRaisesRegex(collector.CollectionError, "configured Git filters"):
            self.collect()
        self.assertFalse(sentinel.exists())

    def test_same_commits_produce_identical_archives(self):
        first, second = self.collect("one.tar"), self.collect("two.tar")
        self.assertEqual(hashlib.sha256(first.read_bytes()).digest(), hashlib.sha256(second.read_bytes()).digest())

    def test_composed_symlink_escape_cli_refuses_before_publication(self):
        repo = self.repos["gimp"]
        (repo / "a").symlink_to(".")
        (repo / "b").symlink_to("a/a/a/../../..")
        revision = self.commit(repo)
        self.components["gimp"] = (repo, revision)
        self.assertEqual(self.git(repo, "cat-file", "blob", revision + ":a"), ".")
        self.assertEqual(self.git(repo, "cat-file", "blob", revision + ":b"), "a/a/a/../../..")

        # Every a resolves to the component root, so the three parent
        # traversals escape even though lexical cancellation appears safe.
        # Never extract or resolve links from the resulting unsafe archive.
        result, output = self.collect_cli()
        self.assertEqual(result.returncode, 1, result.stderr or result.stdout)
        self.assertIn("symlink escapes", result.stderr)
        self.assertFalse(os.path.lexists(output))
        self.assertFalse(list(self.root.glob(".glims-core-sources-*")))

    def test_contained_multihop_symlinks_cli_preserve_exact_targets(self):
        repo = self.repos["gegl"]
        targets = {"a": ".", "b": "a/a/source.c", "c": "b"}
        for name, target in targets.items():
            (repo / name).symlink_to(target)
        self.components["gegl"] = (repo, self.commit(repo))
        self.assertEqual((repo / "c").resolve(strict=True), (repo / "source.c").resolve(strict=True))

        result, output = self.collect_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest, files, links = self.contents(output)
        for name, target in targets.items():
            path = "sources/gegl/" + name
            self.assertEqual(links[path], target)
            record = next(item for item in manifest["files"] if item["path"] == path)
            self.assertEqual(record["sha256"], hashlib.sha256(target.encode("utf-8")).hexdigest())
        self.assertEqual(files["sources/gegl/source.c"], b"/* committed gegl source */\n")
        self.assertFalse(list(self.root.glob(".glims-core-sources-*")))

    def test_contained_dangling_symlinks_cli_preserve_exact_targets(self):
        repo = self.repos["babl"]
        targets = {"a": "missing/future.c", "b": "a"}
        for name, target in targets.items():
            (repo / name).symlink_to(target)
        self.components["babl"] = (repo, self.commit(repo))
        self.assertFalse((repo / "a").exists())
        self.assertFalse((repo / "b").exists())

        result, output = self.collect_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        _, files, links = self.contents(output)
        for name, target in targets.items():
            self.assertEqual(links["sources/babl/" + name], target)
        self.assertNotIn("sources/babl/missing/future.c", files)
        self.assertFalse(list(self.root.glob(".glims-core-sources-*")))


if __name__ == "__main__":
    unittest.main()
