#!/usr/bin/env python3
"""Assemble and (optionally) run the LangAlt reader harness.

Test-only helper for Engine/tests/metadata-language-tests.c and the
syntax check of Engine/metadata-language.c. It never rebuilds the shared
producer: the caller selects an existing producer prefix (a directory
produced by scripts/build-adapter.sh, or any directory with the same
layout) containing:

    obj/          the adapter's object files (obj/*.o)
    compile.rsp   GIMP gimp-console's exact compile flags (clang response file)
    objects.rsp   GIMP gimp-console's object files minus main.c.o
    link.rsp      GIMP gimp-console's exact link arguments (libraries, rpaths)

Subcommands:

  syntax  compile Engine/metadata-language.c with -fsyntax-only against the
          compile.rsp of every engine set (default: all four under
          $GLIMS_ADAPTER_ROOT or <checkout>/_engine/adapter). Never runs
          anything.
  build   compile Engine/metadata-language.c plus the harness with the
          producer's own gimp-console flags and link them with the producer's
          objects — a strict compile/link only, nothing is executed.
  run     run a previously built harness with a throwaway HOME/cache/GIMP
          dir (owned by the runtime decision; NOT run by the author of this
          change).

Examples:

  python3 scripts/test-metadata-language.py syntax
  python3 scripts/test-metadata-language.py build --ref GIMP_3_2_8
  python3 scripts/test-metadata-language.py run --work "$(mktemp -d /tmp/glims-langalt.XXXXXX)"

The harness binary and its objects go to --out (default
<checkout>/.build/metadata-language-tests/, gitignored). The run uses only
throwaway directories: HOME=<work>/home, XDG_CACHE_HOME=<work>/cache,
GIMP3_DIRECTORY=<work>/user. The user's real HOME, ~/.cache and GIMP
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
READER = REPO_ROOT / "Engine" / "metadata-language.c"
HARNESS = REPO_ROOT / "Engine" / "tests" / "metadata-language-tests.c"
FACADE_INCLUDE = REPO_ROOT / "Sources" / "CGlimsEngine" / "include"
ENGINE_DIR = REPO_ROOT / "Engine"
DEFAULT_OUT = REPO_ROOT / ".build" / "metadata-language-tests"
DEFAULT_REF = "GIMP_3_2_8"
ALL_REFS = ("GIMP_3_0_8", "GIMP_3_2_0", "GIMP_3_2_8", "master")


def fail(message: str) -> None:
    print(f"test-metadata-language: {message}", file=sys.stderr)
    sys.exit(1)


def producer_for(ref: str) -> Path:
    env_root = os.environ.get("GLIMS_ADAPTER_ROOT")
    base = Path(env_root) if env_root else REPO_ROOT / "_engine" / "adapter"
    return base / ref


def check_producer(producer: Path) -> dict[str, object]:
    if not producer.is_dir():
        fail(f"producer prefix {producer} is not a directory")
    # The producer may already include this helper after it is merged.
    # Link the current reader object exactly once, alongside frozen Core.
    objects = [p for p in sorted(glob.glob(str(producer / "obj" / "*.o")))
               if Path(p).name != "metadata-language.o"]
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
        fail(f"producer prefix {producer} is missing: {', '.join(missing)}")
    return paths


def cmd_syntax(args: argparse.Namespace) -> None:
    refs = args.refs or list(ALL_REFS)
    for ref in refs:
        producer = producer_for(ref)
        rsp = producer / "compile.rsp"
        if not rsp.is_file():
            fail(f"no compile.rsp for {ref} at {producer}")
        cmd = [
            "xcrun", "clang", f"@{rsp}",
            "-I", str(FACADE_INCLUDE), "-I", str(ENGINE_DIR),
            "-fvisibility=hidden", "-Wall", "-Wextra",
            "-Werror=implicit-function-declaration",
            "-fsyntax-only", str(READER),
        ]
        print("==> syntax", ref)
        print("    " + " ".join(shlex.quote(a) for a in cmd))
        subprocess.run(cmd, check=True)
        print(f"-- {ref}: syntax OK")


def cmd_build(args: argparse.Namespace) -> Path:
    producer = Path(args.producer) if args.producer else producer_for(args.ref)
    paths = check_producer(producer)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    reader_obj = out / "metadata-language.o"
    harness_obj = out / "metadata-language-tests.o"
    binary = out / "metadata-language-tests"

    common = [
        f"@{paths['compile_rsp']}",
        "-I", str(FACADE_INCLUDE), "-I", str(ENGINE_DIR),
    ]
    compile_reader = [
        "xcrun", "clang", *common,
        "-fvisibility=hidden", "-Wall", "-Wextra",
        "-Werror=implicit-function-declaration",
        "-c", str(READER), "-o", str(reader_obj),
    ]
    compile_harness = [
        "xcrun", "clang", *common,
        "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        "-c", str(HARNESS), "-o", str(harness_obj),
    ]
    link = [
        "xcrun", "clang++", "-o", str(binary),
        str(reader_obj), str(harness_obj), *paths["obj"],  # type: ignore[arg-type]
        f"@{paths['objects_rsp']}", f"@{paths['link_rsp']}",
    ]
    print("==> compile reader")
    print("    " + " ".join(shlex.quote(a) for a in compile_reader))
    subprocess.run(compile_reader, check=True)
    print("==> compile harness")
    print("    " + " ".join(shlex.quote(a) for a in compile_harness))
    subprocess.run(compile_harness, check=True)
    print("==> link (compile-only; not executed)")
    print("    " + " ".join(shlex.quote(a) for a in link))
    subprocess.run(link, check=True)
    print(f"-- built {binary} (not run)")
    return binary


def cmd_run(args: argparse.Namespace) -> int:
    binary = Path(args.binary).resolve()
    if not binary.is_file():
        fail(f"harness binary missing: {binary}; run the build subcommand first")
    work = Path(args.work).resolve()
    for sub in ("home", "cache", "user"):
        (work / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["HOME"] = str(work / "home")
    env["XDG_CACHE_HOME"] = str(work / "cache")
    env["GIMP3_DIRECTORY"] = str(work / "user")
    if args.fatal_criticals:
        env["G_DEBUG"] = "fatal-criticals"
    cmd = [str(binary), str(work)]
    print(f"==> run (throwaway HOME={env['HOME']}, XDG_CACHE_HOME={env['XDG_CACHE_HOME']}, "
          f"GIMP3_DIRECTORY={env['GIMP3_DIRECTORY']})")
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    try:
        completed = subprocess.run(cmd, env=env, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        print(f"test-metadata-language: harness did not finish within {args.timeout}s",
              file=sys.stderr)
        return 124
    return completed.returncode


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_syntax = sub.add_parser("syntax", help="-fsyntax-only the reader against compile.rsp sets")
    p_syntax.add_argument("--refs", nargs="*", default=None,
                          help=f"engine sets (default: all of {ALL_REFS})")

    p_build = sub.add_parser("build", help="strictly compile+link the harness (never runs it)")
    p_build.add_argument("--ref", default=DEFAULT_REF,
                         help=f"engine set for the default producer (default: {DEFAULT_REF})")
    p_build.add_argument("--producer", type=Path, default=None,
                         help="producer prefix with obj/, compile.rsp, objects.rsp, link.rsp "
                              "(default: $GLIMS_ADAPTER_ROOT/<ref> or <checkout>/_engine/adapter/<ref>)")
    p_build.add_argument("--out", type=Path, default=DEFAULT_OUT,
                         help=f"output directory (default: {DEFAULT_OUT})")

    p_run = sub.add_parser("run", help="run a built harness with a throwaway home "
                                       "(runtime decision of the owner; not run here)")
    p_run.add_argument("--binary", type=Path, default=DEFAULT_OUT / "metadata-language-tests",
                       help="harness binary (default: <out>/metadata-language-tests)")
    p_run.add_argument("--work", type=Path, required=True,
                       help="throwaway work dir for HOME/cache/GIMP settings")
    p_run.add_argument("--timeout", type=int, default=900,
                       help="seconds before the harness is killed (default: 900)")
    p_run.add_argument("--fatal-criticals", action="store_true",
                       help="also set G_DEBUG=fatal-criticals for the run "
                            "(e.g. to prove refusal cleanup stays quiet)")

    args = parser.parse_args()
    if args.command == "syntax":
        cmd_syntax(args)
    elif args.command == "build":
        cmd_build(args)
    elif args.command == "run":
        sys.exit(cmd_run(args))


if __name__ == "__main__":
    main()
