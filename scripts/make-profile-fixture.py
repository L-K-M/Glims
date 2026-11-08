#!/usr/bin/env python3
"""Create the two-pixel, custom sRGB-profile PNG used by adapter tests.

Uses the project's LittleCMS library; no engine or user configuration is
loaded. The profile and PNG are generated data, not third-party assets.
"""
import ctypes
from pathlib import Path
import struct
import zlib

root = Path(__file__).resolve().parent.parent
cms = ctypes.CDLL(str(root / "_deps/macports/lib/liblcms2.dylib"))
cms.cmsCreate_sRGBProfile.restype = ctypes.c_void_p
cms.cmsMLUalloc.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
cms.cmsMLUalloc.restype = ctypes.c_void_p
cms.cmsMLUsetASCII.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
cms.cmsMLUsetASCII.restype = ctypes.c_int
cms.cmsWriteTag.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]
cms.cmsWriteTag.restype = ctypes.c_int
cms.cmsSaveProfileToMem.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
cms.cmsSaveProfileToMem.restype = ctypes.c_int
cms.cmsMLUfree.argtypes = [ctypes.c_void_p]
cms.cmsCloseProfile.argtypes = [ctypes.c_void_p]

profile = cms.cmsCreate_sRGBProfile()
label = cms.cmsMLUalloc(None, 1)
if not profile or not label:
    raise RuntimeError("LittleCMS could not allocate the fixture profile")
try:
    if not cms.cmsMLUsetASCII(label, b"en", b"US", b"Glims Profile Fixture"):
        raise RuntimeError("LittleCMS could not name the fixture profile")
    if not cms.cmsWriteTag(profile, 0x64657363, label):  # profileDescriptionTag
        raise RuntimeError("LittleCMS could not write the profile description")
    length = ctypes.c_uint32()
    if not cms.cmsSaveProfileToMem(profile, None, ctypes.byref(length)):
        raise RuntimeError("LittleCMS could not size the profile")
    data = ctypes.create_string_buffer(length.value)
    if not cms.cmsSaveProfileToMem(profile, data, ctypes.byref(length)):
        raise RuntimeError("LittleCMS could not serialize the profile")
    icc = bytearray(data.raw[:length.value])
    # Stable generated data: fixed creation time and no optional profile ID.
    icc[24:36] = struct.pack(">6H", 2026, 11, 8, 0, 0, 0)
    icc[84:100] = bytes(16)
finally:
    cms.cmsMLUfree(label)
    cms.cmsCloseProfile(profile)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 2, 0, 0, 0))
png += chunk(b"iCCP", b"Glims Profile Fixture\x00\x00" + zlib.compress(icc))
png += chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\x00\xff\x00"))
png += chunk(b"IEND", b"")
target = root / "Engine/tests/fixtures/profiled.png"
target.write_bytes(png)
print(f"Wrote {target.name}: {len(png)} bytes")
