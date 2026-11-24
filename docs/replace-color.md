# Image > Adjust > Replace Color

Image > Adjust > Replace Color... shifts only the colors near one or more
sampled colors on the active layer. Eyedroppers pick the samples, Fuzziness
widens the match, and Hue, Saturation and Lightness transform the matched
colors. The canvas previews the result live; OK applies it as one undo step
named "Replace Color". Cancel and Escape change nothing.

## Targets and refusals

The command runs on one raster pixel layer. Groups, editable text, link and
vector layers are refused, as are layer masks and channels. Only ordinary RGB
documents qualify: grayscale is refused with "Replace Color is available for
RGB images only.", and indexed and component documents take the same refusal.
An active floating selection refuses until it is anchored or cancelled.

## Engine

`Engine/operation-replace-color.{h,c}` registers the adapter-owned GEGL point
filter `glims:replace-color`, next to `glims:selective-color`. Every setting
is an ordinary scalar GObject property, so effect copying and XCF persistence
keep the whole value:

- `fuzziness` double 0...200, default 40.
- `sample-count` int 0...8, default 0.
- `sample-0` ... `sample-7` colors (sRGB, default black).
- `subtract-0` ... `subtract-7` booleans, default off.
- `hue` double -180...180, `saturation` double -100...100 and `lightness`
  double -100...100, all default 0.

The operation title is "Replace Color", which becomes the undo step's name.
No facade slot is added: the app drives it through the existing
`filter_begin`, `filter_set_property` and `filter_commit` session API, like
Selective Color. A filter session's applicator mask restricts the result to
the current selection, so a selection limits the change.

## Math

The pure kernel lives in `Engine/replace-color-math.{h,c}` and has no GEGL or
GIMP dependency. `scripts/test-replace-color-math.py` compiles it with its
standalone harness optimized and under the address and undefined behavior
sanitizers. CI runs both on Linux and the optimized build on macOS, whose
hosted runners stall starting sanitizer binaries.

The per-pixel weight `w` comes from the Select > Color Range kernel:
`glims_cr_weight` with mode `GLIMS_CR_SAMPLED`, the same fuzziness and the
first `sample-count` samples, invert 0 and no selection limit. With no add
sample every weight is 0 and the operation is the identity; the dialog keeps
OK disabled until an add sample exists.

The color transform mirrors GIMP's Hue-Saturation master range exactly. The
source is `app/operations/gimpoperationhuesaturation.c` (`map_hue`,
`map_saturation`, `map_lightness` and `gimp_operation_hue_saturation_process`)
in the pinned GIMP tree, copied with overlap 0. The HSL conversion copies
babl's HSLA float conversion (`babl/extensions/HSL.c`), so the round trip
agrees with the engine's own hue-saturation operation. With the config's
`hue = H / 180`, `saturation = S / 100` and `lightness = L / 100`:

- `h' = h + hue / 2`, wrapped into 0...1.
- `s' = clamp(s * (saturation + 1), 0, 1)`.
- `l' = l * (lightness + 1)` when lightness is negative, otherwise
  `l' = l + lightness * (1 - l)`.

Then `out = in + w * (mapped - in)` per color channel. Alpha is copied
bit-for-bit. A fully transparent pixel (alpha 0) passes through unchanged,
and a pixel with a non-finite RGB channel passes through unchanged, the same
policy `selective-color-math.h` documents.

## The panel

`Sources/GlimsKit/Filters/ReplaceColorPanel.swift` subclasses
`NativeFilterPanel`, so it shares the queued property transport, the status
line and the Apply/Cancel preview lifecycle. It stays modeless so the canvas
remains clickable for the eyedroppers, and it installs the document's
`canvasSampler` hook while open. Hand, Zoom and scrolling keep working.

Controls:

- Fuzziness slider and integer field, 0...200, default 40.
- A 160 pt mask preview of the matched area, computed with
  `EngineSession.colorRangePreview` in Sampled Colors mode, the same samples
  and fuzziness, no Invert, refreshed off the main thread behind a
  generation counter.
- Three eyedroppers: plain replaces the sample list with one add sample,
  plus appends an add sample, minus appends a subtract sample. Shift-click
  acts as plus and Option-click as minus with any eyedropper. At most eight
  samples are kept.
- Hue, Saturation and Lightness sliders with typed fields.

Every change writes the changed properties to the live session: fuzziness,
the three corrections, and on a sample change `sample-count` plus the
`sample-N`/`subtract-N` rows it touched. OK commits; Cancel discards.

## Recorder

A successful OK records `SemanticImageCommand.applyReplaceColor`, title
"Replace Color", bound to the explicit layer. Files declare version 38 with
tag `applyReplaceColor`: finite `fuzziness` inside 0...200, a `samples` array
of `{red, green, blue, subtract}` objects (at most eight, at least one add),
and finite `hue`, `saturation` and `lightness`. Replay opens a fresh filter
session on the rebound layer and writes the whole settings before committing,
so the recorded row reproduces the committed pixels.
