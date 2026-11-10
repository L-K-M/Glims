#!/usr/bin/env python3
"""Inventory exact installed MacPorts recipes; never assess complete sources."""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import tempfile

KEY = re.compile(r"([0-9a-f]{64})-([0-9]+)\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
VARIANTS = re.compile(r"(?:[+-][A-Za-z0-9_.]+)*\Z")
HEADER_LIMIT = 65536
PORT_FIELDS = "id,name,epoch,version,revision,variants,requested_variants,archs,state,location,portfile"


class MetadataError(Exception):
    def __init__(self, code: str, message: str, path: Path | None = None):
        super().__init__(message)
        self.issue = {"code": code, "message": message}
        if path is not None:
            self.issue["path"] = str(path)


def component(value: object) -> str:
    if not isinstance(value, str) or not value or value in (".", "..") or any(c in value for c in "/\\\0"):
        raise MetadataError("invalid_component", "Registry metadata contains an invalid path component.")
    return value


def within(path: Path, directory: Path) -> Path:
    resolved = path.resolve()
    if not resolved.is_relative_to(directory.resolve()):
        raise MetadataError("outside_prefix", "Metadata path escapes its expected prefix directory.", path)
    return resolved


def file_fingerprint(path: Path) -> dict:
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise MetadataError("not_regular", "Expected a regular metadata file.", path)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    after = path.stat()
    def identity(info):
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    if identity(before) != identity(after):
        raise MetadataError("file_changed", "Metadata file changed while being read.", path)
    return {"size": after.st_size, "sha256": digest.hexdigest(),
            "device": after.st_dev, "inode": after.st_ino,
            "mtime_ns": after.st_mtime_ns, "ctime_ns": after.st_ctime_ns}


def wal_fingerprint(database: Path) -> dict | None:
    path = Path(str(database) + "-wal")
    try:
        evidence = file_fingerprint(path)
    except FileNotFoundError:
        return None
    if evidence["size"]:
        raise MetadataError("nonempty_wal", "Refusing immutable reads while the registry WAL is nonempty.", path)
    return evidence


def verified_file(path: Path, digest: str, size: int, issues: list) -> dict:
    evidence = {"path": str(path), "expected_sha256": digest, "expected_size": size, "verified": False}
    try:
        found = file_fingerprint(path)
        evidence.update(sha256=found["sha256"], size=found["size"])
        if found["sha256"] != digest or found["size"] != size:
            raise MetadataError("checksum_mismatch", "Metadata SHA-256 or size differs from the installed registry.", path)
        evidence["verified"] = True
    except (OSError, MetadataError) as error:
        issues.append(error.issue if isinstance(error, MetadataError) else
                      {"code": "metadata_unreadable", "message": "Installed metadata file is unavailable.", "path": str(path)})
    return evidence


def contents_header(path: Path) -> dict[str, list[str]]:
    """Read only archive headers, not installed-file inventory or arbitrary text."""
    with path.open("rb") as stream:
        data = stream.read(HEADER_LIMIT + 1)
    result = {}
    allowed = {"portname", "portepoch", "portversion", "portrevision", "archs", "portvariant",
               "ports_commit", "macports_version", "os.subplatform", "os.version", "macos_version",
               "xcodeversion", "xcodecltversion", "source_date_epoch"}
    for line in data.splitlines():
        if not line.startswith(b"@"):
            break
        words = line[1:].decode("utf-8").split(None, 1)
        if len(words) == 2 and words[0] in allowed:
            result.setdefault(words[0], []).append(words[1])
    else:
        if len(data) > HEADER_LIMIT:
            raise MetadataError("oversized_header", "Image metadata header exceeds its bounded read.", path)
    return result


def image_evidence(prefix: Path, installed: dict, digest: str, size: int, issues: list) -> dict:
    location = Path(installed["location"])
    if not location.is_absolute():
        raise MetadataError("invalid_image_location", "Installed image location must be absolute.")
    location = within(location, prefix / "var/macports/software")
    if not location.is_dir():
        raise MetadataError("unsupported_image", "Expected an unpacked installed software image directory.", location)
    recipe = within(location / "+PORTFILE", prefix / "var/macports/software")
    result = {"location": str(location), "portfile": verified_file(recipe, digest, size, issues)}
    contents = within(location / "+CONTENTS", prefix / "var/macports/software")
    before = file_fingerprint(contents)
    header = contents_header(contents)
    if file_fingerprint(contents) != before:
        raise MetadataError("file_changed", "Image contents metadata changed while being parsed.", contents)
    result["contents"] = {"path": str(contents), "sha256": before["sha256"], "size": before["size"], "header": header}
    expected = {"portname": installed["name"], "portepoch": str(installed["epoch"]),
                "portversion": installed["version"], "portrevision": str(installed["revision"]),
                "archs": installed["archs"]}
    for key, value in expected.items():
        if header.get(key) != [value]:
            issues.append({"code": "image_metadata_mismatch", "message": f"Image header {key} differs from the installed entry.", "path": str(contents)})
    variants = installed["variants"]
    if not isinstance(variants, str) or not VARIANTS.fullmatch(variants):
        raise MetadataError("invalid_variants", "Installed variant encoding is not recognized.")
    variant_tokens = re.findall(r"[+-][A-Za-z0-9_.]+", variants)
    if sorted(header.get("portvariant", [])) != sorted(variant_tokens):
        issues.append({"code": "image_metadata_mismatch", "message": "Image variants differ from the installed entry.", "path": str(contents)})
    commits = header.get("ports_commit", [])
    if len(commits) != 1 or not HEX40.fullmatch(commits[0]):
        issues.append({"code": "missing_ports_commit", "message": "Image metadata lacks one exact installed ports commit.", "path": str(contents)})
    result["ports_commit"] = commits[0] if len(commits) == 1 and HEX40.fullmatch(commits[0]) else None
    # STATE is supplemental: binary images may omit it. If present, its
    # checksum must agree with the original recipe, not an upstream payload.
    state = within(location / "+STATE", prefix / "var/macports/software")
    if state.exists():
        evidence = file_fingerprint(state)
        with state.open("rb") as stream:
            text = stream.read(HEADER_LIMIT + 1)
        if len(text) > HEADER_LIMIT or file_fingerprint(state) != evidence:
            raise MetadataError("invalid_state", "Image state is oversized or changed during reading.", state)
        sums = re.findall(rb"^checksum: ([0-9a-f]{64})$", text, re.M)
        if sums != [digest.encode("ascii")]:
            issues.append({"code": "state_recipe_mismatch", "message": "Image state does not confirm the installed recipe digest.", "path": str(state)})
        result["state"] = {"path": str(state), "sha256": evidence["sha256"], "size": evidence["size"]}
    return result


def inspect_port(connection: sqlite3.Connection, prefix: Path, requested: str) -> dict:
    result = {"requested_name": requested, "metadata_complete": False, "issues": []}
    issues = result["issues"]
    rows = connection.execute(f"SELECT {PORT_FIELDS} FROM ports WHERE name=? COLLATE NOCASE AND state='installed' ORDER BY id", (requested,)).fetchall()
    if len(rows) != 1:
        issues.append({"code": "installed_entry_count", "message": f"Expected one installed active entry; found {len(rows)}."})
        return result
    installed = dict(rows[0])
    result["installed"] = installed
    try:
        name, version = component(installed["name"]), component(installed["version"])
        revision = installed["revision"]
        if not isinstance(revision, int) or revision < 0 or not isinstance(installed["epoch"], int):
            raise MetadataError("invalid_version", "Installed epoch/revision metadata is invalid.")
        key = installed["portfile"]
        match = KEY.fullmatch(key) if isinstance(key, str) else None
        if not match:
            raise MetadataError("invalid_recipe_key", "Registry recipe key must contain SHA-256 and size.")
        digest, size = match.group(1), int(match.group(2))
        registry = prefix / "var/macports/registry"
        recipe = within(registry / "portfiles" / f"{name}-{version}_{revision}" / key / "Portfile", registry / "portfiles")
        result["registry_portfile"] = verified_file(recipe, digest, size, issues)
        result["image"] = image_evidence(prefix, installed, digest, size, issues)
        result["ports_commit"] = result["image"]["ports_commit"]
        result["portgroups"] = []
        groups = connection.execute("SELECT name,version,size,sha256 FROM portgroups WHERE id=? ORDER BY name, version COLLATE BINARY, sha256", (installed["id"],)).fetchall()
        for row in groups:
            group = dict(row)
            group_name, group_version = component(group["name"]), component(group["version"])
            if not isinstance(group["size"], int) or group["size"] < 0 or not re.fullmatch(r"[0-9a-f]{64}", group["sha256"] or ""):
                raise MetadataError("invalid_group_key", "Recorded PortGroup digest/size is invalid.")
            path = within(registry / "portgroups" / f"{group['sha256']}-{group['size']}" / f"{group_name}-{group_version}.tcl", registry / "portgroups")
            group["file"] = verified_file(path, group["sha256"], group["size"], issues)
            result["portgroups"].append(group)
    except (MetadataError, OSError, UnicodeError, TypeError) as error:
        issues.append(error.issue if isinstance(error, MetadataError) else
                      {"code": "metadata_unreadable", "message": "Installed recipe/image metadata could not be read safely."})
    result["metadata_complete"] = not issues
    return result


def inventory(prefix: Path, names: list[str]) -> dict:
    prefix = prefix.resolve()
    database = prefix / "var/macports/registry/registry.db"
    report = {"schema_version": 1, "prefix": str(prefix), "requested_ports": names,
              "metadata_complete": False, "corresponding_source_complete": False,
              "source_delivery": "not_assessed", "issues": [], "ports": [],
              "registry": {"path": str(database), "read_mode": "immutable_read_only", "stable": False}}
    evidence = report["registry"]
    try:
        evidence["wal_before"] = wal_fingerprint(database)
        evidence["before"] = file_fingerprint(database)
        if wal_fingerprint(database) != evidence["wal_before"]:
            raise MetadataError("registry_changed", "Registry WAL changed before immutable reads.", database)
        uri = database.as_uri() + "?mode=ro&immutable=1"
        with closing(sqlite3.connect(uri, uri=True)) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA query_only=ON")
            report["ports"] = [inspect_port(connection, prefix, name) for name in names]
        evidence["after"] = file_fingerprint(database)
        evidence["wal_after"] = wal_fingerprint(database)
        if evidence["before"] != evidence["after"] or evidence["wal_before"] != evidence["wal_after"]:
            raise MetadataError("registry_changed", "Registry database/WAL changed during inventory; results are incomplete.", database)
        evidence["stable"] = True
    except (MetadataError, OSError, sqlite3.Error) as error:
        report["issues"].append(error.issue if isinstance(error, MetadataError) else
                                {"code": "registry_unreadable", "message": "Installed registry is missing or unreadable.", "path": str(database)})
        for port in report["ports"]:
            port["metadata_complete"] = False
    report["metadata_complete"] = evidence["stable"] and bool(report["ports"]) and all(port["metadata_complete"] for port in report["ports"])
    return report


def write_report(path: Path, report: dict, overwrite: bool) -> None:
    text = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if not overwrite:
        with path.open("x", encoding="utf-8") as stream:
            stream.write(text)
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".installed-port-provenance-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--port", action="append", required=True, dest="ports", metavar="NAME")
    parser.add_argument("--output", type=Path, required=True, help="explicit JSON path outside the source prefix; parent must exist")
    parser.add_argument("--strict-metadata", action="store_true", help="exit 1 if any installed metadata or registry consistency check fails")
    parser.add_argument("--overwrite", action="store_true", help="explicitly replace an existing output JSON")
    args = parser.parse_args()
    prefix, output = args.prefix.resolve(), args.output.resolve()
    if output == prefix or output.is_relative_to(prefix):
        parser.error("output must be outside the read-only source prefix")
    if not output.parent.is_dir():
        parser.error("output parent directory must already exist")
    if output.exists() and not args.overwrite:
        parser.error("output already exists; use a new path or explicit --overwrite")
    if any(not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.+-]*", name) for name in args.ports):
        parser.error("port names must be simple MacPorts names")
    names = sorted(set(args.ports), key=lambda name: (name.casefold(), name))
    report = inventory(prefix, names)
    try:
        write_report(output, report, args.overwrite)
    except OSError as error:
        parser.exit(2, f"Could not write explicit output: {error}\n")
    print(f"metadata_complete={str(report['metadata_complete']).lower()}; source_delivery=not_assessed; {output}")
    return 1 if args.strict_metadata and not report["metadata_complete"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
