# Canvas snapping controls (layer MOVE snapping)

Status: implemented as view/controller state over the pure
`CanvasSnapPlanner` (`docs/canvas-snapping.md`). Only the Move tool's
layer move snaps; crop, selection and guide gestures never snap (see
Limits). No engine/facade change: the single commit reuses the existing
counted `ImageDocument.moveActiveLayer`, one undo step.

## Slice

| File | Change |
|---|---|
| `Sources/GlimsKit/Document/CanvasSnapControls.swift` | New pure `SnapToKind`, per-window `SnapToViewState` (all OFF by default) and `SnapTargetCache` (cached-geometry assembly, moving-layer family exclusion). |
| `Sources/GlimsKit/Document/EngineCanvasView.swift` | The canvas owns its window's `snapTo` state (pure view state, redraw only). |
| `Sources/GlimsKit/Document/CanvasTools.swift` | The Move snap gesture: capture at press, plan per drag from cached state, local snapped preview + indicator lines, one commit on release, cancellation paths. |
| `Sources/GlimsKit/MainMenu.swift` | View ▸ Snap To submenu: Guides, Grid, Canvas, Layer Bounds — no key equivalents. |
| `Sources/GlimsKit/Document/DocumentWindowController.swift` | The four toggle actions, menu validation (cached state only) and close-time cancellation. |
| `Sources/GlimsKit/EngineSmokeTestSnapping.swift` | Modular `exerciseSnapping`, hooked as `GLIMS_SMOKE_CASE=snapping` and into the default full run. |
| `Tests/GlimsKitTests/SnapToControlsTests.swift` | Pure tests of the toggle policy, the target mapping and the cached-target assembly. |
| `docs/canvas-snapping-controls.md` | This document. |

## Per-window toggles

View ▸ Snap To holds four independent checkmarks, each cached per window
on its canvas (`SnapToViewState`), **all OFF by default**. Flipping an
entry is pure view state: no engine call, no pixel, dirty-flag, history,
selection, export or print change. Two windows never couple.

| Entry | Planner targets enabled |
|---|---|
| Guides | `.guide` |
| Grid | `.grid` |
| Canvas | `.imageEdge` + `.imageCenter` (the image edge and centre) |
| Layer Bounds | `.layerEdge` + `.layerCenter` (other layers' edges and centres) |

With every entry off, `targets` is empty, the planner returns
`Result.none`, and the Move tool keeps the legacy raw-delta movement.
No new modifier or keyboard shortcut exists; the existing temporary tools
are preserved (a Command-modified press is still the Move tool and snaps
the same way).

## Move gesture lifecycle

- **Press** (Move tool, not a guide hit): the active layer's id and
  bounds are snapshotted, with the window and document identity. A press
  on a visible guide still wins first (`GuideDragController`), so a guide
  drag never becomes a layer move.
- **Drag**: the proposed rect is the captured bounds plus the raw delta;
  `CanvasSnapPlanner.plan` corrects it using **cached state only** —
  `document.guides`, `document.grid`, the image size and the cached layer
  rects, with the moving layer, its ancestors and its descendants excluded
  from the other-layer candidates. No native RPC runs per drag event. The
  corrected rect is the local preview outline; each axis match draws one
  indicator line at `targetCoordinate`, clipped to the displayed image.
  Zoom, scroll and backing changes are handled by the canvas's own point
  scale (the tolerance is configured in view points).
- **Release**: exactly one `moveActiveLayer(by:)` runs — the existing
  counted document movement, one undo step — with the snapped delta.
- **Refusal before commit**: if pending work exists, a target command is
  pending, the active layer or mask/channel target changed, the captured
  bounds no longer match, the document is closing, or the window detached,
  the drag is cancelled — no stale geometry is applied and nothing is
  retargeted.
- **Cancellation**: Escape, a tool change, window close and late events
  clear the preview and indicators and commit nothing; validity re-checks
  the captured window/document identity, so events from another window or
  after close are dropped.

## Limits

- Only the layer MOVE snaps. No snapping for the crop rectangle,
  selection gestures or the guide drag itself.
- Snap targets are the cached guides, grid, image bounds and other
  layers' rects; the moving layer and its ancestors/descendants are
  excluded. No live engine reads during a drag.
- The preview and indicators are view-only: they never enter the tiles,
  export, print or the dirty flag.

## Verification

`swift build -j 2` and `swift build --build-tests -j 2` compile the
controls, the gesture and the tests. The unit tests and the
`--engine-smoke-test` snapping case were **not executed** in this
environment (compile-checked only); root runs the native UI suite with an
immutable main. The smoke case covers: real canvas move events at zoom +
scroll with snapped native bounds and exactly one undo, disabled
independence across two windows, cancel with no mutation, guide-hit first
priority, invalid/stale-bounds refusal, and the overlay not changing
export pixels.
