# Physical Lab Levels

This candidate adds Levels for the selected L*, a*, or b* channel. The panel
shows physical endpoints: L* 0–100, a*/b* −128–127. Gamma ranges from 0.1 to 10.
Input and output clamps are independent. Equal or reversed endpoints are
accepted deliberately; equal input endpoints use one nominal axis interval
as the transfer denominator. The display does not change untouched settings.

The native calculation uses owned normalized double endpoints, physical float
samples, and one final mask blend/quantization. Integer samples use their full
8/16-bit precision. Affected nonfinite samples or unrepresentable float output
refuse the whole transaction. Exact identity and zero coverage preserve raw
sample bytes, including signed zero. Extended finite float values survive
when neither the transfer nor requested clamps change them.

Slots 210–212 add direct Levels, preview render and snapshot Apply. Shared
Lab snapshot Begin/End retain the selected role, UUID, precision, all axis
bytes, root selection and metadata. Preview returns an independent owned copy.
Apply stages the full edit, compares the captured baseline, then publishes
one Undo operation. Cancel, stale targets, failed calculation, unavailable
Undo and foreign Undo groups leave source pixels unchanged. Native Undo
admission is checked both before staging and after progress callbacks.

The app uses the same captured preview lifecycle as Lab Curves, with explicit
adjustment-kind guards. Close and Cancel invalidate pending replies and drain
owned copies/tokens. The ordinary RGB and native ink routes remain separate.
Recorder version 17 preserves full settings with explicit Lab bindings;
only successfully accepted settings become a replayable command.

## Checks so far

- All 1,755 Swift tests pass. The pinned actual-window app fixture passes 375
  checks across all roles and precisions, including visible preview oracles,
  invalid physical drafts, Apply/Undo, Cancel/close and actual disk Save/Load.
  Explicitly rebound loaded recordings replay in a separate document, match
  the independent physical oracle, and undo in one step.

- 7,442 optimized and ASan/UBSan pure-C checks; 23,064 comparisons against an
  independent rational oracle. Unaligned settings and invalid-format alias
  regressions reproduced and fixed before the passing run.
- 1,576 native checks on each of four engines, including all roles and precisions, physical
  transfer/mask expectations, XCF, Undo/Redo, stale metadata/pixels, cancellation,
  disabled/frozen/grouped Undo and progress-time Undo-state changes.
- An actual older 209-slot producer refuses the missing capability before
  startup; guarded-prefix transport coverage is additional evidence.
- Independent numeric/native and Swift lifecycle reviews. The native review
  found the Undo-admission gap, now reproduced and fixed. Final app, codec
  review is complete; four-engine app and hosted CI checks remain pending.

The native fixture's first normalized affine oracle introduced cancellation
residue for near-neutral chroma, including exact identity. Its corrected
expectations use physical affine algebra and retain strict byte comparisons;
failed logs remain preserved. No tolerance hides those failures.

Run `python3 -I scripts/test-lab-levels.py` for the pure checks and
`python3 -I scripts/test-lab-levels-edit.py --ref GIMP_3_2_8 --adapter-root PATH
--output NEW_DIRECTORY` for the native fixture. No notarization or full
Photoshop 4 equivalence is claimed by this slice.
