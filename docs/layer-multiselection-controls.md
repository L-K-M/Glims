# Layer multiselection controls (palette + document)

Status: implemented in the Swift interface only. No native C/header/API
change: the engine facade slots `image_select_layers` / `image_selected_layers`
(122/123, see `docs/layer-multiselection.md`) are used as they are.

## Scope

Native Shift/Command multi-selection in the Layers palette's
`NSOutlineView` (`allowsMultipleSelection = true`), a cached ordered
`ImageDocument.selectedLayerIDs` (primary first), one counted serial
input-queue write per selection, and reload/Undo/Redo reconciliation
against the engine's own read-back. Batch operations remain
**unsupported**: while `selectedLayerIDs.count > 1`, every
single-layer command refuses with an actionable "Choose one layer"
reason instead of silently acting on the primary layer alone.
Selection itself is transient: no undo step, no dirty flag, no pixel,
selection-mask or mask-pixel change.

## Primary-layer policy (explicit, tested)

`LayerSelectionPolicy` (`Sources/GlimsKit/Document/LayerSelectionPolicy.swift`)
is the single pure definition shared by the document, the palette, the
menus and the tests:

- The selection is an **ordered id list, primary first**. The engine
  keeps the first selected layer active, so the document writes the
  list primary-first through `selectLayers` and the engine's
  `selectedLayers` read-back returns exactly that order.
- The row a selection gesture **added last** becomes the primary — the
  row the user just clicked is what single-layer commands act on. The
  remaining selected rows follow in outline row order.
- A gesture that only removed rows keeps the previous primary, unless
  the primary itself was removed: then the **topmost remaining row**
  takes over.
- An emptied selection is a **refusal, never a clear**: the palette
  restores the native selection instead.

Pinned by `Tests/GlimsKitTests/LayerSelectionPolicyTests.swift` and
exercised against the engine oracle in the smoke test below.

## Document side (`ImageDocument`)

- `selectedLayerIDs: [Int32]` cached on every `reload()`, reconciled
  with `LayerSelectionPolicy.reconcile` against the ids that still
  exist — stale ids (e.g. removed by Undo) drop out, order kept.
  While a single pick (`pendingTargetPick`) or a queued multi-selection
  (`pendingLayerSelection`) is mirrored, the mirror wins; otherwise the
  engine's `selectedLayers` read-back is authoritative, so Undo/Redo
  and command completions reconcile without any native select of their
  own. `activeLayer` is the primary (`selectedLayerIDs.first`, with the
  previous first-layer fallback).
- `selectLayers(_ ids:)` validates every id against the cached layer
  list first (invalid/stale/duplicate/empty refuses with
  `targetChanged` and a refresh), keeps the resolve-first
  floating-selection gate, then queues **one counted serial
  input-queue job** (`queueLayerSelection`) that captures the
  document's own `session`/`image` — queued ids can never retarget to
  the front or a global window. The job clears the channel selection,
  calls `selectLayers(_:image:)`, and requires the read-back to equal
  the requested order exactly before reporting success. The mirror
  sets the primary active at once and mirrors the native exit from
  mask editing (`editing = false` on selected layers; mask pixels and
  flags untouched).
- Single picks keep their existing path (`selectLayer` →
  `queueTargetPick`), now also mirroring `selectedLayerIDs = [layer]`.

## Palette side (`LayersPaletteController`)

- `outlineViewSelectionDidChange` maps the **actual selected row ids**
  through the snapshot (`LayerListSnapshot.layer(for:...)`). Stale rows
  (a layer gone since the snapshot) or an emptied selection refuse:
  nothing is sent to the engine and `reload()` re-applies the native
  selection — a programmatic reload never clears the native selection,
  and all of `reload()`'s own `selectRowIndexes` run under the
  `reloading` guard, so outline reload/selection binding suppresses
  delegate mutations. A refused pick (floating selection resolve-first,
  closing, busy) leaves the document's selection elsewhere and the
  list shows it again. Effect rows keep their single-pick meaning and
  never join a layer multi-selection.
- `reload()` re-applies every selected layer's row (primary included),
  opening the parents of a changed selection inside collapsed groups
  once; rows that no longer resolve are simply not re-selected.
- Per-row edits keep targeting their captured row: visibility checkbox
  and inline rename (`changeLayer` with the row's explicit id), the
  mask thumbnail's Option-click (`toggleMaskShowing(_:)` with an
  explicit layer). Layer-thumbnail clicks stay single picks.
- Drag-drop reorder offers no drop while a multi-selection stands
  (`validateDrop`/`acceptDrop`).
- Button bar: duplicate/delete disabled under multi-selection; New
  Layer and New Layer Group stay enabled — they create and select a
  fresh row, which is safe (the engine selects it, collapsing to a
  single selection).

## Gates while `selectedLayerIDs.count > 1` ("Choose one layer")

All gated routes report
`"Choose one layer first: <action> works on a single layer, and N layers are selected."`
via `onError`/completion and never mutate anything — never silently the
first layer:

| Category | Routes |
|---|---|
| Painting | `beginStroke`, `fill`, `gradient`, `fillPattern`, `gradientResource`, `strokeSelection` (also in `strokeSelectionRefusal`), `strokePath`, `fillPath`, Clear — via `runOnPaintTarget`/explicit gates |
| Layer transforms/moves | `transformActiveLayer`, `transformLayer` on a selected layer, `moveActiveLayer`, drag-drop `moveLayer` |
| Destructive single-layer | `layerCommand` everything but `.new` (duplicate, delete, arrange, mergeDown, flatten, fitToImage, trimToContent, rasterize), `applyMask`, `deleteMask`, `addMask`, `toggleMaskEnabled`, `toggleMaskEditing`, `maskToSelection`, `toggleLocks` on the primary, `layerProperties`, `rasterizeLayerSource`/`restoreLayerSource` on the primary, `copyPixels` non-merged (Copy/Cut), ordinary `pastePixels` |
| Plug-ins / filters | `run(_ procedure:)` (would batch over all selected layers natively), `beginFilterPreview` |
| Cached admission | Layer menu items (delete/duplicate/arrange/transform/properties/locks/mask commands/resize), Edit menu Cut/Copy/Paste/Clear (Copy Merged stays), Filter/plug-in items, palette `paletteMenu` items and button bar — all disabled with the reason in the tooltip |

Allowed under a multi-selection: selection itself, Undo/Redo (with
reconciliation), New Layer / New Layer Group / text creation (fresh
row selected), per-row visibility/rename/mask-view, image-wide
operations (selection, canvas, image transforms, mode/precision), Copy
Merged, Paste Into (explicit target, resolve-first preserved), channel
operations.

## Mask-edit exit

Native multi-selection clears the transient mask EDITING flag on every
selected layer ("cannot edit masks with multiple selected layers") —
kept as genuine native behavior. It touches no mask pixels, no undo
step, no dirty flag; the smoke test pins mask thumbnail bytes,
composite pixels, `enabled`, undo count and dirty flag unchanged.

## Smoke test

`Sources/GlimsKit/EngineSmokeTestLayerMultiselection.swift`
(`exerciseLayerMultiselectionControls`), registered as the focused
selector `GLIMS_SMOKE_CASE=layer-multiselection-controls` and in the
default full suite. It drives the **actual NSOutline selection delegate
path** (`selectRowIndexes`/`deselectRow` with extension, not the cache)
on a nested-group tree and two documents, and checks every selection
against the independent `session.selectedLayers` oracle (exact ids,
primary first, not tree-row order): primary policy, queue ordering and
counting, no retarget while B is front, hidden/collapsed rows and
programmatic reload, stale-row refusal, Undo/Redo reconciliation, the
mask-edit exit without pixel/undo/dirty changes, floating-selection
resolve-first refusal, per-document palette binding, refusal of the
gated paint/move/transform/destructive commands without mutation, and
New Layer creating+selecting a fresh row. Accepted work and both
images drain before `session.stop()`.

## Checks run here

- `swift build -j 2 --build-tests` (Swift compile of sources and tests):
  **passes**.

## NOT RUN here (no engine runtime in this environment)

- `swift test` (unit tests compile; not executed).
- The app's `--engine-smoke-test`, including the
  `layer-multiselection-controls` case: run it with
  `GLIMS_ENGINE_LIBRARY` pointing at the native producer
  (`Glims-wt-layer-multiselection/.build/engine-adapters123`) on a Mac
  with the built engine. The smoke's runtime assertions (oracle orders,
  mask-pixel equality, refusal messages) are unverified until then.
- No native adapter build/link, no conformance suite, no GUI run.
