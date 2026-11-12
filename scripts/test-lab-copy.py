#!/usr/bin/env python3
"""Run independent slot197 RGB/Lab converted-copy acceptance on immutable objects.

Only the fixture is compiled/linked. Adapter and upstream inputs are never
rebuilt. The shared runner supplies isolated HOME/cache/GIMP/TMP and bounded
process groups; all input hashes and failed logs remain in a new output folder.
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
    runner.SOURCE = ROOT / "Engine/tests/lab-copy-tests.c"
    inputs = [Path(__file__).resolve(), ROOT / "Engine/plate-storage.h", ROOT / "Engine/plate-map.h"]
    profile = args.cmyk_profile.resolve()
    inputs.append(profile)
    before = {str(p): runner.digest(p) for p in inputs}
    previous = os.environ.get("GLIMS_TEST_CMYK_PROFILE")
    os.environ["GLIMS_TEST_CMYK_PROFILE"] = str(profile)
    result = 1
    try:
        result = runner.run(producer, output, args.timeout, args.ref)
        if result == 0:
            log = (output / "run.log").read_text()
            summaries = re.findall(r"^(\d+) Lab copy checks, (\d+) failures$", log, re.M)
            if len(summaries) != 1 or int(summaries[0][0]) <= 0 or summaries[0][1] != "0":
                raise RuntimeError("Missing positive complete converted-copy success summary")
            if re.search(r"^FAIL\b", log, re.M) or not log.rstrip().endswith(summaries[0][0] + " Lab copy checks, 0 failures"):
                raise RuntimeError("Converted-copy raw log does not finish successfully")
        return result
    finally:
        if previous is None:
            os.environ.pop("GLIMS_TEST_CMYK_PROFILE", None)
        else:
            os.environ["GLIMS_TEST_CMYK_PROFILE"] = previous
        changed = [name for name, digest in before.items() if not Path(name).is_file() or runner.digest(Path(name)) != digest]
        if (output / "inputs.json").is_file():
            (output / "fixture-extra-inputs.json").write_text(json.dumps(
                {"inputs": before, "changed_inputs": changed, "runner_exit_code": result}, indent=2) + "\n")
        if changed:
            raise RuntimeError("Fixture inputs changed: " + ", ".join(changed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path,
                        default=Path(os.environ.get("GLIMS_ADAPTER_ROOT") or runner.canonical_checkout() / "_engine/adapter"))
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
    with tempfile.TemporaryDirectory(prefix="glims-lab-copy-") as output:
        return run(args, Path(output).resolve())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"test-lab-copy: {error}", file=sys.stderr)
        raise SystemExit(1)
