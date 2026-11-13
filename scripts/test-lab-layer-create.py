#!/usr/bin/env python3
"""Private logical creation fixture against immutable attested producers."""
import importlib.util
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("carrier_runner", ROOT / "scripts/test-lab-layer-storage.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.SOURCES = [ROOT / p for p in ("Engine/lab-layer-map.c", "Engine/lab-layer-storage.c",
    "Engine/lab-layer-create.c", "Engine/tests/lab-layer-create-tests.c")]
runner.EXTRA_INPUTS = [Path(__file__).resolve()]
if __name__ == "__main__":
    try:
        raise SystemExit(runner.main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"test-lab-layer-create: {error}", file=sys.stderr)
        raise SystemExit(1)
