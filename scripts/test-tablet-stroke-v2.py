#!/usr/bin/env python3
"""Compile a private forwarding paint object against immutable native inputs.

Build never executes the binary or rebuilds/relinks the producer. Run is an
explicit separate command with private native settings and bounded cleanup.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import runpy
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "Engine/tests/tablet-stroke-v2-tests.c"
SHIMS = ROOT / "Engine/tests/tablet-stroke-v2-shims.h"
PAINT = ROOT / "Engine/paint.c"
RESPONSE_HELPER = ROOT / "scripts/test-displace-source.py"
_helpers = runpy.run_path(str(RESPONSE_HELPER))
digest, require, response_tokens = (_helpers[name] for name in ("digest", "require", "response_tokens"))
SYMBOLS = {
    "gimp_paint_core_start": "glims_test_tablet_start",
    "gimp_paint_core_paint": "glims_test_tablet_paint",
    "gimp_paint_core_interpolate": "glims_test_tablet_interpolate",
}
NAME = "tablet-stroke-v2-tests"


def disjoint(a: Path, b: Path) -> bool:
    return not a.is_relative_to(b) and not b.is_relative_to(a)


def fresh(path: Path) -> None:
    require(not path.exists() or (path.is_dir() and not any(path.iterdir())),
            f"directory must be new or empty: {path}")
    path.mkdir(parents=True, mode=0o700, exist_ok=True)


def write_json(path: Path, value: dict) -> None:
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def build(producer: Path, output: Path) -> None:
    producer, output = producer.resolve(), output.resolve()
    require(producer.is_dir() and disjoint(output, producer), "producer and output must be disjoint")
    objects = sorted((producer / "obj").glob("*.o"))
    require(sum(p.name == "paint.o" for p in objects) == 1 and any(p.name == "engine.o" for p in objects),
            "producer must contain one paint.o and an engine.o")
    linked = [p for p in objects if p.name != "paint.o"]
    inputs = set(objects)
    responses = ("compile.rsp", "objects.rsp", "link.rsp")
    expanded = {name: response_tokens(producer / name, inputs, set()) for name in responses}
    inputs.update({HARNESS, SHIMS, PAINT, RESPONSE_HELPER, Path(__file__).resolve(),
                   ROOT / "Sources/CGlimsEngine/include/glims_engine.h"})
    inputs.update((ROOT / "Engine").glob("*.h"))
    inputs = {p.resolve() for p in inputs}
    require(all(p.is_file() for p in inputs), "an immutable input is missing")
    require(disjoint(output, ROOT) and all(disjoint(output, p.parent) for p in inputs),
            "output must be outside source and declared input directories")
    before = {str(p): digest(p) for p in sorted(inputs)}
    fresh(output)
    write_json(output / "inputs.json", {"producer": str(producer), "inputs": before})
    normalized = {name: output / ("normalized-" + name) for name in responses}
    for name, path in normalized.items():
        path.write_text(shlex.join(expanded[name]) + "\n")
    private = output / "tablet-private-paint.o"
    harness = output / (NAME + ".o")
    binary = output / NAME
    common = [f"@{normalized['compile.rsp']}", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
              "-I", str(ROOT / "Engine"), "-I", str(HARNESS.parent), "-std=c11", "-O2"]
    commands = [
        ["xcrun", "clang", *common, *(f"-D{old}={new}" for old, new in SYMBOLS.items()),
         "-include", str(SHIMS), "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
         "-c", str(PAINT), "-o", str(private)],
        ["xcrun", "clang", *common, "-Wall", "-Wextra", "-Werror", "-c", str(HARNESS), "-o", str(harness)],
        ["xcrun", "clang++", "-o", str(binary), str(harness), str(private), *map(str, linked),
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
        "inputs": before, "excluded_object": str(producer / "obj/paint.o"), "forwarding_symbols": SYMBOLS,
        "binary": str(binary), "binary_sha256": digest(binary),
        "scope": "real native coordinate delivery and pixels; no UI, hardware or enabled-axis dynamics claim"})
    print(f"Built {binary}; NOT EXECUTED.", flush=True)


def run(binary: Path, work: Path, timeout: int) -> int:
    binary, work = binary.resolve(), work.resolve()
    require(binary.is_file() and disjoint(work, binary.parent) and disjoint(work, ROOT),
            "run directory must be outside binary and source directories")
    require(timeout > 0, "timeout must be positive")
    manifest = json.loads((binary.parent / "build.json").read_text())
    inputs = manifest["inputs"]
    require(disjoint(work, Path(manifest["producer"])), "run directory must not overlap producer")

    def immutable() -> bool:
        return digest(binary) == manifest["binary_sha256"] and all(
            Path(path).is_file() and digest(Path(path)) == expected for path, expected in inputs.items())

    require(immutable(), "binary or source/producer inputs do not match the build manifest")
    fresh(work)
    directories = ("home", "cache", "config", "data", "state", "runtime", "user", "tmp", "swap")
    for leaf in directories:
        (work / leaf).mkdir(mode=0o700)
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("GLIMS_", "DYLD_", "GIMP3_", "GEGL_", "BABL_"))}
    environment.update(HOME=str(work / "home"), CFFIXED_USER_HOME=str(work / "home"),
        XDG_CACHE_HOME=str(work / "cache"), XDG_CONFIG_HOME=str(work / "config"),
        XDG_DATA_HOME=str(work / "data"), XDG_STATE_HOME=str(work / "state"),
        XDG_RUNTIME_DIR=str(work / "runtime"), GIMP3_DIRECTORY=str(work / "user"),
        TMPDIR=str(work / "tmp"), TMP=str(work / "tmp"), TEMP=str(work / "tmp"),
        GEGL_SWAP=str(work / "swap"), G_DEBUG="fatal-criticals", LC_ALL="C", LANG="C")
    interrupted = None

    def on_signal(number: int, frame: object) -> None:
        nonlocal interrupted
        interrupted = number

    process = None
    previous = {}
    code = 124
    started = time.monotonic()
    with (work / "stdout.log").open("xb") as stdout, (work / "stderr.log").open("xb") as stderr:
        try:
            for number in (signal.SIGTERM, signal.SIGINT):
                previous[number] = signal.signal(number, on_signal)
            process = subprocess.Popen([str(binary), str(work)], stdin=subprocess.DEVNULL, stdout=stdout,
                stderr=stderr, cwd=work, env=environment, start_new_session=True)
            deadline = time.monotonic() + timeout
            while interrupted is None and time.monotonic() < deadline:
                try:
                    code = process.wait(timeout=min(.1, max(.001, deadline - time.monotonic())))
                    break
                except subprocess.TimeoutExpired:
                    pass
            if interrupted is not None:
                code = 124
        finally:
            try:
                if process is not None and process.poll() is None:
                    for number in (signal.SIGTERM, signal.SIGKILL):
                        if process.poll() is not None:
                            break
                        try:
                            os.killpg(process.pid, number)
                        except ProcessLookupError:
                            pass
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            pass
                    require(process.poll() is not None, "owned child did not reap after TERM/KILL")
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
    stable = immutable()
    write_json(work / "run.json", {"binary": str(binary), "binary_sha256": manifest["binary_sha256"],
        "inputs_unchanged": stable, "exit_code": code, "signal": interrupted,
        "elapsed_seconds": time.monotonic() - started,
        "stdout_sha256": digest(work / "stdout.log"), "stderr_sha256": digest(work / "stderr.log")})
    require(stable, "immutable binary/source/producer changed during the run")
    sys.stdout.write((work / "stdout.log").read_text(errors="replace"))
    sys.stderr.write((work / "stderr.log").read_text(errors="replace"))
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("build", help="compile/link only using immutable producer objects")
    make.add_argument("--producer", type=Path, required=True)
    make.add_argument("--out", type=Path, required=True)
    execute = commands.add_parser("run", help="explicit real native execution with private settings")
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
