#!/usr/bin/env python3
"""Generate small original RGB/gray ICC profiles for facade conformance.

Requires the project's LittleCMS library, never initializes the engine.
The RGB profile uses sRGB primaries with linear transfer curves so assigning
it changes interpretation of midtones and conversion can preserve appearance.
"""
import ctypes as c
from pathlib import Path
import struct

root = Path(__file__).resolve().parent.parent
cms = c.CDLL(str(root / '_deps/macports/lib/liblcms2.dylib'))

class xyY(c.Structure):
    _fields_ = [('x', c.c_double), ('y', c.c_double), ('Y', c.c_double)]

class Primaries(c.Structure):
    _fields_ = [('red', xyY), ('green', xyY), ('blue', xyY)]

cms.cmsBuildGamma.argtypes = [c.c_void_p, c.c_double]
cms.cmsBuildGamma.restype = c.c_void_p
cms.cmsFreeToneCurve.argtypes = [c.c_void_p]
cms.cmsCreateRGBProfile.argtypes = [c.POINTER(xyY), c.POINTER(Primaries), c.POINTER(c.c_void_p)]
cms.cmsCreateRGBProfile.restype = c.c_void_p
cms.cmsCreateGrayProfile.argtypes = [c.POINTER(xyY), c.c_void_p]
cms.cmsCreateGrayProfile.restype = c.c_void_p
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

def save(profile, filename, description):
    label = cms.cmsMLUalloc(None, 1)
    if not profile or not label:
        raise RuntimeError('Could not allocate an ICC fixture')
    try:
        if not cms.cmsMLUsetASCII(label, b'en', b'US', description.encode('ascii')):
            raise RuntimeError('Could not name the ICC fixture')
        if not cms.cmsWriteTag(profile, 0x64657363, label):
            raise RuntimeError('Could not set the ICC description')
        length = c.c_uint32()
        if not cms.cmsSaveProfileToMem(profile, None, c.byref(length)):
            raise RuntimeError('Could not size the ICC profile')
        buffer = c.create_string_buffer(length.value)
        if not cms.cmsSaveProfileToMem(profile, buffer, c.byref(length)):
            raise RuntimeError('Could not serialize the ICC profile')
        data = bytearray(buffer.raw[:length.value])
        data[24:36] = struct.pack('>6H', 2026, 11, 8, 0, 0, 0)
        data[84:100] = bytes(16)
        path = root / 'Engine/tests/fixtures' / filename
        path.write_bytes(data)
        print(f'Wrote {path.name}: {len(data)} bytes')
    finally:
        cms.cmsMLUfree(label)
        cms.cmsCloseProfile(profile)

white = xyY(0.3127, 0.3290, 1)
primaries = Primaries(xyY(0.64, 0.33, 1), xyY(0.30, 0.60, 1), xyY(0.15, 0.06, 1))
linear = cms.cmsBuildGamma(None, 1)
gray = cms.cmsBuildGamma(None, 2.2)
if not linear or not gray:
    raise RuntimeError('Could not allocate ICC curves')
try:
    curves = (c.c_void_p * 3)(linear, linear, linear)
    save(cms.cmsCreateRGBProfile(c.byref(white), c.byref(primaries), curves),
         'linear-rgb.icc', 'Glims Linear RGB Fixture')
    save(cms.cmsCreateGrayProfile(c.byref(white), gray),
         'gray.icc', 'Glims Gray Fixture')
finally:
    cms.cmsFreeToneCurve(linear)
    cms.cmsFreeToneCurve(gray)
