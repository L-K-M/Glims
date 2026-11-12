"""Prove that accidental new/bypassing facade bindings fail the CI gate."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('facade_coverage', ROOT / 'scripts/check-facade-policy.py')
COVERAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COVERAGE)


class FacadePolicyCoverageTests(unittest.TestCase):
    def test_current_bindings_are_complete(self):
        errors, count = COVERAGE.check(ROOT)
        self.assertEqual(errors, [])
        self.assertEqual(count, 189)

    def test_missing_misrouted_and_bypassing_bindings_refuse(self):
        cases = [
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_ink_snapshot_begin,', 'GLIMS_FACADE_OP_image_duplicate,'),
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_ink_snapshot_levels,', 'GLIMS_FACADE_OP_image_levels_ink,'),
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_ink_snapshot_apply,', 'GLIMS_FACADE_OP_image_levels_ink,'),
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_ink_channel_identity,', 'GLIMS_FACADE_OP_image_components,'),
            ('Engine/facade-operations.def',
             'GLIMS_FACADE(image_ink_snapshot_end, api_image_ink_snapshot_end, IMAGE, CLEANUP)',
             'GLIMS_FACADE(image_ink_snapshot_end, api_image_ink_snapshot_end, IMAGE, COMPONENT)'),
            ('Engine/facade-operations.def',
             'GLIMS_FACADE(image_ink_channel_identity, api_image_ink_channel_identity, IMAGE, COMPONENT)',
             'GLIMS_FACADE(image_ink_channel_identity, api_image_ink_channel_identity, IMAGE, ORDINARY)'),
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_levels_ink,', 'GLIMS_FACADE_OP_image_edit_ink,'),
            ('Engine/facade-operations.def',
             'GLIMS_FACADE(image_levels_ink, api_image_levels_ink, IMAGE, COMPONENT)',
             'GLIMS_FACADE(image_levels_ink, api_image_levels_ink, IMAGE, ORDINARY)'),
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_edit_ink,', 'GLIMS_FACADE_OP_image_clear,'),
            ('Engine/facade-operations.def',
             'GLIMS_FACADE(image_edit_ink, api_image_edit_ink, IMAGE, COMPONENT)',
             'GLIMS_FACADE(image_edit_ink, api_image_edit_ink, IMAGE, ORDINARY)'),
            ('Engine/engine.c',
             'glims_facade_call (engine, GLIMS_FACADE_OP_image_export_native_cmyk_psd,',
             'glims_facade_call (wrong_engine, GLIMS_FACADE_OP_image_export_native_cmyk_psd,'),
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_export_native_cmyk_psd,',
             'GLIMS_FACADE_OP_image_export_psd_cmyk,'),
            ('Engine/facade-operations.def',
             'GLIMS_FACADE(image_export_native_cmyk_psd, api_image_export_native_cmyk_psd, IMAGE, COMPONENT)',
             'GLIMS_FACADE(image_export_native_cmyk_psd, api_image_export_native_cmyk_psd, IMAGE, ORDINARY)'),
            ('Engine/facade-operations.def',
             'GLIMS_FACADE(image_clear, api_image_clear, IMAGE, ORDINARY)', ''),
            ('Engine/facade-operations.def',
             'GLIMS_FACADE(image_clear, api_image_clear, IMAGE, ORDINARY)',
             'GLIMS_FACADE(image_clear, api_image_clear, NONE, GLOBAL)'),
            ('Engine/engine.c', 'GLIMS_FACADE_OP_image_clear,', 'GLIMS_FACADE_OP_image_close,'),
            ('Engine/engine.c', 'return glims_facade_call (e, GLIMS_FACADE_OP_image_clear,',
             'return glims_engine_call (e, GLIMS_FACADE_OP_image_clear,'),
            ('Engine/engine.c', 'GLIMS_FACADE_TARGET_ALL_IMAGES, image,', 'GLIMS_FACADE_TARGET_NONE, 0,'),
            ('Engine/engine.c', '{ glims_facade_brush_source (brush), 0 }', '{ 0, 0 }'),
            ('Engine/engine.c', '{ x_source, y_source }', '{ x_source, 0 }'),
        ]
        files = ['Engine/facade-operations.def', 'Engine/engine.c',
                 'Sources/CGlimsEngine/include/glims_engine.h']
        for changed, before, after in cases:
            with self.subTest(change=(changed, before)), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                for relative in files:
                    destination = root / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    source = (ROOT / relative).read_text()
                    if relative == changed:
                        self.assertIn(before, source)
                        source = source.replace(before, after, 1)
                    destination.write_text(source)
                self.assertTrue(COVERAGE.check(root)[0])
