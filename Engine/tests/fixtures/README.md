# Engine conformance fixtures

Made with GIMP 3.2.0 (the adapter's starting tag) by
`scripts/make-fixtures.sh GIMP_3_2_0`, which runs
[`../make-fixtures.py`](../make-fixtures.py) through libgimp in that
engine's own `gimp-console`.

| File | Content |
|---|---|
| `composite.xcf` | A text layer, a layer group holding a layer with a non-destructive Gaussian blur and a masked layer in multiply mode at 80 % opacity, and a background. |
| `composite.png` | GIMP's own composite of it: the visible layers merged in a duplicate, then exported. |
| `text-units.xcf` | A 144 dpi image with a text layer sized in points (24 pt type, 12 pt line spacing), for reading text settings back in pixels. Added later with the same GIMP 3.2.0; the two files above were kept as they were. |
| `qmask-name.xcf` | A channel named "Qmask" — the name the Quick Mask's channel reserves — beside ordinary "Saved" and "Other" channels, written while the mask was on. Made with GIMP 3.0.8 by `scripts/make-qmask-fixture.sh GIMP_3_0_8`, which runs [`../make-qmask-fixture.py`](../make-qmask-fixture.py): the engine turns the mask on when a channel takes the reserved name, and XCF stores no mask state, so every version adopts the channel as the live mask on open. |
| `indexed.png` | An 8x8 palette PNG (color type 3, four colors), for opening an indexed image through the file plug-ins. Not engine-made: written byte for byte by a deterministic Python zlib script (no engine run involved), so it never needs regenerating. |
| `profiled.png` | Two RGB pixels with a custom named sRGB ICC profile, generated data from LittleCMS by `python3 -I scripts/make-profile-fixture.py`. Repeated metadata reads and an XCF round trip must preserve its profile and pixels. No engine run or user settings are involved. |

The conformance tests open both through the adapter and require the
adapter's render of the XCF to equal GIMP's composite pixel for pixel, and
an XCF save and reopen to keep pixels and structure. The text layer's pixels
are stored in the XCF, so the comparison does not depend on installed fonts.
Regenerate only on purpose, and record the GIMP version here.

`linear-rgb.icc` and `gray.icc` are original LittleCMS-generated profiles
from `scripts/make-icc-fixtures.py`. The former uses sRGB primaries and
linear transfer curves; the latter D65 gray with a 2.2 curve. Their creation
time is fixed and optional profile ID cleared. They test profile assignment,
conversion, model compatibility and XCF persistence without system profiles.
Their bytes and mtimes are preserved (baseline recorded for the wide-gamut
display test task in `/tmp/glims-completion/wide-gamut-display-tests-original-icc.json`).

`wide-linear-rgb.icc` is an original LittleCMS-generated RGB matrix profile
created only by `python3 scripts/make-wide-icc-fixture.py` (a separate script;
it never regenerates or alters `gray.icc`/`linear-rgb.icc`). It uses explicit
wide primaries, D65 white and a linear TRC:
- Red   (.708, .292)
- Green (.170, .797)
- Blue  (.131, .046)
- White (.3127, .3290), luminance normalized (Y=1)
- TRC: linear (gamma 1.0)
This is a physical wide-primary set chosen so saturated channels lie outside
the sRGB gamut. Header date (2026-11-08 00:00:00 UTC) and profile ID (cleared)
are fixed for deterministic bytes. Created with the project LCMS at
`_deps/macports/lib/liblcms2.dylib` / `include/lcms2.h`; no network, no
downloaded assets, no engine.

`Engine/tests/display-render-tests.c` uses this fixture through the public
facade only (`image_from_pixels`, `image_assign_profile`,
`image_render_to_profile`), on a separate image, without touching the original
29 display cases. It checks: wide->same-wide direct premultiplied output
(including saturated R/G/B outside sRGB, alpha 0/partial/opaque and mixtures),
stride/prefix/suffix/row-padding guards, and post-assignment dirty/undo/redo
invariance (profile assignment is intentionally one state change). A
sensitivity oracle derives RGB->XYZ matrices from literal xyY primaries and
white, computes `inv(M_sRGB) * M_wide`, and shows wide primaries map outside
linear sRGB (clipping is not recoverable). A nonidentity wide->`linear-rgb.icc`
destination oracle uses that same independent arithmetic (no `cmsDoTransform`,
no production transform, no renderer-under-test, no LCMS transform output):
straight source samples -> matrix -> clamp to u8 contract -> premultiply alpha
-> quantize. Same D65 source/destination means PCS chromatic adaptation
cancels; ICC coefficient quantization/rounding tolerance is kept tight (<=2
u8), far below clipping loss. The mixed in-gamut sample differs materially
from identity premultiplication.

Allowed checks run here: strict facade-only Clang compile/link of
`Engine/tests/display-render-tests.c` (header only, no Core/GLib/engine
libraries; binary not executed), `python3 -m py_compile` for the new generator
and driver scripts, `python3 scripts/make-wide-icc-fixture.py` headless ICC
generation (LCMS only), and `python3 scripts/test-display-render.py --help`.
Not run (forbidden by task): `scripts/test-display-render.py` normal execution,
any engine/native/runtime/AppKit/unit/GUI/harness execution, adapter or engine
production compiler commands, and no LCMS transforms as an expected-value
oracle. Root executes engine/native/runtime later against stable private 132/135.
