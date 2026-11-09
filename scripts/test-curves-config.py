#!/usr/bin/env python3
"""Strict Curves harness against a fresh immutable slot160 producer."""
from pathlib import Path
import importlib.util
root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/curves-config.c"
driver.HARNESS = root / "Engine/tests/curves-config-tests.c"
driver.ADDITIONAL_SOURCES = []
driver.DEFAULT_OUT_ROOT = root / ".build/curves-config-tests"
if __name__ == "__main__":
    driver.main()
