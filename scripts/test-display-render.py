#!/usr/bin/env python3
"""Build and run the standalone image_render_to_profile (slot 132) tests.

usage: python3 scripts/test-display-render.py [--ref GIMP_REF]
                                              [--adapter-root DIR]
                                              [--timeout SECONDS]

--help prints this text and exits before doing anything else: no compile,
no engine start, no filesystem writes outside argument parsing.

What it does (and nothing more):

  1. Selects an already-built producer: ADAPTER_ROOT/REF/libglimsengine.dylib.
     ADAPTER_ROOT defaults to $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter;
     REF defaults to the first ENGINE_SETS entry in scripts/engine.env.
     Nothing is ever rebuilt and no library is ever replaced: a missing
     adapter/ref is an error pointing at scripts/build-adapter.sh. The
     caller-provided library is only dlopen()ed by the test runner.
  2. Compiles the facade-only runner Engine/tests/display-render-tests.c
     into a unique temporary directory with the facade header only
     (xcrun clang -std=c11, no libraries, exactly like the conformance
     runner): it dlopen()s the producer at run time and uses nothing but
     glims_engine.h.
  3. Runs it once on a unique temporary work directory with HOME,
     XDG_CACHE_HOME and GIMP3_DIRECTORY entirely under that directory, so
     no real HOME or user settings are touched. The ICC fixtures are read
     read-only from <repo>/Engine/tests/fixtures (linear-rgb.icc,
     gray.icc). The engine starts only once per process, so one run
     covers all phases.
  4. Deletes only the test-owned temporary directory on exit.

Compile, load, start and harness failures and timeouts are propagated;
no failure is swallowed.
"""
import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FACADE_INCLUDE = REPO / "Sources" / "CGlimsEngine" / "include"
TESTS_DIR = REPO / "Engine" / "tests"
FIXTURES_DIR = TESTS_DIR / "fixtures"


def fail(message, code=2):
    print(f"test-display-render: {message}", file=sys.stderr)
    raise SystemExit(code)


def default_ref():
    """First ENGINE_SETS entry of scripts/engine.env (the pinned engine)."""
    env_file = REPO / "scripts" / "engine.env"
    for line in env_file.read_text().splitlines():
        if line.startswith("ENGINE_SETS="):
            value = line.split("=", 1)[1].strip().strip('"')
            return value.split()[0].split(":")[0]
    fail("scripts/engine.env has no ENGINE_SETS")


def run_checked(cmd, what, env=None, timeout=None):
    print(f"test-display-render: {what}: {' '.join(shlex.quote(c) for c in cmd[:6])} ...",
          file=sys.stderr)
    try:
        result = subprocess.run(cmd, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(f"{what} timed out after {timeout} s", 124)
    except OSError as error:
        fail(f"{what} could not start: {error}")
    if result.returncode != 0:
        fail(f"{what} failed with exit status {result.returncode}", result.returncode)
    return result


def main():
    parser = argparse.ArgumentParser(
        prog="test-display-render.py",
        description="Build and run the standalone image_render_to_profile (slot 132) "
                    "facade tests against an already-built engine adapter.",
        epilog="example: python3 scripts/test-display-render.py --ref GIMP_3_2_8 "
               "--adapter-root \"$PWD/.build/engine-adapters\"")
    parser.add_argument("--ref", default=None,
                        help="engine set name (default: first ENGINE_SETS entry in "
                             "scripts/engine.env)")
    parser.add_argument("--adapter-root", default=None,
                        help="adapter output root (default: $GLIMS_ADAPTER_ROOT or "
                             "<repo>/_engine/adapter)")
    parser.add_argument("--timeout", type=int, default=900,
                        help="harness timeout in seconds (default: 900)")
    args = parser.parse_args()  # --help exits here, before any work below

    ref = args.ref or default_ref()
    adapter_root = Path(args.adapter_root or os.environ.get("GLIMS_ADAPTER_ROOT")
                        or (REPO / "_engine" / "adapter")).resolve()
    library = adapter_root / ref / "libglimsengine.dylib"
    if not library.is_file():
        fail(f"{library} is missing; build the producer first with "
             f"scripts/build-adapter.sh {ref} (this script never rebuilds)")
    for fixture in ("linear-rgb.icc", "gray.icc"):
        if not (FIXTURES_DIR / fixture).is_file():
            fail(f"{FIXTURES_DIR / fixture} is missing")

    tmp = Path(tempfile.mkdtemp(prefix="glims-display-render-"))
    exit_code = 2
    try:
        work = tmp / "work"
        for child in ("home", "cache", "user"):
            (work / child).mkdir(parents=True)

        runner = tmp / "display-render-tests"
        run_checked(
            ["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(FACADE_INCLUDE),
             str(TESTS_DIR / "display-render-tests.c"), "-o", str(runner)],
            "compiling the facade-only test runner")

        env = os.environ.copy()
        env["HOME"] = str(work / "home")
        env["XDG_CACHE_HOME"] = str(work / "cache")
        env["GIMP3_DIRECTORY"] = str(work / "user")

        print(f"test-display-render: ref={ref} adapter={library} work={work}",
              file=sys.stderr)
        result = run_checked(
            [str(runner), str(library), str(work), str(FIXTURES_DIR)],
            "running the slot-132 harness", env=env, timeout=args.timeout)
        exit_code = result.returncode
    finally:
        try:
            shutil.rmtree(tmp)
        except OSError as error:
            print(f"test-display-render: warning: could not remove {tmp}: {error}",
                  file=sys.stderr)
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
