#!/usr/bin/env python3
"""Check exhaustive public binding and admission coverage without an engine build."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent

def mask(source):
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                  lambda m: ' ' * len(m.group()), source, flags=re.S)

def check(root=ROOT):
    source = (root / 'Engine/engine.c').read_text()
    masked = mask(source)
    header = (root / 'Sources/CGlimsEngine/include/glims_engine.h').read_text()
    header = mask(header[header.index('typedef struct GlimsEngineAPI {'):header.index('} GlimsEngineAPI;')])
    fields = re.findall(r'\(\s*\*\s*(\w+)\s*\)', header)
    definition = mask((root / 'Engine/facade-operations.def').read_text())
    entries = re.findall(r'GLIMS_FACADE\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)', definition)
    errors = []
    if [row[0] for row in entries] != fields:
        errors.append('Manifest members/order must equal every public function field exactly')
    if len(set(fields)) != len(fields):
        errors.append('Duplicate public facade field')
    direct = {'start', 'stop', 'free_string', 'engine_version', 'free_pixels',
              'free_metadata_strings', 'metadata_languages_free',
              'free_curves_snapshot', 'free_histogram_snapshot'}
    cleanup = {'image_close', 'stroke_end', 'filter_abort', 'procedure_cancel'}
    component = {'image_grid', 'image_history', 'image_info', 'stroke_begin_with_brush_resource', 'image_render_to_profile', 'image_select_items', 'image_quick_mask', 'image_history_move', 'select_shape', 'image_guides', 'image_color_info', 'image_duplicate', 'drawable_thumbnail', 'stroke_begin_with_capture_facts', 'image_redo', 'image_selected_items', 'stroke_begin', 'image_selected_layers', 'image_floating_selection', 'image_undo_info', 'image_channels', 'image_components', 'channel_command', 'channel_change', 'image_undo', 'select_command', 'image_render', 'selection_bounds', 'selection_outline', 'image_layers', 'image_save_copy', 'stroke_begin_v2', 'paths', 'image_save'}
    component_stroke = {'stroke_continue', 'stroke_continue_v2'}
    for name, wrapper, kind, policy in entries:
        if name in direct:
            if kind != 'NONE' or policy != 'DIRECT':
                errors.append(f'{name}: direct lifecycle/release exemption changed')
            continue
        if policy == 'DIRECT':
            errors.append(f'{name}: unapproved direct exemption')
        match = re.search(r'\b' + re.escape(wrapper) + r'\s*\(([^;{}]*)\)\s*\{', masked)
        if not match:
            errors.append(f'{name}: wrapper definition missing')
            continue
        start = match.end()
        depth, end = 1, start
        while depth and end < len(masked):
            depth += (masked[end] == '{') - (masked[end] == '}')
            end += 1
        body = masked[start:end - 1]
        if re.search(r'\b(glims_engine_call|call_on_engine)\s*\(', body):
            errors.append(f'{name}: bypasses facade admission')
        calls = re.findall(r'glims_facade_call(?:_reporting_admission)?\s*\(\s*e\s*,\s*GLIMS_FACADE_OP_(\w+)', body)
        if calls != [name]:
            errors.append(f'{name}: must use its own operation ID exactly once')
        params = masked[match.start(1):match.end(1)]
        image = re.search(r'GlimsImageID\s+(\w+)\b', params)
        session_filter = re.search(r'GlimsFilterID\s+(\w+)\b', params)
        stroke = re.search(r'GlimsStrokeID\s+(\w+)\b', params)
        expected_kind = 'IMAGE' if image else 'FILTER' if session_filter else 'STROKE' if stroke else 'NONE'
        expected_id = (image or session_filter or stroke).group(1) if image or session_filter or stroke else '0'
        if name == 'procedure_run':
            expected_kind = 'ALL_IMAGES'
        if kind != expected_kind:
            errors.append(f'{name}: {kind} resolver disagrees with typed {expected_kind} arguments')
        target = re.findall(r'\(GlimsFacadeTarget\)\s*\{\s*GLIMS_FACADE_TARGET_(\w+)\s*,\s*(\w+)\s*,', body)
        if target != [(expected_kind, expected_id)]:
            errors.append(f'{name}: captured owner differs from its typed ID argument')
        source_pairs = {
            'stroke_begin': ('glims_facade_brush_source(brush)', '0'),
            'stroke_begin_v2': ('glims_facade_brush_source(brush)', '0'),
            'stroke_begin_with_capture_facts': ('glims_facade_brush_source(brush)', '0'),
            'stroke_begin_with_brush_resource': ('glims_facade_brush_source(settings)', '0'),
            'selection_stroke': ('glims_facade_brush_source(settings)', '0'),
            'filter_begin_with_source': ('source', '0'),
            'filter_begin_displace_with_sources': ('x_source', 'y_source'),
            'filter_begin_oilify_with_sources': ('radius_source', 'exponent_source'),
        }
        expected_sources = source_pairs.get(name, ('0', '0'))
        packed_target = f'(GlimsFacadeTarget){{GLIMS_FACADE_TARGET_{expected_kind},{expected_id},{{{expected_sources[0]},{expected_sources[1]}}}}}'
        if packed_target not in re.sub(r'\s+', '', body):
            errors.append(f'{name}: source ownership capture differs from its contract')
        expected_policy = ('COMPONENT' if name in component else 'COMPONENT_STROKE' if name in component_stroke else
                           'CLEANUP' if name in cleanup else 'GLOBAL' if kind == 'NONE' else 'ORDINARY')
        if policy != expected_policy:
            errors.append(f'{name}: unexpected initial admission policy {policy}')
    table = source[source.index('static const GlimsEngineAPI api_v1 = {'):]
    table = table[:table.index('\n};')]
    if '#include "facade-operations.def"' not in table or re.findall(r'\.(\w+)\s*=', table) != ['api_version', 'struct_size', 'name']:
        errors.append('The API table must bind only through the manifest')
    return errors, len(fields)

if __name__ == '__main__':
    problems, count = check()
    if problems:
        print('\n'.join(problems), file=sys.stderr)
        raise SystemExit(1)
    print(f'{count} facade functions have exhaustive bindings and typed admission coverage')
