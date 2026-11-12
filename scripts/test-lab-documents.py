#!/usr/bin/env python3
"""Run native Lab document fixtures against one immutable adapter producer.

Uses the storage runner's isolated homes, response validation, bounded process
groups and input receipts. No upstream objects, adapter or GUI are rebuilt.
"""
import argparse
import importlib.util
import math
import os
from pathlib import Path
import re
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lab_storage_runner", ROOT / "scripts/test-lab-storage.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def run(args, output):
    producer = (args.adapter_root / args.ref).resolve()
    cases = ("storage", "policy", "render", "roundtrip") if args.case == "all" else (args.case,)
    for case in cases:
        runner.SOURCE = ROOT / f"Engine/tests/lab-document-{case}-tests.c"
        result = runner.run(producer, output / case, args.timeout, args.ref)
        if result:
            return result
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path,
                        default=Path(os.environ.get("GLIMS_ADAPTER_ROOT") or
                                     runner.canonical_checkout() / "_engine/adapter"))
    parser.add_argument("--case", choices=("all", "storage", "policy", "render", "roundtrip"), default="all")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("--ref must name an engine set")
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
        parser.error("--timeout must be in (0, 3600]")
    if args.output:
        return run(args, args.output.resolve())
    with tempfile.TemporaryDirectory(prefix="glims-lab-documents-") as output:
        return run(args, Path(output).resolve())


if __name__ == "__main__":
    raise SystemExit(main())
