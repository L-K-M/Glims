#!/usr/bin/env python3
"""Compile and run the standalone Selective Color kernel harness.

Pure C, no engine dependency: builds Engine/selective-color-math.c with
Engine/tests/selective-color-math-tests.c under -Wall -Wextra -Werror plus
address/undefined sanitizers. Use --no-sanitizers only for toolchains
without those runtimes; ordinary build failures never disable checking.
"""
from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KERNEL = ROOT / "Engine" / "selective-color-math.c"
HARNESS = ROOT / "Engine" / "tests" / "selective-color-math-tests.c"
OUT_DIR = ROOT / ".build" / "selective-color-math-tests"


def run(cmd: list[str]) -> None:
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-sanitizers", action="store_true")
    args = parser.parse_args()
    cc = os.environ.get("CC", "cc")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    binary = OUT_DIR / "selective-color-math-tests"

    base = [
        cc, "-std=c11", "-O1", "-g",
        "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "Engine"),
    ]
    sanitizers = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-fno-omit-frame-pointer"]

    run([*base, *([] if args.no_sanitizers else sanitizers),
         str(KERNEL), str(HARNESS), "-o", str(binary)])

    run([str(binary)])


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(f"test-selective-color-math: command failed: {exc}", file=sys.stderr)
        sys.exit(1)
