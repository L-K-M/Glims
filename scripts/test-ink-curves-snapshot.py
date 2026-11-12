#!/usr/bin/env python3
"""Compile independent slots 199-201 ink Curves snapshot tests against an existing producer."""
import argparse
import math
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def bounded_process(argv, log, timeout, *, cwd=None, env=None) -> int:
    process = subprocess.Popen(
        argv, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True, stdin=subprocess.DEVNULL,
    )
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return 124


def run(producer: Path, profile: Path, work: Path, timeout: float) -> int:
    work.mkdir(parents=True, exist_ok=False)
    for leaf in ("home", "cache", "config", "data", "user", "tmp"):
        (work / leaf).mkdir()
    required = ["compile.rsp", "objects.rsp", "link.rsp",
                "obj/component-edit.o", "obj/component-curves.o", "obj/component-levels.o"]
    for name in required:
        if not (producer / name).is_file():
            raise SystemExit(f"Matching producer missing {name}: {producer}")
    obj = work / "ink-curves-snapshot-tests.o"
    binary = work / "ink-curves-snapshot-tests"
    with (work / "build.log").open("w") as log:
        result = bounded_process(
            ["xcrun", "clang", "-I", str(ROOT / "Engine"),
             "-I", str(ROOT / "Sources/CGlimsEngine/include"),
             "@" + str(producer / "compile.rsp"), "-std=c11", "-O2",
             "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
             "-c", str(ROOT / "Engine/tests/ink-curves-snapshot-tests.c"), "-o", str(obj)],
            log, 120,
        )
        if result:
            print(f"Fixture compile failed ({result}); see {work / 'build.log'}")
            return result
        result = bounded_process(
            ["xcrun", "clang++", "-o", str(binary), str(obj)]
            + [str(p) for p in sorted((producer / "obj").glob("*.o"))]
            + ["@" + str(producer / "objects.rsp"), "@" + str(producer / "link.rsp")],
            log, 120,
        )
        if result:
            print(f"Fixture link failed ({result}); see {work / 'build.log'}")
            return result
    env = os.environ.copy()
    for key, leaf in (
        ("HOME", "home"), ("CFFIXED_USER_HOME", "home"),
        ("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"),
        ("XDG_DATA_HOME", "data"), ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp"),
        ("BABL_CACHE_DIR", "cache"),
    ):
        env[key] = str(work / leaf)
    with (work / "run.log").open("w") as log:
        result = bounded_process(
            [str(binary), str(work), str(profile)], log, timeout, cwd=work, env=env,
        )
    print((work / "run.log").read_text(), end="")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--producer", type=Path, required=True)
    parser.add_argument("--cmyk-profile", type=Path, required=True)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--timeout", type=float, default=240)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
        parser.error("--timeout must be in (0, 3600]")
    if not args.producer.is_dir() or not args.cmyk_profile.is_file():
        parser.error("Producer directory and external CMYK profile must exist")
    producer, profile = args.producer.resolve(), args.cmyk_profile.resolve()
    if args.work:
        work = args.work.resolve()
        if work.exists():
            parser.error("--work must not exist; preserve earlier fixture output")
        return run(producer, profile, work, args.timeout)
    with tempfile.TemporaryDirectory(prefix="glims-ink-curves-snapshot-") as work:
        # run() expects to create work; create a child to satisfy mkdir(exist_ok=False)
        child = Path(work) / "run"
        return run(producer, profile, child, args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
