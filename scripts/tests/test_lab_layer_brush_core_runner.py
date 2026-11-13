import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('lab_layer_brush_runner', ROOT / 'scripts/test-lab-layer-brush-core.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class BrushCoreRunnerEvidenceTests(unittest.TestCase):
    def check_exception_evidence(self, successful_calls, mutate_input=False, succeeds_after_change=False):
        with tempfile.TemporaryDirectory(prefix='glims-brush-runner-test-') as temporary:
            root = Path(temporary)
            producer = root / 'adapters' / 'test' / 'obj'
            producer.mkdir(parents=True)
            for name in ('engine.o', 'lab-layer-paint.o', 'lab-brush-coverage.o', 'lab-layer-storage.o'):
                (producer / name).touch()
            args = argparse.Namespace(ref='test', adapter_root=root / 'adapters', timeout=1, compile_timeout=1)
            responses = {'compile.rsp': [], 'objects.rsp': [], 'link.rsp': []}
            calls = 0

            def execute(*_args):
                nonlocal calls
                calls += 1
                if calls <= successful_calls:
                    return 0
                if mutate_input:
                    (producer / 'engine.o').write_bytes(b'changed')
                if succeeds_after_change:
                    return 0
                raise OSError('launch failed')

            with patch.object(runner.runner, 'checked_responses', return_value=responses), \
                 patch.object(runner.runner, 'bounded_process', side_effect=execute):
                expected = RuntimeError if succeeds_after_change else OSError
                pattern = 'Immutable inputs changed' if succeeds_after_change else 'launch failed'
                with self.assertRaisesRegex(expected, pattern) as caught:
                    runner.run(args, root / 'evidence')
            result = json.loads((root / 'evidence/result.json').read_text())
            self.assertNotEqual(result['exit_code'], 0)
            if mutate_input:
                self.assertIn(str((producer / 'engine.o').resolve()), result['changed_inputs'])
                if not succeeds_after_change and hasattr(caught.exception, '__notes__'):
                    self.assertTrue(any('Immutable inputs changed' in note for note in caught.exception.__notes__))
            else:
                self.assertEqual(result['changed_inputs'], [])

    def test_runtime_launch_failure_does_not_inherit_success(self):
        self.check_exception_evidence(successful_calls=3)

    def test_later_compile_launch_failure_does_not_inherit_success(self):
        self.check_exception_evidence(successful_calls=1)

    def test_changed_inputs_do_not_hide_the_original_failure(self):
        self.check_exception_evidence(successful_calls=3, mutate_input=True)

    def test_changed_inputs_cannot_be_recorded_as_success(self):
        self.check_exception_evidence(successful_calls=3, mutate_input=True, succeeds_after_change=True)


if __name__ == '__main__':
    unittest.main()
