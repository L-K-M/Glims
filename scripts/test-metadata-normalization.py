#!/usr/bin/env python3
"""Use the frozen-producer test driver for private normalization checks."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("normalization_driver", ROOT / "scripts/test-metadata-language.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.READER = ROOT / "Engine/metadata-normalization.c"
driver.HARNESS = ROOT / "Engine/tests/metadata-normalization-tests.c"
driver.DEFAULT_OUT = ROOT / ".build/metadata-normalization-tests"
original_check = driver.check_producer

def check_producer(producer):
    paths = original_check(producer)
    # Keep a producer's language reader if its public facade uses it;
    # replace only its normalization object with the current source.
    paths["obj"] = [str(p) for p in sorted(producer.glob("obj/*.o"))
                    if p.name != "metadata-normalization.o"]
    return paths

driver.check_producer = check_producer
driver.main()
