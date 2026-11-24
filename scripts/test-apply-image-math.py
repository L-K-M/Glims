#!/usr/bin/env python3
"""Compile and run the standalone Apply Image kernel harness.

Pure C, no engine dependency: builds Engine/apply-image-math.c with
Engine/tests/apply-image-math-tests.c under -Wall -Wextra -Werror
-pedantic and runs the binary in the selected modes. "optimized" builds
at -O2; "sanitized" adds the address and undefined behavior sanitizers.
The default runs both. Hosted macOS runners stall starting ASan binaries,
so CI runs both modes on Linux and the optimized mode on macOS.
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
KERNEL = ROOT / "Engine" / "apply-image-math.c"
HARNESS = ROOT / "Engine" / "tests" / "apply-image-math-tests.c"

BASE_FLAGS = [
    "-std=c11",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-pedantic",
    "-I" + str(ROOT / "Engine"),
    # The kernel includes the facade header for GlimsBlendMode.
    "-I" + str(ROOT / "Sources" / "CGlimsEngine" / "include"),
]
MODE_FLAGS = {
    "optimized": ["-O2"],
    "sanitized": [
        "-O1",
        "-g",
        "-fsanitize=address,undefined",
        "-fno-sanitize-recover=all",
        "-fno-omit-frame-pointer",
    ],
}


def compiler() -> list[str]:
    if platform.system() == "Darwin" and shutil.which("xcrun"):
        return ["xcrun", "clang"]
    return ["clang"]


def run(cmd: list[str], cwd: Path, timeout: int = 60) -> None:
    print("+", " ".join(cmd), flush=True)
    try:
        proc = subprocess.run(cmd, cwd=str(cwd), timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"error: command timed out after {timeout}s: {' '.join(cmd)}",
              file=sys.stderr, flush=True)
        raise SystemExit(124)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", default="all",
                        choices=["all", "optimized", "sanitized"])
    args = parser.parse_args()
    modes = ["optimized", "sanitized"] if args.mode == "all" else [args.mode]

    for required in (KERNEL, HARNESS):
        if not required.is_file():
            print(f"error: missing required file: {required}", file=sys.stderr)
            return 2

    with tempfile.TemporaryDirectory(prefix="glims-apply-image-math-") as directory:
        tmp = Path(directory)
        for mode in modes:
            print(f"== mode: {mode} ==", flush=True)
            binary = tmp / f"apply-image-math-{mode}"
            run(compiler() + BASE_FLAGS + MODE_FLAGS[mode]
                + [str(KERNEL), str(HARNESS), "-lm", "-o", str(binary)], cwd=tmp)
            run([str(binary)], cwd=tmp)

    print("apply-image-math: ok", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
