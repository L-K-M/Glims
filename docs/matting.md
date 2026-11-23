# Layer > Matting

Layer > Matting cleans the colored halo a layer keeps along its partially
transparent edge. Three commands run on the active layer: Defringe...,
Remove Black Matte and Remove White Matte. Each is one undo step named
after the operation, and the Recorder saves the operation and the
Defringe width as one row.

The command is layer-wide and ignores the selection. The halo is an edge
property of the whole layer; a selection would hide part of it and leave
a seam at the selection border. Pixels outside the layer do not exist, so
the command works in the layer's own buffer coordinates and never reads or
writes there.

## Behavior

The layer is read and written in its own pixel format changed to float
components, so its transfer curve is kept and grayscale (Y A) and RGB
(R G B A) layers both work. GIMP stores straight alpha; alpha is never
written. Pixels with alpha 0 or 1 are left exactly as they are.

Remove Black Matte divides each color channel of a partially transparent
pixel by its alpha and clamps the result to 0...1:

    C' = clamp(C / A, 0, 1)

Remove White Matte subtracts the remaining background before dividing:

    C' = clamp((C - (1 - A)) / A, 0, 1)

Defringe takes a width from 1 through 200 pixels. Every pixel with
0 < A < 1 takes the color channels of the nearest fully opaque pixel
(A == 1) within that Chebyshev distance, corner to corner. A pixel with
no opaque neighbor within the width keeps its color. Transparent and
fully opaque pixels never change, and alpha never changes. The search is
a capped two-pass chamfer feature transform over the 8-neighborhood, run
in bands of 64 rows with a width-sized halo above and below, so each
band's result is exact for the Chebyshev distance. Ties keep the earlier
candidate.

## Refusals

Every refusal changes nothing.

- An unknown image or layer, or an id that is a channel or a mask, is
  NOT_FOUND.
- An operation other than 1...3, a Defringe width outside 1...200, a
  matte width other than 0, or a layer without an alpha channel is
  INVALID_ARGUMENT. The no-alpha message is "The layer has no
  transparency to work on.".
- A group layer, an unrasterized text, link or vector layer, or an
  indexed image is refused as the one-click adjustments refuse them.
- A pixel-locked layer is LOCKED.
- A busy engine (a stroke, filter, preview or plug-in), disabled undo or
  an open undo group is BUSY.
- A layer with no pixel at 0 < A < 1 is FAILED with "The layer has no
  partially transparent edge pixels.".
- Defringe with no fully opaque pixel is FAILED with "The layer has no
  fully opaque pixels to take colors from.".
- A run that finds partial pixels but changes no value, for example a
  partial pixel that already has its opaque neighbor's color, succeeds
  and adds no undo step.

## Undo and Recorder

A change is one undo group of type Layer/Channel modification, pushed
over the exact changed-pixel damage rectangle, followed by a projection
change event. The Recorder writes a `matting` command at file format
version 34 with an owned `operation` tag (`defringe`, `removeBlackMatte`
or `removeWhiteMatte`) and, for Defringe, an integer `width` from 1
through 200. The matte commands carry no width. The row binds the
explicit layer it ran on, like Add Layer Mask. A version 34 file must
contain at least one successful matting row; older versions refuse the
tag.
