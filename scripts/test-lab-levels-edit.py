#!/usr/bin/env python3
"""Run slots210-212 Lab Levels edit checks against an immutable adapter producer.

Reuses the Lab runner's bounded compilation/process groups, isolated engine home
and immutable source/object receipts. No external profile or engine rebuild is required.
"""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lab_storage_runner", ROOT / "scripts/test-lab-storage.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def run(args, output):
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise RuntimeError("--output must be a new or empty directory")
    runner.SOURCE = ROOT / "Engine/tests/lab-levels-edit-tests.c"
    return runner.run((args.adapter_root / args.ref).resolve(), output, args.timeout, args.ref)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path,
                        default=Path(os.environ.get("GLIMS_ADAPTER_ROOT") or
                                     runner.canonical_checkout() / "_engine/adapter"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("--ref must name an engine set")
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
        parser.error("--timeout must be in (0, 3600]")
    if args.output:
        return run(args, args.output.resolve())
    with tempfile.TemporaryDirectory(prefix="glims-lab-levels-edit-") as output:
        return run(args, Path(output).resolve())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"test-lab-levels-edit: {error}", file=sys.stderr)
        raise SystemExit(1)
