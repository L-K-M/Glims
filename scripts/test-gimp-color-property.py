#!/usr/bin/env python3
"""Build only this color-property fixture against immutable adapter objects.

Run is a separate explicit command using the existing bounded private-HOME
native runner. Neither command rebuilds or relinks the producer adapter.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import runpy
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "Engine/tests/gimp-color-property-tests.c"
READER = ROOT / "Engine/filter-properties.c"
RESPONSE_HELPER = ROOT / "scripts/test-displace-source.py"
RUNTIME_HELPER = ROOT / "scripts/test-tablet-stroke-v2.py"
_native = runpy.run_path(str(RESPONSE_HELPER))
digest, require, response_tokens = (_native[key] for key in ("digest", "require", "response_tokens"))
_runtime = runpy.run_path(str(RUNTIME_HELPER))
disjoint, fresh, write_json = (_runtime[key] for key in ("disjoint", "fresh", "write_json"))
NAME = "gimp-color-property-tests"


def build(producer: Path, output: Path) -> None:
    producer, output = producer.resolve(), output.resolve()
    require(producer.is_dir() and disjoint(output, producer), "producer and output must be disjoint")
    objects = sorted((producer / "obj").glob("*.o"))
    require({"engine", "filter", "filter-properties"}.issubset({path.stem for path in objects}),
            "producer must contain the existing public API and native property objects")
    inputs = set(objects)
    responses = ("compile.rsp", "objects.rsp", "link.rsp")
    expanded = {name: response_tokens(producer / name, inputs, set()) for name in responses}
    inputs.update({HARNESS, READER, RESPONSE_HELPER, RUNTIME_HELPER, Path(__file__).resolve(),
                   ROOT / "Sources/CGlimsEngine/include/glims_engine.h"})
    inputs.update((ROOT / "Engine").glob("*.h"))
    inputs = {path.resolve() for path in inputs}
    require(all(path.is_file() for path in inputs), "an immutable input is missing")
    require(disjoint(output, ROOT) and all(disjoint(output, path.parent) for path in inputs),
            "output must be outside source and declared input directories")
    before = {str(path): digest(path) for path in sorted(inputs)}
    fresh(output)
    write_json(output / "inputs.json", {"producer": str(producer), "inputs": before})
    normalized = {name: output / ("normalized-" + name) for name in responses}
    for name, path in normalized.items():
        path.write_text(shlex.join(expanded[name]) + "\n")
    obj, binary = output / (NAME + ".o"), output / NAME
    reader_obj = output / "filter-properties.o"
    commands = [
        ["xcrun", "clang", f"@{normalized['compile.rsp']}",
         "-I", str(ROOT / "Sources/CGlimsEngine/include"), "-I", str(ROOT / "Engine"),
         "-fvisibility=hidden", "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
         "-c", str(READER), "-o", str(reader_obj)],
        ["xcrun", "clang", f"@{normalized['compile.rsp']}",
         "-I", str(ROOT / "Sources/CGlimsEngine/include"), "-I", str(ROOT / "Engine"),
         "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-c", str(HARNESS), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), str(reader_obj),
         *[str(path) for path in objects if path.stem != "filter-properties"],
         f"@{normalized['objects.rsp']}", f"@{normalized['link.rsp']}"],
    ]
    try:
        for command in commands:
            print("==>", shlex.join(command), flush=True)
            subprocess.run(command, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
    finally:
        after = {path: digest(Path(path)) if Path(path).is_file() else None for path in before}
        changed = [path for path in before if after[path] != before[path]]
        if sorted((producer / "obj").glob("*.o")) != objects:
            changed.append("producer object membership")
        write_json(output / "inputs-after.json", {"inputs": after, "changed": changed})
        if changed:
            message = "immutable producer/source inputs changed: " + ", ".join(changed)
            if sys.exc_info()[0] is None:
                raise RuntimeError(message)
            print(message, file=sys.stderr)
    write_json(output / "build.json", {"producer": str(producer), "commands": commands,
        "inputs": before, "binary": str(binary), "binary_sha256": digest(binary),
        "excluded_objects": ["filter-properties.o"], "scope": "three GIMP color paramspecs; current property implementation; no UI"})
    print(f"Built {binary}; NOT EXECUTED.", flush=True)


def run(binary: Path, work: Path, timeout: int) -> int:
    binary, work = binary.resolve(), work.resolve()
    manifest = json.loads((binary.parent / "build.json").read_text())
    require(all(disjoint(work, Path(path).parent) for path in manifest["inputs"]),
            "run directory must be outside all declared input directories")
    # The existing runner verifies every input and binary hash before/after,
    # isolates HOME/CFFIXED_USER_HOME/XDG/GIMP/tmp/swap, and retains nonraising
    # TERM+INT handlers through bounded owned-child-group TERM/KILL/reap.
    return _runtime["run"](binary, work, timeout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("build", help="compile fixture only, using immutable producer objects")
    make.add_argument("--producer", type=Path, required=True)
    make.add_argument("--out", type=Path, required=True)
    execute = commands.add_parser("run", help="explicit native fixture execution with private settings")
    execute.add_argument("--binary", type=Path, required=True)
    execute.add_argument("--work", type=Path, required=True)
    execute.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if args.command == "build":
        build(args.producer, args.out)
        return 0
    return run(args.binary, args.work, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
