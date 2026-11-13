#!/usr/bin/env python3
"""Run the bounded pure-C Lab layer map v2 checks.

Compiles Engine/lab-layer-map.c and Engine/plate-map.c with
Engine/tests/lab-layer-map-tests.c and runs the resulting test binary in
selected modes. No engine install, GUI, or native app build is required.
"""
from __future__ import annotations

import argparse
import os
import platform
import signal
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CODEC = ROOT / "Engine" / "lab-layer-map.c"
PLATE = ROOT / "Engine" / "plate-map.c"
TESTS = ROOT / "Engine" / "tests" / "lab-layer-map-tests.c"

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

REQUIRED = [CODEC, PLATE, TESTS]


def compiler() -> list[str]:
    if platform.system() == "Darwin" and shutil.which("xcrun"):
        return ["xcrun", "clang"]
    return ["clang"]


def run(cmd: list[str], cwd: Path, timeout: int) -> int:
    print("+", " ".join(cmd), flush=True)
    process = None

    def interrupted(_number, _frame):
        raise KeyboardInterrupt

    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        process = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"error: command timed out after {timeout}s", file=sys.stderr)
            return 124
        if code:
            return code if code > 0 else 128 - code
        return 0
    finally:
        if process is not None:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            process.wait()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def build_and_test(mode: str, tmp: Path, timeout: int) -> int:
    flags = list(BASE_FLAGS)
    if mode == "optimized":
        flags += OPT_FLAGS
    elif mode == "sanitized":
        flags += SAN_FLAGS
    else:
        raise ValueError(f"unknown mode: {mode}")

    binary = tmp / f"lab-layer-map-{mode}"
    code = run(
        compiler()
        + flags
        + [str(CODEC), str(PLATE), str(TESTS), "-o", str(binary)],
        cwd=tmp,
        timeout=timeout,
    )
    if code:
        return code
    return run([str(binary)], cwd=tmp, timeout=timeout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", default="all", choices=["all", "optimized", "sanitized"])
    parser.add_argument("--timeout", type=int, default=120, help="per-process timeout seconds (bounded)")
    args = parser.parse_args()

    if args.timeout <= 0 or args.timeout > 300:
        print("error: timeout must be in 1..300", file=sys.stderr)
        return 2

    modes = ["optimized", "sanitized"] if args.mode == "all" else [args.mode]
    missing = [str(p) for p in REQUIRED if not p.is_file()]
    if missing:
        for path in missing:
            print(f"report: missing required file: {path}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="glims-lab-layer-map-") as td:
        tmp = Path(td)
        for mode in modes:
            print(f"== mode: {mode} ==", flush=True)
            code = build_and_test(mode, tmp, args.timeout)
            if code:
                return code

    print("lab-layer-map: ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
