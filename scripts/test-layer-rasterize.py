#!/usr/bin/env python3
"""Compile-only batch-rasterize harness against an immutable slot165 producer.

Never builds or relinks an adapter, and never executes the resulting binary.
The caller owns runtime isolation (HOME, XDG_CACHE_HOME, GIMP3_DIRECTORY).
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shlex
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--producer", type=Path, required=True,
                        help="immutable slot165 prefix containing obj/ and response files")
    parser.add_argument("--out", type=Path, required=True,
                        help="private harness output directory outside the producer")
    args = parser.parse_args()
    producer = args.producer.resolve()
    out = args.out.resolve()
    if out == producer or producer in out.parents:
        parser.error("output must be outside the immutable producer")
    response_files = [producer / name for name in ("compile.rsp", "objects.rsp", "link.rsp")]
    objects = sorted((producer / "obj").glob("*.o"))
    if not all(path.is_file() for path in response_files) or not objects:
        parser.error("producer requires obj/*.o, compile.rsp, objects.rsp and link.rsp")
    if not (producer / "obj/layer-rasterize.o").is_file():
        parser.error("producer does not contain the slot165 batch-rasterize backend")
    root = Path(__file__).resolve().parent.parent
    out.mkdir(parents=True, exist_ok=True)
    harness_object = out / "layer-rasterize-tests.o"
    binary = out / "layer-rasterize-tests"
    compile_command = [
        "xcrun", "clang", f"@{response_files[0]}",
        "-I", str(root / "Sources/CGlimsEngine/include"), "-I", str(root / "Engine"),
        "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
        "-c", str(root / "Engine/tests/layer-rasterize-tests.c"), "-o", str(harness_object),
    ]
    link_command = [
        "xcrun", "clang++", "-o", str(binary), str(harness_object),
        *(str(path) for path in objects), f"@{response_files[1]}", f"@{response_files[2]}",
    ]
    for command in (compile_command, link_command):
        print(shlex.join(command), flush=True)
        subprocess.run(command, check=True)
    print(f"Built {binary}; not executed.")


if __name__ == "__main__":
    main()
