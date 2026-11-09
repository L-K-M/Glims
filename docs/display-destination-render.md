# Display destination render (facade slot 132)

Additive native render API `image_render_to_profile` plus its typed Swift
wrapper: renders a scaled area of the composited image directly into a
caller-supplied RGB destination ICC profile, instead of the fixed sRGB
intermediate of `image_render` (which is unchanged). This slice is
native + facade + Swift wrapper only: no canvas, window, screen or
color-space selection UI, no AppKit destination policy — the caller owns
choosing (and falling back from) the destination.

## API

Slot 132, appended after `resource_duplicate` (slot 131) at the end of
`GlimsEngineAPI`; `GLIMS_ENGINE_API_VERSION` stays 1 and all previous
offsets are unchanged (purely additive within the version, per the
header's rules):

```c
GlimsStatus (*image_render_to_profile) (GlimsEngine *engine, GlimsImageID image,
                                         double scale, GlimsRect area,
                                         const uint8_t *destination_icc, size_t destination_icc_length,
                                         uint8_t *pixels, size_t stride, char **error);
```

- Same call shape and lazy projection semantics as `image_render`:
  `scale` (1.0 = one image pixel per output pixel), `area` in scaled
  pixels, caller output buffer with row `stride`. Both renderers share
  `glims_projection_prepare_read` (Engine/image.c): identical scale/area
  validation, `gimp_projection_stop_rendering` + `gimp_projection_flush_now
  (FALSE)`, the scaled/1x1 `validate_area` hot-tile shortcut, and reads
  through GEGL mipmaps. No full-image rendering.
- Output: `area.width * area.height` pixels of **premultiplied 8-bit RGBA
  (`R'aG'aB'aA u8`) in the exact destination RGB ICC space**. Tag the
  result with a color space built from the same ICC bytes.
- `destination_icc` is immutable caller memory; the native profile
  construction (`gimp_color_profile_new_from_icc_profile`) copies the
  bytes inside the synchronous call and no caller pointer is retained.
- Refusals are explicit, never a silent sRGB fallback: NULL/zero-length
  ICC, ICC above the cap, bad scale/area/stride/size → INVALID_ARGUMENT;
  malformed ICC → FAILED with the LCMS error; valid but non-RGB ICC →
  UNSUPPORTED; unknown image → NOT_FOUND. The caller chooses the fallback
  (e.g. `image_render`) outside this API.
- Read-only: allowed whenever `image_render` is allowed; no write-readiness
  gate; image pixels, profile, history and dirty state are untouched.

## Native path (Engine/display-render.c)

1. Shared preparation via `glims_projection_prepare_read`.
2. Source encoding chosen from the image's base type — `R G B A float` for
   RGB and indexed (an indexed image's projection is RGB), `Y A float` for
   grayscale — built **in the projection's own babl space**
   (`babl_format_get_space` of `gimp_projectable_get_format`), so the
   `gegl_buffer_get` read only re-encodes (premultiplied → straight,
   source precision → float) and never converts color space. The
   projection format is validated honestly (4 alpha-carrying components
   for RGB/indexed, 2 for gray); anything else is UNSUPPORTED.
3. Source profile: `gimp_image_get_color_profile`, falling back to
   `gimp_image_get_builtin_color_profile` — the same effective profile
   `image_color_info` reports. No forced default-sRGB/u8 intermediate and
   no retagging of old bytes.
4. Destination profile: owned, built per call from the ICC bytes; must be
   RGB (`gimp_color_profile_is_rgb`).
5. One `gimp_color_transform_new` per call, created/used/freed on the
   engine thread — **no cache**. The profiles alone determine the color
   spaces; the format arguments only select encodings (native contract,
   `gimpcolortransform.c` docs), so the transform runs straight float →
   straight float with alpha preserved (`cmsFLAGS_COPY_ALPHA` is added
   internally by the constructor; the babl-fish branch passes alpha). The
   source encoding is passed space-less and re-tagged with the source
   profile's space; for an image with an explicit profile that space is
   the projection's own (`layer_space` is derived from it), so no second
   conversion runs. Nonlinear ICC math never sees associated components.
6. Premultiplication happens exactly once, after the transform, via a babl
   fish inside the destination space (`R G B A float` → `R'aG'aB'aA u8`),
   row by row into the caller's stride. Alpha 0, partial and opaque pixels
   are deterministic (straight color through the transform, alpha
   unchanged, one premultiply; zero alpha → 0,0,0,0).
7. Fixed policy: relative colorimetric, flags 0 — no proofing, HDR,
   gamut-warning, BPC or user settings, and no raw native enums cross the
   facade. No global LCMS alarm codes or environment manipulation.

LUT behavior is not overclaimed: the constructor prefers a babl fish when
it can build both formats and otherwise falls back to LCMS; malformed or
unsupported profile/format combinations fail explicitly (FAILED) rather
than producing pixels.

## Adapter limits (documented caps, enforced before any allocation)

- `GLIMS_MAX_ICC_PROFILE_BYTES` = 16 MiB — keeps the length far inside
  LCMS's 32-bit size domain; never narrowed to `LCMSuint32` unchecked.
- `GLIMS_MAX_PIXEL_BUFFER_BYTES` = 512 MiB (existing shared cap) — the
  total output size `stride * (height-1) + width*4`, checked in 64-bit
  arithmetic together with int32 coordinate sums and `stride <= G_MAXINT32`
  (gegl's row stride is gint).
- `GLIMS_RENDER_TEMP_CHUNK_BYTES` = 16 MiB — rows are processed in chunks
  whose scratch never exceeds this; a single scratch row above the cap is
  INVALID_ARGUMENT. No unbounded allocation from hostile area/stride/ICC.
- All native error paths release every profile, transform and temp buffer;
  `glims_fail` consumes the `GError` (transferred with `g_steal_pointer`,
  never followed by `g_clear_error` on the same pointer).

## Swift wrapper (EngineSession.swift)

`render(_:scale:area:destinationICC:)` — a new overload next to the
untouched `render(_:scale:area:)`. It builds the matching RGB
`CGColorSpace` from the exact ICC bytes (`CGColorSpace(iccData:)`,
model checked `.rgb`; malformed/non-RGB rejected, never guessed), validates
scale finiteness, area finiteness/integrality/Int32 range, and stride/count
with Int64 overflow checks against the same 512 MiB / 16 MiB caps before
any allocation or narrowing, calls slot 132, and returns a `CGImage` tagged
with that exact space, `premultipliedLast`, 8 bpc / 32 bpp, with the output
`Data` owning its bytes for the provider's lifetime. No handles or profiles
are persisted; no window/screen/color-space selection exists in this slice.

## Standalone test

`Engine/tests/display-render-tests.c` + `scripts/test-display-render.py`
(facade-only dlopen harness, caller-provided library, throwaway
HOME/XDG_CACHE_HOME/GIMP3_DIRECTORY, read-only fixtures
`linear-rgb.icc`/`gray.icc`): independent oracles (piecewise sRGB EOTF for
the nonidentity linear destination, direct premultiply arithmetic for
alpha 0/partial/opaque and the identity case, old-renderer regression),
stride guard bytes, all refusal cases, NOT_FOUND, and dirty/undo
invariants. The script never rebuilds or replaces a library.

## What was checked in this slice, and what was NOT

Checked (this worktree, branch `feat/display-destination-render`):
- `xcrun clang -fsyntax-only` with each ref's existing
  `_engine/adapter/<ref>/compile.rsp` flags plus the facade/Engine include
  paths and the exact `GLIMS_ENGINE_TYPELIB_PATH`/`GLIMS_ENGINE_BIN_PATH`
  defines from `scripts/build-adapter.sh`, for the changed production C
  (`Engine/image.c`, `Engine/display-render.c`, `Engine/engine.c`) across
  all four refs (GIMP_3_2_8, GIMP_3_2_0, master, GIMP_3_0_8); the new test
  source with plain facade-include flags; `swift build -j2` and
  `swift build --build-tests -j2`.

NOT run (no native runtime grant in this slice; Root executes later):
- the standalone slot-132 harness and its pixel oracles — pixel
  correctness is therefore NOT established here; compilation is not
  evidence of engine behavior;
- the full engine matrix (`scripts/engine-matrix.sh`), conformance tests,
  `--engine-smoke-test`, performance: no transform cache exists yet, so
  per-call profile/transform creation cost is unmeasured — Root measures;
- LUT/matrix-profile parity between the babl-fish and LCMS branches of
  `gimp_color_transform_new` is not claimed; behavior for exotic profiles
  may differ between branches and is only bounded by the explicit
  FAILED/UNSUPPORTED refusals;
- physical display calibration, HDR/EDR, and any AppKit window/screen
  destination selection are later slices.

Remaining acceptance gaps owned by Root: runtime execution of the new
harness on all four engine sets, performance measurement of the per-call
transform creation, AppKit destination snapshot/invalidation wiring, and
all `resource_duplicate` acceptance gaps (untouched here).
