#!/usr/bin/env python3
"""Compile/link only the slot167 layer-pick harness against immutable producer inputs.

This driver never rebuilds/relinks adapter sources or runs the harness. Select an
existing private producer containing obj/, compile.rsp, objects.rsp and link.rsp.
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
HARNESS = ROOT / "Engine/tests/layer-pick-tests.c"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def resolve_response_token(token: str) -> Path | None:
    if token.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
        return None
    if token.startswith("@"):
        nested = Path(token[1:])
        return nested if nested.is_absolute() else ROOT / nested
    if token.startswith("-"):
        return None
    candidate = Path(token)
    if candidate.suffix in {".o", ".a", ".dylib"}:
        return candidate
    return None


def response_inputs(path: Path, seen: set[Path]) -> None:
    path = path.resolve()
    if path in seen:
        return
    require(path.is_file(), f"missing response input: {path}")
    seen.add(path)
    for token in shlex.split(path.read_text()):
        if token.startswith("@"):
            nested = resolve_response_token(token)
            if nested is not None:
                response_inputs(nested, seen)
            continue
        candidate = resolve_response_token(token)
        if candidate is not None:
            require(candidate.is_absolute() and candidate.is_file(),
                    f"producer link inputs must be existing absolute paths: {candidate}")
            seen.add(candidate.resolve())


def build(producer: Path, output: Path) -> None:
    producer, output = producer.resolve(), output.resolve()
    require(producer.is_dir(), f"missing producer: {producer}")
    require(output != producer and not output.is_relative_to(producer) and not producer.is_relative_to(output),
            "test output and producer trees must be disjoint")
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())), "output must be new or empty")
    objects = sorted((producer / "obj").glob("*.o"))
    require({"engine", "image"}.issubset({p.stem for p in objects}), "producer lacks required API/image objects")
    responses = {name: producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")}
    inputs = set(objects)
    for path in responses.values():
        response_inputs(path, inputs)
    inputs.update({HARNESS, ROOT / "Engine/engine-private.h", ROOT / "Engine/engine.c", ROOT / "Engine/layer-pick.c",
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
    obj = output / "layer-pick-tests.o"
    binary = output / "layer-pick-tests"
    commands = [
        # The new facade header must win even when old producer response
        # paths name a different checkout. Its include guard then prevents
        # accidentally compiling the baseline test against the old166 shape.
        ["xcrun", "clang", "-I", str(ROOT / "Sources/CGlimsEngine/include"), "-I", str(ROOT / "Engine"),
         "-include", str(ROOT / "Sources/CGlimsEngine/include/glims_engine.h"), f"@{responses['compile.rsp']}",
         "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-c", str(HARNESS), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
         f"@{responses['objects.rsp']}", f"@{responses['link.rsp']}"]
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
