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
  (non-RGB/malformed ICC, engine without slot 132) or FAILED (the LCMS
  profile error) — the tile falls back **once per render request** to the
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

## Test seams (narrow, read-only)

- `EngineCanvasView.destination` is `private(set)` — internal read lets the
  smoke assert which destination the view actually snapshotted.
- `EngineCanvasView.cachedTileICCData()` returns one cached tile's ICC tag
  so the smoke can prove the exact tag on rendered `CGImage`s.

## Verification status

Compile-only in this slice: `swift build -j2` and
`swift build --build-tests -j2` were run in this worktree. The pure unit
tests and the modular `exerciseDisplayDestination` smoke were **written but
not executed** (this task runs no tests/app/engine); the Root executes them.
Physical monitor calibration, LUT/device accuracy, HDR/EDR and per-call
transform performance are explicitly **not** established by this slice.
