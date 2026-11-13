#!/usr/bin/env python3
"""Measure one private 24 MP Lab fill; results are not app latency claims."""
import importlib.util
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('carrier_runner', ROOT / 'scripts/test-lab-layer-storage.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.SOURCES = [ROOT / p for p in ('Engine/lab-layer-paint.c', 'Engine/lab-layer-fill.c',
                                     'Engine/tests/lab-layer-fill-perf.c')]
runner.EXTRA_INPUTS = [Path(__file__).resolve()]
if __name__ == '__main__':
    try:
        raise SystemExit(runner.main())
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'bench-lab-layer-fill: {error}', file=sys.stderr)
        raise SystemExit(1)
