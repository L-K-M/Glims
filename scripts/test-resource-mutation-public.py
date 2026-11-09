#!/usr/bin/env python3
"""Build/run the public-facade resource mutation harness."""
import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
sub = parser.add_subparsers(dest="command", required=True)
build = sub.add_parser("build", help="strictly compile only")
build.add_argument("--out", type=Path, default=ROOT / ".build/resource-mutation-public-tests")
run = sub.add_parser("run", help="run with private settings and a bounded timeout")
run.add_argument("--binary", type=Path, default=ROOT / ".build/resource-mutation-public-tests")
run.add_argument("--library", type=Path, required=True)
run.add_argument("--work", type=Path, required=True)
args = parser.parse_args()

if args.command == "build":
    args.out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         "-I", str(ROOT / "Sources/CGlimsEngine/include"),
         str(ROOT / "Engine/tests/resource-mutation-public-tests.c"),
         "-o", str(args.out)],
        check=True,
    )
else:
    work = args.work.resolve()
    for name in ("home", "cache", "user"):
        (work / name).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(HOME=str(work / "home"), XDG_CACHE_HOME=str(work / "cache"),
               GIMP3_DIRECTORY=str(work / "user"), G_DEBUG="fatal-criticals")
    try:
        result = subprocess.run(
            [str(args.binary.resolve()), str(args.library.resolve()), str(work)],
            env=env, capture_output=True, text=True, timeout=120,
        )
    except subprocess.TimeoutExpired as exc:
        sys.stdout.write(exc.stdout or "")
        sys.stderr.write(exc.stderr or "")
        print("TIMEOUT after 120s", file=sys.stderr)
        raise SystemExit(124)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    raise SystemExit(result.returncode)