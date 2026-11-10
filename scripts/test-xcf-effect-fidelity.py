#!/usr/bin/env python3
"""Strict native XCF effect-fidelity regression against an existing producer."""
from pathlib import Path
import importlib.util
root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/effect-state.c"
driver.HARNESS = root / "Engine/tests/xcf-effect-fidelity-tests.c"
driver.ADDITIONAL_SOURCES = [root / "Engine/effect-archive.c"]
driver.DEFAULT_OUT_ROOT = root / ".build/xcf-effect-fidelity-tests"
if __name__ == "__main__":
    driver.main()
