#!/usr/bin/env python3
"""Run opaque RGB brush Recorder capture checks against immutable engine objects.

The fixture uses private seeding/readback helpers and exercises the public
stroke-capture facade. The shared runner isolates the engine profile and
checks that producer inputs are unchanged; it never rebuilds the adapter.
"""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("lab_storage_runner", ROOT / "scripts/test-lab-storage.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def run(producer, output, timeout, ref):
    runner.SOURCE = ROOT / "Engine/tests/recorder-opaque-brush-tests.c"
    label = "opaque brush capture checks"
    extra = [Path(__file__).resolve(), ROOT / "Engine/tests/recorder-stroke-capture-facts-tests.c"]
    before = {str(path): runner.digest(path) for path in extra}
    result = 1
    try:
        result = runner.run(producer, output, timeout, ref)
        if result == 0:
            text = (output / "run.log").read_text()
            summaries = re.findall(r"^PASSED: (\d+) " + re.escape(label) + r", 0 failures$", text, re.M)
            if (len(summaries) != 1 or int(summaries[0]) <= 0 or
                    re.search(r"^FAIL\b", text, re.M) or
                    not text.rstrip().endswith(summaries[0] + " " + label + ", 0 failures")):
                raise RuntimeError("Missing positive complete opaque brush capture success summary")
        return result
    finally:
        changed = [name for name, digest in before.items()
                   if not Path(name).is_file() or runner.digest(Path(name)) != digest]
        if (output / "inputs.json").is_file():
            (output / "fixture-extra-inputs.json").write_text(json.dumps(
                {"inputs": before, "changed_inputs": changed, "runner_exit_code": result}, indent=2) + "\n")
        if changed:
            raise RuntimeError("Fixture inputs changed: " + ", ".join(changed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", default=runner.pinned_ref())
    parser.add_argument("--adapter-root", type=Path, default=runner.canonical_checkout() / "_engine/adapter")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.ref) or args.ref in {".", ".."}:
        parser.error("--ref must name an engine set")
    if not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
        parser.error("--timeout must be in (0, 3600]")
    producer = (args.adapter_root / args.ref).resolve()
    if args.output:
        return run(producer, args.output.resolve(), args.timeout, args.ref)
    with tempfile.TemporaryDirectory(prefix="glims-opaque-brush-") as output:
        return run(producer, Path(output).resolve(), args.timeout, args.ref)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as error:
        print(f"test-recorder-opaque-brush: {error}", file=sys.stderr)
        raise SystemExit(1)
