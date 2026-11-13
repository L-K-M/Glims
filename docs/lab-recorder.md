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

Complete physical Lab Brush gestures use version 14. Capture keeps the value,
mask settings, actual brush identity/fingerprint and exact accepted V2 sample
batches, including absent versus zero rotation/tangential pressure. Live
painting remains available when an older engine or an unsupported brush cannot
supply replay facts; Recorder marks that row as failed. Cancel restores the
whole gesture and cannot create a replayable edit. Guarded replay checks brush
content/configuration before its first dab and cancels if a later native call
fails.

Rectangle, Ellipse and Lasso selections plus All/None/Invert use version 15.
They own their geometry, operation, antialias, feather and corner radius.
These are explicit Lab commands, independent of the selected axis, and use
no layer/axis binding. Native Lab-only replay refuses RGB and ink destinations
before changing the mask. Existing ordinary selection recordings retain their
ordinary semantics. Other Lab selection commands remain unavailable.

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


## Brush integration candidate

The initial pinned fixture passes 325 native app checks across all three axes,
precisions and mouse/tablet input. It compares captured and loaded replay with
an independent ordinary native Lab stroke, then checks Undo, cancellation,
physical settings, exact sample/batch ownership, changed brush fingerprints,
and incompatible destination role/precision/selection. The actual older
206-slot producer passes 73 fallback checks: live painting works and Recorder
refuses unavailable capture facts. All 1,714 Swift and 141 Python tests pass.
Document/replay source review is clear. Codec/fixture review, four-engine
replay checks and hosted CI remain in progress. This does not qualify an
installed app or establish complete editor parity.


## Selection integration candidate

The pinned native app fixture passes 647 checks across U8/U16/Float, all four
shape operations, three shapes and All/None/Invert. It checks actual save/load,
exact command values, root-mask binding, displayed sample/axis preservation,
Undo/Redo, and replay into a differently selected Lab axis. Independent native
selection calls supply geometry and physical-Fill coverage oracles; hard
rectangles also match a literal Boolean grid. These app checks observe coverage
at display precision, not raw floating-point mask storage. RGB and Multichannel
replay refusal preserves pixels, mask outline and history. The actual older
194-slot producer passes three capability-refusal checks. All 1,721 Swift and
141 Python tests pass; document/value review is clear. Codec/fixture review,
all-engine acceptance and release qualification remain pending.
