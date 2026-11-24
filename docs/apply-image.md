# Image > Blend With Image and Image > Blend Channels

Blend With Image blends one channel (or the composite color) of an open image
into a target of another open image, or of the same image. Blend Channels
blends two single channels and puts the result somewhere new. Both are
destructive, both are one undo step, and both share one pure kernel. This
document describes the engine half: the facade slots, the math, the
channel references and the refusals. The Swift panels, menus and Recorder
rows are a later job and are listed at the end.

## Model

Blend With Image writes into `target` of `image`:

- a raster layer of `image`, or
- a saved channel of `image`.

The source is a `GlimsChannelRef`: an open image, a layer (0 means the
merged visible image), a channel kind, an optional saved-channel id and an
Invert flag. The optional mask is a second channel reference, or
`GLIMS_CHANNEL_NONE`. Every referenced image must have exactly the same
width and height as the target image.

The target changes only inside the current selection. An empty selection
means the whole canvas, as elsewhere in GIMP; a selection that misses the
target therefore succeeds and adds no undo step because every pixel is
unchanged. Partial selection values multiply the blend weight. A non-empty
mask multiplies the weight per pixel, after its own Invert.

The target alpha is never modified. Outside a source layer's bounds the
source snapshot is transparent, so those pixels contribute nothing. A
saved-channel target stores the luma of the blended RGB result; its preview
shows that gray replicated to RGB with alpha 255.

Blend Channels blends `first` as the backdrop (cb) and `second` as the source
(cs). Both must be single channels: GRAY, RED, GREEN, BLUE, ALPHA,
SELECTION or SAVED. COMPOSITE and NONE are refused. The destination is a new
saved channel of `destination_image`, that image's new selection, or a new
clean grayscale 8-bit image with one opaque layer. `destination_image` is
ignored by NEW_IMAGE.

## Math

The kernel lives in `Engine/apply-image-math.{h,c}`. It has no GEGL, GIMP or
GLib dependency beyond the facade's enums and is compiled standalone by
`scripts/test-apply-image-math.py`. Pixels are straight (non-premultiplied)
nonlinear sRGB RGBA floats in 0...1.

The separable functions B(cb, cs) follow the W3C "Compositing and Blending
Level 1" specification (<https://www.w3.org/TR/compositing-1/#blending>),
with cb the backdrop and cs the source:

| Mode | B(cb, cs) |
| --- | --- |
| Normal | cs |
| Multiply | cb x cs |
| Screen | cb + cs - cb x cs |
| Overlay | hard-light with its arguments swapped |
| Soft Light | the spec's quadratic/square-root curve |
| Hard Light | cs <= 0.5 ? 2 cb cs : 1 - 2 (1 - cb) (1 - cs) |
| Darken | min(cb, cs) |
| Lighten | max(cb, cs) |
| Difference | abs(cb - cs) |
| Exclusion | cb + cs - 2 cb cs |

Add and Subtract are this command's own extensions:

- Add: `(cb + cs) / scale + offset`
- Subtract: `(cb - cs) / scale + offset`

Scale is finite and in [1, 2]; offset is finite and in [-1, 1]. Every blend
result is clamped to [0, 1].

Per pixel the kernel applies

```
w = opacity * mask value * selection value * source alpha
out.rgb = cb + w * (B(cb, cs) - cb)
out.a = cb.a
```

Source alpha is 1 for a channel reference without alpha, so a saved channel
or selection contributes fully. Source Invert flips the source color before
blending; mask Invert flips the mask value before the selection limit.
Opacity is finite and in (0, 1].

The engine reads and writes every target through this space, whatever its
native precision, so a linear or perceptual document is converted rather
than blended in the wrong curve.

A single-plane source (RED, GREEN, BLUE, GRAY, ALPHA) is replicated to all
three color channels, so the formula runs per target channel. GRAY is luma
`(299 r + 587 g + 114 b) / 1000` on nonlinear components, the same weights
Color Range uses. COMPOSITE keeps the source's three channels. For a mask,
COMPOSITE contributes its luma as the scalar mask value.

## Channel references

`GlimsChannelKind` values: COMPOSITE (0), RED, GREEN, BLUE, GRAY, ALPHA,
SELECTION, SAVED and NONE (255).

- COMPOSITE: the RGB of a layer, or of the merged visible image when
  `layer` is 0. Effects on the layer are included, as filter-input.c reads
  captured sources; the merged image goes through the projection.
- RED, GREEN, BLUE, GRAY, ALPHA: the same layer/projection selection, then
  one plane. ALPHA is the layer's transparency, or the projection's alpha
  for the merged image.
- SELECTION: the image's selection mask; `layer` is ignored. An empty
  selection reads as zero everywhere, the same as an all-black channel.
- SAVED: the saved channel `item` of `image`; `layer` is ignored. This
  includes the Quick Mask's channel while it is on.
- NONE: only valid as the optional mask, and means "no mask".

Channel values (SELECTION, SAVED and a saved-channel target) are the
stored coverage, read and written in the channel's own curve. GIMP keeps
masks linear except saved channels of 8-bit perceptual images, which it
stores as `Y'` and copies without a gamma conversion; reading them as
linear would turn a stored 50% into about 21%.

## Refusals

Every refusal changes nothing and adds no undo step.

- INVALID_ARGUMENT: a missing or short settings struct, a channel
  reference whose `struct_size` is short, an unknown mode or channel kind,
  Invert not 0/1, NONE as a source, COMPOSITE as a Blend Channels input, an
  unknown destination, a non-finite number, opacity outside (0, 1], scale
  outside [1, 2] or offset outside [-1, 1].
- NOT_FOUND: an unknown image, an unknown or detached layer, or an unknown
  saved channel.
- UNSUPPORTED: an indexed document, a component document (Lab, CMYK,
  multichannel), a group target, or a genuine editable text, link or vector
  target/source.
- LOCKED: the target's pixels are locked.
- BUSY: a busy engine, a running stroke or filter session, a floating
  selection on the edited image, or an open undo group. NEW_IMAGE edits no
  open image, so only the engine-wide conditions apply to it. A
  NEW_SELECTION destination with Quick Mask on is BUSY with "Turn off Quick
  Mask before making a selection."
- FAILED: the referenced images differ in size. Blend With Image's message is
  "Blend With Image needs images of the same pixel size."; Blend Channels' is
  "Blend Channels needs images of the same pixel size."

A result identical to the target's current pixels is not an error: the slot
returns OK and adds no undo step. Identity is checked on the target's own
native samples after packing, so a blend that rounds to the same 8-bit
values also adds no step.

## Undo and history

Blend With Image pushes drawable undo for exactly the changed bounds, so one
undo step covers the whole edit, even when several bands change. The step
is named "Blend With Image". Undo restores the previous bytes; redo reapplies
them.

Blend Channels wraps its work in one group named "Blend Channels". NEW_CHANNEL
adds the channel and fills it inside that group. NEW_SELECTION replaces the
root mask through `gimp_channel_select_buffer` and applies the cached-mask
workaround select.c documents. A NEW_SELECTION whose result equals the
current selection within half an 8-bit step adds no step. NEW_IMAGE creates
a new image with no history and no dirty state.

## Previews

Both previews are read-only: no locks, no undo, no dirty state. They change
nothing and are allowed while other work owns the engine. Each snapshots its
inputs at full size, crops the target layer's footprint, averages it down
with a separable box filter and blends the small result; a request whose
working set would exceed the shared 512 MiB memory budget is FAILED rather
than risking memory pressure.

- `image_apply_image_preview` renders the target's blended result as
  straight-alpha sRGB RGBA 8-bit, scaled so the long side is at most
  `max_side` (1...1024) and never upscaled. A NULL buffer queries the size;
  otherwise the capacity must hold `width * height * 4` bytes. The preview
  reads the target's raw pixels, so existing layer effects are not part of
  the blended input, and it ignores the selection. A saved-channel target
  is gray replicated to RGB with alpha 255.
- `image_calculations_preview` renders the result as one byte per pixel,
  0...255, with the same scaling rule and capacity contract. It ignores the
  destination fields.

## Files

- `Engine/apply-image-math.{h,c}`: the pure kernel.
- `Engine/apply-image.c`: validation, snapshots, both commands and both
  previews.
- `Sources/CGlimsEngine/include/glims_engine.h`: the modes, channel kinds,
  settings structs and slots 261-264.
- `Engine/facade-operations.def`: the four operations, IMAGE resolver and
  ORDINARY policy.
- `Engine/engine.c`: the marshalled wrappers and policy capture.
- `Engine/tests/apply-image-math-tests.c` and
  `scripts/test-apply-image-math.py`: the standalone oracle harness.
- `Engine/tests/engine-tests.c`: `test_apply_image` and `test_calculations`.

## App

The Swift side calls slots 261-264 through `EngineSession`.

The commands are **Image > Blend With Image…** and **Image > Blend
Channels…**, with panels and undo steps of the same names; they sit in the
Image menu beside the Adjust submenu. The facade keeps its internal names
(`image_apply_image`, `image_calculations` and their settings types).

- `EngineSession.BlendMode`, `ChannelKind`, `ChannelRef`,
  `BlendImageSettings` and `BlendChannelsSettings` mirror the facade types,
  validate opacity `(0, 1]`, scale `[1, 2]`, offset `[-1, 1]`, NONE as a
  source, COMPOSITE or NONE as a Blend Channels input, and an optional mask.
  `blendImage`, `blendImagePreview`, `blendChannels` and
  `blendChannelsPreview` throw the engine's error string.
- `ImageDocument.blendImage` and `blendChannels` queue on the counted input
  queue like Color Range. Each reserves and settles the explicit unsupported
  Recorder row "Recorder does not yet save Blend With Image." / "Recorder
  does not yet save Blend Channels." because the Recorder's binding model
  cannot express a foreign image id.
- Both refusals read only cached state: RGB or grayscale ordinary documents
  only (indexed and component documents use the engine's wording), no busy
  target, no floating selection, and for Blend With Image a raster layer or
  saved channel target rather than a group, text, link or vector layer.
- `BlendImagePanel` lists every open document of the same pixel size with the
  front document first, then its layers (Merged included), channels (RGB,
  Red, Green, Blue, Gray, Alpha, Selection and saved channels by name),
  Invert, Mode, Opacity, Scale/Offset for Add and Subtract, and the optional
  mask (None or a document/layer/channel plus Invert). `BlendChannelsPanel`
  has First and Second input groups (single channels only), Mode, Opacity,
  Scale/Offset, Mask and a Result pop-up: New Channel (with an
  "Alpha N"-style name field), Selection or New Document. Both previews run
  off the main thread on the counted read queue behind a generation counter.
- A `.newImage` result reaches `AppController.open` through the document's
  `blendChannelsHandler` and opens as an untitled document.
- The `blend-image` smoke case (`GLIMS_SMOKE_CASE=blend-image`) drives two
  8x8 documents through the real menus and panels: Multiply over B into A
  within one level, one named undo step, Undo restores the bytes, a red/green
  Normal blend creates the "Alpha 1" channel, and New Document opens an
  8x8 grayscale document with one layer.
