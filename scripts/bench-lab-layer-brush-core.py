#!/usr/bin/env python3
"""Observe private layered Lab brush timing using isolated native fixtures."""
import importlib.util
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('brush_runner', root / 'scripts/test-lab-layer-brush-core.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.SOURCES[0] = root / 'Engine/tests/lab-layer-brush-perf.c'
runner.HEADERS.append(Path(__file__).resolve())
if __name__ == '__main__':
    try:
        raise SystemExit(runner.main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'bench-lab-layer-brush-core: {error}', file=sys.stderr)
        raise SystemExit(1)
