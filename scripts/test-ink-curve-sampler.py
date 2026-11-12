#!/usr/bin/env python3
"""Generate independent samples using the unmodified native GimpCurve.

Build/run uses the selected existing adapter. The run writes oracles.json
in its throwaway work directory; compare it to the committed fixture's
case names and samples. Never calls InkCurveSampler.
"""
from pathlib import Path
import importlib.util
root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/curves-config.c"
driver.HARNESS = root / "Engine/tests/ink-curve-sampler-oracle.c"
driver.DEFAULT_OUT_ROOT = root / ".build/ink-curve-sampler"
if __name__ == "__main__":
    driver.main()
