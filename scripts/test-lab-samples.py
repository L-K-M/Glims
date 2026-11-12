#!/usr/bin/env python3
"""Run the bounded pure-C Lab sample codec checks.

Compiles Engine/lab-samples.c with Engine/tests/lab-samples-tests.c and runs the
resulting test binary in selected modes. No engine install, GUI, or native app
build is required.
"""
from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Engine" / "lab-samples.c"
TESTS = ROOT / "Engine" / "tests" / "lab-samples-tests.c"

BASE_FLAGS = [
    "-std=c11",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-pedantic",
    "-I" + str(ROOT / "Engine"),
]
OPT_FLAGS = ["-O2"]
SAN_FLAGS = [
    "-O1",
    "-g",
    "-fsanitize=address,undefined",
    "-fno-sanitize-recover=all",
    "-fno-omit-frame-pointer",
]


def compiler() -> list[str]:
    if platform.system() == "Darwin" and shutil.which("xcrun"):
        return ["xcrun", "clang"]
    return ["clang"]


def run(cmd: list[str], cwd: Path, timeout: int = 60) -> None:
    print("+", " ".join(cmd), flush=True)
    try:
        proc = subprocess.run(cmd, cwd=str(cwd), timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"error: command timed out after {timeout}s: {' '.join(cmd)}", file=sys.stderr)
        raise SystemExit(124)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


def build_and_test(mode: str, tmp: Path) -> None:
    flags = list(BASE_FLAGS)
    if mode == "optimized":
        flags += OPT_FLAGS
    elif mode == "sanitized":
        flags += SAN_FLAGS
    else:
        raise ValueError(f"unknown mode: {mode}")

    binary = tmp / f"lab-samples-{mode}"
    run(compiler() + flags + [str(SOURCE), str(TESTS), "-lm", "-o", str(binary)], cwd=tmp)
    run([str(binary)], cwd=tmp, timeout=60)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", default="all", choices=["all", "optimized", "sanitized"])
    args = parser.parse_args()

    modes = ["optimized", "sanitized"] if args.mode == "all" else [args.mode]

    for req in (SOURCE, TESTS):
        if not req.is_file():
            print(f"error: missing required file: {req}", file=sys.stderr)
            return 2

    with tempfile.TemporaryDirectory(prefix="glims-lab-samples-") as td:
        tmp = Path(td)
        for mode in modes:
            print(f"== mode: {mode} ==", flush=True)
            build_and_test(mode, tmp)

    print("lab-samples: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
