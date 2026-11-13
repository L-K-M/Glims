#!/usr/bin/env python3
"""Native private renderer fixture; compile local code, never rebuild producer.

Inherits the carrier driver's mandatory producer/header attestation, immutable
input hashes, disjoint fresh output, isolated HOME and bounded process groups.
"""
import importlib.util
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('carrier_runner', ROOT/'scripts/test-lab-layer-storage.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.SOURCES = [ROOT/p for p in ('Engine/lab-layer-map.c','Engine/lab-layer-storage.c',
    'Engine/lab-layer-composite.c','Engine/lab-layer-render.c','Engine/tests/lab-layer-render-tests.c')]
runner.EXTRA_INPUTS = [Path(__file__).resolve()]
if __name__ == '__main__':
    try:
        raise SystemExit(runner.main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'test-lab-layer-render: {error}', file=sys.stderr)
        raise SystemExit(1)
