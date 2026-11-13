#!/usr/bin/env python3
"""Core-seeded/public-render ordinary sampling regression; immutable producer only."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('producer_runner',ROOT/'scripts/test-lab-layer-storage.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
runner.SOURCES=[ROOT/'Engine/tests/display-sampling-tests.c']
runner.EXTRA_INPUTS=[Path(__file__).resolve(),ROOT/'Engine/tests/fixtures/linear-rgb.icc',ROOT/'Engine/tests/fixtures/gray.icc']
os.environ['GLIMS_DISPLAY_FIXTURES']=str(ROOT/'Engine/tests/fixtures')
if __name__=='__main__':
    try:raise SystemExit(runner.main())
    except (OSError,RuntimeError,ValueError,KeyError,subprocess.SubprocessError) as error:
        print(f'test-display-sampling: {error}',file=sys.stderr);raise SystemExit(1)
