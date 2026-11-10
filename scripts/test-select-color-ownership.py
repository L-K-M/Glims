#!/usr/bin/env python3
"""Compile only the ownership harness; link an existing immutable producer.

The run subcommand launches a separate engine process per 0/1/2-selection
case, with fresh images per selection. Zero has one unselected baseline
image. No producer/upstream source or object is compiled or changed.
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
SOURCE = ROOT / "Engine/tests/select-color-ownership-tests.c"
DEFAULT_OUT = ROOT / ".build/select-color-ownership-tests"
REFS = ("GIMP_3_2_8", "GIMP_3_2_0", "GIMP_3_0_8", "master")


def fail(message: str) -> None:
    raise SystemExit(f"test-select-color-ownership: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def producer_for(ref: str) -> Path:
    return Path(os.environ.get("GLIMS_ADAPTER_ROOT", str(ROOT / "_engine/adapter"))) / ref


def build(args: argparse.Namespace) -> None:
    producer = (args.producer or producer_for(args.ref)).resolve()
    out = (args.out or DEFAULT_OUT / args.ref).resolve()
    if producer == out or producer in out.parents or out in producer.parents:
        fail("output must be separate from the immutable producer")
    responses = [producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")]
    objects = sorted((producer / "obj").glob("*.o"))
    if not objects or any(not path.is_file() for path in responses):
        fail(f"producer needs obj/*.o, compile.rsp, objects.rsp, link.rsp: {producer}")
    # objects.rsp contains the existing gimp-console objects, excluding main.
    # Treat all of them as immutable too; no implementation object is replaced.
    core_objects = [Path(value) for value in shlex.split(responses[1].read_text())]
    if not core_objects or any(not path.is_absolute() or not path.is_file() for path in core_objects):
        fail("objects.rsp must name existing absolute core-object paths")
    source_inputs = [SOURCE, ROOT / "Engine/engine-private.h", ROOT / "Sources/CGlimsEngine/include/glims_engine.h"]
    watched = sorted(set(responses + objects + core_objects + source_inputs))
    before = {str(path): sha256(path) for path in watched}
    out.mkdir(parents=True, exist_ok=True)
    obj = out / "select-color-ownership-tests.o"
    binary = out / "select-color-ownership-tests"
    commands = [
        ["xcrun", "clang", f"@{responses[0]}", "-std=c11", "-O2",
         "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
         "-I", str(ROOT / "Engine"), "-c", str(SOURCE), "-o", str(obj)],
        ["xcrun", "clang++", "-o", str(binary), str(obj), *map(str, objects),
         f"@{responses[1]}", f"@{responses[2]}"],
    ]
    try:
        for command in commands:
            print("==> " + shlex.join(command), flush=True)
            subprocess.run(command, check=True)
    finally:
        changed = [str(path) for path in watched
                   if not path.is_file() or sha256(path) != before[str(path)]]
        if changed:
            fail("immutable producer input changed: " + ", ".join(changed))
    manifest = {"producer": str(producer), "ref": args.ref,
                "harness_sha256": sha256(SOURCE), "binary_sha256": sha256(binary),
                "commands": commands, "immutable_inputs_sha256": before}
    (out / "build.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Built {binary}; producer inputs unchanged; not executed.")


def run(args: argparse.Namespace) -> int:
    binary = (args.binary or DEFAULT_OUT / args.ref / "select-color-ownership-tests").resolve()
    if not binary.is_file():
        fail(f"binary missing: {binary}; build first")
    work = args.work.resolve()
    work.mkdir(parents=True, mode=0o700, exist_ok=True)
    if any(work.iterdir()):
        fail(f"work directory must be empty, to prevent stale private state: {work}")
    modes = ("contiguous", "by-color") if args.mode == "all" else (args.mode,)
    samples = ("layer", "merged") if args.sample == "all" else (args.sample,)
    results = []
    for mode in modes:
        for sample in samples:
            for count in args.selections:
                case_work = work / f"{mode}-{sample}-{count}"
                names = ("home", "cache", "user", "tmp", "config", "data", "state", "runtime")
                for name in names:
                    (case_work / name).mkdir(parents=True, mode=0o700)
                env = {name: value for name, value in os.environ.items()
                       if not name.startswith("DYLD_")}
                env.update(HOME=str(case_work / "home"), XDG_CACHE_HOME=str(case_work / "cache"),
                           XDG_CONFIG_HOME=str(case_work / "config"), XDG_DATA_HOME=str(case_work / "data"),
                           XDG_STATE_HOME=str(case_work / "state"), XDG_RUNTIME_DIR=str(case_work / "runtime"),
                           GIMP3_DIRECTORY=str(case_work / "user"), TMPDIR=str(case_work / "tmp"),
                           TMP=str(case_work / "tmp"), TEMP=str(case_work / "tmp"),
                           G_DEBUG="fatal-criticals", PYTHONDONTWRITEBYTECODE="1")
                command = [str(binary), str(case_work), str(int(mode == "contiguous")),
                           str(int(sample == "merged")), str(count)]
                print("==> private case " + shlex.join(command), flush=True)
                with (case_work / "stdout.log").open("wb") as stdout, \
                     (case_work / "stderr.log").open("wb") as stderr:
                    process = subprocess.Popen(command, cwd=case_work, env=env,
                                               stdin=subprocess.DEVNULL, stdout=stdout,
                                               stderr=stderr, start_new_session=True)
                    try:
                        code = process.wait(timeout=args.timeout)
                    except subprocess.TimeoutExpired:
                        # Include any plug-in children in timeout cleanup.
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                        code = 124
                out_text = (case_work / "stdout.log").read_text(errors="replace")
                err_text = (case_work / "stderr.log").read_text(errors="replace")
                sys.stdout.write(out_text)
                sys.stderr.write(err_text)
                results.append({"mode": mode, "sample": sample, "selections": count,
                                "returncode": code, "work": str(case_work),
                                "ownership": [line for line in out_text.splitlines()
                                              if line.startswith("OBS after engine stop:")]})
                # Keep logs/results even on RED; no stderr wording is a gate.
                (work / "results.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
                if code == 124:
                    print(f"TIMEOUT after {args.timeout}s: {case_work}", file=sys.stderr)
                    return 124
    return 1 if any(case["returncode"] for case in results) else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("build", help="compile ONLY harness and link immutable producer; never run")
    p.add_argument("--ref", choices=REFS, default=REFS[0])
    p.add_argument("--producer", type=Path)
    p.add_argument("--out", type=Path)
    p = sub.add_parser("run", help="separate process/private state per case; no implicit build")
    p.add_argument("--ref", choices=REFS, default=REFS[0])
    p.add_argument("--binary", type=Path)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--mode", choices=("all", "contiguous", "by-color"), default="all")
    p.add_argument("--sample", choices=("all", "layer", "merged"), default="all")
    p.add_argument("--selections", choices=(0, 1, 2), type=int, nargs="+", default=[0, 1, 2])
    p.add_argument("--timeout", type=int, default=120, help="maximum seconds per isolated case")
    args = parser.parse_args()
    if args.command == "build":
        build(args)
    else:
        if args.timeout < 1 or len(set(args.selections)) != len(args.selections):
            fail("timeout must be positive and selection counts must not repeat")
        raise SystemExit(run(args))


if __name__ == "__main__":
    main()
