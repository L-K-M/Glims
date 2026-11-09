#!/usr/bin/env python3
"""Build/run the private layer-delete harness with an immutable producer.

Build only compiles and links. Runtime is a separate explicit run command.
"""
from pathlib import Path
import importlib.util

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/layer-delete.c"
driver.HARNESS = root / "Engine/tests/layer-delete-tests.c"
driver.ADDITIONAL_SOURCES = [root / "Engine/layer-duplicate-selection-undo.c"]
driver.DEFAULT_OUT_ROOT = root / ".build/layer-delete-tests"

if __name__ == "__main__":
    driver.main()
