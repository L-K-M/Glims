# Canvas display destination (actual-window SDR destination-ICC wiring)

One bounded slice on top of the accepted destination render
(`docs/display-destination-render.md`, facade slot 132,
`EngineSession.render(_:scale:area:destinationICC:)`): the canvas now
renders its tiles into the **actual owning window's backing color space**
instead of always using the fixed sRGB intermediate. SDR only — no HDR,
proofing, gamut warnings, transform/profile cache or destination UI.

## Files

- `Sources/GlimsKit/Document/CanvasDisplayDestination.swift` — the immutable
  snapshot/policy helper (pure classification + main-actor snapshot + the
  per-tile render dispatch with its fallback rule).
- `Sources/GlimsKit/Document/EngineCanvasView.swift` — destination state,
  observers, invalidation and the worker capture. No other production file
  changes; `EngineSession`, the facade, the adapter and Rigi are untouched.
- `Tests/GlimsKitTests/CanvasDisplayDestinationTests.swift` — pure tests of
  the helper (no window, no engine).
- `Sources/GlimsKit/EngineSmokeTestDisplayDestination.swift` —
  `exerciseDisplayDestination` (modular smoke; the shared dispatcher in
  `EngineSmokeTest.swift` wires the `GLIMS_SMOKE_CASE=display-destination`
  selector and the default-run call — Root owns that wiring).

## Destination policy (main actor only)

- The snapshot reads **only** the owning `NSWindow.colorSpace`:
  `CanvasDisplayDestination.snapshot(window:)` takes its immutable
  `iccProfileData` when the space is RGB and within 1...16 MiB
  (`GLIMS_MAX_ICC_PROFILE_BYTES`). All `NSWindow`/`NSScreen`/`NSColorSpace`
  access stays on main; the worker receives plain value-captured `Data`.
- Never guessed from `NSScreen.main`, `NSColorSpace.deviceRGB`/`.genericRGB`
  or the image's working space. The window's **specifically associated
  screen** (`window.screen`) is used only to observe profile changes
  (`NSScreen.colorSpaceDidChangeNotification` filtered to it), never as a
  pixel destination; under TN2313 a window with an unusable backing space is
  **not** overridden with a guessed monitor profile.
- Detached (no window), or a missing/non-RGB/oversized window color space:
  the explicit `.srgbFallback`, which renders through the existing
  `render(_:scale:area:)` and keeps its **real sRGB CGImage tag** — bytes are
  never relabelled.
- No profile is ever stored in a global preference; each view re-reads its
  own window. Two documents/windows are independent (per-view state).

## Render path and fallback classification

- Each queued tile captures the immutable destination together with
  image/scale/area/generation and calls
  `CanvasDisplayDestination.render(...)`, which invokes the accepted
  `render(_:scale:area:destinationICC:)`; its `CGImage` is exactly tagged
  with the destination space.
- If that call fails with an **unusable profile/transform** — UNSUPPORTED
  (non-RGB/malformed ICC, engine without slot 132) or FAILED (a profile/transform or allocation failure) — the tile falls back **once per render request** to the
  existing sRGB render. Every other error (NOT_FOUND stale image/close,
  BUSY, LOCKED/REQUIRES_RASTERIZE admission, INVALID_ARGUMENT, ...) is not a
  destination failure: it propagates through the existing
  `failedTiles`/`onError` path and is never turned into a busy retry loop.
  If the fallback render itself fails, its error propagates the same way.
- No native profile/transform cache is added; the adapter builds per call.

## Invalidation and lifetime

- Observed on main: `viewDidMoveToWindow`, `viewDidChangeBackingProperties`,
  plus notifications for the owning window's backing properties (which
  carry old/new color space per TN2313), screen moves, and the associated
  screen's profile change; `displaysWhenScreenProfileChanges` is enabled.
  Tokens are swapped on window changes and removed on detach/close
  (`stopRendering`); observation blocks capture `self` weakly — no observer
  retain cycle.
- An **ICC identity (byte) change** clears all completed tiles plus the
  stale/failed bookkeeping and bumps the generation, so in-flight renders
  for the old profile are discarded on arrival (the existing
  `generation == self.generation` gate) and never repopulate the cleared
  cache; after the drain the next tile is scheduled with the new
  destination (existing single `renderInFlight` admission — no unbounded
  overlap). A profile change at unchanged backing density still invalidates.
- **Same ICC bytes** (e.g. a density-only backing change) preserve the
  cache; the existing `backingDidChange` logic keeps image center and
  device-pixel zoom semantics.
- The synchronous smoke-only `renderVisibleTilesNow()` follows the same
  destination policy (it re-snapshots first).
- Rendering is read-only: no image pixel, profile, history, dirty, export
  or print change. No native/disk calls from `draw`/menus.

## Test seams

- `EngineCanvasView.destination` is `private(set)` — internal read lets the
  smoke assert which destination the view actually snapshotted.
- `EngineCanvasView.cachedTileICCData()` returns one cached tile's ICC tag
  so the smoke can prove the exact tag on rendered `CGImage`s.
- `EngineCanvasView.hasPendingRender` is a read-only view of the existing
  single `renderInFlight` admission — no native call, no behavior change —
  so the smoke can prove a render request is pending.
- `EngineCanvasView.enqueueRenderBarrier(_:)` enqueues one closure onto the
  existing private serial `renderQueue`, ordered after already-queued work
  and before later work. The smoke uses exactly two such barriers as
  semaphore gates; the closure runs off the main actor, touches no AppKit
  or view state, and only dispatches an "entered" callback to main and waits
  on its semaphore. Normal rendering never calls it; the queue itself is
  not exposed.

## What the modular smoke proves, and how

- **Deterministic old-profile rejection.** After the initial automatic
  rendering fully settles (condition-polled `renderedTileCount > 0 &&
  !hasPendingRender` on both windows, so no unrelated old queued result can
  contaminate the fixture), gate1 is queued and its Main-delivered entered
  callback is awaited (condition-polled; fixed sleeps are not used). With
  the owning window still at profile A, `imageDidChange` + `setNeedsRender`
  value-capture the old-profile tile request behind gate1 (`hasPendingRender`
  asserted). gate2 is queued after that request. The actual window is then
  switched to profile B while gate1 is still closed: the owning snapshot is
  B and the completed cache is 0 immediately. Releasing gate1 lets the old
  render execute and enqueue its completion to Main; the serial queue then
  reaches gate2, whose entered callback is enqueued to Main after that
  completion — so entered2 proves the old completion ran while fresh work is
  still blocked. At that point the cache is still 0 (the stale generation
  did not repopulate it), the destination is B, and `hasPendingRender` shows
  the fresh request queued behind gate2. Releasing gate2 and awaiting
  quiescence shows fresh tiles tagged with the exact new ICC. This checks
  both the synchronous cache clearing and the stale old-profile rejection
  deterministically, never by just waiting for any tile.
- **Center/density.** On the 1200x900 image in an actual 400x320 viewport
  moved to a genuinely nonzero offset (400,300) (asserted established, not
  clamped), `CanvasGeometry.imageCenter` computed with the actual clip-view
  bounds and the old backing factor gives about (600,460); after a simulated
  backing density 1→2 the center recomputed with the new actual bounds and
  factor is preserved (small tolerance), zoom stays 100, the cache count and
  its ICC tag are unchanged, and the scroll offset moved as needed. Window B
  stays independent throughout.
- **Fresh native read-only.** `session.info(imageA)`, `session.undoInfo(imageA)`
  and `session.copyPixels(imageA, merged:)` are read freshly before and
  again after all rendering; the comparison uses the native dirty flag,
  undo/redo counts and pixels — not the cached `doc.undoInfo` /
  `hasUnsavedChanges` — and proves rendering changed none of them.
- **Guaranteed teardown.** The smoke installs its two gates and owned
  canvas/window/document lists up front; a single `defer` signals BOTH gates
  unconditionally FIRST (before any drain/close, so a thrown check or early
  return cannot strand a barrier), then `stopRendering` +
  `closeImageWhenDrained` for each owned canvas/document with a
  condition-waited Main completion, closes the owned windows and removes the
  owned documents from `DocumentList`. Partial fixture creation is handled
  (only what was appended is torn down), no unrelated windows/docs are
  touched, and no native calls happen after an image close.

## Verification status

Compile-only in this slice: `swift build -j2` and
`swift build --build-tests -j2` were run in this worktree. The pure unit
tests and the modular `exerciseDisplayDestination` smoke were **written but
not executed** (this task runs no tests/app/engine; the shared smoke
dispatcher wiring in `EngineSmokeTest.swift` is Root-owned and was not run
here). The Root executes them. Physical monitor calibration, LUT/device
accuracy, HDR/EDR and per-call transform performance are explicitly **not**
established by this slice. The nil-window-colorSpace fallback path remains
an unrun runtime uncertainty that the Root decides on.

## Root runtime acceptance

All 767 unit tests pass. Every supported engine passes 27 focused window
checks; the pinned full app suite passes 1,918 checks. The initial test
incorrectly assumed assigning a nil window color space made its getter nil.
AppKit can resolve that to an actual default space: the test now follows the
getter and separately exercises a real generic-gray window's non-RGB
fallback. Partial-construction cleanup is owned immediately and both render
gates are released before teardown. Native state snapshots precede attachment
and follow final render quiescence.

One independent free Glyph source review of both complete production files
found no important issue; Root checked the current SDK notification contract.
Apple's [TN2313](https://developer.apple.com/library/archive/technotes/tn2313/_index.html)
describes tagged pixel buffers and actual window backing stores. Current
NSWindow SDK headers recommend backing-properties notifications for both
profile and resolution changes; the implementation observes those.

These checks verify wiring, identity, invalidation, selection-free rendering
and lifecycle. Wide-gamut/LUT pixel oracles, physical device accuracy,
performance, proofing, gamut warnings and HDR remain separate work.
