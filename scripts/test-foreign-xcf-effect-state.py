#!/usr/bin/env python3
"""Build/run pinned foreign-XCF binder admission tests using an immutable producer.

Reuses the unchanged foreign-field oracle driver, including its isolated
runtime environment and timeout cleanup. The harness includes that original
oracle unchanged, then tests owned metadata drafts at the native binder seam.

    python3 scripts/test-foreign-xcf-effect-state.py build \
        --producer /absolute/producer/GIMP_3_2_8 --out /tmp/foreign-state-build
    python3 scripts/test-foreign-xcf-effect-state.py run \
        --binary /tmp/foreign-state-build/foreign-xcf-effect-state-tests \
        --work /tmp/foreign-state-work
"""
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys

# Importing the immutable driver must not create files beside its source.
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
DRIVER_PATH = ROOT / "scripts/test-foreign-xcf-effect-fields.py"
spec = importlib.util.spec_from_file_location("foreign_xcf_fields_driver", DRIVER_PATH)
if spec is None or spec.loader is None:
    raise SystemExit("Cannot import the foreign-XCF field oracle driver")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
driver.HARNESS = ROOT / "Engine/tests/foreign-xcf-effect-state-tests.c"
driver.DEFAULT_OUT = ROOT / ".build/foreign-xcf-effect-state-tests" / driver.PINNED_REF
driver.BINARY_NAME = "foreign-xcf-effect-state-tests"
driver.__doc__ = __doc__
original_build, original_run = driver.build, driver.run


def additional_inputs() -> list[Path]:
    return [
        ROOT / "Engine/tests/foreign-xcf-effect-fields-tests.c",
        ROOT / "Engine/foreign-effect-state.h",
        ROOT / "Engine/foreign-effect-load.h",
        ROOT / "Engine/xcf-effect-fields.h",
        DRIVER_PATH,
        Path(__file__).resolve(),
    ]


def build(args: argparse.Namespace) -> int:
    # The inherited build hashes the harness, facade/private headers, all
    # producer/core objects and response files. Cover the included oracle
    # and additional declarations without modifying that original driver.
    inputs = additional_inputs()
    before = {str(path): driver.digest(path) for path in inputs}
    try:
        result = original_build(args)
    finally:
        after = {str(path): driver.digest(path) if path.is_file() else None for path in inputs}
        changed = [path for path in before if before[path] != after[path]]
        if changed:
            driver.fail("included oracle/header/wrapper inputs changed during build: " + ", ".join(changed))
    if result != 0:
        return result
    output = (args.out or driver.DEFAULT_OUT).resolve()
    manifest_path = output / "build.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["inputs_sha256"].update(before)
    manifest["additional_inputs_sha256"] = before
    manifest["additional_inputs_after_sha256"] = after
    manifest["additional_inputs_unchanged"] = True
    manifest["harness_name"] = driver.BINARY_NAME
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return result


def run(args: argparse.Namespace) -> int:
    binary = (args.binary or driver.DEFAULT_OUT / driver.BINARY_NAME).resolve()
    manifest_path = binary.parent / "build.json"
    if not manifest_path.is_file():
        driver.fail("binder harness has no build manifest; build it separately first")
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("harness_name") != driver.BINARY_NAME
            or manifest.get("additional_inputs_unchanged") is not True
            or not manifest.get("additional_inputs_sha256")
            or manifest.get("additional_inputs_sha256") != manifest.get("additional_inputs_after_sha256")):
        driver.fail("binder harness lacks the included-oracle/header input freeze")
    # The inherited run verifies binary identity and uses private HOME,
    # XDG/GIMP/TMP settings. It never rebuilds the harness or producer.
    return original_run(args)


if __name__ == "__main__":
    driver.build, driver.run = build, run
    sys.exit(driver.main())
