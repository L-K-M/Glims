# Direct Lab Curves facade edit (slot202)

`image_curves_lab` applies one normalized 256-sample table to a captured Lab
axis as a direct physical Lab edit. It is appended after
`image_ink_snapshot_apply_curves` in facade definition order (API v1 slot 202)
and admitted for Lab component documents only.

## Contract

- `GlimsLabCurvesSettings` carries `struct_size`, captured `axis` handle,
  `role` (`GLIMS_LAB_AXIS_LIGHTNESS`, `GLIMS_LAB_AXIS_A`, `GLIMS_LAB_AXIS_B`), document-scoped `uuid[16]`, and
  `double samples[256]`.
- `samples[i]` are normalized unit table outputs in `[0,1]` for domain
  `i/255`, mapped through the private `glims_lab_curves_row` path into
  physical coordinates: `L* = 100 * sample`, `a/b = 255 * sample - 128`.
  They are not raw physical table values and do not carry ink/paper semantics.
- Canonical identity is exact `sample[i] == (double)i / 255.0`.
- The request is copied before cooperative dispatch. Target admission uses the
  same captured axis/role/UUID binding as Lab Fill (one selected axis, no
  retarget). Ordinary, CMYK and Multichannel documents refuse unchanged.
- Validation runs even on empty-selection/no-op paths; affected nonfinite float
  samples refuse; zero coverage preserves exact bytes. A full candidate is
  staged and published as one undo step only if bytes change. Busy/cancel/error
  produce no pixel or history changes.

## Implementation

- Header: `Sources/CGlimsEngine/include/glims_engine.h` (struct, slot, docs).
- Policy/definition: `Engine/facade-policy.c`, `Engine/facade-operations.def`.
- Transport/wrappers: `Engine/engine.c`, `Engine/engine-private.h`.
- Native operation: `Engine/component-edit.c` reuses the existing Lab
  `apply_component` transaction with an explicit identity-only `GlimsLabFillSettings`
  bridge for axis/role/UUID binding; `lab_curves_row` maps samples through
  `glims_lab_curves_row`.
- Shared Lab edit errors were made Lab-specific where the new path needs them.

## Tests

- `Engine/tests/lab-curves-edit-tests.c` and `scripts/test-lab-curves-edit.py`
  provide a bounded native fixture runner (same immutable-producer pattern as
  Lab Fill edit tests). Focus: all roles/precisions, constant 0.5 mapping to
  physical `L50` / `a,b -0.5` (integer nearest: U8 128, U16 32768),
  nontrivial selection coverage, identity table no-op, undo/redo, unaffected
  axes/metadata/profile/selection, and invalid size/table/axis/role/UUID
  refusals. Expected bytes are computed independently, never via production
  kernel.

## Validation status

The pinned GIMP 3.2.8 native fixture passes 1,042 checks. It includes
partial/final staging cancellation and retarget callbacks, late invalid
source/mask refusal (including identity), zero-coverage nonfinite byte
preservation, cross-mode refusal digests, a short-header guard page,
future-capacity request tails, XCF round trips and nonempty Undo/Redo history.
Other engine versions and independent review are pending.

## Not in this slice

No UI, snapshot or Recorder integration yet. This direct operation does not
by itself make Lab Curves available from the editor's adjustment panel.
