#!/usr/bin/env python3
"""Generate ONLY Engine/tests/fixtures/wide-linear-rgb.icc for wide-gamut
display-render regression tests. This script never touches gray.icc or
linear-rgb.icc.

Requires the project's LittleCMS library at _deps/macports/lib/liblcms2.dylib.
No engine initialization, no network, no transforms for expected values.

Profile (explicit, original fixture):
  RGB, D65 white (.3127, .3290), linear TRC (gamma 1.0)
  Red   (.708, .292)
  Green (.170, .797)
  Blue  (.131, .046)
These wide primaries place saturated channels outside the sRGB gamut.
Header date and profile ID are fixed for deterministic bytes.
"""
import ctypes as c
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CMS_PATH = ROOT / "_deps/macports/lib/liblcms2.dylib"
OUT = ROOT / "Engine/tests/fixtures/wide-linear-rgb.icc"

cms = c.CDLL(str(CMS_PATH))


class xyY(c.Structure):
    _fields_ = [("x", c.c_double), ("y", c.c_double), ("Y", c.c_double)]


class Primaries(c.Structure):
    _fields_ = [("red", xyY), ("green", xyY), ("blue", xyY)]


cms.cmsBuildGamma.argtypes = [c.c_void_p, c.c_double]
cms.cmsBuildGamma.restype = c.c_void_p
cms.cmsFreeToneCurve.argtypes = [c.c_void_p]
cms.cmsCreateRGBProfile.argtypes = [c.POINTER(xyY), c.POINTER(Primaries), c.POINTER(c.c_void_p)]
cms.cmsCreateRGBProfile.restype = c.c_void_p
cms.cmsMLUalloc.argtypes = [c.c_void_p, c.c_uint32]
cms.cmsMLUalloc.restype = c.c_void_p
cms.cmsMLUsetASCII.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p, c.c_char_p]
cms.cmsMLUsetASCII.restype = c.c_int
cms.cmsWriteTag.argtypes = [c.c_void_p, c.c_uint32, c.c_void_p]
cms.cmsWriteTag.restype = c.c_int
cms.cmsSaveProfileToMem.argtypes = [c.c_void_p, c.c_void_p, c.POINTER(c.c_uint32)]
cms.cmsSaveProfileToMem.restype = c.c_int
cms.cmsMLUfree.argtypes = [c.c_void_p]
cms.cmsCloseProfile.argtypes = [c.c_void_p]

WHITE = xyY(0.3127, 0.3290, 1.0)
# Sensible explicit wide primaries (physical wide-primary set), D65, linear TRC.
WIDE_PRIMARIES = Primaries(xyY(0.708, 0.292, 1.0), xyY(0.170, 0.797, 1.0), xyY(0.131, 0.046, 1.0))
DESCRIPTION = b"Glims Wide Linear RGB Fixture"


def main():
    linear = cms.cmsBuildGamma(None, 1.0)
    if not linear:
        raise RuntimeError("Could not allocate ICC gamma curve")
    profile = None
    label = None
    try:
        curves = (c.c_void_p * 3)(linear, linear, linear)
        profile = cms.cmsCreateRGBProfile(c.byref(WHITE), c.byref(WIDE_PRIMARIES), curves)
        label = cms.cmsMLUalloc(None, 1)
        if not profile or not label:
            raise RuntimeError("Could not allocate ICC profile")
        if not cms.cmsMLUsetASCII(label, b"en", b"US", DESCRIPTION):
            raise RuntimeError("Could not set ICC description")
        if not cms.cmsWriteTag(profile, 0x64657363, label):  # 'desc'
            raise RuntimeError("Could not write ICC description tag")
        length = c.c_uint32()
        if not cms.cmsSaveProfileToMem(profile, None, c.byref(length)):
            raise RuntimeError("Could not size ICC profile")
        buf = c.create_string_buffer(length.value)
        if not cms.cmsSaveProfileToMem(profile, buf, c.byref(length)):
            raise RuntimeError("Could not serialize ICC profile")
        data = bytearray(buf.raw[: length.value])
        # Deterministic header date (2026-11-08 00:00:00 UTC) and clear profile ID.
        data[24:36] = struct.pack(">6H", 2026, 11, 8, 0, 0, 0)
        data[84:100] = bytes(16)
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_bytes(data)
        print(f"Wrote {OUT.relative_to(ROOT)}: {len(data)} bytes")
    finally:
        if label:
            cms.cmsMLUfree(label)
        if profile:
            cms.cmsCloseProfile(profile)
        cms.cmsFreeToneCurve(linear)


if __name__ == "__main__":
    main()
