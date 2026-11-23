#!/usr/bin/env python3
"""Compile and run the standalone Color Range kernel harness.

Pure C, no engine dependency: builds Engine/color-range-math.c with
Engine/tests/color-range-math-tests.c under -Wall -Wextra -Werror plus
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
KERNEL = ROOT / "Engine" / "color-range-math.c"
HARNESS = ROOT / "Engine" / "tests" / "color-range-math-tests.c"
OUT_DIR = ROOT / ".build" / "color-range-math-tests"


def run(cmd: list[str]) -> None:
    print("    " + " ".join(shlex.quote(a) for a in cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-sanitizers", action="store_true")
    args = parser.parse_args()
    cc = os.environ.get("CC", "cc")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    binary = OUT_DIR / "color-range-math-tests"

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
        print(f"test-color-range-math: command failed: {exc}", file=sys.stderr)
        sys.exit(1)
