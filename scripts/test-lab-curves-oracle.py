#!/usr/bin/env python3
"""Independent Fraction oracle for represented-double physical Lab curves.

Uses exact rational arithmetic for fused operations and final integer rounding;
it does not call the production decoder/encoder to determine expected samples.
The input library is a freshly compiled, optimized private kernel.
"""
import ctypes
from fractions import Fraction as F
import math
from pathlib import Path
import random
import struct
import sys


def f32(x):
    return struct.unpack("=f", struct.pack("=f", x))[0]


def fused(a, b, c):
    return float(F(a) * F(b) + F(c))


def expected(role, fmt, raw, coverage, table):
    code = struct.unpack(["=B", "=H", "=f"][fmt], raw)[0]
    if coverage == 0:
        return raw
    if fmt == 2:
        original = float(code)
        normalized = original / 100 if role == 0 else (original + 128) / 255
        position = min(1., max(0., normalized)) * 255
        index = int(position)
        fraction = position - index
    else:
        maximum = 255 if fmt == 0 else 65535
        original = 100. * code / maximum if role == 0 else code / (1. if fmt == 0 else 257.) - 128.
        index, remainder = (code, 0) if fmt == 0 else divmod(code, 257)
        fraction = remainder / 257.
    mapped = table[index] if index == 255 else table[index] + (table[index + 1] - table[index]) * fraction
    target = fused(100. if role == 0 else 255., mapped, 0. if role == 0 else -128.)
    if target == original:
        return raw
    value = target if coverage == 1 else fused(coverage, target, (1. - coverage) * original)
    value = min(max(original, target), max(min(original, target), value))
    if fmt == 2:
        return struct.pack("=f", value)
    scaled = F(value) * maximum / 100 if role == 0 else (F(value) + 128) * (1 if fmt == 0 else 257)
    result = math.floor(scaled + F(1, 2))
    return struct.pack("=B" if fmt == 0 else "=H", result)


def main():
    library = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
    apply = library.glims_lab_curves_row
    apply.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t,
                      ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    apply.restype = ctypes.c_bool
    rng = random.Random(0x4c414243)
    tables = [[0.] * 256, [1.] * 256, [.5] * 256,
              [rng.random() for _ in range(256)],
              [0., .25, .75] + [1.] * 253,
              [math.nextafter(i / 255., 0.) for i in range(256)]]
    weights = [0., .5, 1., f32(.1), f32(2**-149), f32(1 - 2**-24)]
    checks = 0
    for role in range(3):
        for fmt in range(3):
            width = [1, 2, 4][fmt]
            for table in tables:
                values = []
                for i in range(192):
                    if fmt < 2:
                        maximum = 255 if fmt == 0 else 65535
                        code = [0, 1, maximum - 1, maximum][i] if i < 4 else rng.randrange(maximum + 1)
                    else:
                        fixed = [-0., -128., 0., 50., 100., 127., -1e30, 1e30,
                                 -3.4028234663852886e38, 3.4028234663852886e38]
                        code = f32(fixed[i] if i < len(fixed) else rng.uniform(-200., 200.))
                    values.append(struct.pack(["=B", "=H", "=f"][fmt], code))
                masks = [weights[i % len(weights)] for i in range(len(values))]
                original = b"".join(values)
                src = ctypes.create_string_buffer(original)
                dst = ctypes.create_string_buffer(b"\xa5" * len(original))
                curve = (ctypes.c_double * 256)(*table)
                mask = (ctypes.c_float * len(values))(*masks)
                changed = ctypes.c_bool(True)
                assert apply(role, fmt, curve, len(values), src, mask, dst, ctypes.byref(changed))
                wanted = b"".join(expected(role, fmt, v, w, table) for v, w in zip(values, masks))
                actual = dst.raw[:len(original)]
                if actual != wanted:
                    for i in range(len(values)):
                        a, b = actual[i*width:(i+1)*width], wanted[i*width:(i+1)*width]
                        assert a == b, (role, fmt, i, values[i].hex(), masks[i], a.hex(), b.hex())
                assert changed.value == (wanted != original)
                assert src.raw[:len(original)] == original
                checks += len(values)
    print(f"Lab curves Fraction oracle: {checks} sample comparisons passed")


if __name__ == "__main__":
    main()
