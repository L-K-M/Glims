#!/usr/bin/env python3
"""Build or opt in to running the direct native Oilify oracle.

Build compiles only the fixture against an existing immutable producer. Run
requires an explicit fresh work directory and retains logs and pixel artifacts.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "Engine/tests/oilify-native-oracle-tests.c"
FACADE_HARNESS = ROOT / "Engine/tests/oilify-source-tests.c"
DIAGNOSTICS = ROOT / "Engine/tests/oilify-native-oracle-diagnostics.h"
FIXTURE = ROOT / "Engine/tests/filter-input-tests.c"
RESPONSE_HELPER = ROOT / "scripts/test-displace-source.py"
BINARY_NAME = "oilify-native-oracle-tests"
_response = runpy.run_path(str(RESPONSE_HELPER))
digest = _response["digest"]
require = _response["require"]
response_tokens = _response["response_tokens"]


def disjoint(first: Path, second: Path) -> bool:
    return not first.is_relative_to(second) and not second.is_relative_to(first)


def fresh_directory(path: Path) -> None:
    require(not path.exists() or (path.is_dir() and not any(path.iterdir())),
            f"directory must be new or empty: {path}")
    path.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, value: dict) -> None:
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def build(producer: Path, output: Path, facade: bool = False) -> None:
    producer, output = producer.resolve(), output.resolve()
    require(producer.is_dir() and disjoint(output, producer), "producer and output must be disjoint directories")
    objects = sorted((producer / "obj").glob("*.o"))
    require({"engine", "filter", "filter-input"}.issubset({p.stem for p in objects}),
            "producer lacks the existing engine and filter objects")
    inputs = set(objects)
    responses = ("compile.rsp", "objects.rsp", "link.rsp")
    expanded = {name: response_tokens(producer / name, inputs, set()) for name in responses}
    harness = FACADE_HARNESS if facade else HARNESS
    binary_name = "oilify-source-tests" if facade else BINARY_NAME
    inputs.update({harness, FIXTURE, RESPONSE_HELPER, Path(__file__).resolve(),
                   ROOT / "Engine/engine-private.h", ROOT / "Engine/filter-input.h",
                   ROOT / "Sources/CGlimsEngine/include/glims_engine.h"})
    if not facade:
        inputs.add(DIAGNOSTICS)
    inputs = {path.resolve() for path in inputs}
    require(all(path.is_file() for path in inputs), "an immutable input is missing")
    require(all(disjoint(output, path.parent) for path in inputs),
            "output must be disjoint from declared input directories")
    before = {str(path): digest(path) for path in sorted(inputs)}
    fresh_directory(output)
    write_json(output / "inputs.json", {"producer": str(producer), "source": str(harness), "inputs": before})

    normalized = {name: output / ("normalized-" + name) for name in responses}
    for name, path in normalized.items():
        path.write_text(shlex.join(expanded[name]) + "\n")
    obj, binary = output / (binary_name + ".o"), output / binary_name
    commands = [
        ["xcrun", "clang", f"@{normalized['compile.rsp']}", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
         "-I", str(ROOT / "Engine"), "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-c", str(harness), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
         f"@{normalized['objects.rsp']}", f"@{normalized['link.rsp']}"],
    ]
    try:
        for command in commands:
            print("==>", shlex.join(command), flush=True)
            subprocess.run(command, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
    finally:
        after = {path: digest(Path(path)) if Path(path).is_file() else None for path in before}
        changed = [path for path, value in before.items() if after[path] != value]
        write_json(output / "inputs-after.json", {"inputs": after, "changed": changed})
        if changed:
            message = "Immutable producer or source inputs changed: " + ", ".join(changed)
            if sys.exc_info()[0] is None:
                raise RuntimeError(message)
            print(message, file=sys.stderr)
    write_json(output / "binary.json", {"path": str(binary), "sha256": digest(binary)})
    print(f"Built {binary}; use the explicit run subcommand to execute it.", flush=True)


def run(binary: Path, work: Path, timeout: int, diagnostics: bool, ui_fixture: bool) -> int:
    binary, work = binary.resolve(), work.resolve()
    require(binary.is_file() and disjoint(work, binary.parent), "binary and run directories must be disjoint")
    require(disjoint(work, ROOT), "run directory must be outside the source checkout")
    fresh_directory(work)
    overrides = ("GLIMS_", "DYLD_", "GIMP3_", "GEGL_", "BABL_")
    env = {key: value for key, value in os.environ.items() if not key.startswith(overrides)}
    for key, leaf in [("HOME", "home"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                      ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp"), ("GEGL_SWAP", "swap")]:
        directory = work / leaf
        directory.mkdir()
        env[key] = str(directory)
    env["G_DEBUG"] = "fatal-criticals"
    binary_hash = digest(binary)
    started = time.monotonic()
    command = [str(binary), str(work)]
    if diagnostics:
        command.append("--diagnostics")
    elif ui_fixture:
        command.append("--ui-fixture")
    with (work / "native.log").open("x") as log:
        print(f"Running {binary}; output goes to {log.name}", flush=True)
        try:
            result = subprocess.run(command, env=env, cwd=work,
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            result = 124
    artifacts = {}
    for path in sorted((work / "artifacts").glob("*")):
        if path.is_file() and not path.is_symlink():
            artifacts[path.name] = {"bytes": path.stat().st_size, "sha256": digest(path)}
    unchanged = digest(binary) == binary_hash
    write_json(work / "run.json", {"binary": str(binary), "binary_sha256": binary_hash,
                                   "binary_unchanged": unchanged, "exit_code": result,
                                   "diagnostics": diagnostics, "ui_fixture": ui_fixture,
                                   "elapsed_seconds": time.monotonic() - started, "artifacts": artifacts})
    require(unchanged, "fixture binary changed during execution")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build", help="compile/link only using an existing producer")
    build_parser.add_argument("--producer", type=Path, required=True)
    build_parser.add_argument("--out", type=Path, required=True)
    build_parser.add_argument("--facade", action="store_true", help="build the slot170 facade suite")
    run_parser = subparsers.add_parser("run", help="explicitly run the fixture with private settings")
    run_parser.add_argument("--binary", type=Path, required=True)
    run_parser.add_argument("--work", type=Path, required=True)
    run_parser.add_argument("--timeout", type=int, default=180)
    run_mode = run_parser.add_mutually_exclusive_group()
    run_mode.add_argument("--diagnostics", action="store_true", help="retain projection and graph comparisons")
    run_mode.add_argument("--ui-fixture", action="store_true", help="export AppKit inputs and direct-Core frames using the facade fixture binary")
    args = parser.parse_args()
    if args.command == "build":
        build(args.producer, args.out, args.facade)
    else:
        if args.timeout <= 0:
            parser.error("--timeout must be positive")
        sys.exit(run(args.binary, args.work, args.timeout, args.diagnostics, args.ui_fixture))


if __name__ == "__main__":
    main()
