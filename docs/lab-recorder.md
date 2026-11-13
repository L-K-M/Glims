# Physical Lab Recorder commands

Recorder captures committed physical Lab Fill and Curves as version 13
recordings. Fill preserves the signed physical value and opacity. Curves
preserves all 256 normalized samples; their physical meaning comes from the
bound L*, a* or b* axis, never from RGB or paper-intensity ink semantics.

Each binding retains an owned role, u8/u16/float precision and document-scoped
UUID. Live capture confirms the original axis on the ordered engine queue.
Replay requires that same axis to remain selected and validates its UUID and
precision again before editing. Native operations retain their ordinary
selection coverage, edit restrictions and one-Undo behavior.

Loading into another document requires an explicit choice of a matching axis
and precision. The binding sheet offers only compatible Lab axes, with no
automatic selection. The recorded source identity remains in the saved file;
the installed runtime context retains the destination's own identity. Batch
name matching refuses Lab commands. Unsupported precision, changed selection,
wrong role and missing targets fail before the affected edit.

The strict file codec rejects unknown fields, invalid values, inconsistent
per-symbol identities and mixed Lab/ink identity for one symbol. Integer
Fill values stay inside the nominal physical range; float Fill may use finite
values representable by Float. Existing recording versions remain readable.

This slice covers Fill and Curves. Lab brush strokes and Lab selection changes
still produce explicit unsupported Recorder rows; they are not replayable.

## Verification in progress

The pinned native app fixture passes 355 checks across three precisions and
all three axes, including actual binding-sheet choices and Cancel, file
save/load, explicit destination binding, role/precision/selection refusals,
independent physical Fill pixel comparisons, replay and Undo. Initial runtime
checks reproduced a generic channel-reader refusal; capture descriptions,
installation membership and the picker now use the typed Lab axis API.

All 1,687 Swift tests pass after the production fix. Five focused file-value
tests additionally check the final malformed-file cases. The codec review is
clean. The original document review missed the channel-reader defect; a
separate post-fix source check covers the corrected paths. Four-engine app
checks, hosted CI and combined release qualification remain pending. This is
not evidence that the installed app includes this slice.
