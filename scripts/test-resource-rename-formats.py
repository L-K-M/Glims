#!/usr/bin/env python3
"""Run the private checked resource-rename harness with an existing adapter producer.

Uses the shared strict native-harness compiler/isolated runtime driver; never
rebuilds or mutates the producer. Pass its normal build/run/syntax arguments.
"""
from pathlib import Path
import importlib.util

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/resource-rename.c"
driver.ADDITIONAL_SOURCES = [root / "Engine/resource-mutation-inspect.c", root / "Engine/resource-mutation.c"]
driver.HARNESS = root / "Engine/tests/resource-rename-formats-tests.c"
driver.DEFAULT_OUT_ROOT = root / ".build/resource-rename-formats-tests"
driver.main()
