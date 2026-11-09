#!/usr/bin/env python3
"""Strict private BC-config harness build; runtime is a separate command."""
from pathlib import Path
import importlib.util

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/filter-config.c"
driver.ADDITIONAL_SOURCES = [root / "Engine/filter.c"]
driver.HARNESS = root / "Engine/tests/filter-config-tests.c"
driver.DEFAULT_OUT_ROOT = root / ".build/filter-config-tests"

if __name__ == "__main__":
    driver.main()
