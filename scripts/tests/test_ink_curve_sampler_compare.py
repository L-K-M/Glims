import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "test-ink-curve-sampler.py"
FIXTURE = REPO / "Engine" / "tests" / "fixtures" / "ink-curve-sampler.json"


def run_compare(actual_path, *extra, env=None):
    cmd = [sys.executable, "-O", str(SCRIPT), "compare", str(actual_path), *extra]
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(cmd, cwd=REPO, env=merged, capture_output=True, text=True)


def load_cases():
    return json.loads(FIXTURE.read_text())["cases"]


def write_json(path, data):
    path.write_text(json.dumps(data, allow_nan=False))


class CompareInkCurveSamplerTests(unittest.TestCase):
    def write_actual(self, cases):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        path = Path(td.name) / "oracles.json"
        write_json(path, cases)
        return path

    def test_valid_record_passes(self):
        res = run_compare(self.write_actual(load_cases()))
        self.assertEqual(res.returncode, 0, msg=res.stderr + res.stdout)

    def test_perturbation_fails(self):
        cases = load_cases()
        cases[0]["samples"][17] += 1e-9
        res = run_compare(self.write_actual(cases))
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("identity", res.stderr)

    def test_short_samples_fail(self):
        cases = load_cases()
        cases[0]["samples"] = cases[0]["samples"][:-1]
        res = run_compare(self.write_actual(cases))
        self.assertNotEqual(res.returncode, 0)

    def test_extra_case_fails(self):
        cases = load_cases() + [{"name": "extra", "samples": [0.0] * 256}]
        res = run_compare(self.write_actual(cases))
        self.assertNotEqual(res.returncode, 0)

    def test_missing_case_fails(self):
        res = run_compare(self.write_actual(load_cases()[:-1]))
        self.assertNotEqual(res.returncode, 0)

    def test_wrong_order_fails(self):
        cases = load_cases()
        cases[0], cases[1] = cases[1], cases[0]
        res = run_compare(self.write_actual(cases))
        self.assertNotEqual(res.returncode, 0)

    def test_duplicate_cases_fail(self):
        cases = load_cases() + [load_cases()[0]]
        res = run_compare(self.write_actual(cases))
        self.assertNotEqual(res.returncode, 0)

    def test_bool_fails(self):
        cases = load_cases()
        cases[0]["samples"][0] = True
        res = run_compare(self.write_actual(cases))
        self.assertNotEqual(res.returncode, 0)

    def test_nonfinite_literal_refuses(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        path = Path(td.name) / "oracles.json"
        path.write_text('[{"name":"identity","samples":[NaN' + ',0.0' * 255 + ']}]')
        self.assertNotEqual(run_compare(path).returncode, 0)
        path.write_text('[{"name":"identity","samples":[Infinity' + ',0.0' * 255 + ']}]')
        self.assertNotEqual(run_compare(path).returncode, 0)

    def test_malformed_json_and_missing_file_refuse(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        path = Path(td.name) / "oracles.json"
        path.write_text('{not json')
        self.assertNotEqual(run_compare(path).returncode, 0)
        self.assertNotEqual(run_compare(Path(td.name) / "missing.json").returncode, 0)

    def test_python_o_does_not_bypass(self):
        cases = load_cases()
        cases[0]["samples"][0] += 1e-9
        res = run_compare(self.write_actual(cases))
        self.assertNotEqual(res.returncode, 0)


if __name__ == "__main__":
    unittest.main()
