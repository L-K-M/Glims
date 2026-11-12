#!/usr/bin/env python3
"""Build/run private Lab scalar-storage checks using an existing adapter producer.

No Lab mode is adopted and no adapter or upstream objects are rebuilt. --ref
selects the engine set; --adapter-root defaults to GLIMS_ADAPTER_ROOT or the
canonical checkout's _engine/adapter. --output retains a new/empty evidence
folder; otherwise all test files and isolated engine settings are temporary.
Compile/link and runtime limits apply to each entire owned process group.
Missing producer inputs are rejected, never repaired by rebuilding them.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import runpy
import shlex
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Engine/tests/lab-storage-tests.c"
RESPONSE_HELPER = ROOT / "scripts/test-displace-source.py"
_helpers = runpy.run_path(str(RESPONSE_HELPER))
digest, response_tokens = (_helpers[key] for key in ("digest", "response_tokens"))


def pinned_ref() -> str:
    match = re.search(r'^ENGINE_SETS="([^:\s"]+)',
                      (ROOT / "scripts/engine.env").read_text(), re.MULTILINE)
    if not match:
        raise RuntimeError("Cannot find pinned engine set in scripts/engine.env")
    return match.group(1)


def canonical_checkout() -> Path:
    # Linked worktrees need the shared input checkout, not a guessed sibling name.
    result = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=ROOT,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=10, check=False)
    if result.returncode == 0:
        common = Path(result.stdout.strip())
        common = (common if common.is_absolute() else ROOT / common).resolve()
        if common.name == ".git":
            return common.parent
    return ROOT


def disjoint(first: Path, second: Path) -> bool:
    return not (first.is_relative_to(second) or second.is_relative_to(first))


def stop_group(process: subprocess.Popen) -> None:
    # The leader may exit before a plug-in: always target the group as well.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def bounded_process(argv: list[str], log, timeout: float, work: Path, env: dict) -> int:
    requested_signal = 0

    def interrupted(number, _frame):
        nonlocal requested_signal
        requested_signal = number

    old_handlers = {number: signal.signal(number, interrupted)
                    for number in (signal.SIGINT, signal.SIGTERM)}
    process = None
    try:
        print("+ " + shlex.join(argv), file=log, flush=True)
        process = subprocess.Popen(argv, cwd=work, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True,
                                   stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        while True:
            if requested_signal:
                return 128 + requested_signal
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(f"Process group exceeded {timeout:g} seconds", file=log, flush=True)
                return 124
            try:
                code = process.wait(timeout=min(remaining, 0.25))
                return code if code >= 0 else 128 - code
            except subprocess.TimeoutExpired:
                pass
    finally:
        if process is not None:
            stop_group(process)
        for number, previous in old_handlers.items():
            signal.signal(number, previous)


def checked_responses(producer: Path, inputs: set[Path]) -> dict[str, list[str]]:
    responses = {name: response_tokens(producer / name, inputs, set())
                 for name in ("compile.rsp", "objects.rsp", "link.rsp")}
    # The shared normalizer rejects missing file inputs. Also reject missing
    # include/library paths and output flags before using our response copies.
    directory_flags = {"-I", "-L", "-F", "-isystem", "-iquote", "-isysroot"}
    for name, tokens in responses.items():
        expects_directory = False
        for token in tokens:
            directory = None
            if expects_directory:
                directory = token
                expects_directory = False
            elif token in directory_flags:
                expects_directory = True
            elif token.startswith(("-I", "-L", "-F")) and len(token) > 2:
                directory = token[2:]
            elif token.startswith("-Wl,-rpath,"):
                directory = token[len("-Wl,-rpath,"):]
            elif token in {"-o", "-MF", "-MJ", "-MD", "-MMD", "-save-temps"} or token.startswith(("-o", "-MF", "-MJ", "--serialize-diagnostics")):
                raise RuntimeError(f"Unexpected output option in {name}: {token}")
            if directory is not None and not directory.startswith("@") and not Path(directory).is_dir():
                raise RuntimeError(f"Missing producer directory input: {directory}")
        if expects_directory:
            raise RuntimeError(f"Missing directory argument in {name}")
    if not responses["objects.rsp"]:
        raise RuntimeError("Producer objects.rsp is empty")
    return responses


def run(producer: Path, work: Path, timeout: float, ref: str) -> int:
    # The unchanged native fixture uses a 1024-byte XCF path buffer.
    if len(os.fsencode(work)) + len("/lab-FLOAT_LINEAR.xcf") >= 1024:
        raise RuntimeError("Output path is too long for the native fixture")
    objects = sorted((producer / "obj").glob("*.o"))
    if not {"engine.o", "channels.o"}.issubset({path.name for path in objects}):
        raise RuntimeError(f"Producer lacks engine/channel objects: {producer}")
    inputs = set(objects)
    responses = checked_responses(producer, inputs)
    inputs.update({SOURCE, RESPONSE_HELPER, Path(__file__).resolve(),
                   ROOT / "Engine/engine-private.h",
                   ROOT / "Sources/CGlimsEngine/include/glims_engine.h"})
    inputs = {path.resolve() for path in inputs}
    if not all(path.is_file() for path in inputs):
        raise RuntimeError("An immutable source/producer input is missing")
    if not disjoint(work, ROOT) or not disjoint(work, producer) or any(
            not disjoint(work, path.parent) for path in inputs):
        raise RuntimeError("Output must be disjoint from source and producer input directories")
    if work.exists() and (not work.is_dir() or any(work.iterdir())):
        raise RuntimeError("--output must be a new or empty directory")
    work.mkdir(parents=True, exist_ok=True)
    before = {str(path): digest(path) for path in sorted(inputs)}
    (work / "inputs.json").write_text(json.dumps(
        {"ref": ref, "producer": str(producer), "inputs": before}, indent=2) + "\n")
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
    obj, binary = work / "lab-storage-tests.o", work / "lab-storage-tests"
    commands = [
        ["xcrun", "clang", "-I", str(ROOT / "Engine"), "-I", str(ROOT / "Sources/CGlimsEngine/include"),
         "@" + str(copied["compile.rsp"]), "-std=c11", "-O2", "-Wall", "-Wextra",
         "-Werror=implicit-function-declaration", "-Werror=excess-initializers", "-Wno-declaration-after-statement",
         "-c", str(SOURCE), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
         "@" + str(copied["objects.rsp"]), "@" + str(copied["link.rsp"])],
    ]
    result = 1
    try:
        with (work / "build.log").open("w") as log:
            for command in commands:
                result = bounded_process(command, log, 180, work, env)
                if result:
                    print((work / "build.log").read_text(), end="")
                    return result
        with (work / "run.log").open("w") as log:
            result = bounded_process([str(binary), str(work)], log, timeout, work, env)
        print((work / "run.log").read_text(), end="")
        return result
    finally:
        changed = [name for name, expected in before.items()
                   if not Path(name).is_file() or digest(Path(name)) != expected]
        if sorted((producer / "obj").glob("*.o")) != objects:
            changed.append("producer object membership")
        (work / "result.json").write_text(json.dumps(
            {"ref": ref, "exit_code": result, "changed_inputs": changed}, indent=2) + "\n")
        if changed:
            raise RuntimeError("Immutable inputs changed: " + ", ".join(changed))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=pinned_ref())
    parser.add_argument("--adapter-root", type=Path,
                        help="Producer root containing <ref>/obj and response files (or GLIMS_ADAPTER_ROOT)")
    parser.add_argument("--output", type=Path, help="New or empty evidence directory; default is temporary")
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("--ref must be an engine set name")
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
        parser.error("--timeout must be in (0, 3600]")
    adapter_root = args.adapter_root or Path(os.environ.get("GLIMS_ADAPTER_ROOT") or
                                            canonical_checkout() / "_engine/adapter")
    producer = (adapter_root / args.ref).resolve()
    if not producer.is_dir():
        parser.error(f"Missing producer {producer}; build it with scripts/build-adapter.sh first")
    if args.output:
        return run(producer, args.output.resolve(), args.timeout, args.ref)
    with tempfile.TemporaryDirectory(prefix="glims-lab-storage-") as temporary:
        return run(producer, Path(temporary).resolve(), args.timeout, args.ref)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"test-lab-storage: {error}", file=sys.stderr)
        raise SystemExit(1)
