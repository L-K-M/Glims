#!/usr/bin/env python3
"""Run public Lab brush facade checks against an immutable slot194 producer.

No producer rebuilds or mutations. Native settings and child process groups are
isolated and bounded by the shared Lab storage harness. --output retains a new
or empty evidence folder; otherwise all output is temporary.
"""
import argparse
import importlib.util
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lab_storage_runner", ROOT / "scripts/test-lab-storage.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.SOURCE = ROOT / "Engine/tests/lab-brush-tests.c"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path,
                        default=Path(os.environ.get("GLIMS_ADAPTER_ROOT") or
                                     runner.canonical_checkout() / "_engine/adapter"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("--ref must name an engine set")
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 600:
        parser.error("--timeout must be in (0,600]")
    producer = (args.adapter_root / args.ref).resolve()
    if args.output:
        return runner.run(producer, args.output.resolve(), args.timeout, args.ref)
    with tempfile.TemporaryDirectory(prefix="glims-lab-brush-") as output:
        return runner.run(producer, Path(output).resolve(), args.timeout, args.ref)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"test-lab-brush: {error}", file=sys.stderr)
        raise SystemExit(1)
