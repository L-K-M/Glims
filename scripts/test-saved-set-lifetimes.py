#!/usr/bin/env python3
"""Build and run the saved-set lifetime regression harness.

Test-only helper for Engine/tests/saved-set-lifetime-tests.c. It never
rebuilds the shared producer: the caller selects an existing producer prefix
(a directory produced by scripts/build-adapter.sh, or any directory with the
same layout) containing:

    obj/          the adapter's object files (obj/*.o)
    compile.rsp   GIMP gimp-console's exact compile flags (clang response file)
    objects.rsp   GIMP gimp-console's object files minus main.c.o
    link.rsp      GIMP gimp-console's exact link arguments (libraries, rpaths)

Subcommands:

  build   compile + link the harness against the producer, without running it
  run     run a previously built harness with a throwaway HOME/cache/GIMP dir
  all     build then run

Examples (run by the owner of the runtime decision; this script only assembles
exact clang command lines from the producer's own rsp files):

  python3 scripts/test-saved-set-lifetimes.py build \
      --producer "$PWD/.build/engine-adapters/GIMP_3_2_8"

  python3 scripts/test-saved-set-lifetimes.py all \
      --producer "$PWD/.build/engine-adapters/GIMP_3_2_8" \
      --work "$(mktemp -d /tmp/glims-saved-set-tests.XXXXXX)"

The harness binary and its object go to --out (default
<checkout>/.build/saved-set-lifetime-tests/, gitignored). The run uses only
throwaway directories: HOME=<work>/home, XDG_CACHE_HOME=<work>/cache,
GIMP3_DIRECTORY=<work>/user, and passes <work> to the binary, which creates
<work>/{home,user,cache} itself. The user's real HOME, ~/.cache and GIMP
settings are never touched.
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
SOURCE = REPO_ROOT / "Engine" / "tests" / "saved-set-lifetime-tests.c"
FACADE_INCLUDE = REPO_ROOT / "Sources" / "CGlimsEngine" / "include"
ENGINE_DIR = REPO_ROOT / "Engine"
DEFAULT_OUT = REPO_ROOT / ".build" / "saved-set-lifetime-tests"
DEFAULT_REF = "GIMP_3_2_8"


def default_producer(checkout: Path, ref: str) -> Path:
    env_root = os.environ.get("GLIMS_ADAPTER_ROOT")
    base = Path(env_root) if env_root else checkout / "_engine" / "adapter"
    return base / ref


def fail(message: str) -> "None":
    print(f"test-saved-set-lifetimes: {message}", file=sys.stderr)
    sys.exit(1)


def check_producer(producer: Path) -> dict[str, object]:
    if not producer.is_dir():
        fail(f"producer prefix {producer} is not a directory; pass --producer "
             f"PREFIX with obj/, compile.rsp, objects.rsp, link.rsp "
             f"(default: {default_producer(REPO_ROOT, DEFAULT_REF)})")
    objects = sorted(glob.glob(str(producer / "obj" / "*.o")))
    paths = {
        "obj": objects,
        "compile_rsp": producer / "compile.rsp",
        "objects_rsp": producer / "objects.rsp",
        "link_rsp": producer / "link.rsp",
    }
    missing = [name for name, value in paths.items()
               if (isinstance(value, list) and not value) or
               (isinstance(value, Path) and not value.is_file())]
    if missing:
        fail(f"producer prefix {producer} is missing: {', '.join(missing)}; "
             f"run scripts/build-adapter.sh {DEFAULT_REF} in a checkout first "
             f"(or point --producer at an existing adapter build dir)")
    if not SOURCE.is_file():
        fail(f"harness source missing: {SOURCE}")
    if not (FACADE_INCLUDE / "glims_engine.h").is_file():
        fail(f"facade header missing: {FACADE_INCLUDE / 'glims_engine.h'}")
    if not (ENGINE_DIR / "engine-private.h").is_file():
        fail(f"adapter private header missing: {ENGINE_DIR / 'engine-private.h'}")
    return paths


def build(producer: Path, out: Path) -> Path:
    paths = check_producer(producer)
    out.mkdir(parents=True, exist_ok=True)
    obj = out / "saved-set-lifetime-tests.o"
    binary = out / "saved-set-lifetime-tests"

    # Compile with the producer's own gimp-console flags (exact args from its
    # compile.rsp) plus the facade and adapter include dirs, exactly like
    # scripts/build-adapter.sh compiles Engine/*.c.
    compile_cmd = [
        "xcrun", "clang", f"@{paths['compile_rsp']}",
        "-I", str(FACADE_INCLUDE), "-I", str(ENGINE_DIR),
        "-std=c11", "-O2", "-Wall", "-Wextra",
        "-Werror=implicit-function-declaration",
        "-c", str(SOURCE), "-o", str(obj),
    ]
    # Link the harness object + adapter objects + GIMP objects (objects.rsp
    # has no main.c.o; the harness supplies main) with the producer's exact
    # link args. No -dynamiclib/-install_name/-exported_symbol restriction.
    link_cmd = [
        "xcrun", "clang++", "-o", str(binary),
        str(obj), *paths["obj"],  # type: ignore[arg-type]
        f"@{paths['objects_rsp']}", f"@{paths['link_rsp']}",
    ]

    print("==> compile")
    print("    " + " ".join(shlex.quote(a) for a in compile_cmd))
    subprocess.run(compile_cmd, check=True)
    print("==> link")
    print("    " + " ".join(shlex.quote(a) for a in link_cmd))
    subprocess.run(link_cmd, check=True)
    print(f"-- built {binary}")
    return binary


def run(binary: Path, work: Path, timeout: int) -> int:
    if not binary.is_file():
        fail(f"harness binary missing: {binary}; run the build subcommand first")
    for sub in ("home", "cache", "user"):
        (work / sub).mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    # Throwaway engine state only; the real HOME / ~/.cache / GIMP settings
    # must never be touched.
    env["HOME"] = str(work / "home")
    env["XDG_CACHE_HOME"] = str(work / "cache")
    env["GIMP3_DIRECTORY"] = str(work / "user")

    cmd = [str(binary), str(work)]
    print(f"==> run (throwaway HOME={env['HOME']}, "
          f"XDG_CACHE_HOME={env['XDG_CACHE_HOME']}, GIMP3_DIRECTORY={env['GIMP3_DIRECTORY']})")
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    try:
        completed = subprocess.run(cmd, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"test-saved-set-lifetimes: harness did not finish within {timeout}s",
              file=sys.stderr)
        return 124
    return completed.returncode


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--checkout", type=Path, default=REPO_ROOT,
                        help="Glims checkout containing Engine/ and Sources/CGlimsEngine "
                             f"(default: {REPO_ROOT})")
    parser.add_argument("--ref", default=DEFAULT_REF,
                        help=f"engine set name used only to resolve the default producer "
                             f"(default: {DEFAULT_REF})")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_producer(p: argparse.ArgumentParser, required: bool) -> None:
        p.add_argument("--producer", type=Path, required=required,
                       default=None,
                       help="producer prefix containing obj/, compile.rsp, objects.rsp, "
                            "link.rsp (default: $GLIMS_ADAPTER_ROOT/<ref> or "
                            "<checkout>/_engine/adapter/<ref>)")

    p_build = sub.add_parser("build", help="compile + link the harness (does not run it)")
    add_producer(p_build, required=False)
    p_build.add_argument("--out", type=Path, default=DEFAULT_OUT,
                         help=f"output directory (default: {DEFAULT_OUT})")

    p_run = sub.add_parser("run", help="run a built harness with a throwaway home")
    p_run.add_argument("--binary", type=Path, default=DEFAULT_OUT / "saved-set-lifetime-tests",
                       help="harness binary (default: <out>/saved-set-lifetime-tests)")
    p_run.add_argument("--work", type=Path, required=True,
                       help="throwaway work dir for HOME/cache/GIMP settings and XCF files")
    p_run.add_argument("--timeout", type=int, default=900,
                       help="seconds before the harness is killed (default: 900)")

    p_all = sub.add_parser("all", help="build then run")
    add_producer(p_all, required=True)
    p_all.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p_all.add_argument("--work", type=Path, required=True)
    p_all.add_argument("--timeout", type=int, default=900)

    args = parser.parse_args()
    if args.command == "build":
        build(args.producer or default_producer(REPO_ROOT, args.ref), args.out)
    elif args.command == "run":
        sys.exit(run(args.binary, args.work, args.timeout))
    elif args.command == "all":
        binary = build(args.producer or default_producer(REPO_ROOT, args.ref), args.out)
        sys.exit(run(binary, args.work, args.timeout))


if __name__ == "__main__":
    main()
