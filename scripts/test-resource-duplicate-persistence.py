#!/usr/bin/env python3
"""Build and run the resource-duplicate persistence regression harness.

Test-only helper for Engine/tests/resource-duplicate-persistence-tests.c. It
never rebuilds or relinks the shared producer/engine: the caller selects an
existing producer prefix (a directory produced by scripts/build-adapter.sh, or
any directory with the same layout) containing:

    obj/          the adapter's object files (obj/*.o)
    compile.rsp   GIMP gimp-console's exact compile flags (clang response file)
    objects.rsp   GIMP gimp-console's object files minus main.c.o
    link.rsp      GIMP gimp-console's exact link arguments (libraries, rpaths)

Producer selection is explicit:

  --producer PATH       use PATH directly, or
  --ref NAME --adapter-root DIR
                        use DIR/NAME (default adapter root is
                        $GLIMS_ADAPTER_ROOT or <checkout>/_engine/adapter)

--producer-checkout selects the Glims checkout that supplies the current
Engine/engine-private.h and facade headers used while compiling the test;
the selected producer's own compile.rsp still supplies the matching GIMP
private headers and objects.rsp/link.rsp supply GIMP console objects/libraries.
No libgimp and no engine source is compiled by this script.

Subcommands:

  build   compile + link the harness against the selected producer
  run     run a previously built harness with a throwaway HOME/cache/GIMP dir
  all     build then run

Examples:

  python3 scripts/test-resource-duplicate-persistence.py build \
      --ref GIMP_3_2_8 --adapter-root "$PWD/_engine/adapter"

  python3 scripts/test-resource-duplicate-persistence.py all \
      --producer "$PWD/_engine/adapter/GIMP_3_2_8" \
      --work "$(mktemp -d /tmp/glims-resource-duplicate.XXXXXX)"

The run uses only throwaway directories: HOME=<work>/home,
XDG_CACHE_HOME=<work>/cache, GIMP3_DIRECTORY=<work>/user, and passes <work> to
the binary, which creates <work>/{home,user,cache} itself. The user's real
HOME, ~/.cache and GIMP settings are never touched.
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
SOURCE = REPO_ROOT / "Engine" / "tests" / "resource-duplicate-persistence-tests.c"
FACADE_INCLUDE = REPO_ROOT / "Sources" / "CGlimsEngine" / "include"
ENGINE_DIR = REPO_ROOT / "Engine"
DEFAULT_OUT = REPO_ROOT / ".build" / "resource-duplicate-persistence-tests"
DEFAULT_REF = "GIMP_3_2_8"


def default_adapter_root(checkout: Path) -> Path:
    env_root = os.environ.get("GLIMS_ADAPTER_ROOT")
    return Path(env_root) if env_root else checkout / "_engine" / "adapter"


def resolve_producer(args: argparse.Namespace) -> Path:
    if args.producer:
        return args.producer
    return Path(args.adapter_root) / args.ref


def fail(message: str) -> "None":
    print(f"test-resource-duplicate-persistence: {message}", file=sys.stderr)
    sys.exit(1)


def check_producer(producer: Path) -> dict[str, object]:
    if not producer.is_dir():
        fail(f"producer prefix {producer} is not a directory; pass --producer "
             f"PREFIX or --ref NAME --adapter-root DIR (default adapter root: "
             f"{default_adapter_root(REPO_ROOT)})")
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
             f"point --producer/--adapter-root at an existing adapter build dir")
    if not SOURCE.is_file():
        fail(f"harness source missing: {SOURCE}")
    if not (FACADE_INCLUDE / "glims_engine.h").is_file():
        fail(f"facade header missing: {FACADE_INCLUDE / 'glims_engine.h'}")
    if not (ENGINE_DIR / "engine-private.h").is_file():
        fail(f"adapter private header missing: {ENGINE_DIR / 'engine-private.h'}")
    return paths


def run_command(cmd: list[str]) -> int:
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    completed = subprocess.run(cmd)
    return completed.returncode


def build(producer: Path, out: Path, producer_checkout: Path) -> int:
    paths = check_producer(producer)
    if not (producer_checkout / "Engine/engine-private.h").is_file():
        fail(f"matching producer private headers missing from {producer_checkout}")
    if not (producer_checkout / "Sources/CGlimsEngine/include/glims_engine.h").is_file():
        fail(f"matching facade headers missing from {producer_checkout}")
    out.mkdir(parents=True, exist_ok=True)
    obj = out / "resource-duplicate-persistence-tests.o"
    binary = out / "resource-duplicate-persistence-tests"

    # Compile with the producer's own gimp-console flags (exact args from its
    # compile.rsp) plus the facade and adapter include dirs. The producer's
    # compile.rsp already selects the matching GIMP private headers; this
    # script never compiles Engine/*.c or relinks the adapter.
    compile_cmd = [
        "xcrun", "clang", f"@{paths['compile_rsp']}",
        "-I", str(producer_checkout / "Sources/CGlimsEngine/include"),
        "-I", str(producer_checkout / "Engine"),
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
    code = run_command(compile_cmd)
    if code != 0:
        return code
    print("==> link")
    code = run_command(link_cmd)
    if code != 0:
        return code
    print(f"-- built {binary}")
    return 0


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
        print(f"test-resource-duplicate-persistence: harness did not finish "
              f"within {timeout}s", file=sys.stderr)
        return 124
    return completed.returncode


def add_producer_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--producer-checkout", type=Path, default=REPO_ROOT,
                        help="source checkout supplying Engine/engine-private.h and "
                             "Sources/CGlimsEngine/include headers")
    parser.add_argument("--producer", type=Path, default=None,
                        help="producer prefix containing obj/, compile.rsp, objects.rsp, "
                             "link.rsp (alternative to --ref + --adapter-root)")
    parser.add_argument("--adapter-root", type=Path,
                        default=default_adapter_root(REPO_ROOT),
                        help="adapter root used with --ref "
                             f"(default: {default_adapter_root(REPO_ROOT)})")
    parser.add_argument("--ref", default=DEFAULT_REF,
                        help=f"engine set name under --adapter-root (default: {DEFAULT_REF})")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="compile + link the harness (does not run it)")
    add_producer_args(p_build)
    p_build.add_argument("--out", type=Path, default=DEFAULT_OUT,
                         help=f"output directory (default: {DEFAULT_OUT})")

    p_run = sub.add_parser("run", help="run a built harness with a throwaway home")
    p_run.add_argument("--binary", type=Path,
                       default=DEFAULT_OUT / "resource-duplicate-persistence-tests",
                       help="harness binary (default: <out>/resource-duplicate-persistence-tests)")
    p_run.add_argument("--work", type=Path, required=True,
                       help="throwaway work dir for HOME/cache/GIMP settings and test files")
    p_run.add_argument("--timeout", type=int, default=900,
                       help="seconds before the harness is killed (default: 900)")

    p_all = sub.add_parser("all", help="build then run")
    add_producer_args(p_all)
    p_all.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p_all.add_argument("--work", type=Path, required=True,
                       help="throwaway work dir for HOME/cache/GIMP settings and test files")
    p_all.add_argument("--timeout", type=int, default=900,
                       help="seconds before the harness is killed (default: 900)")

    args = parser.parse_args()
    if args.command == "build":
        producer = resolve_producer(args)
        sys.exit(build(producer, args.out, args.producer_checkout))
    if args.command == "run":
        sys.exit(run(args.binary, args.work, args.timeout))
    if args.command == "all":
        producer = resolve_producer(args)
        code = build(producer, args.out, args.producer_checkout)
        if code != 0:
            sys.exit(code)
        sys.exit(run(args.out / "resource-duplicate-persistence-tests",
                     args.work, args.timeout))


if __name__ == "__main__":
    main()
