#!/usr/bin/env python3
"""Build a private real-Core telemetry adapter, or explicitly run its AppKit case.

The run subcommand requires the caller's desktop lease. No producer object or
library is rebuilt/relinked in place, and no additional facade export exists.
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
HELPER = ROOT / "scripts/test-tablet-stroke-v2.py"
_helpers = runpy.run_path(str(HELPER))
digest, require, response_tokens, disjoint, fresh, write_json = (
    _helpers[name] for name in ("digest", "require", "response_tokens", "disjoint", "fresh", "write_json"))
PAINT = ROOT / "Engine/paint.c"
TELEMETRY = ROOT / "Engine/tests/tablet-v2-ui-telemetry.c"
SHIMS = ROOT / "Engine/tests/tablet-v2-ui-telemetry.h"
SYMBOLS = {"gimp_paint_core_start": "glims_test_tablet_ui_start",
           "gimp_paint_core_paint": "glims_test_tablet_ui_paint",
           "gimp_paint_core_interpolate": "glims_test_tablet_ui_interpolate"}


def build(producer: Path, output: Path) -> None:
    producer, output = producer.resolve(), output.resolve()
    require(producer.is_dir() and disjoint(output, producer) and disjoint(output, ROOT),
            "producer, source and output trees must not overlap")
    objects = sorted((producer / "obj").glob("*.o"))
    require(sum(p.name == "paint.o" for p in objects) == 1 and any(p.name == "engine.o" for p in objects),
            "producer must contain exactly one paint.o and an engine.o")
    inputs = set(objects)
    responses = ("compile.rsp", "objects.rsp", "link.rsp")
    expanded = {name: response_tokens(producer / name, inputs, set()) for name in responses}
    inputs.update({PAINT, TELEMETRY, SHIMS, HELPER, Path(__file__).resolve(),
        ROOT / "scripts/test-displace-source.py", ROOT / "Sources/CGlimsEngine/include/glims_engine.h",
        ROOT / "Sources/GlimsKit/EngineSmokeTestTabletStrokeV2.swift"})
    inputs.update((ROOT / "Engine").glob("*.h"))
    inputs = {p.resolve() for p in inputs}
    require(all(p.is_file() for p in inputs) and all(disjoint(output, p.parent) for p in inputs),
            "an immutable input is missing or overlaps output")
    before = {str(p): digest(p) for p in sorted(inputs)}
    fresh(output)
    write_json(output / "inputs.json", {"producer": str(producer), "inputs": before})
    normalized = {name: output / ("normalized-" + name) for name in responses}
    for name, path in normalized.items():
        path.write_text(shlex.join(expanded[name]) + "\n")
    private, trace = output / "tablet-ui-private-paint.o", output / "tablet-ui-telemetry.o"
    library = output / "libglimsengine.dylib"
    common = [f"@{normalized['compile.rsp']}", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
              "-I", str(ROOT / "Engine"), "-I", str(SHIMS.parent), "-std=c11", "-O2", "-fvisibility=hidden"]
    commands = [
        ["xcrun", "clang", *common, *(f"-D{a}={b}" for a, b in SYMBOLS.items()), "-include", str(SHIMS),
         "-Wall", "-Wextra", "-Werror=implicit-function-declaration", "-c", str(PAINT), "-o", str(private)],
        ["xcrun", "clang", *common, "-Wall", "-Wextra", "-Werror", "-c", str(TELEMETRY), "-o", str(trace)],
        ["xcrun", "clang++", "-dynamiclib", "-o", str(library), str(private), str(trace),
         *(str(p) for p in objects if p.name != "paint.o"), f"@{normalized['objects.rsp']}",
         f"@{normalized['link.rsp']}", "-install_name", "@rpath/libglimsengine.dylib",
         "-Wl,-exported_symbol,_glims_engine_get_api"],
    ]
    try:
        for command in commands:
            print("==>", shlex.join(command), flush=True)
            subprocess.run(command, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
        nm = subprocess.check_output(["nm", "-gU", str(library)], text=True)
        exports = sorted(line.split()[2] for line in nm.splitlines() if len(line.split()) == 3)
        require(exports == ["_glims_engine_get_api"], f"unexpected private adapter exports: {exports}")
    finally:
        after = {p: digest(Path(p)) if Path(p).is_file() else None for p in before}
        changed = [p for p in before if before[p] != after[p]]
        if sorted((producer / "obj").glob("*.o")) != objects:
            changed.append("producer object membership")
        write_json(output / "inputs-after.json", {"inputs": after, "changed": changed})
        require(not changed, "immutable inputs changed: " + ", ".join(changed))
    write_json(output / "build.json", {"producer": str(producer), "inputs": before, "commands": commands,
        "excluded_object": str(producer / "obj/paint.o"), "forwarding_symbols": SYMBOLS,
        "exports": exports, "library": str(library), "library_sha256": digest(library)})
    print(f"Built private adapter {library}; NOT EXECUTED.", flush=True)


def run(app: Path, adapter: Path, work: Path, timeout: int) -> int:
    app, adapter, work = app.resolve(), adapter.resolve(), work.resolve()
    require(timeout > 0 and app.is_file() and adapter.is_file(), "missing executable/adapter or invalid timeout")
    manifest = json.loads((adapter.parent / "build.json").read_text())
    require(disjoint(work, ROOT) and disjoint(work, adapter.parent) and disjoint(work, app.parent)
            and disjoint(work, Path(manifest["producer"])), "run work must be disjoint from input trees")
    inputs = manifest["inputs"]

    def immutable() -> bool:
        return digest(adapter) == manifest["library_sha256"] and all(
            Path(p).is_file() and digest(Path(p)) == value for p, value in inputs.items())

    require(immutable(), "private adapter/source/producer no longer match the build receipt")
    fresh(work)
    for leaf in ("home", "cache", "config", "data", "state", "runtime", "user", "tmp", "swap", "artifacts"):
        (work / leaf).mkdir(mode=0o700)
    environment = {k: v for k, v in os.environ.items()
        if not k.startswith(("GLIMS_", "DYLD_", "GIMP3_", "GEGL_", "BABL_"))}
    environment.update(HOME=str(work / "home"), CFFIXED_USER_HOME=str(work / "home"),
        XDG_CACHE_HOME=str(work / "cache"), XDG_CONFIG_HOME=str(work / "config"),
        XDG_DATA_HOME=str(work / "data"), XDG_STATE_HOME=str(work / "state"),
        XDG_RUNTIME_DIR=str(work / "runtime"), GIMP3_DIRECTORY=str(work / "user"),
        TMPDIR=str(work / "tmp"), TMP=str(work / "tmp"), TEMP=str(work / "tmp"), GEGL_SWAP=str(work / "swap"),
        GLIMS_ENGINE_LIBRARY=str(adapter), GLIMS_SMOKE_CASE="tablet-stroke-v2",
        GLIMS_TABLET_V2_TELEMETRY=str(work / "artifacts/native-tablet.ndjson"),
        G_DEBUG="fatal-criticals", LC_ALL="C", LANG="C")
    app_hash = digest(app)
    process = None
    previous = {}
    interruption = None
    code = 124
    started = time.monotonic()

    def on_signal(number: int, frame: object) -> None:
        nonlocal interruption
        interruption = number

    with (work / "smoke.log").open("xb") as stdout, (work / "stderr.log").open("xb") as stderr:
        try:
            for number in (signal.SIGTERM, signal.SIGINT):
                previous[number] = signal.signal(number, on_signal)
            process = subprocess.Popen([str(app), "--engine-smoke-test"], env=environment, cwd=work,
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
            deadline = time.monotonic() + timeout
            while interruption is None and time.monotonic() < deadline:
                try:
                    code = process.wait(timeout=min(.1, max(.001, deadline - time.monotonic())))
                    break
                except subprocess.TimeoutExpired:
                    pass
            if interruption is not None:
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
                    require(process.poll() is not None, "owned app process did not reap after TERM/KILL")
            finally:
                for number, handler in previous.items():
                    signal.signal(number, handler)
    stable = immutable() and digest(app) == app_hash
    artifacts = {p.name: {"bytes": p.stat().st_size, "sha256": digest(p)}
                 for p in (work / "artifacts").iterdir() if p.is_file() and not p.is_symlink()}
    write_json(work / "run.json", {"app": str(app), "app_sha256": app_hash, "adapter": str(adapter),
        "adapter_sha256": manifest["library_sha256"], "inputs_unchanged": stable, "exit_code": code,
        "signal": interruption, "elapsed_seconds": time.monotonic() - started, "artifacts": artifacts,
        "desktop_lease": "must be owned and released by caller; not acquired by this driver"})
    require(stable, "immutable app/adapter/source/producer changed during execution")
    sys.stdout.write((work / "smoke.log").read_text(errors="replace"))
    sys.stderr.write((work / "stderr.log").read_text(errors="replace"))
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("build", help="compile private forwarding adapter only")
    make.add_argument("--producer", type=Path, required=True)
    make.add_argument("--out", type=Path, required=True)
    execute = commands.add_parser("run", help="caller must already own desktop; launch the focused AppKit fixture")
    execute.add_argument("--app-executable", type=Path, required=True)
    execute.add_argument("--adapter", type=Path, required=True)
    execute.add_argument("--work", type=Path, required=True)
    execute.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if args.command == "build":
        build(args.producer, args.out)
        return 0
    return run(args.app_executable, args.adapter, args.work, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
