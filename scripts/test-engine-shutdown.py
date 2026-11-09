#!/usr/bin/env python3
"""Run the native shutdown regression harness with an existing adapter producer.

Uses the shared strict native-harness compiler/isolated runtime driver; never
rebuilds or mutates the producer. Pass its normal build/run/syntax arguments.
"""
from pathlib import Path
import importlib.util

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_driver", root / "scripts/test-layer-duplicate-prepare.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = root / "Engine/engine.c"
driver.HARNESS = root / "Engine/tests/engine-shutdown-tests.c"
driver.DEFAULT_OUT_ROOT = root / ".build/engine-shutdown-tests"
def engine_flags(ref):
    install = (root / "_engine/install" / ref).resolve()
    deps = (root / "_deps/macports").resolve()
    typelibs = f"{install}/lib/girepository-1.0:{deps}/lib/girepository-1.0"
    return [f'-DGLIMS_ENGINE_TYPELIB_PATH="{typelibs}"', f'-DGLIMS_ENGINE_BIN_PATH="{install}/bin"']
driver.EXTRA_COMPILE_FLAGS = engine_flags
driver.main()
