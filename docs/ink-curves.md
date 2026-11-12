# Scalar ink Curves

The native candidate edits one selected CMYK or Multichannel ink using an owned
256-sample lookup table. Input and output are ink intensity: 0 is full ink and
1 is paper. It does not run an RGB filter on the document's display preview.
Lab Curves and the application interface are separate work.

Slots 199–201 add a direct committed edit, a preview from an existing native
ink snapshot, and snapshot Apply. Begin/End remain slots 185/188. The table
accepts nonmonotone curves, retains native U8/U16/float precision and blends
the captured selection once. The canonical identity table preserves finite
extended float samples, signed zero and subnormals byte for byte. See
[component-curves.md](component-curves.md) for interpolation and rounding.

Every preview is a separately owned image. The private calculated image is
cached by both adjustment kind and owned settings; switching Levels/Curves on
one token cannot return another adjustment's cached calculation. Source pixels,
profile, plane identities, selection, file identity and history stay unchanged.
Preview copies retain corresponding plane metadata but have their own native
handles and no source file identity.

Apply revalidates the captured source and selected ink. A changed Apply makes
one Undo step. Success, including an identity no-op, consumes the token;
refusal/cancellation retains it for retry or End. End creates no Undo step.
Source Close retires its private snapshot while already returned images remain
independently owned. Existing Levels uses the same render/apply lifecycle.

## Verification

All four engines pass 741 public-facade acceptance checks each: all three native
precisions in both ink modes; independent literal constant and nonmonotone U16
oracles; fractional selection; exact identity; repeated/edited returned copies;
Levels/Curves cache alternation; direct edit; Apply/Undo/Redo; stale source,
selection, target, lock and malformed-settings refusal; source Close and owned
image cleanup. The unchanged production code also passes existing conformance,
662 snapshot-lifecycle checks and 1,534 ink Levels checks on all four engines.
The fixture and all adapter inputs stayed unchanged throughout the matrix.

The fixture's initial compile rejected two nested callback definitions. Its
first runtime run then rejected six metadata assertions that incorrectly
compared duplicate handles/file identity to the source. The corrected assertions
check corresponding selected planes and require preview copies to shed source
file identity. A separate rational calculation supplies fixed U16 expectations.
These were fixture corrections; production code did not change for them.

Independent native, fixture and Swift transport reviews found no important
remaining issue in their bounded scopes. All 1,632 Swift and 130 Python tests
pass. Transport checks cover exact 256-sample ownership, guarded short API
prefixes, independent direct/snapshot capabilities, pre-dispatch rejection and
producer error ownership. Latest-head CI and the modeless application interface
remain separate gates. This candidate is not an installed UI feature or a
Photoshop-parity claim.

## Freehand panel candidate

Image > Adjust > Curves opens a modeless selected-ink panel for native CMYK
and Multichannel documents when snapshot capability is available. A freehand
graph edits the actual 256 samples; index/output fields edit one sample. Reset
restores exact identity. Changing the selected index never edits a sample.
Numeric drafts, including nonfinite and huge indices, must validate before
Apply or a graph gesture. Preview, Cancel and Close preserve the source;
Apply commits once and uses the same counted cleanup lifecycle as ink Levels.

All 1,644 Swift tests pass. Pinned hosted AppKit checks cover six mode/precision
combinations, real graph drags and field editors, invalid Return, queued-preview
Cancel, Reset, displayed-pixel equality against an independent Fill oracle,
Apply/Undo/Redo and Close during capture. The existing ink Levels case remains
green. Independent panel and lifecycle reviews found no important findings.
All four engines pass 174 Curves and 505 existing Levels hosted UI checks
each, with the frozen executable and unchanged adapters. Latest-head CI
remains in progress.

This first panel exposes Freehand only. Smooth point sampling and semantic
Recorder support are subsequent work; when recording is active, the edit's
Recorder row explicitly reports that Curves recording is unavailable. This
candidate has not replaced the installed, separately qualified editor.

## Smooth control-point candidate

The selected-ink panel now switches between Freehand and Smooth. Freehand to
Smooth uses nine evenly spaced sample positions, so it can approximate a drawn
curve; Smooth to Freehand retains the current table exactly. Smooth supports
point input/output fields, Smooth/Corner types, click/drag, arrow keys and
Delete. Reset restores exact two-point identity. Removing the final point
retains the last sample table. At most 256 points are accepted.

Invalid drafts remain visible and block mode/type changes and Apply. Browsing
points or leaving an unchanged rounded readout never modifies exact values.
Graph edits publish once when completed; Escape or focus loss discards the
pointer draft. Selection-only and unchanged-sample actions keep a current
preview usable. A refused insertion restores the accepted graph.

The initial helper implementation's draft-loss, rounding, keyboard ownership,
Reset and point-limit defects were reproduced by parent regression tests and
fixed before integration. The pinned actual AppKit fixture passes 243 checks,
including an independent Fill oracle for Smooth preview and committed pixels
in both ink modes at all three precisions, invalid live editors, keyboard
editing, Undo/Redo and Close. All 1,665 Swift tests passed before an additional
pointer-cancel test; that test and the 11 surrounding focused tests also pass.
The remaining engine UI matrix and latest-head CI are in progress.

Independent production review found no important issue. A later wording-only
change displays "1 point" correctly. Fixture review is in progress. This does
not qualify physical tablet input, VoiceOver, Photoshop spline equivalence or
the installed bundle, which remains separately qualified.
