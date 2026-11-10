#!/usr/bin/env python3
"""Collect explicitly supplied local runtime payloads; never complete sources.

Payloads stay opaque. This tool evaluates no recipes and consults no registry,
Git checkout, network, archive contents or current ports tree.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import tarfile

MAX_REQUEST = 1024**2
MAX_MANIFEST = 2 * 1024**2
MAX_FILE = 128 * 1024**2
MAX_PAYLOAD = 256 * 1024**2
MAX_ARCHIVE = 260 * 1024**2
CHUNK = 1024**2
HEX = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
IDENTIFIER = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
READ_FLAGS = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW


class CollectionError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise CollectionError(message)


def object_fields(value, fields):
    require(type(value) is dict and set(value) == set(fields),
            "Missing or unknown object fields")


def bounded_text(value, nonempty=False):
    require(type(value) is str, "Expected a string")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError as error:
        raise CollectionError("Strings must be valid UTF-8") from error
    require(size <= 4096 and not any(ord(c) < 32 or ord(c) == 127 for c in value)
            and (not nonempty or size > 0), "Invalid or oversized string")
    return value


def integer(value, maximum, minimum=0):
    require(type(value) is int and minimum <= value <= maximum, "Invalid integer")


def sequence(value, maximum, minimum=0):
    require(type(value) is list and minimum <= len(value) <= maximum, "Invalid list length")


def relative_parts(value):
    bounded_text(value, True)
    parts = value.split("/")
    require("\\" not in value and all(p not in {"", ".", ".."} for p in parts),
            "Source paths must contain strict relative components")
    return parts


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key")
        result[key] = value
    return result


def json_shape(value, depth=0):
    require(depth <= 8, "JSON depth exceeds eight")
    if type(value) is dict:
        for key, child in value.items():
            bounded_text(key)
            json_shape(child, depth + 1)
    elif type(value) is list:
        for child in value:
            json_shape(child, depth + 1)
    elif type(value) is str:
        bounded_text(value)


def parse_spec(raw):
    require(len(raw) <= MAX_REQUEST, "Request exceeds 1 MiB")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                           parse_constant=lambda _: require(False, "Nonfinite JSON number"))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise CollectionError("Invalid UTF-8 JSON request") from error
    json_shape(value)
    object_fields(value, ("schema_version", "roots", "components", "payloads", "evidence"))
    require(type(value["schema_version"]) is int and value["schema_version"] == 1,
            "Unsupported schema version")
    roots, components, payloads = (value[k] for k in ("roots", "components", "payloads"))
    require(type(roots) is dict and 1 <= len(roots) <= 16, "Expected 1..16 input roots")
    require(type(components) is dict and 1 <= len(components) <= 128,
            "Expected 1..128 component records")
    require(type(payloads) is dict and 1 <= len(payloads) <= 64, "Expected 1..64 payloads")
    for key, path in roots.items():
        require(IDENTIFIER.fullmatch(key) is not None, "Invalid root ID")
        bounded_text(path, True)
        require(Path(path).is_absolute() and str(Path(path)) == path, "Input root is not absolute/canonical")
    used_roots, used_payloads, source_keys = set(), set(), {}
    total = 0
    for digest, payload in payloads.items():
        require(HEX.fullmatch(digest) is not None, "Invalid payload SHA256")
        object_fields(payload, ("size", "sources"))
        integer(payload["size"], MAX_FILE)
        total += payload["size"]
        sequence(payload["sources"], 16, 1)
        aliases = set()
        for source in payload["sources"]:
            object_fields(source, ("root", "path"))
            require(type(source["root"]) is str and source["root"] in roots, "Unknown input root")
            relative_parts(source["path"])
            key = (source["root"], source["path"])
            require(key not in aliases, "Duplicate source alias")
            require(key not in source_keys or source_keys[key] == digest, "Conflicting source alias")
            aliases.add(key)
            source_keys[key] = digest
            used_roots.add(source["root"])
    require(total <= MAX_PAYLOAD, "Payload total exceeds 256 MiB")
    registry_ids = set()
    for key, component in components.items():
        require(IDENTIFIER.fullmatch(key) is not None, "Invalid component ID")
        object_fields(component, ("installed", "bindings", "unresolved_patches"))
        installed = component["installed"]
        object_fields(installed, ("registry_id", "name", "epoch", "version", "revision", "variants",
                                  "requested_variants", "archs", "ports_commit"))
        integer(installed["registry_id"], 2**63 - 1, 1)
        require(installed["registry_id"] not in registry_ids, "Duplicate installed registry ID")
        registry_ids.add(installed["registry_id"])
        for field in ("epoch", "revision"):
            integer(installed[field], 2**63 - 1)
        for field in ("name", "version", "archs", "ports_commit"):
            bounded_text(installed[field], True)
        for field in ("variants", "requested_variants"):
            bounded_text(installed[field])
        require(COMMIT.fullmatch(installed["ports_commit"]) is not None, "Invalid recorded ports commit")
        sequence(component["bindings"], 64, 1)
        bindings, recipes = set(), 0
        for binding in component["bindings"]:
            object_fields(binding, ("role", "name", "version", "sha256"))
            require(type(binding["role"]) is str and binding["role"] in {"archive", "recipe", "portgroup"},
                    "Unknown payload role")
            bounded_text(binding["name"], True)
            if binding["role"] == "portgroup":
                bounded_text(binding["version"], True)
            else:
                require(binding["version"] is None, "Only PortGroup bindings have a version")
            require(type(binding["sha256"]) is str and binding["sha256"] in payloads,
                    "Binding refers to an absent payload")
            identity = (binding["role"], binding["name"], binding["version"])
            require(identity not in bindings, "Duplicate component binding")
            bindings.add(identity)
            recipes += binding["role"] == "recipe"
            used_payloads.add(binding["sha256"])
        require(recipes == 1, "Each component requires exactly one recipe binding")
        sequence(component["unresolved_patches"], 64)
        patches = set()
        for patch in component["unresolved_patches"]:
            object_fields(patch, ("name", "guard"))
            identity = tuple(bounded_text(patch[k], True) for k in ("name", "guard"))
            require(identity not in patches, "Duplicate patch declaration")
            patches.add(identity)
    require(used_roots == set(roots) and used_payloads == set(payloads), "Unused root or payload")
    sequence(value["evidence"], 16)
    labels = set()
    for evidence in value["evidence"]:
        object_fields(evidence, ("label", "sha256", "notes"))
        bounded_text(evidence["label"], True)
        bounded_text(evidence["notes"])
        require(type(evidence["sha256"]) is str and HEX.fullmatch(evidence["sha256"]), "Invalid evidence SHA256")
        require(evidence["label"] not in labels, "Duplicate evidence label")
        labels.add(evidence["label"])
    return value


def directory_identity(info):
    require(stat.S_ISDIR(info.st_mode), "Expected a directory")
    return info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode)


def file_identity(info):
    require(stat.S_ISREG(info.st_mode), "Expected a regular file")
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def walk_directory(path):
    """Open every absolute component without following symlinks; close predecessors."""
    path = Path(path)
    require(path.is_absolute(), "Directory must be absolute")
    fd = os.open("/", DIRECTORY_FLAGS)
    chain = [directory_identity(os.fstat(fd))]
    try:
        for part in path.parts[1:]:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            chain.append(directory_identity(os.fstat(fd)))
        return fd, chain
    except BaseException:
        os.close(fd)
        raise


def canonical_path(path):
    try:
        return Path(path).resolve(strict=True)
    except RuntimeError as error:
        raise CollectionError("Directory contains a symlink loop") from error


class Directory:
    def __init__(self, path, canonical=False):
        self.path = Path(path)
        if canonical:
            require(str(canonical_path(self.path)) == str(self.path), "Input root contains an alias")
        self.fd, self.chain = walk_directory(self.path)

    def validate(self):
        fd, chain = walk_directory(self.path)
        try:
            require(chain == self.chain and directory_identity(os.fstat(self.fd)) == chain[-1],
                    "Directory ancestry changed")
        finally:
            os.close(fd)

    def close(self):
        os.close(self.fd)


def relative_parent(root, parts):
    fd = os.dup(root.fd)
    chain = []
    try:
        for part in parts[:-1]:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            chain.append(directory_identity(os.fstat(fd)))
        return fd, chain
    except BaseException:
        os.close(fd)
        raise


class Source:
    def __init__(self, root, relative):
        self.root, self.relative = root, relative
        self.parts = relative_parts(relative)
        self.parent, self.chain = relative_parent(root, self.parts)
        self.fd = None
        try:
            self.fd = os.open(self.parts[-1], READ_FLAGS, dir_fd=self.parent)
            self.before = file_identity(os.fstat(self.fd))
        except BaseException:
            self.close()
            raise

    def validate(self):
        require(file_identity(os.fstat(self.fd)) == self.before and
                file_identity(os.stat(self.parts[-1], dir_fd=self.parent, follow_symlinks=False)) == self.before,
                "Input file changed during reading")

    def record(self):
        self.validate()
        return self.root, self.relative, self.chain, self.before

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
        os.close(self.parent)


def revalidate(record):
    root, relative, chain, identity = record
    source = Source(root, relative)
    try:
        require(source.chain == chain and source.before == identity, "Input path changed after reading")
        source.validate()
    finally:
        source.close()


class HashReader:
    def __init__(self, source, size):
        require(source.before[3] == size, "Input file size does not match request")
        self.source, self.remaining = source, size
        self.hash = hashlib.sha256()

    def read(self, size):
        wanted = min(size, self.remaining, CHUNK)
        chunks = []
        while wanted:
            data = os.read(self.source.fd, wanted)
            if not data:
                break
            chunks.append(data)
            self.remaining -= len(data)
            wanted -= len(data)
            self.hash.update(data)
        return b"".join(chunks)

    def finish(self, digest):
        require(self.remaining == 0 and os.read(self.source.fd, 1) == b"", "Input length changed")
        require(self.hash.hexdigest() == digest, "Input SHA256 does not match request")
        self.source.validate()


class BoundedWriter:
    def __init__(self, stream):
        self.stream, self.size = stream, 0

    def write(self, data):
        require(self.size + len(data) <= MAX_ARCHIVE, "Output archive exceeds 260 MiB")
        written = self.stream.write(data)
        require(written == len(data), "Incomplete archive write")
        self.size += written
        return written

    def tell(self):
        return self.size

    def flush(self):
        self.stream.flush()


def member(name, size):
    result = tarfile.TarInfo(name)
    result.size, result.mode, result.mtime = size, 0o644, 0
    result.uid = result.gid = 0
    result.uname = result.gname = ""
    return result


def manifest_bytes(raw, spec):
    files = [{"sha256": digest, "size": payload["size"],
              "sources": sorted(payload["sources"], key=lambda row: (row["root"], row["path"])),
              "path": "payloads/sha256/" + digest}
             for digest, payload in sorted(spec["payloads"].items())]
    components = {}
    for key, value in sorted(spec["components"].items()):
        components[key] = {**value, "bindings": sorted(value["bindings"],
            key=lambda row: (row["role"], row["name"], row["version"] or "", row["sha256"])),
            "unresolved_patches": sorted(value["unresolved_patches"], key=lambda row: (row["name"], row["guard"]))}
    manifest = {"schema_version": 1, "scope": "explicit-local-runtime-payloads",
                "corresponding_source_complete": False, "source_delivery": "local_collection_only",
                "binary_binding": None, "historical_patch_payloads_verified": False,
                "request_sha256": hashlib.sha256(raw).hexdigest(), "roots": spec["roots"],
                "components": components, "payloads": files,
                "evidence": sorted(spec["evidence"], key=lambda row: row["label"])}
    data = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
    require(len(data) <= MAX_MANIFEST, "Output manifest exceeds 2 MiB")
    return data


def write_archive(stream, raw, spec, roots, records):
    data = manifest_bytes(raw, spec)
    with tarfile.open(fileobj=BoundedWriter(stream), mode="w:", format=tarfile.PAX_FORMAT) as archive:
        # These claims are published only after every payload and alias verifies.
        archive.addfile(member("manifest.json", len(data)), io.BytesIO(data))
        for digest, payload in sorted(spec["payloads"].items()):
            aliases = sorted(payload["sources"], key=lambda row: (row["root"], row["path"]))
            for index, alias in enumerate(aliases):
                source = Source(roots[alias["root"]], alias["path"])
                try:
                    reader = HashReader(source, payload["size"])
                    if index == 0:
                        archive.addfile(member("payloads/sha256/" + digest, payload["size"]), reader)
                    else:
                        while reader.remaining:
                            require(reader.read(CHUNK), "Input ended before its declared length")
                    reader.finish(digest)
                    records.append(source.record())
                finally:
                    source.close()
        archive.addfile(member("request.json", len(raw)), io.BytesIO(raw))


def absent(parent, name):
    try:
        os.stat(name, dir_fd=parent.fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise CollectionError("Output already exists; overwrites are refused")


def collect(spec_path, output):
    spec_path, output = Path(spec_path), Path(output)
    spec_parent = Directory(canonical_path(spec_path.parent))
    roots, output_parent = {}, None
    stage, stage_fd, archive_fd, published = None, None, None, False
    stage_identity = archive_identity = None
    stage_created = False
    records = []
    try:
        source = Source(spec_parent, spec_path.name)
        try:
            require(source.before[3] <= MAX_REQUEST, "Request exceeds 1 MiB")
            chunks = []
            remaining = source.before[3]
            while remaining:
                chunk = os.read(source.fd, min(CHUNK, remaining))
                require(chunk, "Request ended early")
                chunks.append(chunk)
                remaining -= len(chunk)
            require(os.read(source.fd, 1) == b"", "Request grew during reading")
            raw = b"".join(chunks)
            records.append(source.record())
        finally:
            source.close()
        spec = parse_spec(raw)
        root_ids = set()
        for name, path in spec["roots"].items():
            root = Directory(path, canonical=True)
            roots[name] = root
            require(root.chain[-1] not in root_ids, "Input roots refer to the same directory")
            root_ids.add(root.chain[-1])
        relative_parts(output.name)
        output_parent = Directory(canonical_path(output.parent))
        require(not root_ids.intersection(output_parent.chain), "Output is inside a protected input root")
        absent(output_parent, output.name)
        stage = ".glims-runtime-payloads-" + secrets.token_hex(16)
        os.mkdir(stage, 0o700, dir_fd=output_parent.fd)
        stage_created = True
        stage_identity = directory_identity(os.stat(stage, dir_fd=output_parent.fd, follow_symlinks=False))
        stage_fd = os.open(stage, DIRECTORY_FLAGS, dir_fd=output_parent.fd)
        require(directory_identity(os.fstat(stage_fd)) == stage_identity, "Staging directory was replaced")
        archive_fd = os.open("payloads.tar", os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=stage_fd)
        archive_identity = os.fstat(archive_fd)
        with os.fdopen(os.dup(archive_fd), "wb") as stream:
            write_archive(stream, raw, spec, roots, records)
        os.fsync(archive_fd)
        for root in [spec_parent, output_parent, *roots.values()]:
            root.validate()
        for record in records:
            revalidate(record)
        require(directory_identity(os.stat(stage, dir_fd=output_parent.fd, follow_symlinks=False)) == stage_identity,
                "Staging directory changed")
        current = os.stat("payloads.tar", dir_fd=stage_fd, follow_symlinks=False)
        require(stat.S_ISREG(current.st_mode) and (current.st_dev, current.st_ino) ==
                (archive_identity.st_dev, archive_identity.st_ino), "Staging file changed")
        os.link("payloads.tar", output.name, src_dir_fd=stage_fd,
                dst_dir_fd=output_parent.fd, follow_symlinks=False)
        published = True
    finally:
        cleanup_errors = []
        if archive_fd is not None:
            os.close(archive_fd)
        if stage_fd is not None and archive_identity is not None:
            try:
                entry = os.stat("payloads.tar", dir_fd=stage_fd, follow_symlinks=False)
                if (entry.st_dev, entry.st_ino) == (archive_identity.st_dev, archive_identity.st_ino):
                    os.unlink("payloads.tar", dir_fd=stage_fd)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_errors.append(str(error))
        if stage_fd is not None:
            os.close(stage_fd)
        if stage_created and stage_identity is not None:
            try:
                entry = os.stat(stage, dir_fd=output_parent.fd, follow_symlinks=False)
                if directory_identity(entry) == stage_identity:
                    os.rmdir(stage, dir_fd=output_parent.fd)
            except (OSError, CollectionError) as error:
                cleanup_errors.append(str(error))
        if output_parent is not None:
            output_parent.close()
        for root in roots.values():
            root.close()
        spec_parent.close()
        if cleanup_errors:
            print("Owned staging cleanup incomplete: " + "; ".join(cleanup_errors), file=sys.stderr)
    require(published, "Archive was not published")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        collect(args.spec, args.output)
    except (CollectionError, OSError, tarfile.TarError) as error:
        print("Collection refused: " + str(error), file=sys.stderr)
        return 1
    print("Collected explicit local payloads; corresponding_source_complete=false")
    return 0


if __name__ == "__main__":
    sys.exit(main())
