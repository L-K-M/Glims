#!/usr/bin/env python3
"""Build or run the Variable Blur source-input oracle against an existing producer.

Neither command rebuilds the adapter prefix. Build compiles test-local copies
of filter-input.c and filter.c, excludes their producer objects, and links the
remaining immutable producer inputs. Run uses a private HOME/XDG/GIMP/TMP tree.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_driver", ROOT / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = ROOT / "Engine/filter-input.c"
driver.ADDITIONAL_SOURCES = [ROOT / "Engine/filter.c"]
HARNESS = ROOT / "Engine/tests/variable-blur-source-tests.c"
DEFAULT_OUT = ROOT / ".build/variable-blur-source-tests"
BINARY_NAME = "variable-blur-source-tests"


def build(args: argparse.Namespace) -> None:
    producer = args.producer.resolve()
    paths = driver.check_producer(producer)
    output = args.out.resolve()
    # Keep outputs disjoint from the selected producer's immutable inputs.
    if output == producer or output.is_relative_to(producer):
        raise SystemExit("test outputs must be outside the selected producer prefix")
    output.mkdir(parents=True, exist_ok=True)
    common = [f"@{paths['compile_rsp']}", "-I", str(ROOT / "Sources/CGlimsEngine/include"),
              "-I", str(ROOT / "Engine")]
    objects = []
    for source in [driver.READER, *driver.ADDITIONAL_SOURCES, HARNESS]:
        target = output / (source.stem + ".o")
        flags = ["-fvisibility=hidden", "-Wall", "-Wextra", "-Werror=implicit-function-declaration"]
        if source == HARNESS:
            flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"]
        command = ["xcrun", "clang", *common, *flags, "-c", str(source), "-o", str(target)]
        print("==>", shlex.join(command), flush=True)
        subprocess.run(command, check=True)
        objects.append(str(target))
    binary = output / BINARY_NAME
    command = ["xcrun", "clang++", "-o", str(binary), *objects, *paths["obj"],
               f"@{paths['objects_rsp']}", f"@{paths['link_rsp']}"]
    print("==>", shlex.join(command), flush=True)
    subprocess.run(command, check=True)
    print(f"Built {binary}; not executed", flush=True)


def run(args: argparse.Namespace) -> int:
    binary = args.binary.resolve()
    if not binary.is_file():
        raise SystemExit(f"missing test binary: {binary}")
    work = args.work.resolve()
    if work.exists() and any(work.iterdir()):
        raise SystemExit(f"run requires a fresh empty work directory: {work}")
    work.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("GLIMS_", "DYLD_")):
            env.pop(key)
    for key, leaf in [("HOME", "home"), ("XDG_CACHE_HOME", "cache"),
                      ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                      ("GIMP3_DIRECTORY", "user"), ("TMPDIR", "tmp")]:
        path = work / leaf
        path.mkdir()
        env[key] = str(path)
    env["G_DEBUG"] = "fatal-criticals"
    env.pop("GIMP_TESTING_NO_GEGL_BLACKLIST", None)
    env.pop("GIMP_ALLOW_GEGL_GRAPH_LAYER_EFFECT", None)
    command = [str(binary), str(work)]
    print("==>", shlex.join(command), flush=True)
    try:
        result = subprocess.run(command, env=env, cwd=work, stdin=subprocess.DEVNULL, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        print(f"Variable Blur harness timed out after {args.timeout}s", file=sys.stderr)
        return 124
    return result.returncode


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build_parser = sub.add_parser("build", help="compile/link only using an existing producer")
    build_parser.add_argument("--producer", type=Path, required=True)
    build_parser.add_argument("--out", type=Path, required=True)
    run_parser = sub.add_parser("run", help="execute a previously built harness with private settings")
    run_parser.add_argument("--binary", type=Path, required=True)
    run_parser.add_argument("--work", type=Path, required=True)
    run_parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    if args.command == "build":
        build(args)
    else:
        if args.timeout <= 0:
            parser.error("--timeout must be positive")
        sys.exit(run(args))


if __name__ == "__main__":
    main()
