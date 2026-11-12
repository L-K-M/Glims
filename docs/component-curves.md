# Scalar ink Curves foundation

This private numeric kernel prepares Curves for selected CMYK and Multichannel
inks. It does not enable a menu command or alter ordinary RGB Curves.

A curve contains 256 finite output intensities between 0 and 1 at uniformly
spaced inputs. Zero is full ink; one is paper. The outputs may rise or fall,
so inversion and nonmonotone curves are valid. U8 samples address the table
directly. U16 and float samples interpolate between adjacent entries without
an intermediate U8 conversion. Selection coverage blends the mapped value
with the original once, before integer rounding or float conversion.

The exact canonical identity table preserves finite input bytes, including
extended float values and negative zero. Other curves extend their endpoint
values outside the unit interval. Zero coverage preserves any source bytes;
affected nonfinite samples and invalid masks refuse the whole row before any
destination write. Exact in-place evaluation and unaligned pixel buffers are
supported. The header specifies the remaining input and ownership conditions.

`scripts/test-component-curves.sh` runs the standalone numeric checks in
optimized and ASan/UBSan builds. The kernel has no GIMP dependency and is not
linked into the adapter yet. Native captured-target preview, Apply/Undo,
Recorder and panel integration remain separate work. These semantics do not
claim Photoshop spline or numeric equivalence.
