#!/usr/bin/env python3
"""Build/run complete-inventory and runtime-version refusal regressions."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--producer", type=Path, required=True)
parser.add_argument("--out", type=Path, default=ROOT / ".build/metadata-inventory-tests")
parser.add_argument("--run", action="store_true", help="explicitly execute after strict compilation")
args = parser.parse_args()
producer = args.producer.resolve()
args.out.parent.mkdir(parents=True, exist_ok=True)
test_object = args.out.with_suffix(".o")
subprocess.run(["xcrun", "clang++", f"@{producer / 'compile-cxx.rsp'}",
    "-I", str(ROOT / "Engine"), "-I", str(ROOT / "Sources/CGlimsEngine/include"),
    "-Wall", "-Wextra", "-Werror", "-c", str(ROOT / "Engine/tests/metadata-inventory-tests.cpp"),
    "-o", str(test_object)], check=True)
subprocess.run(["xcrun", "clang++", str(test_object), str(producer / "obj/metadata-inventory.o"),
                f"@{producer / 'link.rsp'}", "-o", str(args.out)], check=True)
if args.run:
    with tempfile.TemporaryDirectory(prefix="glims-metadata-inventory-") as owned:
        work = Path(owned)
        for name in ("home", "cache", "user"):
            (work / name).mkdir()
        env = os.environ.copy()
        env.update(HOME=str(work / "home"), XDG_CACHE_HOME=str(work / "cache"),
                   GIMP3_DIRECTORY=str(work / "user"), G_DEBUG="fatal-criticals")
        subprocess.run([str(args.out.resolve())], env=env, check=True, timeout=60)
