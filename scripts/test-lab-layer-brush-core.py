#!/usr/bin/env python3
"""Run private layered Lab brush checks against immutable adapter objects.

Only the fixture and current private core are compiled; the coverage and paint
kernels come from the existing adapter objects. Select an existing producer with
--adapter-root/GLIMS_ADAPTER_ROOT and --ref. All child groups have deadlines;
engine settings are isolated. --output retains a new evidence directory.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
FRAMEWORK = ROOT / "scripts/test-lab-storage.py"
spec = importlib.util.spec_from_file_location("lab_storage_runner", FRAMEWORK)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
SOURCES = [ROOT / "Engine/tests/lab-layer-brush-core-tests.c",
           ROOT / "Engine/lab-layer-brush-core.c"]
HEADERS = [ROOT / "Engine" / name for name in
           ("engine-private.h", "lab-layer-brush-core.h", "lab-layer-paint.h",
            "lab-brush-coverage.h", "lab-layer-storage.h", "lab-layer-map.h")]
HEADERS.append(ROOT / "Sources/CGlimsEngine/include/glims_engine.h")


def run(args, work: Path) -> int:
    producer = (args.adapter_root / args.ref).resolve()
    objects = sorted((producer / "obj").glob("*.o"))
    names = {path.name for path in objects}
    required = {"engine.o", "lab-layer-paint.o", "lab-brush-coverage.o", "lab-layer-storage.o"}
    if not required.issubset(names):
        raise RuntimeError(f"Producer lacks required existing objects: {producer}")
    if "lab-layer-brush-core.o" in names:
        raise RuntimeError("Producer must not already contain the private brush core")
    inputs = set(objects)
    responses = runner.checked_responses(producer, inputs)
    inputs.update(SOURCES + HEADERS + [Path(__file__), FRAMEWORK, runner.RESPONSE_HELPER])
    inputs = {path.resolve() for path in inputs}
    if not all(path.is_file() for path in inputs):
        raise RuntimeError("An immutable source/producer input is missing")
    if not runner.disjoint(work, ROOT) or not runner.disjoint(work, producer) or any(
            not runner.disjoint(work, path.parent) for path in inputs):
        raise RuntimeError("Output must be disjoint from source and producer inputs")
    if work.exists() and (not work.is_dir() or any(work.iterdir())):
        raise RuntimeError("--output must be a new or empty directory")
    work.mkdir(parents=True, exist_ok=True)
    before = {str(path): runner.digest(path) for path in sorted(inputs)}
    (work / "inputs.json").write_text(json.dumps(
        {"ref": args.ref, "producer": str(producer), "inputs": before}, indent=2) + "\n")
    env = os.environ.copy()
    for key, leaf in (("HOME", "home"), ("CFFIXED_USER_HOME", "home"),
                      ("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"),
                      ("XDG_DATA_HOME", "data"), ("GIMP3_DIRECTORY", "user"),
                      ("TMPDIR", "tmp"), ("BABL_CACHE_DIR", "babl-cache")):
        (work / leaf).mkdir(exist_ok=True)
        env[key] = str(work / leaf)
    copied = {}
    for name, tokens in responses.items():
        copied[name] = work / ("normalized-" + name)
        copied[name].write_text(shlex.join(tokens) + "\n")
    compiled = [work / (source.stem + ".o") for source in SOURCES]
    binary = work / "lab-layer-brush-core-tests"
    commands = [["xcrun", "clang", "-I", str(ROOT / "Engine"),
                 "-I", str(ROOT / "Sources/CGlimsEngine/include"),
                 "@" + str(copied["compile.rsp"]), "-std=c11", "-O2", "-Wall", "-Wextra",
                 "-Werror=implicit-function-declaration", "-Werror=excess-initializers",
                 "-Wno-declaration-after-statement", "-c", str(source), "-o", str(obj)]
                for source, obj in zip(SOURCES, compiled)]
    commands.append(["xcrun", "clang++", "-o", str(binary), *map(str, compiled),
                     *map(str, objects), "@" + str(copied["objects.rsp"]),
                     "@" + str(copied["link.rsp"])])
    result = 1
    try:
        with (work / "build.log").open("w") as log:
            for command in commands:
                result = runner.bounded_process(command, log, args.compile_timeout, work, env)
                if result:
                    print((work / "build.log").read_text(), end="")
                    return result
        with (work / "run.log").open("w") as log:
            command = [str(binary), str(work)]
            result = runner.bounded_process(command, log, args.timeout, work, env)
        print((work / "run.log").read_text(), end="")
        return result
    finally:
        changed = [name for name, expected in before.items()
                   if not Path(name).is_file() or runner.digest(Path(name)) != expected]
        if sorted((producer / "obj").glob("*.o")) != objects:
            changed.append("producer object membership")
        (work / "result.json").write_text(json.dumps(
            {"ref": args.ref, "exit_code": result, "changed_inputs": changed}, indent=2) + "\n")
        if changed:
            raise RuntimeError("Immutable inputs changed: " + ", ".join(changed))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path,
                        default=Path(os.environ.get("GLIMS_ADAPTER_ROOT") or
                                     runner.canonical_checkout() / "_engine/adapter"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=120, help="whole runtime process-group deadline")
    parser.add_argument("--compile-timeout", type=float, default=180,
                        help="per compiler/linker process-group deadline")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("--ref must name an engine set")
    for value in (args.timeout, args.compile_timeout):
        if not math.isfinite(value) or not 0 < value <= 600:
            parser.error("timeouts must be in (0, 600]")
    if args.output:
        return run(args, args.output.resolve())
    with tempfile.TemporaryDirectory(prefix="glims-lab-brush-core-") as temporary:
        return run(args, Path(temporary).resolve())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"test-lab-layer-brush-core: {error}", file=sys.stderr)
        raise SystemExit(1)
