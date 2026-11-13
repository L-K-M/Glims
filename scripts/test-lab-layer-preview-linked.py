#!/usr/bin/env python3
"""Run the preview fixture against an attested producer containing the preview."""
import importlib.util
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('carrier_runner', root / 'scripts/test-lab-layer-storage.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.SOURCES = [root / 'Engine/tests/lab-layer-preview-tests.c']
runner.EXTRA_INPUTS = [Path(__file__).resolve()] + [root / name for name in (
    'Engine/lab-layer-preview.c', 'Engine/lab-layer-preview-read.c',
    'Engine/display-sample.c')]
if __name__ == '__main__':
    try:
        raise SystemExit(runner.main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'test-lab-layer-preview-linked: {error}', file=sys.stderr)
        raise SystemExit(1)
