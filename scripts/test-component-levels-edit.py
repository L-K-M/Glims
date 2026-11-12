#!/usr/bin/env python3
"""Compile independent slot184 Levels-on-ink tests against an existing producer."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def bounded_process(argv, log, timeout, *, cwd=None, env=None) -> int:
    process = subprocess.Popen(
        argv, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
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
    work.mkdir(parents=True, exist_ok=True)
    for leaf in ("home", "cache", "config", "data", "user", "tmp", "cancel"):
        (work / leaf).mkdir(exist_ok=True)
    for name in ("compile.rsp", "objects.rsp", "link.rsp",
                 "obj/component-edit.o", "obj/component-levels.o"):
        if not (producer / name).is_file():
            raise SystemExit(f"Matching slot184 producer missing {name}: {producer}")
    obj = work / "component-levels-edit-tests.o"
    binary = work / "component-levels-edit-tests"
    with (work / "build.log").open("w") as log:
        result = bounded_process(
            ["xcrun", "clang", "-I", str(ROOT / "Engine"),
             "-I", str(ROOT / "Sources/CGlimsEngine/include"),
             "@" + str(producer / "compile.rsp"), "-std=c11", "-O2",
             "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
             "-c", str(ROOT / "Engine/tests/component-levels-edit-tests.c"), "-o", str(obj)],
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
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    if not 0 < args.timeout <= 3600:
        parser.error("--timeout must be in (0, 3600]")
    if not args.producer.is_dir() or not args.cmyk_profile.is_file():
        parser.error("Producer directory and external CMYK profile must exist")
    producer, profile = args.producer.resolve(), args.cmyk_profile.resolve()
    if args.work:
        return run(producer, profile, args.work.resolve(), args.timeout)
    with tempfile.TemporaryDirectory(prefix="glims-component-levels-edit-") as work:
        return run(producer, profile, Path(work), args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
