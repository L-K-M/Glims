#!/usr/bin/env python3
"""Run facade-only CMYK editor integration tests against a matching adapter.

Builds only the public-facade fixture, using the supplied matching adapter.
The external source ICC is read in place. All native settings and artifacts
use --work, or an automatically removed temporary directory.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
def compile_test(library: Path, work: Path) -> Path:
    work.mkdir(parents=True, exist_ok=True)
    for leaf in ("home", "cache", "config", "data", "user", "tmp"):
        (work / leaf).mkdir(exist_ok=True)

    if not library.is_file():
        raise SystemExit(f"adapter library is missing: {library}")

    binary = work / "cmyk-editor-tests"
    deps = (ROOT / "_deps/macports").resolve()
    compile_cmd = [
        "xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "Sources/CGlimsEngine/include"), "-I", str(deps / "include"),
        str(ROOT / "Engine/tests/cmyk-editor-tests.c"), str(library),
        str(deps / "lib/liblcms2.dylib"), f"-Wl,-rpath,{library.parent}",
        "-o", str(binary),
    ]
    with (work / "compile.log").open("w") as log:
        subprocess.run(compile_cmd, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    return binary


def run_binary(binary: Path, work: Path, profile: Path, timeout: float) -> int:
    env = os.environ.copy()
    for key, leaf in [
        ("HOME", "home"), ("CFFIXED_USER_HOME", "home"),
        ("XDG_CACHE_HOME", "cache"), ("XDG_CONFIG_HOME", "config"),
        ("XDG_DATA_HOME", "data"), ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp"),
    ]:
        env[key] = str(work / leaf)
    env["BABL_CACHE_DIR"] = str(work / "cache/babl")
    with (work / "run.log").open("w") as log:
        process = subprocess.Popen(
            [str(binary), str(work), str(profile)],
            env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            result = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            result = 124
    print((work / "run.log").read_text(), end="")
    return result


def run(library: Path, profile: Path, work: Path, timeout: float) -> int:
    binary = compile_test(library, work)
    print(f"compile: ok (binary={binary}, library={library})", flush=True)
    result = run_binary(binary, work, profile, timeout)
    print(f"run: exit={result}, artifacts={work}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True,
                        help="matching adapter built with scripts/build-adapter.sh")
    parser.add_argument("--cmyk-profile", type=Path, required=True,
                        help="external CMYK ICC profile, read in place")
    parser.add_argument("--work", type=Path, help="retain isolated test artifacts here")
    parser.add_argument("--timeout", type=float, default=300.0)
    args = parser.parse_args()
    if not 0 < args.timeout <= 3600:
        parser.error("--timeout must be within 0–3600 seconds")
    library, profile = args.library.resolve(), args.cmyk_profile.resolve()
    if not profile.is_file():
        parser.error(f"CMYK profile missing: {profile}")
    if args.work:
        return run(library, profile, args.work.resolve(), args.timeout)
    with tempfile.TemporaryDirectory(prefix="glims-cmyk-editor-") as work:
        return run(library, profile, Path(work), args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
