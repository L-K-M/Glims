# CMYK preview transform foundation

`Engine/cmyk-transform.c` is a private conversion primitive for the next CMYK
document slice. It does not expose a document mode, change the facade or route
existing image rendering through CMYK. Native CMYK editing remains unfinished.

The transform copies an exact, bounded ICC payload into its own LittleCMS
context. It accepts CMYK input, output or color-space profiles that support the
relative-colorimetric input direction; it refuses device-link and unrelated
profile classes. The fixed policy is relative colorimetric with black-point
compensation. No environment or process-global color-management setting changes.

Input contains interleaved C/M/Y/K intensity, zero for full ink and one for
paper. LittleCMS receives explicit coverage percentages, `100 * (1 - I)`.
Output is straight linear-sRGB RGBA with alpha exactly one. Linear sRGB uses
the same white point and quantization-adjusted primaries as GIMP's builtin
linear profile. A future preview must transform full-resolution samples before
forming mipmaps. It must keep these derived pixels separate from native ink
storage and the source ICC payload.

One call accepts up to 4,096 samples with fixed 256-pixel scratch buffers.
All input samples are checked before any output changes. Invalid buffers,
nonfinite intensity and intensity outside zero through one refuse with an error.
Exact in-place conversion is supported; other overlap is a caller restriction.
The owner serializes one instance. Separate instances own separate native
contexts, profiles and transforms. Caller ICC bytes may be released immediately
after construction.

## Qualification on 2026-11-12

The standalone fixture passes 23 checks against each of the four installed
engines, both optimized and with address/undefined-behavior sanitizers. It
compares 4,096 patches against an independent direct LittleCMS double-precision
CMYK-percent conversion using GIMP's separately constructed linear-sRGB output
profile. Maximum raw linear-RGB error was `0.0000115931034` in every run, below
the fixture's `0.0002` tolerance. Output alpha is exact; input samples remain
byte-exact. The fixture also covers scratch-chunk boundaries, exact in-place
conversion, caller-profile lifetime, invalid final samples without partial
writes, impossible counts and incompatible/truncated profiles.

The external `/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc` was
read in place and is not redistributed. These results qualify that profile and
the stated policy; they do not establish every vendor profile's behavior.
All four rebuilt adapters pass existing conformance. No Swift or GUI behavior
changes in this foundation, and no new app/GUI test was claimed for it.

One independent source review of the exact four implementation/test files found
no confirmed important issue. It did not execute the native libraries or assess
future document integration. Source snapshot SHA256:
`b2b76f9a600aee10313040820f9ca2be2585ee66d1a5b56c90ef718792a3a0ab`.

Reproduce with:

```sh
python3 scripts/test-cmyk-transform.py --ref GIMP_3_2_8 \
  --cmyk-profile '/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc'
python3 scripts/test-cmyk-transform.py --ref GIMP_3_2_8 --sanitize \
  --cmyk-profile '/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc'
```

Replace the engine ref for the remaining installed sets. Compilation and each
native invocation are bounded by timeouts; HOME, cache and settings use a
throwaway directory. Future storage/profile persistence, native paint, display
cache, Undo/XCF and public controls require separate integration qualification.
