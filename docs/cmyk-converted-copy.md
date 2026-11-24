# Converted CMYK copies

Image > Create CMYK Copy creates a separate document from an RGB canvas.
On a CMYK document the command becomes Create RGB Copy. The original
stays open with its layers, selections, metadata and history unchanged,
and the confirmation sheet describes the copy's pixel-only scope before
starting work. The new document requires its own Save even though its
construction has no Undo steps.

The copy reads the full visible canvas at the source resolution
regardless of any selection. RGB layers contribute their merged visible
appearance; a CMYK source contributes all four authoritative ink planes.
Editable structure, paths, saved selections and other metadata stay in
the original and are not copied.

## Color contract

The RGB source accepts 8-bit, 16-bit and 32-bit float RGB using the
effective standard sRGB or linear-sRGB profile, and requires an opaque
canvas. Custom profiles must first be converted to sRGB using the
existing profile command. Native linked-layer objects, including frozen
ones, must be replaced with ordinary pixel layers: a queued file update
could otherwise change them while the conversion pauses to check for
Cancel.

RGB to CMYK runs a private LittleCMS transform from linear sRGB to the
chosen CMYK profile, relative colorimetric with black-point compensation,
inside its own context. The destination keeps the document's native ink
model: four C/M/Y/K planes where intensity 0 is full ink and 1 is paper,
at the chosen ink precision. The profile must be CMYK color space, an
output-capable class, and no larger than 4 MB.

CMYK to RGB reuses the document's stored profile through the same
relative-colorimetric, black-point-compensated path to linear sRGB and
writes one opaque layer. Float output keeps linear sRGB; 8-bit and
16-bit output encode to standard sRGB through babl so stored values
carry the correct interpretation.

Unsupported modes, grayscale, indexed, same-mode copies, transparency,
nonfinite samples and damaged CMYK storage or profile all refuse without
changing anything.

## Ownership and admission

Facade slot 265 has an owned, size-checked settings prefix and returns a
fresh image only after conversion finishes. Input settings may be
unaligned, and future tails are ignored. A missing profile for CMYK
output or a supplied profile for RGB output is INVALID_ARGUMENT. Private
component preparation constructs the candidate without publishing a
handle; cancellation or failure destroys the partial candidate and
returns no image.

Active engine work, strokes, filter previews and incomplete Undo
operations block conversion. Floating selections and Quick Mask must be
resolved first. The app rechecks cached admission after callbacks, counts
accepted source reads through Close, and treats result adoption as a
file operation through Quit. The original does not acquire an Undo step
or an unsaved-change marker.

## Verification

The code follows the Lab copy's ownership, admission and cancellation
pattern. Checked locally on GIMP 3.2.8 before merging: the engine
conformance suite with `test_cmyk_copy` (refusals publish no image, U8
and FLOAT CMYK copies, the CMYK to RGB round trip), `CmykCopyTests`,
`AlertAccessoryLayoutTests` for the sheet's popups, the `cmyk-copy`
smoke case through the real menu and sheet, and the facade policy
check. Not checked: other engine sets for this revision, and a printed
proof against a press profile.
