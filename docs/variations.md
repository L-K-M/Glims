# Image > Adjust > Variations

Image > Adjust > Variations… opens a sheet on the document window. It
accumulates Color Balance corrections for one tonal range plus a master
lightness and saturation change, shows what every click would do as a live
thumbnail, and applies the whole set to one layer as a single undo step.

## Dialog

The top row has Original and Current Pick. The ring around Current Pick
holds six color thumbnails in clockwise order from the top: More Green,
More Yellow, More Red, More Magenta, More Blue and More Cyan. The right
column has Lighter above and Darker below. Below the ring are the
Shadows/Midtones/Highlights/Saturation radio group, the Fine-to-Coarse
slider and Show Clipping.

Each thumbnail is a button with its name under it. Clicking a color
thumbnail adds one step to that correction in the chosen tonal range;
clicking again adds another. Lighter and Darker add one step to lightness
over the whole tonal range, so the Shadows/Midtones/Highlights radio does
not apply to them. In Saturation mode the ring is replaced by Less
Saturation and More Saturation, which add a negative or positive step to
saturation. Every value clamps to -1...1 after each click.

Clicking Original resets every accumulated value to zero; the chosen
range, mode and step stay where they were. OK is disabled while the
settings are identity (all values zero), and Cancel changes nothing.
Original itself shows the unmodified layer, so it is a one-click way back
to the start.

The Fine-to-Coarse slider has seven positions with steps 0.02, 0.03,
0.05, 0.08, 0.12, 0.18 and 0.25, defaulting to the fourth position
(0.08). A step is a fraction of the native Color Balance slider range.

## Mapping

The dialog's math lives in `Sources/GlimsKit/Document/VariationsModel.swift`,
a pure value type with no AppKit. More Red adds +step to `cyanRed`, More
Cyan adds -step to it, More Green +step to `magentaGreen`, More Magenta
-step, More Blue +step to `yellowBlue` and More Yellow -step, all in the
selected range. Lighter/Darker add ±step to `lightness`. Saturation mode
adds -/+step to `saturation`.

## Applying

Facade slots 255 and 256 carry the command. `image_variations_apply`
validates the settings, the image, the explicit layer (an attached RGB
pixel layer, not a group, mask or channel, rasterized and not
pixel-locked), the selection overlap, the absence of a floating selection
and an idle engine before touching anything. Identity settings are
INVALID_ARGUMENT with "Variations has no change to apply.".

A successful call opens one undo group named "Variations", applies
`gimp:color-balance` with Preserve Luminosity on when any of the three
ranges is nonzero, then `gimp:hue-saturation` with the master range's
lightness and saturation (hue 0, every other range zero) when either is
nonzero, closes the group and flushes the image. `gimp_drawable_apply_operation`
honors the image selection, so both operations are bounded by it. Undo
restores the layer and redo reapplies it.

Only ordinary RGB documents qualify. Grayscale, indexed, Lab, CMYK and
ink-channel documents refuse with the reason in the menu item's tool tip.
The same refusal covers groups, editable text/link/vector layers, locked
pixels, a selection that misses the layer, a floating selection and a
busy engine.

## Preview and clipping

`image_variations_preview` renders the layer's own thumbnail exactly as
the Layers palette does, at most the requested size (1...256) on the long
side, straight-alpha sRGB RGBA 8-bit, never upscaled. Passing a NULL pixel
buffer queries the size only; `clipping` is then ignored. The preview ignores the selection and allows
identity settings, which reproduce the plain thumbnail.

The same two operations run in the same order on a float copy, quantized
back to the 8-bit grid between them so an 8-bit layer's destructive result
matches. `clipping` is optional, one byte per pixel: 255 where any final
RGB channel lies below -0.5/255 or above 1 + 0.5/255 before 8-bit
conversion, 0 otherwise. Show Clipping overlays those pixels in a vivid
color on each thumbnail. Thumbnail requests run off the main thread with a
generation counter, so a stale result is dropped rather than painted.

## Recorder

A successful OK records `SemanticImageCommand.applyVariations`, bound to
the explicit layer like the other layer adjustments. The file format writes
an `applyVariations` command at version 35 with a `settings` object holding
`shadows`, `midtones`, `highlights` (each `cyanRed`, `magentaGreen`,
`yellowBlue`), `lightness` and `saturation`. Every value must be finite in
-1...1 and the identity is refused. Version 35 requires at least one
successful Variations row; earlier versions refuse the tag. Replay calls
the same facade slot, so it is one undo step.
