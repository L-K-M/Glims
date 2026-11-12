# Native ink Levels foundation

The additive `image_levels_ink` operation applies one scalar Levels mapping to
the explicit sole selected CMYK or Multichannel ink channel. It retains the
document's native U8, U16 or float precision. This foundation does not yet enable
a Levels panel for ink documents; a frozen-source preview is the next step.

Intensity zero is full ink and one is paper. Input endpoints normalize the
sample; equal endpoints subtract the low endpoint instead. An optional input
clamp precedes gamma, which maps positive values with `pow(value, 1/gamma)`.
Output endpoints and optional output clamping follow. The current selection
blends that proposal with the original once. Integer output is bounded and
rounded half upward; float output retains representable extended values.
Zero selection coverage preserves the exact original bytes, including nonfinite
samples. Invalid affected samples or arithmetic overflow refuse atomically.

The shared native edit transaction snapshots the selection and stages tiles
before publishing. Busy ownership, read access and cooperative cancellation
match Fill/Clear/Invert. It revalidates the explicit target and lock before one
native Undo and a non-yielding changed-region copy. Identity makes no Undo.
Other ink planes, component UUIDs, source profile, visibility and file identity
remain unchanged. Recorder and a modeless preview are separate integrations.

## Validation

The pure kernel passes 131,713 checks in both optimized and ASan/UBSan builds.
Independent oracles cover exhaustive integer identity, rational mappings,
gamma, weighted selections, extended float, exact cancellation, clamps and
subnormal input spans. Cancellation, half-tie rounding and subnormal-span
regressions were observed failing before correction. An exact dyadic Fraction
probe also passes 18,000 cases. Arbitrary decimal endpoint calculations retain
normal floating-point rounding limits near half ties.

Each of all four engine sets passes 1,534 native Levels checks, including
independent raw samples, exact Undo/Redo, six mode/precision XCF save/reopens,
locks, invalid targets/settings, and cancellation before publication. Each also
passes the existing 1,314 scalar edit checks and 39 ownership/cancellation
checks, plus general adapter conformance. Independent numeric and integration
reviews found no remaining confirmed important findings. Latest CI is a
separate merge gate. No live-preview, installed-build or Photoshop 4 parity
claim follows from this foundation.
