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
| `Sources/GlimsKit/EngineSmokeTestViewOverlays.swift` | New modular `exerciseViewOverlays` in the smoke-extension style; Root wired its focused selector and full-suite dispatcher. |
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

## Acceptance checks

The first pure run reproduced three invalid-extent failures because CGRect
width/height accessors standardize negative sizes. Validation now checks raw
origin/size and finite far edges. Fifteen geometry/state tests pass, including
device-center stroke alignment and full-image edges at 1x and 2x backing.
The nonorigin 32×28 layer fixture distinguishes layer/mask bounds from its
64×48 image's channel bounds.

All 681 unit tests/build checks pass. All 28 focused overlay checks pass on
every supported engine, including real menu actions, independent windows,
busy toggling, layer/mask/channel/floating targets, native selection retained
while edges hide, and unchanged pixels/history/dirty state. The combined
pinned app passes 1,728 checks. Completed independent acceptance-fix source
review found no important issue.

The aligned line has a one-device-pixel geometric width. Pixel-perfect screen
coverage and tiny subpixel boundaries remain visual verification limits;
alignment can collapse very small rectangles to zero extent. Final editor
bundle and whole-editor on-screen verification are separate.
