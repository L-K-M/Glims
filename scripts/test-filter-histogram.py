#!/usr/bin/env python3
"""Strict histogram/Levels Auto harness against a fresh slot163 producer."""
from pathlib import Path
import importlib.util
root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/filter-histogram.c"
driver.HARNESS = root / "Engine/tests/filter-histogram-tests.c"
driver.ADDITIONAL_SOURCES = []
driver.DEFAULT_OUT_ROOT = root / ".build/filter-histogram-tests"
if __name__ == "__main__":
    driver.main()
