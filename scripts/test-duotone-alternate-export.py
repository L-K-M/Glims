#!/usr/bin/env python3
"""Run private Duotone export admission checks against an existing producer."""
import importlib.util
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('native_runner', root / 'scripts/test-lab-storage.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.SOURCE = root / 'Engine/tests/duotone-alternate-export-tests.c'
if __name__ == '__main__':
    try:
        raise SystemExit(runner.main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'test-duotone-alternate-export: {error}', file=sys.stderr)
        raise SystemExit(1)
