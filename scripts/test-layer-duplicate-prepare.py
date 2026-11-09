#!/usr/bin/env python3
"""Compile/run the layer-duplicate-prepare native core harness.

Test-only helper. It never rebuilds the shared producer: the caller selects
an existing producer prefix containing obj/, compile.rsp, objects.rsp and
link.rsp.
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
READER = REPO_ROOT / "Engine" / "layer-duplicate-prepare.c"
HARNESS = REPO_ROOT / "Engine" / "tests" / "layer-duplicate-prepare-tests.c"
FACADE_INCLUDE = REPO_ROOT / "Sources" / "CGlimsEngine" / "include"
ENGINE_DIR = REPO_ROOT / "Engine"
DEFAULT_OUT_ROOT = REPO_ROOT / ".build" / "layer-duplicate-prepare-tests"
DEFAULT_REF = "GIMP_3_2_8"
ALL_REFS = ("GIMP_3_2_8", "GIMP_3_2_0", "GIMP_3_0_8", "master")


def fail(message: str) -> None:
    print(f"test-layer-duplicate-prepare: {message}", file=sys.stderr)
    sys.exit(1)


def producer_for(ref: str) -> Path:
    env_root = os.environ.get("GLIMS_ADAPTER_ROOT")
    base = Path(env_root) if env_root else REPO_ROOT / "_engine" / "adapter"
    return base / ref


def check_producer(producer: Path) -> dict[str, object]:
    if not producer.is_dir():
        fail(f"producer prefix {producer} is not a directory")
    objects = sorted(glob.glob(str(producer / "obj" / "*.o")))
    # Recompile the implementation under test even when it is already part
    # of the selected producer; link it exactly once.
    objects = [path for path in objects if Path(path).name != READER.stem + ".o"]
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
    out = Path(args.out) if args.out else (DEFAULT_OUT_ROOT / args.ref)
    out.mkdir(parents=True, exist_ok=True)
    reader_obj = out / "layer-duplicate-prepare.o"
    harness_obj = out / "layer-duplicate-prepare-tests.o"
    binary = out / "layer-duplicate-prepare-tests"

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
        str(reader_obj), str(harness_obj), *paths["obj"],
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
    ref = getattr(args, "ref", None) or DEFAULT_REF
    if args.binary:
        binary = Path(args.binary).resolve()
    else:
        binary = (DEFAULT_OUT_ROOT / ref / "layer-duplicate-prepare-tests").resolve()
    if not binary.is_file():
        fail(f"harness binary missing: {binary}; run the build subcommand first")
    work = Path(args.work).resolve()
    for sub in ("home", "cache", "user"):
        (work / sub).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["HOME"] = str(work / "home")
    env["XDG_CACHE_HOME"] = str(work / "cache")
    env["GIMP3_DIRECTORY"] = str(work / "user")
    env["G_DEBUG"] = "fatal-criticals"
    cmd = [str(binary), str(work)]
    print(f"==> run (throwaway HOME={env['HOME']}, XDG_CACHE_HOME={env['XDG_CACHE_HOME']}, "
          f"GIMP3_DIRECTORY={env['GIMP3_DIRECTORY']})")
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    try:
        completed = subprocess.run(cmd, env=env, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        print(f"test-layer-duplicate-prepare: harness did not finish within {args.timeout}s",
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
                         help="producer prefix with obj/, compile.rsp, objects.rsp, link.rsp")
    p_build.add_argument("--out", type=Path, default=None,
                         help=f"output directory (default: {DEFAULT_OUT_ROOT}/<ref>)")

    p_run = sub.add_parser("run", help="run a built harness with a throwaway home")
    p_run.add_argument("--ref", default=DEFAULT_REF,
                       help=f"engine set whose build dir holds the binary (default: {DEFAULT_REF})")
    p_run.add_argument("--binary", type=Path, default=None,
                       help="harness binary (default: <out-root>/<ref>/layer-duplicate-prepare-tests)")
    p_run.add_argument("--work", type=Path, required=True,
                       help="throwaway work dir for HOME/cache/GIMP settings")
    p_run.add_argument("--timeout", type=int, default=120,
                       help="seconds before the harness is killed (default: 120)")
    p_run.add_argument("--fatal-criticals", action="store_true",
                       help="also set G_DEBUG=fatal-criticals for the run")

    args = parser.parse_args()
    if args.command == "syntax":
        cmd_syntax(args)
    elif args.command == "build":
        cmd_build(args)
    elif args.command == "run":
        sys.exit(cmd_run(args))


if __name__ == "__main__":
    main()
