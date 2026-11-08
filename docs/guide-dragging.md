# Guide dragging (feat/guide-dragging)

Direct guide gestures on the pixel rulers and with the Move tool. One
bounded feature; no snap/grid/rotation, no new native API, no architecture
change. Native side is untouched: the gestures commit through the existing
`ImageDocument.addGuide` / `moveGuide` / `removeGuide`, each exactly one
native undo step (a same-position move keeps the native no-op with no
undo).

## Scope

- Drag from the horizontal native pixel ruler creates a **horizontal**
  guide, from the vertical ruler a **vertical** guide, at the dropped
  image-pixel position (rounded to the nearest pixel, valid range
  `0...extent` inclusive on the guide's own axis).
- The Move tool (including its Command temporary form) can drag an
  existing **visible** guide, hit within `GuideDragLogic.hitTolerancePoints`
  (8) **view points** — measured as the on-axis image distance times the
  canvas point scale, so it feels the same at every zoom/backing factor.
  Only an actual guide hit is intercepted: brush, selection, ordinary
  layer-move and pan behavior are unchanged.
- An existing guide intentionally released **outside the image** (raw axis
  coordinate `< 0` or `> extent`) is removed. A **new** guide dropped
  invalid/outside cancels with no action. Merely moving the pointer
  outside never deletes; only an intentional `mouseUp` can remove.
- During `mouseDragged` a **local view-only ghost** (dashed orange line
  with white underlay, clipped to the displayed image) is drawn by the
  canvas. **No guide/native RPC per drag event** — the gesture state is
  pure view state until the release.
- On intentional `mouseUp`, exactly **one** `addGuide`/`moveGuide`/
  `removeGuide` runs on the gesture's captured document.
- **Escape**, **tool change**, **window close** cancel and clear the ghost
  with no native metadata/pixel/history mutation. Late events after the
  window closed are ignored (captured window/document identity check).
- Guards at gesture start read **cached state only** (`acceptsEdits`:
  closing, engine busy, filter preview, plug-in, clipboard transfer,
  saving-for-close) — the same admission rules as image-metadata edits;
  **pixel locks do not block guides**, and no native UI validation call
  is made. Rulers hidden (`rulersVisible == false`) cannot begin a drag;
  hidden guides (`showsGuides == false`) cannot be hit by the Move tool.
- Gestures are **per document window**: the state lives on the window's
  `EngineCanvasView` (`guideDrag`), shared by its rulers and tool
  controller; no global controller or binding. Each gesture captures its
  `NSWindow` and `ImageDocument` at the press, so other windows or global
  front changes cannot redirect it.
- Geometry reuses the existing AppKit conversion path
  (`NSView.convert` window→canvas, `EngineCanvasView.imagePoint(at:)`)
  and the shared `CanvasGeometry` point-scale/image-rect helpers, so
  zoom, backing scale, scroll, native ruler reservation and the flipped
  canvas all come out right; no assumed vertical orientation and no
  unsafe float→integer conversion (`Int32(exactly:)` after rounding).
- The ghost is drawn in `EngineCanvasView.draw` over the cached tiles:
  it never touches export, print or engine pixels (printing uses an
  immutable PrintSnapshot). Rulers carry accessibility labels plus help
  text describing the drag and Escape; the canvas/ruler route Escape
  through `GuideDragController.keyDown`.

## Files

- `Sources/GlimsKit/Document/GuideDragging.swift` — `GuideDragLogic`
  (pure: axis coordinate, inside-image test, commit rounding, view-point
  hit test, ghost line endpoints) and `GuideDragController` (per-canvas
  gesture: begin from ruler / Move hit, drag, commit-or-cancel, cancel,
  Escape).
- `Sources/GlimsKit/Document/PixelRulerView.swift` — ruler
  `mouseDown/mouseDragged/mouseUp/keyDown` forwarding into
  `canvas.guideDrag`, first-responder for Escape, accessibility help.
- `Sources/GlimsKit/Document/EngineCanvasView.swift` — owns `guideDrag`,
  Escape routing in `keyDown`, `drawGuideGhost()` in `draw`.
- `Sources/GlimsKit/Document/CanvasTools.swift` — Move-tool guide-hit
  interception in `mouseDown`, gesture routing in `mouseDragged/mouseUp`,
  tool-change cancel in the `ToolState` observer.
- `Sources/GlimsKit/Document/DocumentWindowController.swift` —
  `windowWillClose` cancels the gesture.
- `Tests/GlimsKitTests/GuideDraggingTests.swift` — pure unit tests for
  the geometry/hit/rounding/cancel rules.
- `Sources/GlimsKit/EngineSmokeTest.swift` —
  `GLIMS_SMOKE_CASE=guide-dragging` (also in the default smoke run):
  real `NSEvent`s dispatched to the actual ruler/canvas handlers —
  horizontal+vertical creation, Move hit/move/same-position-no-op/
  delete-outside, ordinary move unchanged, hidden rulers/guides,
  Escape/tool-change/window-close/busy cancellation, per-document
  isolation, zoom+scroll+backing geometry against an independent
  frame-arithmetic oracle plus a canvas view-bitmap ghost check, exact
  one-step Undo/Redo, and unchanged native render pixels/history for
  ghosts and cancels. Controlled semaphore gates with `defer` release;
  predicate `wait`s with deadlines.

## Checks

Compiled (this branch, both allowed commands):

- `swift build -j 2` — passes.
- `swift build -j 2 --build-tests` — passes.

NOT run here (root owns runtime/Desktop/unit/native checks): `swift test`,
the app's `--engine-smoke-test` (including `GLIMS_SMOKE_CASE=guide-dragging`
and the default suite) against a real engine, adapter conformance, and any
GUI run. The smoke case is compile-checked only; its runtime assertions
(oracle tolerances, ghost bitmap colors, undo-count deltas) are unverified
until root executes them.

## Root acceptance checkpoint

An actual ruler drag beyond the image's perpendicular edge reproduced a
wrong guide creation. Drop containment now checks both image coordinates;
an existing guide dropped there is removed as one step, while a new one
cancels. Twelve pure tests and the focused pinned interface case pass.
The first run also exposed fixture errors: a zero-distance vertical guide
was ignored by the nearest-guide expectation; an ordinary layer move left
an old undo baseline; the independent frame oracle omitted flipped-view
transforms. Those are corrected, and the ghost bitmap check samples the
one-device-pixel antialiased footprint. Four-engine/full integration and
current-main adoption remain pending.
