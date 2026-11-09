#!/usr/bin/env python3
"""Compile/run metadata Undo admission with a matching producer."""
import importlib.util
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("prepare_driver", ROOT / "scripts/test-metadata-language.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.HARNESS = ROOT / "Engine/tests/metadata-undo-admission-tests.c"
driver.DEFAULT_OUT = ROOT / ".build/metadata-undo-admission-tests"
driver.main()
