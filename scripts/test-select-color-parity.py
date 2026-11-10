#!/usr/bin/env python3
"""Capture unchanged-producer selection masks/history, then compare a candidate.

Build compiles only this harness. Run captures actual engine output under
private settings. Compare requires exact full float-mask and Undo metadata
equality; it derives no expected selection from the adapter workaround.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Engine/tests/select-color-parity-tests.c"
DEFAULT_OUT = ROOT / ".build/select-color-parity-tests"
EXPECTED = {f"{number:02d}-{phase}.mask{suffix}"
            for number in range(16) for phase in ("before", "after", "undo", "redo")
            for suffix in ("", ".txt")}


def fail(message: str) -> None:
    raise SystemExit(f"test-select-color-parity: {message}")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def build(args: argparse.Namespace) -> None:
    producer = args.producer.resolve()
    out = args.out.resolve()
    if producer == out or producer in out.parents or out in producer.parents:
        fail("output must be separate from the immutable producer")
    responses = [producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")]
    objects = sorted((producer / "obj").glob("*.o"))
    if not objects or any(not path.is_file() for path in responses):
        fail("producer needs existing obj/*.o and all three response files")
    core = [Path(value) for value in shlex.split(responses[1].read_text())]
    if not core or any(not path.is_absolute() or not path.is_file() for path in core):
        fail("objects.rsp must name existing absolute core objects")
    inputs = sorted(set(objects + core + responses + [SOURCE, ROOT / "Engine/engine-private.h",
                        ROOT / "Sources/CGlimsEngine/include/glims_engine.h"]))
    before = {str(path): digest(path) for path in inputs}
    out.mkdir(parents=True, exist_ok=True)
    obj, binary = out / "select-color-parity-tests.o", out / "select-color-parity-tests"
    commands = [
        ["xcrun", "clang", f"@{responses[0]}", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-I", str(ROOT / "Engine"), "-I", str(ROOT / "Sources/CGlimsEngine/include"),
         "-c", str(SOURCE), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
         f"@{responses[1]}", f"@{responses[2]}"],
    ]
    try:
        for command in commands:
            print("==> " + shlex.join(command), flush=True)
            subprocess.run(command, check=True)
    finally:
        if any(not path.is_file() or digest(path) != before[str(path)] for path in inputs):
            fail("immutable producer/source inputs changed during build")
    (out / "build.json").write_text(json.dumps({"producer": str(producer), "commands": commands,
        "source_sha256": digest(SOURCE), "binary_sha256": digest(binary),
        "inputs_sha256": before}, indent=2, sort_keys=True) + "\n")
    print(f"Built {binary}; inputs unchanged; not executed.")


def run(args: argparse.Namespace) -> int:
    binary = args.binary.resolve()
    build_info = json.loads((binary.parent / "build.json").read_text())
    if digest(binary) != build_info["binary_sha256"]:
        fail("binary does not match its build manifest")
    work = args.work.resolve()
    work.mkdir(parents=True, mode=0o700, exist_ok=True)
    if any(work.iterdir()):
        fail("capture work directory must be empty")
    for name in ("home", "cache", "user", "tmp", "config", "data", "state", "runtime", "capture"):
        (work / name).mkdir(mode=0o700)
    env = {name: value for name, value in os.environ.items() if not name.startswith("DYLD_")}
    env.update(HOME=str(work / "home"), XDG_CACHE_HOME=str(work / "cache"),
               GIMP3_DIRECTORY=str(work / "user"), TMPDIR=str(work / "tmp"),
               TMP=str(work / "tmp"), TEMP=str(work / "tmp"),
               XDG_CONFIG_HOME=str(work / "config"), XDG_DATA_HOME=str(work / "data"),
               XDG_STATE_HOME=str(work / "state"), XDG_RUNTIME_DIR=str(work / "runtime"),
               G_DEBUG="fatal-criticals", LC_ALL="C", LANG="C", PYTHONDONTWRITEBYTECODE="1")
    with (work / "stdout.log").open("wb") as stdout, (work / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen([str(binary), str(work)], env=env, cwd=work,
            stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
    stdout_text = (work / "stdout.log").read_text(errors="replace")
    sys.stdout.write(stdout_text)
    sys.stderr.write((work / "stderr.log").read_text(errors="replace"))
    if code:
        return code
    files = {path.name for path in (work / "capture").iterdir()}
    if files != EXPECTED:
        fail(f"incomplete/unexpected capture file set: missing={sorted(EXPECTED-files)}, extra={sorted(files-EXPECTED)}")
    engine = [line for line in stdout_text.splitlines() if line.startswith("PARITY engine=")]
    if len(engine) != 1:
        fail("capture lacks its actual engine/fixture identity")
    manifest = {"build": build_info, "engine": engine[0],
                "files_sha256": {name: digest(work / "capture" / name) for name in sorted(EXPECTED)}}
    (work / "capture.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Captured 16 fixtures, {len(EXPECTED)} actual mask/history files at {work}")
    return 0


def compare(args: argparse.Namespace) -> int:
    reference, candidate = args.reference.resolve(), args.candidate.resolve()
    records = [json.loads((path / "capture.json").read_text()) for path in (reference, candidate)]
    if records[0]["build"]["source_sha256"] != records[1]["build"]["source_sha256"] or records[0]["engine"] != records[1]["engine"]:
        fail("captures must use the identical oracle source and engine/fixture version")
    mismatches = []
    for root, record in zip((reference, candidate), records):
        if set(record["files_sha256"]) != EXPECTED or {path.name for path in (root / "capture").iterdir()} != EXPECTED:
            fail(f"incomplete/unexpected capture set at {root}")
        for name, expected in record["files_sha256"].items():
            if digest(root / "capture" / name) != expected:
                fail(f"capture changed since recording: {root / 'capture' / name}")
    for name in sorted(EXPECTED):
        if (reference / "capture" / name).read_bytes() != (candidate / "capture" / name).read_bytes():
            mismatches.append(name)
    print(f"{'FAILED' if mismatches else 'PASSED'}: {len(EXPECTED)} full mask/history files; differing={mismatches}")
    return 1 if mismatches else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("build", help="compile ONLY parity harness, link selected immutable producer")
    p.add_argument("--producer", type=Path, required=True)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p = sub.add_parser("run", help="capture actual masks/history under private settings")
    p.add_argument("--binary", type=Path, default=DEFAULT_OUT / "select-color-parity-tests")
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--timeout", type=int, default=180)
    p = sub.add_parser("compare", help="byte-compare complete original and candidate captures")
    p.add_argument("--reference", type=Path, required=True)
    p.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build": build(args)
    elif args.command == "run":
        if args.timeout < 1: fail("timeout must be positive")
        raise SystemExit(run(args))
    else: raise SystemExit(compare(args))


if __name__ == "__main__":
    main()
