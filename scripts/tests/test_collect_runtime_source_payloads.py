#!/usr/bin/env python3
"""Synthetic specifications only: no live prefix, network or source archives."""
import copy
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "collect-runtime-source-payloads.py"
SPEC = importlib.util.spec_from_file_location("runtime_payload_collector", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class RuntimePayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.inputs = self.base / "inputs"
        self.inputs.mkdir()
        self.request, self.output = self.base / "request.json", self.base / "result.tar"
        self.payload_bytes = {}
        self.spec = {"schema_version": 1, "roots": {"cache": str(self.inputs)},
                     "components": {}, "payloads": {}, "evidence": []}
        group = self.add_payload("groups/shared.tcl", b"exec impossible-command; opaque group\n")
        for index, name in enumerate(("first", "second"), 1):
            recipe = self.add_payload("recipes/" + name + "/Portfile", ("opaque " + name).encode())
            if index == 1:
                self.alias = self.inputs / "images/first/+PORTFILE"
                self.alias.parent.mkdir(parents=True)
                self.alias.write_bytes(self.payload_bytes[recipe])
                self.spec["payloads"][recipe]["sources"].append({"root": "cache", "path": "images/first/+PORTFILE"})
            archive = self.add_payload("archives/" + name, b"not an archive: " + name.encode())
            self.spec["components"][name] = {
                "installed": {"registry_id": index, "name": name, "epoch": 0,
                              "version": "1.2", "revision": 3, "variants": "+quartz",
                              "requested_variants": "+quartz-x11", "archs": "arm64",
                              "ports_commit": "6" * 40},
                "bindings": [self.binding("recipe", "Portfile", recipe),
                             self.binding("archive", name + ".tar.gz", archive),
                             self.binding("portgroup", "muniversal", group, "1.0")],
                "unresolved_patches": [{"name": "not-verified.patch", "guard": "literal guard text"}]}

    def binding(self, role, name, digest, version=None):
        return {"role": role, "name": name, "version": version, "sha256": digest}

    def add_payload(self, relative, data):
        path = self.inputs / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        self.payload_bytes[digest] = data
        self.spec["payloads"][digest] = {"size": len(data), "sources": [{"root": "cache", "path": relative}]}
        return digest

    def write_request(self):
        raw = (json.dumps(self.spec, sort_keys=True, indent=2) + "\n").encode()
        self.request.write_bytes(raw)
        return raw

    def collect(self, output=None):
        self.write_request()
        collector.collect(self.request, output or self.output)

    def refused(self, output=None):
        output = output or self.output
        self.write_request()
        with self.assertRaises((collector.CollectionError, OSError, tarfile.TarError)):
            collector.collect(self.request, output)
        self.assertFalse(os.path.lexists(output))
        self.assertEqual(list(self.base.glob(".glims-runtime-payloads-*")), [])

    def test_shared_group_exact_bytes_and_partial_flags(self):
        before = {p: p.read_bytes() for p in self.inputs.rglob("*") if p.is_file()}
        self.collect()
        with tarfile.open(self.output) as archive:
            entries = archive.getmembers()
            self.assertTrue(all(entry.isreg() for entry in entries))
            self.assertEqual(archive.getnames(), sorted(archive.getnames()))
            for entry in entries:
                self.assertEqual((entry.uid, entry.gid, entry.mode, entry.mtime), (0, 0, 0o644, 0))
            manifest = json.load(archive.extractfile("manifest.json"))
            self.assertFalse(manifest["corresponding_source_complete"])
            self.assertFalse(manifest["historical_patch_payloads_verified"])
            self.assertIsNone(manifest["binary_binding"])
            self.assertEqual(manifest["source_delivery"], "local_collection_only")
            self.assertEqual(len(manifest["payloads"]), 5)
            self.assertEqual(manifest["components"]["first"]["installed"], self.spec["components"]["first"]["installed"])
            self.assertEqual(manifest["components"]["first"]["unresolved_patches"],
                             self.spec["components"]["first"]["unresolved_patches"])
            groups = [c["bindings"] for c in manifest["components"].values()]
            self.assertEqual([next(b["sha256"] for b in rows if b["role"] == "portgroup") for rows in groups],
                             [next(iter(self.payload_bytes))] * 2)
            for digest, data in self.payload_bytes.items():
                self.assertEqual(archive.extractfile("payloads/sha256/" + digest).read(), data)
            self.assertEqual(archive.extractfile("request.json").read(), self.request.read_bytes())
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_repeat_is_deterministic_and_spec_sibling_output_is_allowed(self):
        self.collect()
        other = self.base / "second.tar"
        self.collect(other)
        self.assertEqual(self.output.read_bytes(), other.read_bytes())

    def test_short_regular_reads_still_collect_exact_bytes(self):
        original = collector.os.read
        def short(fd, size):
            return original(fd, max(1, size // 2))
        with mock.patch.object(collector.os, "read", side_effect=short):
            self.collect()
        with tarfile.open(self.output) as archive:
            for digest, data in self.payload_bytes.items():
                self.assertEqual(archive.extractfile("payloads/sha256/" + digest).read(), data)

    def test_every_recipe_alias_is_verified(self):
        self.alias.write_bytes(b"different bytes")
        self.refused()

    def test_wrong_digest_and_sizes_refuse(self):
        original = copy.deepcopy(self.spec)
        for change in ("digest", "short", "long"):
            with self.subTest(change=change):
                self.spec = copy.deepcopy(original)
                digest = next(iter(self.spec["payloads"]))
                if change == "digest":
                    self.spec["payloads"]["0" * 64] = self.spec["payloads"].pop(digest)
                    for c in self.spec["components"].values():
                        for b in c["bindings"]:
                            if b["sha256"] == digest:
                                b["sha256"] = "0" * 64
                else:
                    self.spec["payloads"][digest]["size"] += -1 if change == "short" else 1
                self.refused()

    def test_missing_source_refuses(self):
        self.alias.unlink()
        self.refused()

    def test_duplicate_json_keys_refuse(self):
        raw = self.write_request().decode().rstrip()
        self.request.write_text(raw[:-1] + ', "schema_version": 1}')
        with self.assertRaisesRegex(collector.CollectionError, "Duplicate JSON"):
            collector.collect(self.request, self.output)
        self.assertFalse(self.output.exists())

    def test_unknown_fields_and_false_completeness_claims_refuse(self):
        for key in ("corresponding_source_complete", "source_delivery", "unexpected"):
            with self.subTest(key=key):
                self.spec[key] = True
                self.refused()
                del self.spec[key]

    def test_invalid_types_numbers_and_commit_refuse(self):
        original = copy.deepcopy(self.spec)
        for field, value in (("registry_id", True), ("epoch", -1), ("revision", "0"),
                             ("ports_commit", "4c08"), ("archs", [])):
            with self.subTest(field=field):
                self.spec = copy.deepcopy(original)
                self.spec["components"]["first"]["installed"][field] = value
                self.refused()
        for raw in (b'{"value": NaN}', b'{"value": Infinity}'):
            with self.assertRaises(collector.CollectionError):
                collector.parse_spec(raw)

    def test_absent_refs_and_unused_payloads_or_roots_refuse(self):
        original = copy.deepcopy(self.spec)
        for change in ("reference", "unused_payload", "unused_root"):
            with self.subTest(change=change):
                self.spec = copy.deepcopy(original)
                if change == "reference":
                    self.spec["components"]["first"]["bindings"][0]["sha256"] = "0" * 64
                elif change == "unused_payload":
                    self.add_payload("unreferenced", b"unreferenced bytes")
                else:
                    self.spec["roots"]["unused"] = str(self.base)
                self.refused()

    def test_duplicate_binding_and_registry_id_refuse(self):
        row = self.spec["components"]["first"]
        row["bindings"].append(dict(row["bindings"][0]))
        self.refused()
        row["bindings"].pop()
        self.spec["components"]["second"]["installed"]["registry_id"] = 1
        self.refused()

    def test_conflicting_same_name_portgroup_binding_refuses(self):
        row = self.spec["components"]["first"]
        duplicate = dict(next(b for b in row["bindings"] if b["role"] == "portgroup"))
        duplicate["sha256"] = row["bindings"][0]["sha256"]
        row["bindings"].append(duplicate)
        self.refused()

    def test_metadata_and_output_bounds(self):
        with self.assertRaises(collector.CollectionError):
            collector.parse_spec(b" " * (collector.MAX_REQUEST + 1))
        for field, value in (("name", "a" * 4097), ("name", "\U0001f680" * 1025)):
            original = self.spec["components"]["first"]["installed"][field]
            self.spec["components"]["first"]["installed"][field] = value
            self.refused()
            self.spec["components"]["first"]["installed"][field] = original
        for constant in ("MAX_PAYLOAD", "MAX_MANIFEST", "MAX_ARCHIVE"):
            with self.subTest(constant=constant), mock.patch.object(collector, constant, 1):
                self.refused()
        digest = next(iter(self.spec["payloads"]))
        self.spec["payloads"][digest]["size"] = collector.MAX_FILE + 1
        self.refused()

    def test_request_depth_limit(self):
        value = []
        for _ in range(10):
            value = [value]
        with self.assertRaisesRegex(collector.CollectionError, "depth"):
            collector.parse_spec(json.dumps(value).encode())

    def test_unsafe_source_paths_refuse(self):
        source = next(iter(self.spec["payloads"].values()))["sources"][0]
        for path in ("../outside", "/absolute", "a//b", "a/./b", "a/../b", "a\\b", "a\nb"):
            with self.subTest(path=path):
                source["path"] = path
                self.refused()

    def test_leaf_symlink_refuses(self):
        data = self.alias.read_bytes()
        self.alias.unlink()
        target = self.base / "retained"
        target.write_bytes(data)
        self.alias.symlink_to(target)
        self.refused()

    def test_relative_ancestor_symlink_refuses(self):
        parent = self.alias.parent
        target = self.base / "moved-images"
        parent.rename(target)
        parent.symlink_to(target, target_is_directory=True)
        self.refused()

    def test_noncanonical_root_and_ancestor_symlinks_refuse(self):
        alias = self.base / "cache-alias"
        alias.symlink_to(self.inputs, target_is_directory=True)
        self.spec["roots"]["cache"] = str(alias)
        self.refused()
        self.spec["roots"]["cache"] = str(alias / "images")
        self.refused()

    def test_spec_symlink_refuses(self):
        self.write_request()
        original = self.base / "original-request"
        self.request.rename(original)
        self.request.symlink_to(original)
        with self.assertRaises((collector.CollectionError, OSError)):
            collector.collect(self.request, self.output)
        self.assertFalse(self.output.exists())

    def test_symlink_loop_is_a_clean_cli_refusal(self):
        one, two = self.base / "loop-one", self.base / "loop-two"
        one.symlink_to(two)
        two.symlink_to(one)
        self.spec["roots"]["cache"] = str(one)
        self.write_request()
        result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--spec", str(self.request),
                                 "--output", str(self.output)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Collection refused:", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        self.assertFalse(self.output.exists())

    def test_directory_payload_refuses(self):
        self.alias.unlink()
        self.alias.mkdir()
        self.refused()

    @unittest.skipUnless(hasattr(os, "mkfifo"), "Requires Unix FIFO support")
    def test_fifo_payload_refuses_without_blocking(self):
        self.alias.unlink()
        os.mkfifo(self.alias)
        self.write_request()
        result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--spec", str(self.request),
                                 "--output", str(self.output)], capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_output_within_input_root_refuses(self):
        self.refused(self.inputs / "forbidden.tar")

    def test_output_case_alias_cannot_bypass_root(self):
        alias = self.inputs.with_name(self.inputs.name.upper())
        if not alias.exists() or not os.path.samefile(alias, self.inputs):
            self.skipTest("Filesystem is case-sensitive")
        self.refused(alias / "forbidden.tar")

    def test_existing_output_and_dangling_symlink_are_preserved(self):
        self.write_request()
        self.output.write_bytes(b"keep this output")
        with self.assertRaises(collector.CollectionError):
            collector.collect(self.request, self.output)
        self.assertEqual(self.output.read_bytes(), b"keep this output")
        self.output.unlink()
        self.output.symlink_to(self.base / "absent")
        with self.assertRaises(collector.CollectionError):
            collector.collect(self.request, self.output)
        self.assertTrue(self.output.is_symlink())

    def test_output_cannot_overwrite_spec_or_hardlinked_input(self):
        before = self.write_request()
        with self.assertRaises(collector.CollectionError):
            collector.collect(self.request, self.request)
        self.assertEqual(self.request.read_bytes(), before)
        os.link(self.alias, self.output)
        with self.assertRaises(collector.CollectionError):
            collector.collect(self.request, self.output)
        self.assertEqual(self.output.read_bytes(), self.alias.read_bytes())

    def test_output_parent_alias_to_input_is_refused(self):
        alias = self.base / "output-alias"
        alias.symlink_to(self.inputs, target_is_directory=True)
        self.refused(alias / "forbidden.tar")

    def test_competing_output_wins_without_overwrite(self):
        original = collector.os.link
        def compete(*args, **kwargs):
            self.output.write_bytes(b"competitor")
            return original(*args, **kwargs)
        self.write_request()
        with mock.patch.object(collector.os, "link", side_effect=compete), self.assertRaises(FileExistsError):
            collector.collect(self.request, self.output)
        self.assertEqual(self.output.read_bytes(), b"competitor")
        self.assertEqual(list(self.base.glob(".glims-runtime-payloads-*")), [])

    def test_write_fsync_and_link_failures_leave_no_partial_output(self):
        cases = [(collector.BoundedWriter, "write"), (collector.os, "fsync"), (collector.os, "link")]
        for owner, name in cases:
            with self.subTest(name=name), mock.patch.object(owner, name, side_effect=OSError(errno.EIO, "injected")):
                self.refused()

    def test_interrupt_before_publication_cleans_staging(self):
        self.write_request()
        with mock.patch.object(collector.os, "fsync", side_effect=KeyboardInterrupt), self.assertRaises(KeyboardInterrupt):
            collector.collect(self.request, self.output)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.base.glob(".glims-runtime-payloads-*")), [])

    def test_source_mutation_during_streaming_refuses(self):
        original = collector.HashReader.read
        changed = False
        def mutate(reader, size):
            nonlocal changed
            data = original(reader, size)
            if not changed:
                changed = True
                with (reader.source.root.path / reader.source.relative).open("ab") as stream:
                    stream.write(b"extra")
            return data
        with mock.patch.object(collector.HashReader, "read", mutate):
            self.refused()

    def test_leaf_swap_after_copy_refuses_even_with_identical_bytes(self):
        original = collector.revalidate
        swapped = False
        def swap(record):
            nonlocal swapped
            root, relative, _, _ = record
            if root.path == self.inputs and not swapped:
                swapped = True
                path = root.path / relative
                data = path.read_bytes()
                path.rename(path.with_name(path.name + ".old"))
                path.write_bytes(data)
            return original(record)
        with mock.patch.object(collector, "revalidate", swap):
            self.refused()

    def test_ancestor_swap_preserving_leaf_inode_refuses(self):
        old_parent = self.alias.parent
        replacement = self.base / "replacement"
        replacement.mkdir()
        os.link(self.alias, replacement / self.alias.name)
        original = collector.revalidate
        swapped = False
        def swap(record):
            nonlocal swapped
            if not swapped:
                swapped = True
                old_parent.rename(self.base / "old-parent")
                replacement.rename(old_parent)
            return original(record)
        with mock.patch.object(collector, "revalidate", swap):
            self.refused()

    def test_root_swap_after_copy_refuses(self):
        replacement = self.base / "replacement-root"
        shutil.copytree(self.inputs, replacement, copy_function=os.link)
        original = collector.Directory.validate
        swapped = False
        def swap(root):
            nonlocal swapped
            if not swapped:
                swapped = True
                self.inputs.rename(self.base / "old-root")
                replacement.rename(self.inputs)
            return original(root)
        with mock.patch.object(collector.Directory, "validate", swap):
            self.refused()

    def test_spec_mutation_before_publication_refuses(self):
        original = collector.write_archive
        def mutate(*args):
            original(*args)
            self.request.write_bytes(self.request.read_bytes() + b" ")
        with mock.patch.object(collector, "write_archive", side_effect=mutate):
            self.refused()

    def test_cli_refusal_is_structured_without_traceback(self):
        self.request.write_text('{"incomplete": true}')
        result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--spec", str(self.request),
                                 "--output", str(self.output)], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Collection refused:", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
