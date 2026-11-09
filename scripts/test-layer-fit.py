#!/usr/bin/env python3
"""Build/run the layer-fit harness against an immutable slot156 producer.

Build only compiles and links; runtime is a separate explicit command.
"""
from pathlib import Path
import importlib.util

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/layer-fit.c"
driver.HARNESS = root / "Engine/tests/layer-fit-tests.c"
driver.ADDITIONAL_SOURCES = []
driver.DEFAULT_OUT_ROOT = root / ".build/layer-fit-tests"

if __name__ == "__main__":
    driver.main()
