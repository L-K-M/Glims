#!/usr/bin/env python3
"""Collect pinned local GIMP/GEGL/babl Git source inputs; never a complete release source set.

No fetch, checkout, submodule update, build or network operation is performed.
The new output is a tar archive containing committed files and manifest.json.
"""
from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tempfile
import unicodedata

MAX_NODES = 68
MAX_DEPTH = 16
MAX_FILES = 100_000
MAX_SOURCE_BYTES = 4 * 1024**3
MAX_TREE_BYTES = 32 * 1024**2
MAX_SYMLINK_EXPANSIONS = 40
MAX_SYMLINK_COMPONENTS = 4096
GLIMS_PATHS = ("Engine", "Sources/CGlimsEngine", "scripts", "Resources/Info.plist", "LICENSE")


class CollectionError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CollectionError(message)


def git(arguments: list[str], repo: Path | None = None, allowed: tuple[int, ...] = (0,)) -> bytes:
    # Do not inherit a caller's alternate worktree/index, credentials helper,
    # global attributes/configuration, optional index writes or lazy fetches.
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_ATTR_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0",
                       GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_ALLOW_PROTOCOL="")
    command = ["git", "--no-optional-locks", "-c", "protocol.allow=never",
               "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"]
    if repo is not None:
        command += ["-C", str(repo)]
    try:
        result = subprocess.run(command + arguments, stdin=subprocess.DEVNULL,
                                capture_output=True, env=environment, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CollectionError(f"Local Git operation failed: {error}") from error
    require(result.returncode in allowed,
            "Local Git operation refused: " + result.stderr.decode("utf-8", "replace")[:2000].strip())
    require(len(result.stdout) <= MAX_TREE_BYTES, "Git metadata exceeds the collection limit")
    return result.stdout


def text(arguments: list[str], repo: Path) -> str:
    return git(arguments, repo).decode("utf-8").strip()


def safe_path(value: str) -> str:
    parts = PurePosixPath(value).parts
    require(value and not value.startswith("/") and "\\" not in value and
            not any(ord(c) < 32 for c in value) and
            all(p not in {".", "..", ".git"} for p in parts), "Unsafe source archive path")
    return str(PurePosixPath(value))


@dataclass
class Repository:
    path: Path
    git_dir: Path
    common_dir: Path
    objects: Path
    object_format: str
    dirty: bool | None


def repository(path: Path) -> Repository:
    path = path.resolve()
    require(path.is_dir() and not any(c in str(path) for c in "\n\r\0"), "Expected a local Git repository directory")
    bare = text(["rev-parse", "--is-bare-repository"], path) == "true"
    git_dir = Path(text(["rev-parse", "--absolute-git-dir"], path)).resolve()
    if bare:
        require(git_dir == path, "A bare input must name its repository root")
    else:
        require(Path(text(["rev-parse", "--show-toplevel"], path)).resolve() == path,
                "A working-tree input must name its repository root")
    common = Path(text(["rev-parse", "--git-common-dir"], path))
    common = (path / common).resolve() if not common.is_absolute() else common.resolve()
    objects = (common / "objects").resolve()
    require(objects.is_dir() and not any(c in str(objects) for c in "\n\r\0"), "Missing local Git object directory")
    alternates = objects / "info/alternates"
    require(not alternates.exists() or not alternates.read_bytes().strip(),
            "Input repositories with alternate object stores are not supported")
    object_format = text(["rev-parse", "--show-object-format"], path)
    require(object_format in {"sha1", "sha256"}, "Unsupported Git object format")
    # Status can invoke configured clean filters when refreshing tracked
    # files. Refuse those repositories rather than executing their programs.
    filters = git(["config", "--get-regexp", r"^filter\."], path, allowed=(0, 1))
    require(not filters, "Repositories with configured Git filters are not supported")
    dirty = None if bare else bool(git(["status", "--porcelain=v1", "--untracked-files=no",
                                       "--ignore-submodules=all"], path))
    return Repository(path, git_dir, common, objects, object_format, dirty)


@dataclass
class Entry:
    path: str
    mode: str
    oid: str
    size: int


@dataclass
class Node:
    key: str
    prefix: str
    repo: Repository
    commit: str
    tree: str
    entries: list[Entry]
    selected: tuple[str, ...]


class Collector:
    def __init__(self, modules: dict[str, Path]):
        self.modules = modules
        self.used: set[str] = set()
        self.nodes: list[Node] = []
        self.files = 0
        self.bytes = 0

    def plan(self, key: str, prefix: str, path: Path, revision: str,
             selected: tuple[str, ...] = (), depth: int = 0) -> None:
        require(depth <= MAX_DEPTH and len(self.nodes) < MAX_NODES, "Submodule recursion exceeds the collection limit")
        repo = repository(path)
        commit = text(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], repo.path)
        require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit) is not None, "Expected an exact local commit")
        tree = text(["rev-parse", commit + "^{tree}"], repo.path)
        arguments = ["ls-tree", "-r", "-l", "-z", "--full-tree", commit]
        if selected:
            arguments += ["--", *selected]
        entries = []
        for record in git(arguments, repo.path).split(b"\0"):
            if not record:
                continue
            metadata, name = record.split(b"\t", 1)
            mode, kind, oid, size = metadata.decode("ascii").split()
            name = safe_path(name.decode("utf-8"))
            require((mode, kind) in {("100644", "blob"), ("100755", "blob"),
                                      ("120000", "blob"), ("160000", "commit")}, "Unsupported Git tree entry")
            entries.append(Entry(name, mode, oid, 0 if size == "-" else int(size)))
        if selected:
            for item in selected:
                require(any(e.path == item or e.path.startswith(item + "/") for e in entries),
                        f"The Glims commit lacks required build input: {item}")
        self.files += sum(e.mode != "160000" for e in entries)
        self.bytes += sum(e.size for e in entries)
        require(self.files <= MAX_FILES and self.bytes <= MAX_SOURCE_BYTES, "Source payload exceeds the collection limit")
        self.nodes.append(Node(key, prefix, repo, commit, tree, entries, selected))
        for entry in entries:
            if entry.mode != "160000":
                continue
            child = key + "/" + entry.path
            require(child in self.modules, f"Missing explicit local submodule mapping: {child} at {entry.oid}")
            self.used.add(child)
            self.plan(child, prefix + "/" + entry.path, self.modules[child], entry.oid, depth=depth + 1)


def archive_component_key(component: str) -> str:
    # Treat canonical Unicode and case aliases conservatively for Mac
    # extraction while retaining each member's exact committed spelling.
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", component).casefold())


def validated_symlinks(nodes: list[Node]) -> dict[str, str]:
    targets: dict[str, str] = {}
    graph: dict[tuple[str, ...], tuple[str, ...]] = {}
    roots: dict[str, tuple[str, ...]] = {}
    spellings = {}
    # Plan every mapped repository before resolving anything: a parent
    # target can traverse links supplied by a nested gitlink's archive.
    for node in nodes:
        for entry in node.entries:
            name = node.prefix + "/" + entry.path
            parts = PurePosixPath(name).parts
            branch = spellings
            for part in parts:
                spelling, child = branch.setdefault(archive_component_key(part), (part, {}))
                require(spelling == part, "Source archive filename collision")
                branch = child
            if entry.mode != "120000":
                continue
            data = git(["cat-file", "blob", entry.oid], node.repo.path)
            blob = hashlib.new(node.repo.object_format, f"blob {len(data)}\0".encode("ascii") + data).hexdigest()
            require(len(data) == entry.size and blob == entry.oid,
                    "Source symlink does not match its committed blob")
            target = data.decode("utf-8")
            require(target and not target.startswith("/") and "\\" not in target and
                    not any(ord(c) < 32 for c in target), "Unsafe source symlink target")
            require(name not in targets, "Duplicate source symlink")
            targets[name] = target
            graph[tuple(archive_component_key(part) for part in parts)] = PurePosixPath(target).parts
            roots[name] = PurePosixPath(node.prefix).parts

    for name, target in targets.items():
        stack = [archive_component_key(part) for part in PurePosixPath(name).parent.parts]
        root = roots[name]
        pending = deque(PurePosixPath(target).parts)
        require(len(pending) <= MAX_SYMLINK_COMPONENTS, "Source symlink resolution exceeds the collection limit")
        steps = expansions = 0
        while pending:
            require(steps < MAX_SYMLINK_COMPONENTS, "Source symlink resolution exceeds the collection limit")
            steps += 1
            item = pending.popleft()
            if item == "..":
                require(len(stack) > len(root), "Source symlink escapes its component")
                stack.pop()
                continue
            stack.append(archive_component_key(item))
            nested = graph.get(tuple(stack))
            if nested is not None:
                # Substitute before consuming '..'. A repeated link is not
                # itself a cycle (a -> '.' may appear several times); bound
                # actual expansions and total components instead.
                expansions += 1
                require(expansions <= MAX_SYMLINK_EXPANSIONS,
                        "Source symlink expansion exceeds the collection limit")
                stack.pop()
                require(steps + len(pending) + len(nested) <= MAX_SYMLINK_COMPONENTS,
                        "Source symlink resolution exceeds the collection limit")
                pending.extendleft(reversed(nested))
    return targets


class HashReader:
    def __init__(self, stream, size: int, object_format: str):
        self.stream = stream
        self.sha = hashlib.sha256()
        self.blob = hashlib.new(object_format)
        self.blob.update(f"blob {size}\0".encode("ascii"))

    def read(self, size: int) -> bytes:
        data = self.stream.read(size)
        self.sha.update(data)
        self.blob.update(data)
        return data


def append_node(node: Node, temporary: Path, number: int, archive: tarfile.TarFile,
                paths: dict[str, str], files: list[dict], symlinks: dict[str, str]) -> None:
    # An isolated bare view reads only existing local objects. Its attributes
    # override export-ignore/export-subst, including input info/attributes,
    # so exported blobs must match the exact committed objects below.
    isolated = temporary / f"git-{number}"
    git(["init", "--bare", "--template=", f"--object-format={node.repo.object_format}", str(isolated)])
    (isolated / "objects/info/alternates").write_text(str(node.repo.objects) + "\n")
    (isolated / "info").mkdir(exist_ok=True)
    (isolated / "info/attributes").write_text("* -export-ignore -export-subst\n")
    part = temporary / f"part-{number}.tar"
    arguments = ["archive", "--format=tar", f"--prefix={node.prefix}/", f"--output={part}", node.commit]
    if node.selected:
        arguments += ["--", *node.selected]
    git(arguments, isolated)
    expected = {node.prefix + "/" + e.path: e for e in node.entries if e.mode != "160000"}
    seen = set()
    with tarfile.open(part, "r:") as source:
        for member in source:
            name = safe_path(member.name.rstrip("/"))
            member.name = name
            require(name == node.prefix or name.startswith(node.prefix + "/"), "Archive entry escaped its component")
            require(member.isdir() or member.isreg() or member.issym(), "Unsupported source archive member type")
            kind = "directory" if member.isdir() else "symlink" if member.issym() else "file"
            if name in paths:
                require(kind == paths[name] == "directory", "Duplicate source archive member")
                continue
            paths[name] = kind
            member.uid = member.gid = 0
            member.uname = member.gname = ""
            member.pax_headers = {}
            if member.isdir():
                member.mode = 0o755
                archive.addfile(member)
                continue
            require(name in expected, "Git archive contains an unexpected source file")
            entry = expected[name]
            seen.add(name)
            record = {"path": name, "type": kind, "git_blob": entry.oid, "size": entry.size}
            if member.issym():
                require(entry.mode == "120000", "Git archive changed a file into a symlink")
                target = member.linkname
                require(name in symlinks and target == symlinks[name],
                        "Git archive symlink differs from its validated target")
                data = target.encode("utf-8")
                blob = hashlib.new(node.repo.object_format, f"blob {len(data)}\0".encode("ascii") + data).hexdigest()
                require(len(data) == entry.size and blob == entry.oid, "Git archive symlink does not match its committed blob")
                member.mode = 0o777
                record.update(sha256=hashlib.sha256(data).hexdigest(), target=target, mode="0777")
                archive.addfile(member)
            else:
                require(entry.mode != "120000" and member.size == entry.size, "Git archive file differs from its tree entry")
                stream = source.extractfile(member)
                require(stream is not None, "Missing archived source bytes")
                reader = HashReader(stream, entry.size, node.repo.object_format)
                member.mode = 0o755 if entry.mode == "100755" else 0o644
                archive.addfile(member, reader)
                require(reader.blob.hexdigest() == entry.oid, "Git archive file does not match its committed blob")
                record.update(sha256=reader.sha.hexdigest(), mode=f"{member.mode:04o}")
                stream.close()
            files.append(record)
    require(seen == set(expected), "Git archive omitted committed source files")
    part.unlink()


def collect(components: dict[str, tuple[Path, str]], glims: tuple[Path, str],
            modules: dict[str, Path], output: Path) -> None:
    require(set(components) == {"gimp", "gegl", "babl"}, "Exactly GIMP, GEGL and babl inputs are required")
    destination = output.resolve()
    require(not os.path.lexists(output) and not os.path.lexists(destination), "Output already exists; overwrites are refused")
    require(destination.parent.is_dir(), "Output parent must already exist")
    collector = Collector(modules)
    for name in ("gimp", "gegl", "babl"):
        collector.plan(name, "sources/" + name, *components[name])
    collector.plan("glims", "build/glims", *glims, selected=GLIMS_PATHS)
    require(collector.used == set(modules), "Unused submodule mapping; check its component/path spelling")
    for node in collector.nodes:
        for root in (node.repo.path, node.repo.git_dir, node.repo.common_dir, node.repo.objects):
            require(not destination.is_relative_to(root), "Output must be outside every input repository and Git directory")
    symlinks = validated_symlinks(collector.nodes)
    # Staging beside the destination permits atomic, exclusive hard-link
    # publication. An incomplete archive is never installed at the output.
    with tempfile.TemporaryDirectory(prefix=".glims-core-sources-", dir=destination.parent) as directory:
        temporary = Path(directory)
        staged = temporary / "sources.tar"
        files: list[dict] = []
        paths: dict[str, str] = {}
        with tarfile.open(staged, "w:", format=tarfile.PAX_FORMAT) as archive:
            for index, node in enumerate(collector.nodes):
                append_node(node, temporary, index, archive, paths, files, symlinks)
            manifest = {
                "schema_version": 1, "scope": "pinned-core-source-inputs",
                "corresponding_source_complete": False, "source_delivery": "local_collection_only",
                "not_collected": ["MacPorts dependency source and conditional patches", "remaining runtime/build dependencies"],
                "components": [{"name": n.key, "commit": n.commit, "tree": n.tree,
                                "object_format": n.repo.object_format, "archive_prefix": n.prefix,
                                "selected_paths": list(n.selected), "tracked_worktree_dirty": n.repo.dirty,
                                "untracked_files": "not_consulted_or_exported"} for n in collector.nodes],
                "files": sorted(files, key=lambda item: item["path"]),
            }
            data = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
            member = tarfile.TarInfo("manifest.json")
            member.size, member.mode, member.mtime = len(data), 0o644, 0
            archive.addfile(member, io.BytesIO(data))
        with staged.open("rb") as stream:
            os.fsync(stream.fileno())
        try:
            os.link(staged, destination)
        except FileExistsError as error:
            raise CollectionError("Output appeared during collection; overwrites are refused") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("gimp", "gegl", "babl", "glims"):
        parser.add_argument("--" + name, nargs=2, required=True, metavar=("LOCAL_REPO", "REVISION"))
    parser.add_argument("--submodule", action="append", default=[], metavar="COMPONENT/PATH=LOCAL_REPO")
    parser.add_argument("--output", type=Path, required=True, help="new tar file outside all input repositories")
    args = parser.parse_args()
    try:
        modules = {}
        for value in args.submodule:
            key, separator, path = value.partition("=")
            require(bool(separator and path) and safe_path(key) == key and "/" in key,
                    "Expected --submodule COMPONENT/PATH=LOCAL_REPO")
            require(key not in modules, "Duplicate submodule mapping")
            modules[key] = Path(path)
        components = {name: (Path(getattr(args, name)[0]), getattr(args, name)[1]) for name in ("gimp", "gegl", "babl")}
        collect(components, (Path(args.glims[0]), args.glims[1]), modules, args.output)
    except (CollectionError, OSError, ValueError, UnicodeError, tarfile.TarError) as error:
        parser.exit(1, f"collect-core-sources: {error}\n")
    print(f"Collected {args.output}; corresponding_source_complete=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
