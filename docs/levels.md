# Levels configuration editor

This implementation candidate has passed the native, UI and isolated
bundle checks below. Latest-head CI and merge remain separate gates.

The dedicated `gimp:levels` form edits Value, Red, Green, Blue and Alpha.
Each channel retains Low Input, High Input, Gamma, Low Output and High
Output. Endpoints use normalized 0…1 values; Gamma uses 0.1…10. Equal and
reversed endpoints are valid native mappings and are kept exactly. The
channel selector is local form state, so changing it does not modify the
native property-access cursor or discard other channels. The transfer
curve and input/output clamps apply to the entire settings value.

Every new Levels effect starts with identity channel mappings, linear
transfer curve and both clamps off across all supported engines. This is
an explicit product default: upstream3.0 and3.2 constructors do not have
identical defaults. This form has no histogram or automatic stretch.

Generic enum property writes to Levels’ operation TRC are refused, so they
cannot desynchronize the config. The older numeric setter already rejects
double-to-enum conversion. Both new and existing commits validate the
complete Levels config before freezing masks or changing native history.

The facade appends complete-value Get/Set at slots 154/155 with API version 1.
It maps its owned TRC enum by name inside the adapter. A full-value write
validates all 25 numbers, both boolean flags and the transfer curve before
mutation, privately duplicates the native config and preserves inherited
operation settings. Numeric equality, including signed-zero equality, is
an exact no-op. Get reads all five typed native arrays without moving the
live channel cursor; failures zero owned output fields while preserving
the caller's size and future tail.

On 3.2, a replacement stages the one-way configuration-to-operation TRC
binding without initial synchronization, checks its endpoints, properties
and flags, then installs the configuration/binding/TRC and notifies the
operation once. On 3.0, which has no corresponding native binding field,
the adapter explicitly synchronizes the operation TRC on prepare, copy
and Set. Generic effect-property copying skips Levels' operation TRC so
the configuration hook owns this coherent transition. Existing effects
whose operation and config TRCs disagree are refused without normalizing
or changing the live effect. Editing such legacy effects remains open.

The captured document owns counted preview work. Failed typed initial
reads abort the preview. The form keeps a complete settings draft and
tracks pending writes, accepted generations and field text. Rejected
writes cannot become the base of later edits; asynchronous replies retain
valid or invalid text still being edited. Apply first commits the active
field and then uses the shared preview finalization. Cancel preserves the
committed source effect and history. Existing effect edits retain their
position in the native filter stack.

No upstream GIMP/GEGL/babl changes, libgimp loading, mirrored private layouts
or compensating unrefs are introduced. Native Undo/XCF config setters have
a separately tracked extra-reference limitation; this change does not
claim to repair it. Narrow valid input intervals can produce extended or
nonfinite float output with clamping off; the adapter does not invent an
endpoint ordering or epsilon restriction that the native operation lacks.

## Acceptance

- The complete Swift suite passes 956 tests, including eight Levels model
  and policy tests. The first stable run observed eight obsolete catalog
  expectations fail before their intentional Levels support update.
- The initial native producers passed 1,917 general checks on each 3.2/master
  engine and 1,703 on 3.0.8; 21 focused UI checks passed on each engine.
- Independent source review found an operation-only generic TRC bypass and
  missing new-commit validation. Four regression assertions failed before
  the guards and then passed with them. The final matrix passes 492 focused
  native checks on each 3.2/master build and 475 on 3.0.8, plus their
  1,917/1,703 general checks. The legacy numeric setter’s existing conversion
  refusal is independently checked without a production change.
- UI source review found no important issue. Final native follow-up review
  accepts the guards. The final post-guard UI run passes 21 checks on each
  supported engine. The self-contained bundle passes 1,917 native and 2,520
  app checks with native and Swift build trees inaccessible.
- The 13 raw pixel oracles derive independently from the pinned operation's
  arithmetic. All 13 cases pass, with independent TRC-space checks, within
  the focused native suite. Actual image ICC and physical-display coverage
  remain separate from those standalone operation-space checks.
