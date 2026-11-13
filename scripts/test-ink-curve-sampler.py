#!/usr/bin/env python3
"""Generate/compare independent samples using the unmodified native GimpCurve.

Build/run uses the selected existing adapter. The run writes oracles.json
in its throwaway work directory. Compare validates actual cases against the
committed fixture's case names and samples. Never calls InkCurveSampler.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FIXTURE = ROOT / "Engine/tests/fixtures/ink-curve-sampler.json"
SIBLING_DRIVER = ROOT / "scripts/test-layer-duplicate-prepare.py"
TOLERANCE = 2e-14
EXPECTED_SAMPLES = 256


def fail(message: str, code: int = 2) -> "NoReturn":
    print(f"test-ink-curve-sampler: {message}", file=sys.stderr)
    raise SystemExit(code)


def _reject_constant(s: str):
    raise ValueError(f"non-finite constant {s!r}")


def load_json(path: Path):
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f, parse_constant=_reject_constant)
    except FileNotFoundError as e:
        fail(f"cannot read {path}: {e.strerror or 'missing file'}")
    except OSError as e:
        fail(f"cannot read {path}: {e.strerror or e}")
    except json.JSONDecodeError as e:
        fail(f"invalid JSON in {path}: {e.msg} at line {e.lineno} column {e.colno}")
    except ValueError as e:
        fail(f"invalid JSON in {path}: {e}")


def load_driver():
    try:
        spec = importlib.util.spec_from_file_location("native_driver", SIBLING_DRIVER)
        if spec is None or spec.loader is None:
            raise ImportError("no loader")
        driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(driver)
    except Exception as e:
        fail(f"cannot load sibling driver {SIBLING_DRIVER}: {e}")
    driver.READER = ROOT / "Engine/curves-config.c"
    driver.HARNESS = ROOT / "Engine/tests/ink-curve-sampler-oracle.c"
    driver.DEFAULT_OUT_ROOT = ROOT / ".build/ink-curve-sampler"
    return driver


def expect_finite_number(value, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{where}: expected finite number, got {type(value).__name__}")
    number = float(value)
    if not math.isfinite(number):
        fail(f"{where}: expected finite number")
    return number


def extract_cases(data, label: str):
    if isinstance(data, dict) and "cases" in data:
        cases = data["cases"]
    else:
        cases = data
    if not isinstance(cases, list):
        fail(f"{label}: expected a case list or object with 'cases'")
    out = []
    names = set()
    for i, case in enumerate(cases):
        if not isinstance(case, dict):
            fail(f"{label} case {i}: expected object")
        name = case.get("name")
        if not isinstance(name, str) or not name:
            fail(f"{label} case {i}: missing/invalid name")
        if name in names:
            fail(f"{label}: duplicate case name {name!r}")
        names.add(name)
        samples = case.get("samples")
        if not isinstance(samples, list):
            fail(f"{label} case {name!r}: samples must be a list")
        if len(samples) != EXPECTED_SAMPLES:
            fail(f"{label} case {name!r}: expected {EXPECTED_SAMPLES} samples, got {len(samples)}")
        nums = [expect_finite_number(v, f"{label} case {name!r} sample {j}") for j, v in enumerate(samples)]
        out.append((name, nums))
    return out


def compare(actual_path: Path, expected_path: Path = DEFAULT_FIXTURE) -> int:
    actual = extract_cases(load_json(actual_path), str(actual_path))
    expected = extract_cases(load_json(expected_path), str(expected_path))
    actual_names = [n for n, _ in actual]
    expected_names = [n for n, _ in expected]
    if len(actual) != len(expected):
        fail(f"case count mismatch: actual {len(actual)} vs expected {len(expected)}")
    for i, (a, e) in enumerate(zip(actual_names, expected_names)):
        if a != e:
            fail(f"case mismatch at index {i}: actual {a!r} vs expected {e!r}")
    for (name, a_samples), (_, e_samples) in zip(actual, expected):
        for i, (a, e) in enumerate(zip(a_samples, e_samples)):
            if abs(a - e) > TOLERANCE:
                fail(f"case {name!r} sample {i}: |{a:.17g} - {e:.17g}| > {TOLERANCE}")
    print(f"compare: {len(actual)} cases OK ({actual_path})")
    return 0


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "compare":
        p = argparse.ArgumentParser(prog="test-ink-curve-sampler.py compare")
        p.add_argument("actual", type=Path)
        p.add_argument("--expected", type=Path, default=DEFAULT_FIXTURE)
        args = p.parse_args(argv[1:])
        return compare(args.actual, args.expected)

    driver = load_driver()
    # Let driver parse build/run/syntax options; preserve behavior.
    if argv and argv[0] == "run":
        # Parse enough to know --work for auto-compare, but defer full validation to driver.
        pre = argparse.ArgumentParser(add_help=False)
        pre.add_argument("--work", type=Path)
        known, _ = pre.parse_known_args(argv[1:])
        # Run driver in-process by invoking its main on argv.
        old_argv = sys.argv[:]
        sys.argv = [str(SIBLING_DRIVER), *argv]
        try:
            driver.main()
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
            if code != 0:
                raise
        finally:
            sys.argv = old_argv
        if known.work is None:
            fail("run succeeded but --work was not provided for auto-compare")
        return compare(known.work.resolve() / "oracles.json", DEFAULT_FIXTURE)

    old_argv = sys.argv[:]
    sys.argv = [str(SIBLING_DRIVER), *argv]
    try:
        driver.main()
    finally:
        sys.argv = old_argv
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
