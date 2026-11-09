#!/usr/bin/env python3
"""Build and run the Core-linked gradient-create-native harness.

Test-only driver for Engine/tests/gradient-create-tests.c and the
INTERNAL-ONLY helper Engine/resource-gradient-create.c (no facade slot).
It never rebuilds or relinks the shared producer/engine: the caller selects
an existing producer prefix (a directory produced by scripts/build-adapter.sh,
or any directory with the same layout) containing:

    obj/          the adapter's object files (obj/*.o)
    compile.rsp   GIMP gimp-console's exact compile flags (clang response file)
    objects.rsp   GIMP gimp-console's object files minus main.c.o
    link.rsp      GIMP gimp-console's exact link arguments (libraries, rpaths)

Producer selection is explicit:

  --producer PATH       use PATH directly, or
  --ref NAME --adapter-root DIR
                        use DIR/NAME (default adapter root is
                        $GLIMS_ADAPTER_ROOT or <checkout>/_engine/adapter)

Subcommands:

  build   compile the helper + harness into OUT and link the standalone
          harness executable against the producer objects; also compile the
          reused Engine/tests/resource-create-interpose.c fault shim
  run     run a built harness for one phase with a throwaway HOME/cache/GIMP
          dir: --work DIR --phase create|verify [--shim PATH]
  all     build, then run phase "create" and phase "verify" as two SEPARATE
          processes on one throwaway work dir (the engine is never restarted
          inside one process)

The new helper is compiled into OUT as its own object because the selected
producer predates it; if the producer's obj/ already contains a matching
resource-gradient-create.o, that object is used instead and the helper is
not compiled again (no duplicate symbol). No libgimp and no other Engine or
upstream source is compiled by this script; the producer objects are
read-only inputs.

The run uses only throwaway directories: HOME=<work>/home,
XDG_CACHE_HOME=<work>/cache, GIMP3_DIRECTORY=<work>/user, plus a gimprc that
pins the writable gradient folder under <work>/user. The user's real HOME,
~/.cache and GIMP settings are never touched. The optional fault shim goes
in through DYLD_INSERT_LIBRARIES (the harness dlsyms its glims_test_* controls
and arms them only around single resource calls after startup).

Examples:

  python3 scripts/test-gradient-create.py build --ref GIMP_3_2_8
  python3 scripts/test-gradient-create.py run --work /tmp/gc --phase create
  python3 scripts/test-gradient-create.py all --producer "$PWD/_engine/adapter/GIMP_3_2_8" \
      --work "$(mktemp -d /tmp/glims-gradient-create.XXXXXX)"
"""
from __future__ import annotations

import argparse
import glob
import os
import shlex
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
HELPER_SOURCE = REPO_ROOT / "Engine" / "resource-gradient-create.c"
HARNESS_SOURCE = REPO_ROOT / "Engine" / "tests" / "gradient-create-tests.c"
SHIM_SOURCE = REPO_ROOT / "Engine" / "tests" / "resource-create-interpose.c"
FACADE_INCLUDE = REPO_ROOT / "Sources" / "CGlimsEngine" / "include"
ENGINE_DIR = REPO_ROOT / "Engine"
DEFAULT_OUT = REPO_ROOT / ".build" / "gradient-create-tests"
DEFAULT_REF = "GIMP_3_2_8"

# The only runtime libraries the shim links: glib/gobject/gio dylibs found in
# the producer's link.rsp. Never libgimp, never engine objects.
SHIM_LIB_BASENAMES = {"libglib-2.0.dylib", "libgobject-2.0.dylib", "libgio-2.0.dylib"}

GIMPRC = """\
# Written by scripts/test-gradient-create.py before engine startup: pin the
# writable gradient folder to this throwaway GIMP3_DIRECTORY while keeping
# the engine's own stock data dirs in the search path.
(gradient-path "${gimp_dir}/gradients:${gimp_data_dir}/gradients")
(gradient-path-writable "${gimp_dir}/gradients")
"""


def default_adapter_root() -> Path:
    env_root = os.environ.get("GLIMS_ADAPTER_ROOT")
    return Path(env_root) if env_root else REPO_ROOT / "_engine" / "adapter"


def resolve_producer(args: argparse.Namespace) -> Path:
    if args.producer:
        return Path(args.producer)
    return Path(args.adapter_root) / args.ref


def fail(message: str) -> None:
    print(f"test-gradient-create: {message}", file=sys.stderr)
    sys.exit(1)


def check_producer(producer: Path) -> dict:
    if not producer.is_dir():
        fail(f"producer prefix {producer} is not a directory; pass --producer PREFIX or "
             f"--ref NAME --adapter-root DIR (default adapter root: {default_adapter_root()})")
    paths = {
        "obj": sorted(glob.glob(str(producer / "obj" / "*.o"))),
        "compile_rsp": producer / "compile.rsp",
        "objects_rsp": producer / "objects.rsp",
        "link_rsp": producer / "link.rsp",
    }
    missing = [name for name, value in paths.items()
               if (isinstance(value, list) and not value) or
               (isinstance(value, Path) and not value.is_file())]
    if missing:
        fail(f"producer prefix {producer} is missing: {', '.join(missing)}; point "
             f"--producer/--adapter-root at an existing adapter build dir")
    for required in (HELPER_SOURCE, HARNESS_SOURCE, SHIM_SOURCE,
                     FACADE_INCLUDE / "glims_engine.h", ENGINE_DIR / "engine-private.h"):
        if not required.is_file():
            fail(f"required source missing: {required}")
    return paths


def read_rsp(path: Path) -> list:
    """One quoted argument per line, as written by scripts/adapter-flags.py."""
    args = []
    for line in path.read_text().splitlines():
        args.extend(shlex.split(line))
    return args


def run_command(cmd: list) -> int:
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    return subprocess.run(cmd).returncode


def build(producer: Path, out: Path) -> int:
    paths = check_producer(producer)
    compile_args = read_rsp(paths["compile_rsp"])
    link_args = read_rsp(paths["link_rsp"])
    out.mkdir(parents=True, exist_ok=True)
    helper_obj = out / "resource-gradient-create.o"
    harness_obj = out / "gradient-create-tests.o"
    binary = out / "gradient-create-tests"
    shim = out / "resource-create-interpose.dylib"

    # Use the producer's own helper object when it already ships one.
    producer_helper = producer / "obj" / "resource-gradient-create.o"
    link_objects = list(paths["obj"])
    if producer_helper.is_file():
        link_objects = [o for o in link_objects if Path(o).name != "resource-gradient-create.o"]
        link_objects.append(str(producer_helper))
        print(f"==> using the producer's own {producer_helper}")
    else:
        print("==> compile the new helper object")
        code = run_command(["xcrun", "clang", f"@{paths['compile_rsp']}",
                            "-I", str(FACADE_INCLUDE), "-I", str(ENGINE_DIR),
                            "-std=c11", "-O2", "-Wall", "-Wextra",
                            "-Werror=implicit-function-declaration",
                            "-c", str(HELPER_SOURCE), "-o", str(helper_obj)])
        if code != 0:
            return code
        link_objects.insert(0, str(helper_obj))

    print("==> compile the harness object")
    code = run_command(["xcrun", "clang", f"@{paths['compile_rsp']}",
                        "-I", str(FACADE_INCLUDE), "-I", str(ENGINE_DIR),
                        "-std=c11", "-O2", "-Wall", "-Wextra",
                        "-Werror=implicit-function-declaration",
                        "-c", str(HARNESS_SOURCE), "-o", str(harness_obj)])
    if code != 0:
        return code

    print("==> compile the reused fault shim (glib dylibs only)")
    shim_libs = [a for a in link_args
                 if a.endswith(".dylib") and os.path.isabs(a)
                 and os.path.basename(a) in SHIM_LIB_BASENAMES]
    missing = SHIM_LIB_BASENAMES - {os.path.basename(p) for p in shim_libs}
    if missing:
        fail(f"{paths['link_rsp']} does not list the glib/gobject/gio dylibs the shim "
             f"needs: {sorted(missing)}")
    code = run_command(["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-dynamiclib", *compile_args, "-I", str(FACADE_INCLUDE),
                        str(SHIM_SOURCE), *shim_libs, "-o", str(shim)])
    if code != 0:
        return code

    print("==> link the standalone harness executable")
    code = run_command(["xcrun", "clang++", "-o", str(binary),
                        str(harness_obj), *link_objects,
                        f"@{paths['objects_rsp']}", f"@{paths['link_rsp']}"])
    if code != 0:
        return code
    print(f"-- built {binary} (+ {shim.name})")
    return 0


def run(binary: Path, work: Path, phase: str, shim: Path | None, timeout: int) -> int:
    if not binary.is_file():
        fail(f"harness binary missing: {binary}; run the build subcommand first")
    if phase not in ("create", "verify"):
        fail(f"unknown phase {phase!r}; expected create or verify")
    for sub in ("home", "cache", "user"):
        (work / sub).mkdir(parents=True, exist_ok=True)
    (work / "user" / "gimprc").write_text(GIMPRC)

    env = os.environ.copy()
    env["HOME"] = str(work / "home")
    env["XDG_CACHE_HOME"] = str(work / "cache")
    env["GIMP3_DIRECTORY"] = str(work / "user")
    if shim is not None:
        if not shim.is_file():
            fail(f"shim missing: {shim}")
        env["DYLD_INSERT_LIBRARIES"] = str(shim)
    cmd = [str(binary), str(work), phase]
    print(f"==> run phase {phase} (HOME={env['HOME']}, GIMP3_DIRECTORY={env['GIMP3_DIRECTORY']})")
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    try:
        return subprocess.run(cmd, env=env, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        print(f"test-gradient-create: phase {phase} did not finish within {timeout}s",
              file=sys.stderr)
        return 124


def add_producer_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--producer", type=Path, default=None,
                        help="producer prefix with obj/, compile.rsp, objects.rsp, link.rsp")
    parser.add_argument("--adapter-root", type=Path, default=default_adapter_root(),
                        help="adapter root used with --ref")
    parser.add_argument("--ref", default=DEFAULT_REF,
                        help=f"engine set name under --adapter-root (default: {DEFAULT_REF})")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="compile + link helper, harness and shim (no run)")
    add_producer_args(p_build)
    p_build.add_argument("--out", type=Path, default=DEFAULT_OUT,
                         help=f"output directory (default: {DEFAULT_OUT})")

    p_run = sub.add_parser("run", help="run one phase of a built harness")
    p_run.add_argument("--binary", type=Path, default=DEFAULT_OUT / "gradient-create-tests")
    p_run.add_argument("--work", type=Path, required=True, help="throwaway work dir")
    p_run.add_argument("--phase", required=True, choices=("create", "verify"))
    p_run.add_argument("--shim", type=Path, default=DEFAULT_OUT / "resource-create-interpose.dylib",
                       help="fault shim for DYLD_INSERT_LIBRARIES (default: <out>/shim)")
    p_run.add_argument("--timeout", type=int, default=900)

    p_all = sub.add_parser("all", help="build, then run create and verify as two processes")
    add_producer_args(p_all)
    p_all.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p_all.add_argument("--work", type=Path, required=True)
    p_all.add_argument("--timeout", type=int, default=900)

    args = parser.parse_args()  # --help exits here, before any work below

    if args.command == "build":
        sys.exit(build(resolve_producer(args), args.out))
    if args.command == "run":
        sys.exit(run(args.binary, args.work, args.phase, args.shim, args.timeout))
    if args.command == "all":
        producer = resolve_producer(args)
        code = build(producer, args.out)
        if code != 0:
            sys.exit(code)
        binary = args.out / "gradient-create-tests"
        shim = args.out / "resource-create-interpose.dylib"
        code = run(binary, args.work, "create", shim, args.timeout)
        if code != 0:
            sys.exit(code)
        sys.exit(run(binary, args.work, "verify", shim, args.timeout))


if __name__ == "__main__":
    main()
