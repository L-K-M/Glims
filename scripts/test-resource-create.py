#!/usr/bin/env python3
"""Build and run the standalone resource_create_pixels (slot 129) tests.

usage: python3 scripts/test-resource-create.py [--ref GIMP_REF]
                                               [--adapter-root DIR]
                                               [--timeout SECONDS]

--help prints this text and exits before doing anything else: no compile,
no engine start, no filesystem writes outside argument parsing.

What it does (and nothing more):

  1. Selects an already-built producer: ADAPTER_ROOT/REF/libglimsengine.dylib
     plus the producer's own compile.rsp/link.rsp flags. ADAPTER_ROOT
     defaults to $GLIMS_ADAPTER_ROOT or <repo>/_engine/adapter; REF defaults
     to the first ENGINE_SETS entry in scripts/engine.env. Nothing is ever
     rebuilt: a missing adapter/ref is an error pointing at
     scripts/build-adapter.sh.
  2. Compiles the two test-only sources in a unique temporary directory:
     Engine/tests/resource-create-tests.c (facade-only dlopen runner, linked
     against nothing but the facade header, exactly like the conformance
     runner) and Engine/tests/resource-create-interpose.c (a -dynamiclib
     shim compiled with the producer's compile.rsp flags and linked only
     against the glib/gobject/gio dylibs found in the producer's link.rsp —
     never libgimp, never engine objects).
  3. Runs the runner twice on one unique temporary work directory (the
     engine starts only once per process): phase "create" exercises
     resource_create_pixels happy paths, refusals, BUSY and the armed
     deterministic fault cases; phase "verify" restarts the engine on the
     same directories and checks restart persistence. HOME,
     XDG_CACHE_HOME and GIMP3_DIRECTORY are set entirely under the work
     directory, and an isolated gimprc is written into the user directory
     before startup so the writable brush/pattern folders are the ones
     under the work directory. The shim goes in through
     DYLD_INSERT_LIBRARIES.
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

# The only runtime libraries the shim links: the producer's own glib
# copies from its link.rsp. libgimp*/gegl/babl/engine objects are never
# linked into the dlopen facade runner or the shim.
SHIM_LIB_BASENAMES = {"libglib-2.0.dylib", "libgobject-2.0.dylib", "libgio-2.0.dylib"}

GIMPRC = """\
# Written by scripts/test-resource-create.py before engine startup:
# pin the writable resource folders to this throwaway GIMP3_DIRECTORY
# while keeping the engine's own stock data dirs in the search path.
(brush-path "${gimp_dir}/brushes:${gimp_data_dir}/brushes")
(brush-path-writable "${gimp_dir}/brushes")
(pattern-path "${gimp_dir}/patterns:${gimp_data_dir}/patterns")
(pattern-path-writable "${gimp_dir}/patterns")
"""


def fail(message, code=2):
    print(f"test-resource-create: {message}", file=sys.stderr)
    raise SystemExit(code)


def default_ref():
    """First ENGINE_SETS entry of scripts/engine.env (the pinned engine)."""
    env_file = REPO / "scripts" / "engine.env"
    for line in env_file.read_text().splitlines():
        if line.startswith("ENGINE_SETS="):
            value = line.split("=", 1)[1].strip().strip('"')
            return value.split()[0].split(":")[0]
    fail("scripts/engine.env has no ENGINE_SETS")


def read_rsp(path):
    """One quoted argument per line, as written by scripts/adapter-flags.py."""
    args = []
    for line in path.read_text().splitlines():
        args.extend(shlex.split(line))
    return args


def run_checked(cmd, what, env=None, timeout=None):
    print(f"test-resource-create: {what}: {' '.join(shlex.quote(c) for c in cmd[:6])} ...",
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
        prog="test-resource-create.py",
        description="Build and run the standalone resource_create_pixels (slot 129) "
                    "facade tests against an already-built engine adapter.",
        epilog="example: python3 scripts/test-resource-create.py --ref GIMP_3_2_8 "
               "--adapter-root \"$PWD/.build/engine-adapters\"")
    parser.add_argument("--ref", default=None,
                        help="engine set name (default: first ENGINE_SETS entry in "
                             "scripts/engine.env)")
    parser.add_argument("--adapter-root", default=None,
                        help="adapter output root (default: $GLIMS_ADAPTER_ROOT or "
                             "<repo>/_engine/adapter)")
    parser.add_argument("--timeout", type=int, default=900,
                        help="per-phase harness timeout in seconds (default: 900)")
    args = parser.parse_args()  # --help exits here, before any work below

    ref = args.ref or default_ref()
    adapter_root = Path(args.adapter_root or os.environ.get("GLIMS_ADAPTER_ROOT")
                        or (REPO / "_engine" / "adapter")).resolve()
    out = adapter_root / ref
    library = out / "libglimsengine.dylib"
    compile_rsp = out / "compile.rsp"
    link_rsp = out / "link.rsp"
    for required in (library, compile_rsp, link_rsp):
        if not required.is_file():
            fail(f"{required} is missing; build the producer first with "
                 f"scripts/build-adapter.sh {ref} (this script never rebuilds)")

    compile_args = read_rsp(compile_rsp)
    link_args = read_rsp(link_rsp)

    shim_libs = []
    for arg in link_args:
        base = os.path.basename(arg)
        if arg.endswith(".dylib") and os.path.isabs(arg) and base in SHIM_LIB_BASENAMES:
            shim_libs.append(arg)
        elif "libgimp" in base or base.endswith(".a") or base.endswith(".o"):
            continue  # never linked into the shim/runner
    missing = SHIM_LIB_BASENAMES - {os.path.basename(p) for p in shim_libs}
    if missing:
        fail(f"{link_rsp} does not list the glib/gobject/gio dylibs the shim needs: "
             f"{sorted(missing)}")

    tmp = Path(tempfile.mkdtemp(prefix="glims-resource-create-"))
    exit_code = 2
    try:
        work = tmp / "work"
        for child in ("home", "cache", "user"):
            (work / child).mkdir(parents=True)
        (work / "user" / "gimprc").write_text(GIMPRC)

        shim = tmp / "resource-create-interpose.dylib"
        runner = tmp / "resource-create-tests"

        run_checked(
            ["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-dynamiclib", *compile_args, "-I" + str(FACADE_INCLUDE),
             str(TESTS_DIR / "resource-create-interpose.c"), *shim_libs,
             "-o", str(shim)],
            "compiling the interposer shim with the producer's compile flags")

        run_checked(
            ["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(FACADE_INCLUDE),
             str(TESTS_DIR / "resource-create-tests.c"), "-o", str(runner)],
            "compiling the facade-only test runner")

        env = os.environ.copy()
        env["HOME"] = str(work / "home")
        env["XDG_CACHE_HOME"] = str(work / "cache")
        env["GIMP3_DIRECTORY"] = str(work / "user")
        env["DYLD_INSERT_LIBRARIES"] = str(shim)

        print(f"test-resource-create: ref={ref} adapter={library} work={work}",
              file=sys.stderr)
        for phase in ("create", "verify"):
            result = run_checked(
                [str(runner), str(library), str(work), phase],
                f"running harness phase {phase!r}", env=env, timeout=args.timeout)
            if result.returncode != 0:
                exit_code = result.returncode
                break
        else:
            exit_code = 0
    finally:
        # Only this test's own temporary directory is removed; the
        # sentinel oracle results were already reported by the harness
        # before it exited.
        try:
            shutil.rmtree(tmp)
        except OSError as error:
            print(f"test-resource-create: warning: could not remove {tmp}: {error}",
                  file=sys.stderr)
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
