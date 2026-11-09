#!/usr/bin/env python3
"""Compile (and optionally run) the standalone resource_create_gradient
(slot 138) facade-only tests.

usage: python3 scripts/test-gradient-create-facade.py [--ref GIMP_REF]
       [--adapter-root DIR | --producer LIBRARY] [--compile-only]
       [--timeout SECONDS]

--help prints this text and exits before doing anything else: no compile,
no engine start, no filesystem writes outside argument parsing.

What it does (and nothing more):

  * Selects an already-built producer: --producer LIBRARY, or
    ADAPTER_ROOT/REF/libglimsengine.dylib with ADAPTER_ROOT from
    --adapter-root, $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter and REF
    from --ref or the first ENGINE_SETS entry in scripts/engine.env.
    Nothing is ever rebuilt: this script never builds, relinks or starts
    an adapter itself; a missing producer is an error pointing at
    scripts/build-adapter.sh.
  * --compile-only compiles Engine/tests/gradient-create-facade-tests.c
    with strict flags (clang -std=c11 -Wall -Wextra -Werror) against ONLY
    the public facade header Sources/CGlimsEngine/include — the harness
    dlopens the producer and links nothing but the C library, no Core or
    native GIMP headers — so the facade wire can be compile-checked with
    no runtime at all.
  * Without --compile-only it also runs the harness twice on one unique
    temporary work directory, each phase as its own process (the engine
    starts only once per process): "create" exercises the public slot end
    to end and writes the persisted identity triplets to a plain owned
    handoff file; "verify" starts a fresh engine on the same directories
    and checks the reload. HOME, XDG_CACHE_HOME and GIMP3_DIRECTORY are
    set entirely under the throwaway work directory, and an isolated
    gimprc written into the user directory pins the writable gradient
    folder there. Only this test's own temporary directory is deleted on
    exit.

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
TEST_SOURCE = REPO / "Engine" / "tests" / "gradient-create-facade-tests.c"

# Written before engine startup: pin the writable gradient folder to the
# throwaway GIMP3_DIRECTORY while keeping the engine's stock data dirs in
# the search path.
GIMPRC = """\
# Written by scripts/test-gradient-create-facade.py before engine startup.
(gradient-path "${gimp_dir}/gradients:${gimp_data_dir}/gradients")
(gradient-path-writable "${gimp_dir}/gradients")
"""


def fail(message, code=2):
    print(f"test-gradient-create-facade: {message}", file=sys.stderr)
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
    print(f"test-gradient-create-facade: {what}: "
          f"{' '.join(shlex.quote(c) for c in cmd[:6])} ...", file=sys.stderr)
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
        prog="test-gradient-create-facade.py",
        description="Compile (and optionally run) the standalone facade-only "
                    "resource_create_gradient (slot 138) tests against an "
                    "already-built engine adapter producer.",
        epilog="example: python3 scripts/test-gradient-create-facade.py "
               "--ref GIMP_3_2_8 --adapter-root \"$PWD/.build/engine-adapters\" "
               "--compile-only")
    parser.add_argument("--ref", default=None,
                        help="engine set name (default: first ENGINE_SETS entry in "
                             "scripts/engine.env)")
    parser.add_argument("--adapter-root", default=None,
                        help="adapter output root (default: $GLIMS_ADAPTER_ROOT or "
                             "<repo>/_engine/adapter)")
    parser.add_argument("--producer", default=None,
                        help="direct path to the producer libglimsengine.dylib "
                             "(overrides --adapter-root/--ref selection)")
    parser.add_argument("--compile-only", action="store_true",
                        help="only compile the facade test harness with strict "
                             "flags; never start an engine or run a phase")
    parser.add_argument("--timeout", type=int, default=900,
                        help="per-phase harness timeout in seconds (default: 900)")
    args = parser.parse_args()  # --help exits here, before any work below

    if args.producer:
        library = Path(args.producer).resolve()
        ref = args.ref or Path(args.producer).parent.name
    else:
        ref = args.ref or default_ref()
        adapter_root = Path(args.adapter_root or os.environ.get("GLIMS_ADAPTER_ROOT")
                            or (REPO / "_engine" / "adapter")).resolve()
        library = adapter_root / ref / "libglimsengine.dylib"
    if not library.is_file():
        fail(f"{library} is missing; build the producer first with "
             f"scripts/build-adapter.sh {ref} (this script never rebuilds)")
    if not TEST_SOURCE.is_file():
        fail(f"{TEST_SOURCE} is missing")

    tmp = Path(tempfile.mkdtemp(prefix="glims-gradient-create-facade-"))
    exit_code = 2
    try:
        runner = tmp / "gradient-create-facade-tests"
        run_checked(
            ["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(FACADE_INCLUDE), str(TEST_SOURCE), "-o", str(runner)],
            "compiling the facade-only test harness (public header only, dlopen)")
        print(f"test-gradient-create-facade: compiled {runner} from {TEST_SOURCE.name}",
              file=sys.stderr)

        if args.compile_only:
            exit_code = 0
        else:
            work = tmp / "work"
            for child in ("home", "cache", "user"):
                (work / child).mkdir(parents=True)
            (work / "user" / "gimprc").write_text(GIMPRC)

            env = os.environ.copy()
            env["HOME"] = str(work / "home")
            env["XDG_CACHE_HOME"] = str(work / "cache")
            env["GIMP3_DIRECTORY"] = str(work / "user")

            print(f"test-gradient-create-facade: ref={ref} producer={library} work={work}",
                  file=sys.stderr)
            for phase in ("create", "verify"):
                result = run_checked(
                    [str(runner), str(library), str(work), phase],
                    f"running harness phase {phase!r} (separate process, isolated env)",
                    env=env, timeout=args.timeout)
                if result.returncode != 0:
                    exit_code = result.returncode
                    break
            else:
                exit_code = 0
    finally:
        # Only this test's own temporary directory is removed.
        try:
            shutil.rmtree(tmp)
        except OSError as error:
            print(f"test-gradient-create-facade: warning: could not remove {tmp}: {error}",
                  file=sys.stderr)
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
