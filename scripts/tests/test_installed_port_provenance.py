"""Installed-recipe inventory fixtures; never modify the real registry."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "installed-port-provenance.py"
SPEC = importlib.util.spec_from_file_location("installed_port_provenance", SCRIPT)
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class InstalledPortProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="glims-port-provenance-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prefix = self.root / "prefix"
        self.registry = self.prefix / "var/macports/registry"
        self.registry.mkdir(parents=True)
        self.database = self.registry / "registry.db"
        self.recipe = b"PortSystem 1.0\nname fixture\nversion 1.2.3\nif {$subport eq {other}} {patchfiles special.patch}\n"
        self.key = f"{sha(self.recipe)}-{len(self.recipe)}"
        self.registry_recipe = self.registry / "portfiles/fixture-1.2.3_2" / self.key / "Portfile"
        self.registry_recipe.parent.mkdir(parents=True)
        self.registry_recipe.write_bytes(self.recipe)
        self.image = self.prefix / "var/macports/software/fixture/fixture-1.2.3_2+quartz.darwin_27.arm64"
        self.image.mkdir(parents=True)
        (self.image / "+PORTFILE").write_bytes(self.recipe)
        self.contents = ("@name fixture-1.2.3_2+quartz\n@portname fixture\n@portepoch 0\n"
                         "@portversion 1.2.3\n@portrevision 2\n@archs arm64\n@portvariant +quartz\n"
                         "@ports_commit " + "a" * 40 + "\n@macports_version 2.12.7\n"
                         "Volumes/installed-file\n@comment SECRET_NOT_HEADER\n")
        (self.image / "+CONTENTS").write_text(self.contents)
        (self.image / "+STATE").write_text(f"version: 2\nchecksum: {sha(self.recipe)}\ntarget: org.macports.build\n")
        self.group_bytes = b"# exact original PortGroup\n"
        self.group = self.registry / f"portgroups/{sha(self.group_bytes)}-{len(self.group_bytes)}/cmake-1.1.tcl"
        self.group.parent.mkdir(parents=True)
        self.group.write_bytes(self.group_bytes)
        with sqlite3.connect(self.database) as connection:
            connection.create_collation("VERSION", lambda a, b: (a > b) - (a < b))
            connection.executescript("""
                CREATE TABLE ports (id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE, epoch INTEGER,
                    version TEXT COLLATE VERSION, revision INTEGER, variants TEXT,
                    requested_variants TEXT, archs TEXT, state TEXT, location TEXT, portfile TEXT);
                CREATE TABLE portgroups (id INTEGER, name TEXT, version TEXT COLLATE VERSION,
                    size INTEGER, sha256 TEXT);
            """)
            connection.execute("INSERT INTO ports VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (1, "fixture", 0, "1.2.3", 2, "+quartz", "+quartz-x11", "arm64", "installed", str(self.image), self.key))
            connection.execute("INSERT INTO portgroups VALUES (?,?,?,?,?)",
                               (1, "cmake", "1.1", len(self.group_bytes), sha(self.group_bytes)))
        self.output_count = 0

    def invoke(self, strict=True, output=None, extra=()):
        self.output_count += 1
        output = output or self.root / f"report-{self.output_count}.json"
        command = [sys.executable, "-I", str(SCRIPT), "--prefix", str(self.prefix),
                   "--port", "fixture", "--output", str(output), *extra]
        if strict:
            command.append("--strict-metadata")
        result = subprocess.run(command, capture_output=True, text=True,
                                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, timeout=20)
        return result, json.loads(output.read_text()) if output.is_file() and result.returncode in (0, 1) else None

    def assert_incomplete(self, result, report, code):
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(report["metadata_complete"])
        self.assertFalse(report["corresponding_source_complete"])
        issues = report["issues"] + [issue for port in report["ports"] for issue in port["issues"]]
        self.assertIn(code, [issue["code"] for issue in issues])

    def prefix_bytes(self):
        return {str(path.relative_to(self.prefix)): sha(path.read_bytes())
                for path in self.prefix.rglob("*") if path.is_file()}

    def test_installed_recipe_wins_and_no_sources_are_claimed(self):
        current = self.prefix / "var/macports/sources/current/Portfile"
        current.parent.mkdir(parents=True)
        current.write_text("name wrong\nversion 999\nSECRET_MUTABLE_TREE\n")
        # A normal read-only SQLite connection can initialize this sidecar;
        # immutable reads must leave it and the source tree byte-identical.
        Path(str(self.database) + "-wal").write_bytes(b"")
        Path(str(self.database) + "-shm").write_bytes(b"old")
        before = self.prefix_bytes()
        result, report = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(report["metadata_complete"])
        self.assertTrue(report["registry"]["stable"])
        self.assertEqual(report["registry"]["before"], report["registry"]["after"])
        self.assertFalse(report["corresponding_source_complete"])
        self.assertEqual(report["source_delivery"], "not_assessed")
        port = report["ports"][0]
        self.assertEqual(port["installed"]["requested_variants"], "+quartz-x11")
        self.assertEqual(port["ports_commit"], "a" * 40)
        self.assertEqual(port["registry_portfile"]["sha256"], sha(self.recipe))
        self.assertEqual(port["image"]["portfile"]["sha256"], sha(self.recipe))
        self.assertTrue(port["portgroups"][0]["file"]["verified"])
        self.assertNotIn("SECRET", json.dumps(report))
        self.assertNotIn("patchfiles", json.dumps(report))
        self.assertEqual(self.prefix_bytes(), before)

    def test_recipe_checksum_mismatch(self):
        self.registry_recipe.write_bytes(self.recipe.replace(b"name fixture", b"name fixturx"))
        self.assert_incomplete(*self.invoke(), "checksum_mismatch")

    def test_recipe_size_is_checked_independently(self):
        wrong_key = f"{sha(self.recipe)}-{len(self.recipe) + 1}"
        self.registry_recipe.parent.rename(self.registry_recipe.parent.with_name(wrong_key))
        with sqlite3.connect(self.database) as connection:
            connection.execute("UPDATE ports SET portfile=? WHERE id=1", (wrong_key,))
        self.assert_incomplete(*self.invoke(), "checksum_mismatch")

    def test_image_recipe_must_match_too(self):
        (self.image / "+PORTFILE").write_bytes(b"different image recipe")
        self.assert_incomplete(*self.invoke(), "checksum_mismatch")

    def test_installed_entry_ambiguity(self):
        with sqlite3.connect(self.database) as connection:
            connection.execute("INSERT INTO ports SELECT 2,name,epoch,'2.0',revision,variants,requested_variants,archs,state,location,portfile FROM ports")
        self.assert_incomplete(*self.invoke(), "installed_entry_count")

    def test_inactive_image_does_not_create_ambiguity(self):
        with sqlite3.connect(self.database) as connection:
            connection.execute("INSERT INTO ports SELECT 2,name,epoch,'2.0',revision,variants,requested_variants,archs,'imaged',location,portfile FROM ports")
        result, report = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["ports"][0]["installed"]["id"], 1)

    def test_missing_portgroup(self):
        self.group.unlink()
        self.assert_incomplete(*self.invoke(), "metadata_unreadable")

    def test_portgroup_checksum_mismatch(self):
        self.group.write_bytes(self.group_bytes.replace(b"original", b"tampered"))
        self.assert_incomplete(*self.invoke(), "checksum_mismatch")

    def test_nonempty_wal_is_rejected_before_sqlite_open(self):
        wal = Path(str(self.database) + "-wal")
        wal.write_bytes(b"uncheckpointed data")
        before = self.prefix_bytes()
        with mock.patch.object(inventory.sqlite3, "connect", side_effect=AssertionError("must not open")):
            report = inventory.inventory(self.prefix, ["fixture"])
        self.assertFalse(report["metadata_complete"])
        self.assertEqual(report["issues"][0]["code"], "nonempty_wal")
        self.assertEqual(self.prefix_bytes(), before)
        self.assert_incomplete(*self.invoke(), "nonempty_wal")

    def test_nonempty_journal_is_rejected_before_sqlite_open(self):
        journal = Path(str(self.database) + "-journal")
        journal.write_bytes(b"pending rollback transaction")
        Path(str(self.database) + "-wal").write_bytes(b"")
        Path(str(self.database) + "-shm").write_bytes(b"existing shared-memory bytes")
        before = self.prefix_bytes()
        with mock.patch.object(inventory.sqlite3, "connect", side_effect=AssertionError("must not open")):
            report = inventory.inventory(self.prefix, ["fixture"])
        self.assertFalse(report["metadata_complete"])
        self.assertFalse(report["registry"]["stable"])
        self.assertEqual(report["issues"][0]["code"], "nonempty_journal")
        self.assertEqual(self.prefix_bytes(), before)
        self.assert_incomplete(*self.invoke(), "nonempty_journal")
        self.assertEqual(self.prefix_bytes(), before)

    def test_absent_and_empty_journal_allow_unchanged_inventory(self):
        journal = Path(str(self.database) + "-journal")
        for contents in (None, b""):
            with self.subTest(journal=contents):
                if contents is not None:
                    journal.write_bytes(contents)
                before = self.prefix_bytes()
                report = inventory.inventory(self.prefix, ["fixture"])
                self.assertTrue(report["metadata_complete"], report["issues"])
                self.assertTrue(report["registry"]["stable"])
                self.assertFalse(report["corresponding_source_complete"])
                self.assertEqual(self.prefix_bytes(), before)

    def test_database_change_during_inspection_fails_consistency(self):
        original = inventory.inspect_port
        def changed(connection, prefix, name):
            report = original(connection, prefix, name)
            with sqlite3.connect(self.database) as writer:
                writer.execute("UPDATE ports SET requested_variants='-changed' WHERE id=1")
            return report
        with mock.patch.object(inventory, "inspect_port", side_effect=changed):
            report = inventory.inventory(self.prefix, ["fixture"])
        self.assertFalse(report["metadata_complete"])
        self.assertFalse(report["ports"][0]["metadata_complete"])
        self.assertEqual(report["issues"][0]["code"], "registry_changed")

    def test_wal_created_during_inspection_fails_consistency(self):
        original = inventory.inspect_port
        def changed(connection, prefix, name):
            report = original(connection, prefix, name)
            Path(str(self.database) + "-wal").write_bytes(b"new pending transaction")
            return report
        with mock.patch.object(inventory, "inspect_port", side_effect=changed):
            report = inventory.inventory(self.prefix, ["fixture"])
        self.assertFalse(report["metadata_complete"])
        self.assertFalse(report["ports"][0]["metadata_complete"])
        self.assertEqual(report["issues"][0]["code"], "nonempty_wal")

    def test_nonempty_journal_created_during_inspection_fails_consistency(self):
        original = inventory.inspect_port
        journal = Path(str(self.database) + "-journal")
        payload = b"new pending rollback transaction"
        before = self.prefix_bytes()
        def changed(connection, prefix, name):
            report = original(connection, prefix, name)
            journal.write_bytes(payload)
            return report
        with mock.patch.object(inventory, "inspect_port", side_effect=changed):
            report = inventory.inventory(self.prefix, ["fixture"])
        self.assertFalse(report["metadata_complete"])
        self.assertFalse(report["registry"]["stable"])
        self.assertFalse(report["ports"][0]["metadata_complete"])
        self.assertEqual(report["issues"][0]["code"], "nonempty_journal")
        self.assertEqual(self.prefix_bytes(), before | {str(journal.relative_to(self.prefix)): sha(payload)})

    def test_empty_journal_created_during_inspection_fails_consistency(self):
        original = inventory.inspect_port
        journal = Path(str(self.database) + "-journal")
        before = self.prefix_bytes()
        def changed(connection, prefix, name):
            report = original(connection, prefix, name)
            journal.write_bytes(b"")
            return report
        with mock.patch.object(inventory, "inspect_port", side_effect=changed):
            report = inventory.inventory(self.prefix, ["fixture"])
        self.assertFalse(report["metadata_complete"])
        self.assertFalse(report["registry"]["stable"])
        self.assertFalse(report["ports"][0]["metadata_complete"])
        self.assertEqual(report["issues"][0]["code"], "registry_changed")
        self.assertEqual(self.prefix_bytes(), before | {str(journal.relative_to(self.prefix)): sha(b"")})

    def test_missing_ports_commit_is_incomplete(self):
        (self.image / "+CONTENTS").write_text(self.contents.replace("@ports_commit " + "a" * 40 + "\n", ""))
        self.assert_incomplete(*self.invoke(), "missing_ports_commit")

    def test_non_strict_mode_reports_incomplete_without_claiming_success(self):
        self.group.unlink()
        result, report = self.invoke(strict=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(report["metadata_complete"])
        self.assertIn("metadata_complete=false", result.stdout)

    def test_output_requires_explicit_overwrite(self):
        output = self.root / "existing.json"
        output.write_text("original output")
        result, _ = self.invoke(output=output)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(output.read_text(), "original output")
        result, report = self.invoke(output=output, extra=("--overwrite",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(report["metadata_complete"])

    def test_even_explicit_overwrite_cannot_write_inside_prefix(self):
        before = self.database.read_bytes()
        result, _ = self.invoke(output=self.database, extra=("--overwrite",))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.database.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
