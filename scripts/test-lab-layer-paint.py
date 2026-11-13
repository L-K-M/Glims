#!/usr/bin/env python3
"""Check the private Lab source-over row kernel against rational arithmetic."""
import ctypes
from fractions import Fraction as F
import math
from pathlib import Path
import platform
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='glims-lab-paint-') as tmp:
        library = Path(tmp) / 'liblabpaint.dylib'
        shared = ['-dynamiclib'] if platform.system() == 'Darwin' else ['-shared', '-fPIC']
        subprocess.run(['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', *shared,
                        '-I', str(ROOT / 'Engine'), str(ROOT / 'Engine/lab-layer-paint.c'),
                        '-lm', '-o', str(library)], check=True, timeout=60)
        fn = ctypes.CDLL(str(library)).glims_lab_layer_paint_row
        ptr = ctypes.POINTER(ctypes.c_uint8)
        fn.argtypes = [ctypes.c_size_t, ctypes.POINTER(ptr), ctypes.c_void_p,
                       ctypes.c_double, ctypes.c_double, ctypes.c_double, ctypes.c_double,
                       ctypes.POINTER(ptr), ctypes.POINTER(ctypes.c_bool)]
        fn.restype = ctypes.c_bool
        rng = random.Random(782197)
        comparisons = 0
        for case in range(300):
            width = 31
            samples = [[rng.randrange(256) for _ in range(width)] for _ in range(4)]
            if case == 0:
                samples[3] = [0] * width
            masks = [F(rng.randrange(5), 4) for _ in range(width)]
            color = [F(rng.randrange(25601), 256), F(rng.randrange(-32768, 32513), 256),
                     F(rng.randrange(-32768, 32513), 256)]
            opacity = F(rng.randrange(5), 4)
            inputs = [(ctypes.c_uint8 * width)(*row) for row in samples]
            outputs = [(ctypes.c_uint8 * width)(*([165] * width)) for _ in range(4)]
            in_ptrs = (ptr * 4)(*[ctypes.cast(row, ptr) for row in inputs])
            out_ptrs = (ptr * 4)(*[ctypes.cast(row, ptr) for row in outputs])
            mask = (ctypes.c_float * width)(*[float(x) for x in masks])
            before = [bytes(row) for row in inputs]
            changed = ctypes.c_bool(False)
            assert fn(width, in_ptrs, mask, *map(float, color), float(opacity), out_ptrs, ctypes.byref(changed))
            assert before == [bytes(row) for row in inputs]
            assert changed.value == any(bytes(inputs[i]) != bytes(outputs[i]) for i in range(4))
            for x in range(width):
                source_alpha = opacity * masks[x]
                old_alpha = F(samples[3][x], 255)
                alpha = source_alpha + old_alpha * (1 - source_alpha)
                encoded_alpha = alpha * 255
                q_alpha = (encoded_alpha.numerator * 2 + encoded_alpha.denominator) // (2 * encoded_alpha.denominator)
                if not source_alpha or (samples[3][x] == 0 and q_alpha == 0):
                    for role in range(4):
                        assert outputs[role][x] == samples[role][x]
                        comparisons += 1
                    continue
                source_fraction = source_alpha / alpha
                old = [F(samples[0][x] * 100, 255), F(samples[1][x] - 128), F(samples[2][x] - 128)]
                result = [old[i] * (1 - source_fraction) + color[i] * source_fraction for i in range(3)]
                encoded = [result[0] * F(255, 100), result[1] + 128, result[2] + 128, encoded_alpha]
                for role, exact in enumerate(encoded):
                    # Binary64 can land on either side of an exact half; the
                    # integer witness tests cover chosen rounding boundaries.
                    distance = abs(exact - (exact.numerator // exact.denominator + F(1, 2)))
                    if distance < F(1, 10**10):
                        continue
                    expected = (exact.numerator * 2 + exact.denominator) // (2 * exact.denominator)
                    assert outputs[role][x] == expected, (case, x, role, exact, outputs[role][x], expected)
                    comparisons += 1
        boundaries = 0
        for old_alpha in range(255):
            halfway = float(F(1, 2 * (255 - old_alpha)))
            for opacity in (math.nextafter(halfway, 0.0), halfway, math.nextafter(halfway, 1.0)):
                inputs = [(ctypes.c_uint8 * 1)(v) for v in (128, 128, 128, old_alpha)]
                outputs = [(ctypes.c_uint8 * 1)(0) for _ in range(4)]
                in_ptrs = (ptr * 4)(*[ctypes.cast(row, ptr) for row in inputs])
                out_ptrs = (ptr * 4)(*[ctypes.cast(row, ptr) for row in outputs])
                changed = ctypes.c_bool(False)
                assert fn(1, in_ptrs, None, 50, 0, 0, opacity, out_ptrs, ctypes.byref(changed))
                exact = F(old_alpha) + F.from_float(opacity) * (255 - old_alpha)
                expected = (exact.numerator * 2 + exact.denominator) // (2 * exact.denominator)
                assert outputs[3][0] == expected, (old_alpha, opacity, exact, outputs[3][0], expected)
                boundaries += 1
        color_boundaries = 0
        for old in range(255):
            halfway = float(F(1, 2 * (255 - old)))
            for opacity in (math.nextafter(halfway, 0.0), halfway, math.nextafter(halfway, 1.0)):
                inputs = [(ctypes.c_uint8 * 1)(v) for v in (old, old, old, 255)]
                outputs = [(ctypes.c_uint8 * 1)(0) for _ in range(4)]
                in_ptrs = (ptr * 4)(*[ctypes.cast(row, ptr) for row in inputs])
                out_ptrs = (ptr * 4)(*[ctypes.cast(row, ptr) for row in outputs])
                changed = ctypes.c_bool(False)
                assert fn(1, in_ptrs, None, 100, 127, 127, opacity, out_ptrs, ctypes.byref(changed))
                exact = F(old) + F.from_float(opacity) * (255 - old)
                expected = (exact.numerator * 2 + exact.denominator) // (2 * exact.denominator)
                for role in range(3):
                    assert outputs[role][0] == expected, (old, opacity, role, exact, outputs[role][0], expected)
                    color_boundaries += 1
        print(f'PASS: 300 rational rows, {comparisons} component comparisons, {boundaries} alpha and {color_boundaries} color boundaries')


if __name__ == '__main__':
    main()
