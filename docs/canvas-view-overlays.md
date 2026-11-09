# Canvas view overlays (Show Selection Edges, Show Layer Boundary)

Status: implemented as per-window cached display controls. No engine,
facade, native-header, dependency or Rigi change; no global preference,
controller or `UserDefaults` write — each document window caches its own
two flags, and the flags survive a document reload because the canvas
view outlives `ImageDocument.reload()`.

## Slice

| File | Change |
|---|---|
| `Sources/GlimsKit/Document/CanvasViewOverlays.swift` | New: `SelectionEdgesViewState` (default ON), `LayerBoundaryViewState` (default OFF) and the pure `LayerBoundaryGeometry` helper (target-to-rect resolution, view-rect mapping, 1-physical-pixel line width). |
| `Sources/GlimsKit/Document/ImageDocument.swift` | New cached read `cachedPaintTargetBounds`, resolved from the private cached `paintTarget` plus the `layers`/`info` caches. |
| `Sources/GlimsKit/Document/EngineCanvasView.swift` | `showsSelectionEdges` / `showsLayerBoundary` documented as the per-window caches; `drawLayerBoundary` rewritten to the cached paint-target rect at 1 physical pixel, dashed, clipped to the canvas frame. |
| `Sources/GlimsKit/Document/DocumentWindowController.swift` | The two per-window view states, the toggle actions (push to the canvas, set the sender's checkmark) and menu validation reading the cached state, enabled unless the document is closing. |
| `Sources/GlimsKit/MainMenu.swift` | (Pre-existing) View ▸ Show Layer Boundary and View ▸ Show Selection Edges, no key equivalents. |
| `Tests/GlimsKitTests/CanvasViewOverlaysTests.swift` | Pure tests: defaults, mask/channel/floating precedence, missing-target clearing, invalid extents, zoom/backing mapping. |
| `Sources/GlimsKit/EngineSmokeTestViewOverlays.swift` | New modular `exerciseViewOverlays` in the smoke-extension style; the shared `EngineSmokeTest.swift` dispatcher is Root-owned and untouched. |
| `docs/canvas-view-overlays.md` | This document. |

## Show Selection Edges

- Default ON. The View item's checkmark reads the window's cached
  `SelectionEdgesViewState`; flipping it only stops/starts the
  marching-ants drawing. The native selection, `selectionBounds`,
  `selectionOutline`, selection admission/policy, floating behavior and
  every painting/selection command are untouched — hiding edges over a
  nonempty selection leaves the native bounds in place.
- No shortcut by default (`keyEquivalent == ""`).
- The ants timer is gated on `showsSelectionEdges` in the canvas's
  existing `updateAntsTimer()`: hidden means no timer and no tick work;
  showing again restores the unchanged cached contour.
- The menu item stays enabled whenever the document is not closing —
  including while the engine is busy — and neither the action, the draw
  nor the validation makes an engine or disk call.

## Show Layer Boundary

- Default OFF. The outline is a dashed rect exactly **1 physical pixel**
  wide (`LayerBoundaryGeometry.deviceLineWidth` = point scale / render
  scale = 1/backing factor), drawn in view points through the canvas's
  own zoom/backing scale, clipped to the canvas frame (a floating
  selection's bounds can reach past the image edge). White underlay plus
  black dash so it reads on light and dark images.
- The rect is resolved from the **current cached paint target**
  (`ImageDocument.paintTarget`) on every draw via
  `ImageDocument.cachedPaintTargetBounds`:
  - ordinary layer → the layer's absolute cached bounds;
  - editing mask → the owner layer's bounds (not the mask drawable);
  - selected channel → the image bounds;
  - active floating selection → the floating layer's actual cached
    bounds (floating wins ahead of channel/mask targets, as in
    `paintTarget` itself).
- Nil when no target is current or its cached bounds are missing/invalid
  (non-finite or non-positive extents): the draw simply shows nothing
  rather than a previous/remembered unrelated layer.
- Pure overlay: no engine read is added to draw or validation, and it
  never paints raster pixels — export and print use the engine
  projection / an immutable PrintSnapshot, never this view.

## Checks actually run (this branch)

- `swift build -j 2` — Build complete (GlimsKit + product).
- `swift build -j 2 --build-tests` — Build complete (incl.
  `CanvasViewOverlaysTests` and `EngineSmokeTestViewOverlays`).

## Explicitly UNRUN

- `swift test` / any unit-test runtime: not allowed in this task; the new
  pure tests compile but were not executed here.
- `EngineSmokeTestViewOverlays.exerciseViewOverlays`: compiles only. No
  `GLIMS_SMOKE_CASE` selector or dispatch entry was added — that wiring in
  the shared `EngineSmokeTest.swift` is Root-owned. Runtime behavior
  (menu dispatch, checkmarks, busy toggling, boundary geometry per
  target, reload persistence, cleanup) is therefore unverified at
  runtime; the renderer source (`EngineCanvasView.draw` →
  `drawLayerBoundary` / `drawSelectionOutline`) is the evidence for the
  later visual review.
- No app launch, `--smoke-test`, engine build, adapter or bundle check.
