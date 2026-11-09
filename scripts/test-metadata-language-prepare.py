#!/usr/bin/env python3
"""Compile/run detached single-language preparation with a matching producer."""
import importlib.util
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("prepare_driver", ROOT / "scripts/test-metadata-language.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.HARNESS = ROOT / "Engine/tests/metadata-language-prepare-tests.c"
driver.DEFAULT_OUT = ROOT / ".build/metadata-language-prepare-tests"
driver.main()
