#!/usr/bin/env python3
"""Compile independent slot 266 CMYK Trap tests against an existing producer."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def bounded_process(argv, log, timeout, *, cwd=None, env=None) -> int:
    process = subprocess.Popen(
        argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        status = process.wait(timeout=timeout)
        # wait() is negative when a signal killed the child; normalize to the
        # conventional 128+signal so wrappers can tell a crash from exit 245.
        return 128 - status if status < 0 else status
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
    for leaf in ("home", "cache", "config", "data", "user", "tmp"):
        (work / leaf).mkdir(exist_ok=True)
    for name in ("compile.rsp", "objects.rsp", "link.rsp", "obj/trap-cmyk.o"):
        if not (producer / name).is_file():
            raise SystemExit(f"Matching slot 266 producer missing {name}: {producer}")
    # The default 16 x 4 build, then a 2100 x 140 build whose diagonal
    # stripes put ink boundaries across the engine's tile seams.
    variants = (
        ("trap-cmyk-tests", []),
        ("trap-cmyk-seams", ["-DTRAP_TEST_W=2100", "-DTRAP_TEST_H=140",
                             "-DTRAP_TEST_DIAGONAL=1"]),
    )
    for name, defines in variants:
        result = run_variant(producer, profile, work, timeout, name, defines)
        if result:
            return result
    return 0


def run_variant(producer: Path, profile: Path, work: Path, timeout: float,
                name: str, defines: list) -> int:
    obj = work / f"{name}.o"
    binary = work / name
    with (work / f"{name}-build.log").open("w") as log:
        result = bounded_process(
            ["xcrun", "clang", "-I", str(ROOT / "Engine"),
             "-I", str(ROOT / "Sources/CGlimsEngine/include"),
             "@" + str(producer / "compile.rsp"), "-std=c11", "-O2",
             "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
             *defines, "-c", str(ROOT / "Engine/tests/trap-cmyk-tests.c"), "-o", str(obj)],
            log, 120,
        )
        if result:
            print(f"Fixture compile failed ({result}); see {work / f'{name}-build.log'}")
            return result
        result = bounded_process(
            ["xcrun", "clang++", "-o", str(binary), str(obj)]
            + [str(p) for p in sorted((producer / "obj").glob("*.o"))]
            + ["@" + str(producer / "objects.rsp"), "@" + str(producer / "link.rsp")],
            log, 120,
        )
        if result:
            print(f"Fixture link failed ({result}); see {work / f'{name}-build.log'}")
            return result
    env = os.environ.copy()
    for key, leaf in (
        ("HOME", "home"), ("CFFIXED_USER_HOME", "home"),
        ("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"),
        ("XDG_DATA_HOME", "data"), ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp"),
    ):
        env[key] = str(work / leaf)
    with (work / f"{name}-run.log").open("w") as log:
        result = bounded_process(
            [str(binary), str(work), str(profile)], log, timeout, cwd=work, env=env,
        )
    # A crashed binary may leave bytes that are not UTF-8.
    print((work / f"{name}-run.log").read_text(errors="replace"), end="")
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
    with tempfile.TemporaryDirectory(prefix="glims-trap-cmyk-") as work:
        return run(producer, profile, Path(work), args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
