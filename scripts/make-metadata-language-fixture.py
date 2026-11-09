#!/usr/bin/env python3
"""Build a Core-only known-map fixture generator, or explicitly run it.

Build borrows immutable adapter objects and never relinks the producer.
Run writes only the requested XCF and isolates native settings below work.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("language_driver", ROOT / "scripts/test-metadata-language.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)

parser = argparse.ArgumentParser(description=__doc__)
sub = parser.add_subparsers(dest="command", required=True)
build = sub.add_parser("build", help="compile/link only; never run")
build.add_argument("--producer", type=Path)
build.add_argument("--ref", default="GIMP_3_2_8")
build.add_argument("--out", type=Path, default=ROOT / ".build/metadata-language-fixture")
run = sub.add_parser("run", help="explicitly write an XCF with throwaway settings")
run.add_argument("--binary", type=Path, required=True)
run.add_argument("--output", type=Path, required=True)
run.add_argument("--work", type=Path, required=True)
args = parser.parse_args()
if args.command == "build":
    driver.HARNESS = ROOT / "Engine/tests/metadata-language-fixture.c"
    driver.cmd_build(args)
else:
    work = args.work.resolve()
    for name in ("home", "cache", "user"):
        (work / name).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(HOME=str(work / "home"), XDG_CACHE_HOME=str(work / "cache"),
               GIMP3_DIRECTORY=str(work / "user"), G_DEBUG="fatal-criticals")
    subprocess.run([str(args.binary.resolve()), str(args.output.resolve()), str(work)],
                   env=env, check=True, timeout=120)
