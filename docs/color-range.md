# Select > Color Range

Select > Color Range… selects every pixel of the merged visible image whose
color is near one or more sampled colors, or inside a fixed hue or luma band.
It replaces the whole-image selection as one undo step named "Color Range".
Cancel and Escape change nothing.

## Source and space

The command reads the projection, never the active layer, through the same
helper `glims_image_sample_color` uses (`Engine/image.c`), in straight
nonlinear sRGB. The dialog samples with `EngineSession.sampleColor`, so a
click in the canvas or in the panel preview and the evaluated weights agree.

The weight is applied in order: a fully transparent projection pixel gets 0,
then Invert replaces w with 1 - w (so a transparent pixel is selected only
when Invert is on), then a non-empty selection multiplies w by its value at
that pixel. Indexed documents are refused; component
documents (CMYK, Lab, ink) are refused by the facade's ordinary policy.

## Math

The pure kernel lives in `Engine/color-range-math.{h,c}` and has no GEGL or
GIMP dependency. `scripts/test-color-range-math.py` compiles it with its
standalone harness under the sanitizers.

Sampled Colors maps Fuzziness F in 0...200 to a tolerance
`t = max(F / 200, 1 / 512)`, so F = 0 still matches an exact color. For a
clamped pixel p and sample s, `d = max(|pr - sr|, |pg - sg|, |pb - sb|)`.
The antialias ramp from the by-color selection is
`r = 1.5 - d / t`, `w = r <= 0 ? 0 : r < 0.5 ? 2r : 1`. Adds take their
maximum, subtracts take theirs, and `w = clamp(A - S, 0, 1)`.

The six hue ranges use HSV of the clamped color, with centers Reds 0,
Yellows 60, Greens 120, Cyans 180, Blues 240 and Magentas 300 degrees. The
circular distance `dh` gives weight 1 up to 15 degrees and falls linearly to
0 at 45. A saturation gate `clamp((sat - 0.02) / 0.08, 0, 1)` keeps grays
out. Fuzziness does not apply to fixed ranges.

Tonal ranges use luma `L = 0.299 r + 0.587 g + 0.114 b`. Shadows are 1 up to
L = 0.25 and fall to 0 at L = 0.5. Highlights are 1 from L = 0.75 and fall
to 0 at L = 0.5. Midtones are 0 outside 0.125...0.875, 1 inside
0.375...0.625, and linear between.

If every final weight is below 0.5/255, the slot refuses FAILED with
"No pixels match the color range." and changes nothing. Every malformed
settings request (unknown mode, fuzziness outside 0...200 or non-finite,
invert not 0/1, more than 64 samples, non-finite samples, a fixed mode with
samples, Sampled Colors without an add sample, a short struct) is
INVALID_ARGUMENT.

## The panel

`Sources/GlimsKit/Document/ColorRangePanel.swift` is a utility panel, not a
sheet, so the canvas stays clickable for the eyedroppers. It owns Return and
Escape, refreshes its preview off the main thread behind a generation
counter, and marks the document's `filterPreviewIsOpen` while open, so other
image edits refuse exactly as they do during a filter preview.

Controls:

- Select popup: Sampled Colors, the six hue ranges, then Highlights,
  Midtones and Shadows.
- Fuzziness slider and integer field, 0...200, default 40. Disabled for the
  fixed modes, which ignore it.
- A 200 pt preview with Selection and Image choices. Selection draws the
  engine's weight mask; Image draws the projection thumbnail the Navigator
  renders.
- Three eyedroppers: plain replaces the sample list with one add sample,
  plus appends an add sample, minus appends a subtract sample. Shift-click
  acts as plus and Option-click as minus with any eyedropper. Choosing a
  fixed mode keeps the samples for later.
- Invert, OK and Cancel. OK is disabled until the settings can produce a
  selection.

While the panel is open, `CanvasToolController.canvasSampler` routes a canvas
press to sampling before the tool runs, except for Hand and Zoom. Scrolling
and keyboard zoom are untouched.

## Facade

Slots 257 `selection_color_range` and 258 `color_range_preview` follow
`image_variations_preview`. Apply builds the full-size float mask, multiplies
by the current selection when one exists, and calls
`gimp_channel_select_buffer` with GIMP_CHANNEL_OP_REPLACE, then applies the
cached-mask workaround `select.c` documents. The preview reads a scaled
projection and returns one byte per pixel, 0...255, at most 512 on the long
side; a NULL mask queries the size. Neither slot locks anything or changes
history.

## Recorder

A successful OK records `SemanticImageCommand.colorRange`, title
"Color Range". It is target-independent like the other whole-image selection
commands and needs the `none` binding. Files declare version 36 with tag
`colorRange`: a lowerCamel `mode` string (`sampledColors`, `reds`, ...,
`shadows`), finite `fuzziness`, Boolean `invert`, and a `samples` array of
`{red, green, blue, subtract}`. Sampled Colors keeps one to 64 samples with
at least one add; a fixed mode stores none. Replay calls
`session.selectColorRange` on the receiving image's own projection.
