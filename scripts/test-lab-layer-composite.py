#!/usr/bin/env python3
"""Standalone physical-Lab row checks, including an exact rational oracle.

No engine, native image, UI, or installed dependencies are loaded. The oracle
composes bottom-to-top with Fraction, independently of the C incremental mean.
"""
import argparse
import ctypes
from fractions import Fraction as F
from pathlib import Path
import platform
import random
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command):
    print('+ ' + ' '.join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, timeout=60)


def oracle(library):
    class Layer(ctypes.Structure):
        _fields_ = [(name, ctypes.POINTER(ctypes.c_uint8)) for name in ('l', 'a', 'b', 'alpha')] + [('opacity', ctypes.c_double)]
    kernel = ctypes.CDLL(str(library)).glims_lab_layer_composite_row
    kernel.argtypes = [ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(Layer), ctypes.c_void_p]
    kernel.restype = ctypes.c_bool
    rng = random.Random(32017)
    cases = [(0, 3), (1, 7), (2, 7), (256, 7)] + [(rng.randrange(1, 13), 7) for _ in range(64)]
    comparisons = 0
    for case, (count, width) in enumerate(cases):
        samples = [[bytes(rng.randrange(256) for _ in range(width)) for _ in range(4)] for _ in range(count)]
        opacities = [F(rng.randrange(9), 8) for _ in range(count)]
        if case == 1:
            opacities[0] = F(1, 2**1074)
            samples[0][3] = bytes([255] * width)
        planes = [[(ctypes.c_uint8 * width).from_buffer_copy(plane) for plane in row] for row in samples]
        rows = (Layer * count)(*[Layer(*row, float(opacity)) for row, opacity in zip(planes, opacities)])
        descriptors_before = bytes(rows)
        before = [[bytes(plane) for plane in row] for row in planes]
        destination = ctypes.create_string_buffer(width * 4 * 8 + 2)
        destination.raw = bytes([0xA5]) * len(destination)
        assert kernel(count, width, rows if count else None, ctypes.byref(destination, 1))
        actual = struct.unpack_from('=' + 'd' * width * 4, destination, 1)
        assert destination.raw[0] == 0xA5 and destination.raw[-1] == 0xA5
        assert before == [[bytes(plane) for plane in row] for row in planes]
        assert descriptors_before == bytes(rows)
        for x in range(width):
            alpha, colors = F(0), [F(0), F(0), F(0)]
            # Independent back-to-front premultiplied rational recurrence.
            for row, opacity in reversed(list(zip(samples, opacities))):
                coverage = F(row[3][x], 255) * opacity
                source = [F(100 * row[0][x], 255), F(row[1][x] - 128), F(row[2][x] - 128)]
                colors = [s * coverage + d * (1 - coverage) for s, d in zip(source, colors)]
                alpha = coverage + alpha * (1 - coverage)
            expected = [float(c / alpha) for c in colors] + [float(alpha)] if alpha else [0.0] * 4
            for channel, value in enumerate(expected):
                tolerance = 1e-14 if channel == 3 else 1e-12
                observed = actual[x * 4 + channel]
                assert abs(observed - value) <= tolerance, (case, x, channel, observed, value)
                comparisons += 1
    print(f'Fraction oracle: {len(cases)} cases, {comparisons} components passed', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', nargs='?', default='all', choices=['all', 'optimized', 'sanitized'])
    args = parser.parse_args()
    compiler = ['xcrun', 'clang'] if platform.system() == 'Darwin' else ['clang']
    base = compiler + ['-std=c11', '-Wall', '-Wextra', '-Werror', '-pedantic', '-I' + str(ROOT / 'Engine')]
    source = ROOT / 'Engine/lab-layer-composite.c'
    tests = ROOT / 'Engine/tests/lab-layer-composite-tests.c'
    modes = ['optimized', 'sanitized'] if args.mode == 'all' else [args.mode]
    with tempfile.TemporaryDirectory(prefix='glims-lab-layer-composite-') as temporary:
        work = Path(temporary)
        for mode in modes:
            flags = ['-O2'] if mode == 'optimized' else ['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-fno-omit-frame-pointer']
            binary = work / mode
            run(base + flags + [source, tests, '-lm', '-o', binary])
            run([binary])
        if 'optimized' in modes:
            library = work / ('oracle.dylib' if platform.system() == 'Darwin' else 'oracle.so')
            shared = ['-dynamiclib'] if platform.system() == 'Darwin' else ['-shared', '-fPIC']
            run(base + ['-O2'] + shared + [source, '-lm', '-o', library])
            oracle(library)
    print('PASSED: Lab layer composite standalone checks', flush=True)


if __name__ == '__main__':
    main()
