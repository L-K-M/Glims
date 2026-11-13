#!/usr/bin/env python3
"""Independent literal/Fraction oracle for represented Lab levels cases.

This oracle derives expected values from the stated physical/normalized
equations and explicit integer decode/encode definitions. It does not call
production codec/kernel helpers to derive expected samples.
"""
import ctypes
import math
import struct
import sys
from fractions import Fraction
from pathlib import Path


def u8_decode_l(q):
    return Fraction(100 * q, 255)


def u8_decode_c(q):
    return Fraction(q - 128, 1)


def u16_decode_l(q):
    return Fraction(100 * q, 65535)


def u16_decode_c(q):
    return Fraction(q, 257) - 128


def quant_u8(phys, role):
    # nearest integer, half up
    scaled = (Fraction(phys) * 255 / 100) if role == 0 else (Fraction(phys) + 128)
    return int(math.floor(scaled + Fraction(1, 2)))


def quant_u16(phys, role):
    scaled = (Fraction(phys) * 65535 / 100) if role == 0 else (Fraction(phys) + 128) * 257
    return int(math.floor(scaled + Fraction(1, 2)))


def component_map_normalized(n, s, clamp_input, clamp_output):
    # s: (low_in, high_in, gamma, low_out, high_out)
    low_in, high_in, gamma, low_out, high_out = s
    if high_in == low_in:
        t = n - low_in
    else:
        t = (n - low_in) / (high_in - low_in)
    if clamp_input:
        if t < 0:
            t = Fraction(0, 1)
        elif t > 1:
            t = Fraction(1, 1)
    if gamma != 1 and t > 0:
        # gamma 2 -> pow(t,1/2)
        if gamma == 2:
            tf = float(t)
            t = Fraction.from_float(math.sqrt(tf))
        elif gamma == Fraction(1, 2):
            t = t * t
        else:
            t = Fraction.from_float(pow(float(t), 1 / float(gamma)))
    out = low_out + t * (high_out - low_out)
    if clamp_output:
        if out < 0:
            out = Fraction(0, 1)
        elif out > 1:
            out = Fraction(1, 1)
    return out


def phys_from_norm(role, n):
    return n * 100 if role == 0 else n * 255 - 128


def norm_from_phys(role, p):
    return Fraction(p, 100) if role == 0 else (Fraction(p) + 128) / 255


def expect_u8(role, q, s, mask_num, mask_den):
    src_phys = u8_decode_l(q) if role == 0 else u8_decode_c(q)
    n = Fraction(q, 255)
    mapped_n = component_map_normalized(n, s, False, False)
    target = phys_from_norm(role, mapped_n)
    if mask_num == mask_den:
        blended = target
    elif mask_num == 0:
        return q
    else:
        blended = src_phys * (1 - Fraction(mask_num, mask_den)) + target * Fraction(mask_num, mask_den)
    return quant_u8(blended, role)


def expect_u16(role, q, s, mask_num, mask_den):
    src_phys = u16_decode_l(q) if role == 0 else u16_decode_c(q)
    n = Fraction(q, 65535)
    mapped_n = component_map_normalized(n, s, False, False)
    target = phys_from_norm(role, mapped_n)
    if mask_num == 0:
        return q
    if mask_num == mask_den:
        blended = target
    else:
        blended = src_phys * (1 - Fraction(mask_num, mask_den)) + target * Fraction(mask_num, mask_den)
    return quant_u16(blended, role)


class Settings(ctypes.Structure):
    _fields_ = [(key, ctypes.c_double) for key in
                ("low_input", "high_input", "gamma", "low_output", "high_output")] + [
                    ("clamp_input", ctypes.c_uint32), ("clamp_output", ctypes.c_uint32)]


def run():
    if len(sys.argv) != 2:
        raise SystemExit("usage: test-lab-levels-oracle.py MATCHING_PURE_LIBRARY")
    library = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
    apply = library.glims_lab_levels_row
    apply.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(Settings), ctypes.c_size_t,
                      ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_void_p,
                      ctypes.POINTER(ctypes.c_bool)]
    apply.restype = ctypes.c_bool
    checks = 0

    def check(role, bits, q, settings, numerator=1, denominator=1):
        nonlocal checks
        expected = (expect_u8 if bits == 8 else expect_u16)(
            role, q, settings, numerator, denominator)
        expected = max(0, min((1 << bits) - 1, expected))
        sample = ctypes.c_uint8 if bits == 8 else ctypes.c_uint16
        source, destination = sample(q), sample(17)
        mask = ctypes.c_float(numerator / denominator)
        changed = ctypes.c_bool(True)
        native = Settings(*map(float, settings), 0, 0)
        ok = apply(role, 0 if bits == 8 else 1, ctypes.byref(native), 1,
                   ctypes.byref(source), ctypes.byref(mask), ctypes.byref(destination),
                   ctypes.byref(changed))
        assert ok, ("refused", role, bits, q, settings, numerator, denominator)
        assert destination.value == expected, (role, bits, q, settings, numerator,
                                               denominator, destination.value, expected)
        assert changed.value == (expected != q), ("changed", role, bits, q)
        assert source.value == q
        checks += 1

    # Exact Fraction arithmetic for affine transfer+physical blend+one final quantization.
    cases = [tuple(map(Fraction, values)) for values in [
        (0, 1, 1, 1, 0), (1, 0, 1, 0, 1), (.25, .25, 1, 0, 1),
        (.25, .75, 1, .125, .875), (.75, .25, 1, .875, .125),
    ]]
    for role in range(3):
        for bits in (8, 16):
            samples = range(256) if bits == 8 else range(0, 65536, 257)
            for settings in cases:
                for q in samples:
                    for n, d in [(1, 1), (1, 2), (1, 4)]:
                        check(role, bits, q, settings, n, d)
            if bits == 16:
                for q in [1, 2, 32767, 32768, 32895, 32896, 65534, 65535]:
                    check(role, bits, q, cases[0], 1, 2)
    print(f"Lab levels Fraction-vs-kernel oracle: {checks} checks passed")


if __name__ == "__main__":
    run()
