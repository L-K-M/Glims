# Private Lab preview and storage qualification

This foundation does not enable Lab documents, menus, editing, import or
export. The sample codec is described in [lab-samples.md](lab-samples.md).
Its physical float representation has been qualified against native channel
storage; the private display primitive converts physical Lab to linear sRGB.

## Preview contract

`lab-transform.h` accepts interleaved physical binary32 L*, a*, b* and writes
linear-sRGB RGBA, with alpha exactly one. It uses the D50 reference returned
by LittleCMS (`0.9642, 1, 0.8249`) and the same adjusted sRGB chromaticities as
Glims' existing CMYK preview. A private LittleCMS context constructs the
linear profile; its D50-adapted colorants yield the inverse XYZ-to-RGB matrix.
No additional chromatic adaptation, black-point compensation, arbitrary
embedded Lab profile or look transform is applied.

The CIE inverse Lab calculation uses double intermediates. This is deliberate:
an independent LittleCMS probe with finite `FLT_MAX` L or chroma produced
infinite XYZ but a finite RGB sentinel near `-1e22`. Checking only the final
RGB for NaN/Inf would accept that result. The private primitive instead refuses
nonfinite input and any derived RGB value outside finite binary32 before
writing the row. Signed and extended RGB within that range remains intact;
it is not clipped to the display gamut. Extreme negative L can still be
representable because it uses CIE's linear branch. The authoritative sample
codec can retain values that this display primitive cannot render.

Calls accept at most 4,096 pixels. All input is validated before any output
write, including late invalid samples and output overflow. Buffers may be
unaligned, must remain alive and unchanged by other threads during the call,
and must not overlap. Conversion allocates no memory and does not mutate the
transform, so callers may share a live transform across independent buffers.
Ownership must prevent concurrent destruction.

The color equations follow the CIE Lab/XYZ relationship in
[ICC.1:2022, section 6.3.4](https://www.color.org/specification/ICC.1-2022-05.pdf).
Integer storage uses the v4 convention; it must not be confused with legacy
v2 Lab bytes or normalized floating-point intensity.

## Numeric evidence

The optimized and ASan/UBSan transform suite passes 7,800 checks. It compares
a signed/extended grid with a separately constructed LittleCMS Lab-to-linear
standard-sRGB transform, tests analytic neutral values at L=0, 8, 50 and 100,
and checks unaligned buffers, bounded batches, invalid values, output overflow,
overlap and unchanged output on failure. The maximum observed absolute RGB
difference is 0.000210524 over that grid. The oracle's standard chromaticities
and Glims' adjusted chromaticities differ slightly; the explicit per-component
tolerance is `0.0003 * max(1, abs(reference))`. This is not a bitwise equivalence
claim or a calibrated-display measurement.

Run `python3 scripts/test-lab-transform.py` and repeat with `--sanitize`.
`--deps` can select an existing dependency prefix. The runner compiles only
the private primitive and tests against LittleCMS; it starts no engine or GUI.

## Native storage evidence

A private GRAY carrier with three native scalar channels passed 155 checks on
each of GIMP 3.2.8, 3.0.8, 3.2.0 and master. Literal samples survived raw buffer
writes, one drawable Undo/Redo, duplication and XCF save/finalize/reopen exactly.
Controls include U8 chroma 128, U16 chroma 32896, physical signed chroma,
L=-5/110, chroma=-160/160, both zero signs, minimum subnormals and both signs of
`FLT_MAX`. The fixture proves that the original image was finalized and that
the reopened image/channels have fresh IDs. It does not adopt them as a public
Glims document or claim that any ink arithmetic is valid for Lab.

Public mode admission still requires its own persisted encoding, canonical
axis identities, native initialization and mode-specific operation policy.
In particular, current Ink/Paper Fill, Clear, Invert, Levels and painting
semantics must not become available just because Lab also uses scalar storage.
Conversion, alpha/layers, standard Lab interchange and user-facing controls
remain separate work.
