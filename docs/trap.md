# Image > Trap

Image > Trap… spreads the lighter cyan, magenta and yellow inks under darker
neighbors so that small plate misregistration shows no paper gaps. It works on
native CMYK documents only and never changes black.

## Definition

Each pixel carries four coverages c, m, y and k in 0...1. Build darkness from
them that does not depend on the display:

    R = (1 - c)(1 - k)
    G = (1 - m)(1 - k)
    B = (1 - y)(1 - k)
    L = 0.2126 R + 0.7152 G + 0.0722 B
    D = 1 - L

The luma coefficients follow Rec. 709, so darkness tracks displayed lightness
rather than an ink name. This ordering keeps yellow lighter than cyan, cyan
lighter than magenta, and every color lighter than black. Misregistration
moves one plate sideways; extending the lighter ink beneath the darker one
keeps the pair continuously covered at the boundary instead of exposing paper.

For a width w in whole pixels from 1 to 16, each pixel p considers neighbors q
inside the canvas, excluding itself, whose squared distance satisfies
(qx - px)^2 + (qy - py)^2 <= w^2. A neighbor counts as lighter only when
D(q) < D(p) - 1/512. The epsilon keeps near-equal inks, including two areas of
the same plate color and quantization noise, from spreading into each other.

For each of C, M and Y, the new coverage is the maximum of the pixel's own
coverage and the coverage of every lighter neighbor in the disk. K never
changes: it is the darkest ink and defines the image's shape, and spreading the
chroma inks beneath it hides gaps without altering that shape. Coverages only
ever grow, so nothing gets lighter and a pixel already at full ink keeps it.
A result identical to the original adds no undo step.

## Precision

U8 and U16 planes blend to nearest, half up. FLOAT keeps exact values, including
finite extended float samples. A nonfinite sample anywhere Trap reads (the
processed pixels and the width margin around them) refuses the operation
atomically before publication; nothing is sanitized. The engine stages
copy-on-write candidates under the busy gate and publishes them as one native
Undo group.

Trap works through tiles of at most 128 rows by 2048 columns plus the width
margin on every side, so its scratch memory stays near 11 MiB whatever the
canvas size, and every pixel still sees its whole disk across tile seams.

## Selection

An active selection blends each affected scalar once:
result = original + coverage x (new - original). The neighborhood still reads
unselected pixels, so a selection limits where trapping appears, not what the
kernel can see. With no selection the whole canvas traps.

## Refusals and cost

Trap refuses RGB, grayscale, Lab and multichannel documents, a pixel-locked C,
M or Y plane, a floating selection and Quick Mask. A busy engine, stroke or
filter also refuses, and cancellation discards candidates before any pixel
changes. The kernel costs O(pixels x w^2), which is why the width stops at 16
whole pixels.
