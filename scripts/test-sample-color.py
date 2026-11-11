#!/usr/bin/env python3
"""Compile-only or explicitly run the slot174 native sample-color oracle.

Build consumes an existing immutable API174 producer, compiles ONLY the C
harness and links its authentic production objects. It never recompiles or
relinks the adapter. Matching producer flags are required for the selected
engine ref. Run is separate, bounded and uses new private HOME/XDG/GIMP/TMP.
No existing evidence or producer files are overwritten.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
HARNESS = ROOT / "Engine/tests/sample-color-tests.c"
BINARY_NAME = "sample-color-tests"
SUPPORTED = ("GIMP_3_2_8", "GIMP_3_2_0", "GIMP_3_0_8", "master")

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise SystemExit(msg)


def response_tokens(path: Path, inputs: set[Path], stack: set[Path]) -> list[str]:
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

    def absolute(value: str, record: bool) -> str:
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
            for i, part in enumerate(parts[1:], 1):
                if Path(part).suffix in {".o", ".a", ".dylib"} and not part.startswith("@"):
                    parts[i] = absolute(part, record=True)
            normalized.append(",".join(parts))
        elif not token.startswith("-") and Path(token).suffix in {".o", ".a", ".dylib"}:
            normalized.append(absolute(token, record=True))
        else:
            normalized.append(token)
    require(argument_flag is None, f"missing path argument in response {path}")
    return normalized


def build(args: argparse.Namespace) -> None:
    require(args.ref in SUPPORTED, f"Unsupported engine ref: {args.ref}")
    base = Path(os.environ.get("GLIMS_ADAPTER_ROOT", ROOT / "_engine/adapter")).resolve()
    producer = (args.producer or base / args.ref).resolve()
    output = args.out.resolve()
    require(producer.is_dir(), f"Missing existing producer: {producer}")
    require(not output.is_relative_to(producer) and not producer.is_relative_to(output),
            "Output must be disjoint from the immutable producer")
    require(not output.is_relative_to(ROOT) and not ROOT.is_relative_to(output),
            "Use a build output outside the source checkout")
    require(not output.exists() or (output.is_dir() and not any(output.iterdir())),
            "Build output must be new or empty; existing evidence is never overwritten")
    all_objects = sorted((producer / "obj").glob("*.o"))
    require({"engine", "image"}.issubset({p.stem for p in all_objects}),
            "Fresh API174 engine.o and image.o are required")
    objects = [p for p in all_objects if p.stem != "engine-tests"]
    responses = {name: producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")}
    inputs = set(all_objects)
    expanded = {name: response_tokens(path, inputs, set()) for name, path in responses.items()}
    flag_text = " ".join(expanded["compile.rsp"] + expanded["objects.rsp"])
    refs = {ref for ref in SUPPORTED if f"/{ref}/" in flag_text}
    require(refs == {args.ref}, f"Producer flags must match only {args.ref}; found {sorted(refs)}")
    sources = {HARNESS, Path(__file__).resolve(), ROOT / "Engine/engine-private.h",
               ROOT / "Sources/CGlimsEngine/include/glims_engine.h"}
    inputs.update(path.resolve() for path in sources)
    require(all(path.is_file() for path in inputs), "A declared source/producer input is missing")
    require(not any(output.is_relative_to(path.parent) or path.parent.is_relative_to(output)
                    for path in inputs), "Output overlaps an immutable input directory")
    before = {str(path): digest(path) for path in sorted(inputs)}
    output.mkdir(parents=True, exist_ok=True)
    normalized = {name: output / f"normalized-{name}" for name in responses}
    for name, path in normalized.items():
        path.write_text(shlex.join(expanded[name]) + "\n")
    obj = output / "sample-color-tests.o"
    binary = output / BINARY_NAME
    compile_command = ["xcrun", "clang", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
                       "-I", str(ROOT / "Engine"), f"@{normalized['compile.rsp']}",
                       "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                       "-c", str(HARNESS), "-o", str(obj)]
    link_command = ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
                    f"@{normalized['objects.rsp']}", f"@{normalized['link.rsp']}"]
    record = {"ref": args.ref, "producer": str(producer), "inputs_sha256": before,
              "commands": [compile_command, link_command], "production_recompiled": False,
              "executed": False}
    try:
        for command in (compile_command, link_command):
            print("==>", shlex.join(command), flush=True)
            subprocess.run(command, check=True, cwd=ROOT, stdin=subprocess.DEVNULL)
    finally:
        changed = [path for path, old in before.items()
                   if not Path(path).is_file() or digest(Path(path)) != old]
        record["changed_inputs"] = changed
        (output / "inputs.json").write_text(json.dumps(record, indent=2) + "\n")
        require(not changed, "Immutable producer/source inputs changed; preserve outputs for inspection")
    record.update(binary=str(binary), binary_sha256=digest(binary))
    (output / "build.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Built {binary}; NOT EXECUTED; producer unchanged.", flush=True)


def run(args: argparse.Namespace) -> int:
    binary, work = args.binary.resolve(), args.work.resolve()
    require(binary.is_file(), f"Missing already-built harness: {binary}")
    require(0 < args.timeout <= 1800, "Timeout must be positive and at most 1800 seconds")
    record = json.loads((binary.parent / "build.json").read_text())
    require(digest(binary) == record["binary_sha256"], "Binary differs from its build receipt")
    producer = Path(record["producer"])
    for protected in (ROOT, producer, binary.parent):
        require(not work.is_relative_to(protected) and not protected.is_relative_to(work),
                "Run work must be disjoint from source, producer and built binary")
    require(not work.exists() or (work.is_dir() and not any(work.iterdir())),
            "Run work must be new or empty; existing evidence is never overwritten")
    work.mkdir(parents=True, exist_ok=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("GLIMS_", "DYLD_", "GIMP", "GEGL_", "BABL_"))}
    for key, leaf in [("HOME", "home"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                      ("XDG_STATE_HOME", "state"), ("XDG_RUNTIME_DIR", "runtime"),
                      ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp"), ("GEGL_SWAP", "swap")]:
        directory = work / leaf
        directory.mkdir(mode=0o700)
        env[key] = str(directory)
    env.update(CFFIXED_USER_HOME=env["HOME"], TMP=env["TMPDIR"], TEMP=env["TMPDIR"],
               G_DEBUG="fatal-criticals", LC_ALL="C", LANG="C")
    process = None
    start = time.monotonic()
    code = 124
    def interrupted(number, frame):
        raise InterruptedError(f"Interrupted by signal {number}")
    previous = {number: signal.signal(number, interrupted) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        with (work / "native.log").open("x") as log:
            process = subprocess.Popen([str(binary), str(work)], cwd=work, env=env,
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=args.timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt, InterruptedError):
                code = 124
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        for number, handler in previous.items():
            signal.signal(number, handler)
    text = (work / "native.log").read_text(errors="replace")
    checks = len(re.findall(r"^ok\s+sample-color:", text, re.M))
    failures = len(re.findall(r"^FAIL\s+sample-color:", text, re.M))
    unreachable = [line for line in text.splitlines() if "branch not exercised" in line]
    success = code == 0 and checks > 0 and failures == 0 and "PASSED:" in text
    result = {"binary": str(binary), "binary_sha256": digest(binary), "ref": record["ref"],
              "exit": code, "checks": checks, "failures": failures,
              "unreachable_native_invalid_cases": unreachable,
              "elapsed_seconds": time.monotonic() - start, "timeout": args.timeout,
              "standalone_validation": False, "success": success}
    (work / "run.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)
    return 0 if success else code or 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="Compile only against an existing fresh API174 producer")
    build_parser.add_argument("--ref", choices=SUPPORTED, default="GIMP_3_2_8")
    build_parser.add_argument("--producer", type=Path)
    build_parser.add_argument("--out", type=Path, required=True)
    run_parser = commands.add_parser("run", help="Explicit isolated native execution")
    run_parser.add_argument("--binary", type=Path, required=True)
    run_parser.add_argument("--work", type=Path, required=True)
    run_parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    try:
        if args.command == "build":
            build(args)
            return 0
        return run(args)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"test-sample-color: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
