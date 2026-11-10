#!/usr/bin/env python3
"""Compile/link only the dual-source Displace harness against immutable producer inputs.

This driver never rebuilds/relinks adapter sources or runs the harness. Select an
existing private producer containing obj/, compile.rsp, objects.rsp and link.rsp.

Response-file resolution is fixed relative to the containing .rsp directory
recursively (not cwd), to make link/compile inputs deterministic regardless of
subprocess working directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "Engine/tests/displace-source-tests.c"
FIXTURE = ROOT / "Engine/tests/filter-input-tests.c"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def response_tokens(path: Path, inputs: set[Path], stack: set[Path]) -> list[str]:
    """Rebase nested responses and known file/dir arguments before compiler use.

    Reading relative nested paths against their containing response is not
    enough: clang otherwise interprets them against cwd. Flatten into new
    output responses; the immutable producer files are never rewritten.
    """
    path = path.resolve()
    require(path not in stack, f"cyclic producer response input: {path}")
    require(path.is_file(), f"missing response input: {path}")
    inputs.add(path)
    stack = stack | {path}
    tokens = shlex.split(path.read_text())
    normalized: list[str] = []
    directory_flags = {"-I", "-L", "-F", "-isystem", "-iquote", "-isysroot"}
    file_flags = {"-include", "-imacros"}
    argument_flag: str | None = None

    def absolute(value: str, *, record: bool) -> str:
        candidate = Path(value)
        candidate = (candidate if candidate.is_absolute() else path.parent / candidate).resolve()
        if record:
            require(candidate.is_file(), f"missing producer file input: {candidate}")
            inputs.add(candidate)
        return str(candidate)

    for token in tokens:
        if argument_flag:
            normalized.append(absolute(token, record=argument_flag in file_flags))
            argument_flag = None
        elif token.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            normalized.append(token)
        elif token.startswith("@"):
            nested = Path(token[1:])
            nested = nested if nested.is_absolute() else path.parent / nested
            normalized.extend(response_tokens(nested, inputs, stack))
        elif token in directory_flags | file_flags:
            normalized.append(token)
            argument_flag = token
        elif token.startswith(("-I", "-L", "-F")) and len(token) > 2:
            normalized.append(token[:2] + absolute(token[2:], record=False))
        elif token.startswith("-Wl,"):
            parts = token.split(",")
            for index, part in enumerate(parts[1:], 1):
                if Path(part).suffix in {".o", ".a", ".dylib"} and not part.startswith("@"):
                    parts[index] = absolute(part, record=True)
            normalized.append(",".join(parts))
        elif not token.startswith("-") and Path(token).suffix in {".o", ".a", ".dylib"}:
            normalized.append(absolute(token, record=True))
        else:
            normalized.append(token)
    require(argument_flag is None, f"missing path argument in response {path}")
    return normalized


def build(producer: Path, output: Path) -> None:
    producer, output = producer.resolve(), output.resolve()
    require(producer.is_dir(), f"missing producer: {producer}")
    require(output != producer and not output.is_relative_to(producer) and not producer.is_relative_to(output),
            "test output and producer trees must be disjoint")
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())), "output must be new or empty")
    obj_dir = producer / "obj"
    require(obj_dir.is_dir(), "producer missing obj/ directory")
    objects = sorted(obj_dir.glob("*.o"))
    require({"engine", "filter", "filter-input"}.issubset({p.stem for p in objects}),
            "producer lacks required API/snapshot objects")
    responses = {name: producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")}
    inputs = set(objects)
    expanded = {name: response_tokens(path, inputs, set()) for name, path in responses.items()}
    inputs.update({HARNESS, FIXTURE, ROOT / "Engine/engine-private.h", ROOT / "Engine/filter-input.h",
                   ROOT / "Sources/CGlimsEngine/include/glims_engine.h", Path(__file__).resolve()})
    inputs = {path.resolve() for path in inputs}
    require(all(path.is_file() for path in inputs), "a declared immutable input is missing")
    source_roots = {ROOT / "Engine", ROOT / "Sources/CGlimsEngine", ROOT / "scripts"}
    protected_dirs = {path.parent for path in inputs} | source_roots
    require(not any(output == path or output.is_relative_to(path) or path.is_relative_to(output)
                    for path in protected_dirs), "output must be disjoint from all declared input directories")
    before = {str(p): digest(p) for p in sorted(inputs)}
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"producer": str(producer), "source": str(HARNESS), "inputs": before}
    (output / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    obj = output / "displace-source-tests.o"
    binary = output / "displace-source-tests"
    normalized = {name: output / ("normalized-" + name) for name in responses}
    for name, path in normalized.items():
        path.write_text(shlex.join(expanded[name]) + "\n")
    commands = [
        ["xcrun", "clang", f"@{normalized['compile.rsp']}", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
         "-I", str(ROOT / "Engine"), "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-c", str(HARNESS), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
         f"@{normalized['objects.rsp']}", f"@{normalized['link.rsp']}"]
    ]
    try:
        for command in commands:
            print("==>", shlex.join(command), flush=True)
            subprocess.run(command, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
    finally:
        after = {path: digest(Path(path)) if Path(path).is_file() else None for path in before}
        changed = [path for path, value in before.items() if after[path] != value]
        (output / "inputs-after.json").write_text(json.dumps({"inputs": after, "changed": changed}, indent=2) + "\n")
        if changed:
            message = "Immutable producer/source inputs changed: " + ", ".join(changed)
            if sys.exc_info()[0] is None:
                raise RuntimeError(message)
            print(message, file=sys.stderr)
    print(f"Built {binary}; NOT EXECUTED. Frozen inputs: {output / 'inputs.json'}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("build", help="compile/link only; never execute")
    command.add_argument("--producer", type=Path, required=True)
    command.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    build(args.producer, args.out)


if __name__ == "__main__":
    main()
