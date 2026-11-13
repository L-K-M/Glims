#!/usr/bin/env python3
"""Run slot203–206 Lab Curves snapshot checks against an immutable adapter producer.

Reuses the Lab runner's bounded compilation/process groups, isolated engine home
and immutable source/object receipts. The external CMYK profile constructs a real
unsupported-mode witness and is passed via GLIMS_TEST_CMYK_PROFILE.
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
    producer = (args.adapter_root / args.ref).resolve()
    runner.SOURCE = ROOT / "Engine/tests/lab-curves-snapshot-tests.c"
    profile = args.cmyk_profile.resolve()
    before = runner.digest(profile)
    fixture = ROOT / "Engine/tests/lab-curves-edit-tests.c"
    fixture_before = runner.digest(fixture)
    previous = os.environ.get("GLIMS_TEST_CMYK_PROFILE")
    os.environ["GLIMS_TEST_CMYK_PROFILE"] = str(profile)
    try:
        return runner.run(producer, output, args.timeout, args.ref)
    finally:
        if previous is None:
            os.environ.pop("GLIMS_TEST_CMYK_PROFILE", None)
        else:
            os.environ["GLIMS_TEST_CMYK_PROFILE"] = previous
        fixture_changed = not fixture.is_file() or runner.digest(fixture) != fixture_before
        if (output / "inputs.json").is_file():
            (output / "included-fixture-input.json").write_text(json.dumps(
                {"path": str(fixture), "sha256": fixture_before, "changed": fixture_changed}, indent=2) + "\n")
        if fixture_changed:
            raise RuntimeError("Included native fixture changed during run")
        changed = not profile.is_file() or runner.digest(profile) != before
        if (output / "inputs.json").is_file():
            (output / "external-profile-input.json").write_text(json.dumps(
                {"path": str(profile), "sha256": before, "changed": changed}, indent=2) + "\n")
        if changed:
            raise RuntimeError("External CMYK fixture profile changed during the run")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path,
                        default=Path(os.environ.get("GLIMS_ADAPTER_ROOT") or
                                     runner.canonical_checkout() / "_engine/adapter"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--cmyk-profile", type=Path,
                        default=Path("/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc"))
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("--ref must name an engine set")
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
        parser.error("--timeout must be in (0, 3600]")
    if not args.cmyk_profile.is_file() or not 128 <= args.cmyk_profile.stat().st_size <= 4 * 1024 * 1024:
        parser.error("--cmyk-profile must be an existing 128-byte to 4-MiB ICC file")
    if args.output:
        return run(args, args.output.resolve())
    with tempfile.TemporaryDirectory(prefix="glims-lab-curves-snapshot-") as output:
        return run(args, Path(output).resolve())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"test-lab-curves-snapshot: {error}", file=sys.stderr)
        raise SystemExit(1)
