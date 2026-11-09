# Adjustment-layer controls (Layer ▸ New Adjustment Layer…)

The Swift UI slice over the frozen facade slot 130
(`adjustment_layer_new`, see `docs/adjustment-layer-create.md` and
`docs/adjustment-layer-tests.md`). The native signature is unchanged; no
C, header, upstream, dependency, Rigi or build-script file is touched.

## Product flow

1. **Creation sheet** (`AdjustmentLayerSheetController` in
   `Sources/GlimsKit/Document/AdjustmentLayerForm.swift`): a name field, an
   adjustment picker and Create/Cancel. Cancel before Create mutates
   nothing. The hint states simply that Create adds an adjustment layer
   and opens its parameters.
2. **Accepted Create** queues the native creation as one counted target
   command (`ImageDocument.createAdjustmentLayer`) behind accepted input,
   after this document's pending edits end. Placement is resolved from
   the fresh worker `session.layers` through `LayerTree.newGroupPlacement`,
   exactly like `createGroup`. The native call commits the layer and its
   default effect as ONE undo step and returns the actual `(layer,
   effect)` ids, which phase 2 passes to the existing modeless editor
   `DocumentWindowController.editEffectParameters(_:on:operationName:)`.
   Canceling that later parameter edit keeps the explicitly created
   adjustment layer; accepting parameter edits adds the one existing
   effect undo step. Preview/abort adds none. No second editor and no
   fake generic configuration is created; an operation with zero editable
   parameters is handled by the existing generic capability.

## Catalog read

On invocation the sheet reads the native catalog asynchronously as one
counted document job (`ImageDocument.loadNativeFilterOperations`, long
queue, `pendingWork`-counted so a close waits), installs the list into
`NativeFilterCatalog`'s cache (`install(_:)`) so `editEffectParameters`
resolves the chosen operation, and filters to the supported known set
(`AdjustmentLayerLogic.availableOperations`): Brightness/Contrast,
Exposure, Hue/Chroma, Saturation, Color Temperature, Invert — matched by
actual native name and `support == .supported`, in a stable display order,
with no unsupported fallback. A generation counter plus sheet
invalidation drop late or post-close answers. Property queries for the
editor keep running off the main thread through the catalog's queue. No
native call happens in menu validation or draw.

## Admission and lifetime

- Cached mode gate: RGB and grayscale only; Indexed is visibly disabled
  in the menu (tooltip reason) and refused in the action and the document
  until the native Indexed guard lands in the parent slice.
- Busy/closed/preview/plug-in/floating gates match `createGroup`; no
  single-layer, mask or channel target restriction, since creation only
  inserts metadata into the hierarchy.
- The sheet captures its document at open; name and operation are
  captured at acceptance, so another document becoming front cannot
  redirect the work. Create and Cancel disable while accepted work runs.
- Window close invalidates the sheet; the counted job keeps the image
  alive and the close waits for it; a host closed before completion never
  opens the editor (the committed layer stays). Failures keep the draft
  and show the native error inline.

## Files

| Path | Role |
|---|---|
| `Sources/GlimsKit/Document/AdjustmentLayerForm.swift` | Pure logic (`AdjustmentLayerLogic`) + creation sheet |
| `Sources/GlimsKit/Document/ImageDocument.swift` | `createAdjustmentLayer`, `loadNativeFilterOperations` |
| `Sources/GlimsKit/Document/DocumentWindowController.swift` | Menu action, retained sheet, phase-2 opener, validation |
| `Sources/GlimsKit/Filters/NativeFilterCatalog.swift` | `install(_:)` cache entry |
| `Sources/GlimsKit/MainMenu.swift` | The Layer menu item |
| `Tests/GlimsKitTests/AdjustmentLayerControlsTests.swift` | Pure input/menu/readiness tests |
| `Sources/GlimsKit/EngineSmokeTestAdjustmentControls.swift` | `exerciseAdjustmentControls` (wired by the root dispatcher) |

## Verification

Compile-only in this slice: `swift build -j 2` and
`swift build -j 2 --build-tests`. The modular smoke
(`GLIMS_SMOKE_CASE=adjustment-controls`) is not run here; the root
serializes runtime/native/GUI acceptance. Not covered by it: a deep
generic parameter-edit harness (the group-filter editing path already has
native check coverage) and the native Indexed backend guard, which the
parent slice owns.
