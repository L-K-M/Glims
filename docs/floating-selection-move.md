# Floating-selection move (existing floating selection only)

Scope of this slice: moving the pixels of an **already existing**
floating selection — by pointer Move (with or without snapping) and by
arrow-key nudges. Everything is Swift in `Sources/GlimsKit`, its smoke
case and its tests; no C/header/adapter/build-script/dependency/Rigi
changes. No automatic floating creation, no anchoring, no
detach/new-layer behavior and no target switching is introduced: the
move never resolves the floating selection.

## What is implemented

- **Captured floating-move command** — `ImageDocument.moveFloatingSelection(by:completion:)`
  (`ImageDocument.swift`). It captures the expected
  `EngineSession.FloatingState` (floating id + attachment target +
  target kind) from the document cache and the image handle, then queues
  **one counted, serial job on the document's `inputQueue` behind all
  accepted input** (`enqueue(on: inputQueue, input: true)`), so pending
  stroke/field/text input lands first and a close drains the job before
  the image is destroyed (`pendingWork` counting, `closeImageWhenDrained`).
  `endPendingUserEdits()` runs first, as for every user command, so
  in-flight field edits and an active stroke are finished/ended.
  On the worker the job reads `session.floatingSelection(image)` **fresh,
  immediately before the move**, and requires it to still equal the
  captured state exactly (`FloatingControlsLogic.floatingStateStillMatches`)
  before calling the existing `session.moveLayer(floating, image, by:)`.
  A Detach (New Layer) that converted the same id into an ordinary layer
  reports no active floating selection, so **that same id is never moved
  after conversion**; any mismatch throws and is reported visibly via
  `onError` plus the completion, with no mutation and no undo. Native
  move readiness and position locks stay authoritative (the engine's own
  refusal propagates). The command is *not* a target command: the
  floating layer remains the paint target, and the attachment (layer,
  mask or channel) and the unresolved floating state are preserved —
  the move never anchors. `moveActiveLayer` still refuses every
  unresolved floating selection with the resolve-first reason; the
  floating move goes only through this specific captured command.
- **Pointer Move** (`CanvasTools.swift`, `FloatingMoveGesture`): a Move
  press while a floating selection is active captures window, document,
  expected floating state and the floating row's bounds **even when
  every Snap To entry is off**. A guide hit under the pointer keeps
  first priority and never becomes a floating move. The whole gesture
  is local and view-only: no engine call per dragged event; the preview
  rect is the captured bounds plus the raw drag delta, corrected by the
  existing `CanvasSnapPlanner` when snapping is on (the floating layer's
  own family stays excluded from candidates) and always rounded to a
  **whole-image-pixel** translation via `SnapTargetCache.pixelMove`, so
  the displayed rect equals the committed rect. The release commits
  exactly one captured move (`FloatingControlsLogic.commitDelta`) → one
  native undo step; a same-position release follows the engine's own
  no-op semantics. A capture that is invalid (no window, closing,
  unusable bounds, inactive state) or a cancelled gesture
  (Escape / tool change / window close via `cancelFloatingMove`) keeps
  `floatingMoveWasRequested` set, so the release is **consumed and
  refuses — it never falls through to an ordinary/raw layer move**.
  Two document windows cannot retarget: validity requires the captured
  window and document to still be the canvas's own.
- **Keyboard** (`CanvasTools.keyDown`): arrow keys route to
  `moveFloatingSelection(by:)` with the usual `CanvasKeyboardPolicy.nudge`
  amount (1 px, Shift 10 px) while a floating selection is active;
  otherwise the ordinary `moveActiveLayer` path is unchanged. Mask /
  channel transform gates and ordinary single-/multi-layer policies
  are untouched.
- **Pure policy** (`FloatingControlsLogic`): `floatingMoveReadiness`,
  `floatingStateStillMatches`, `wholePixelDelta`, `commitDelta`,
  `usableMoveBounds` — all cached-state-only, no engine calls from
  validation paths, no synchronous native RPC in any new UI/menu path.
- **Smoke coverage**: new modular `Sources/GlimsKit/EngineSmokeTestFloatingMove.swift`,
  `GLIMS_SMOKE_CASE=floating-move` (also in the default full suite).
  It drives real `NSEvent`s to the actual canvas view handlers:
  capture with snap off, no native call per drag (pendingWork/undo/
  pixels unchanged mid-drag), whole-pixel preview == committed delta,
  one undo, moved rendered pixels and bounds, unchanged attachment /
  kind / selection mask / unresolved state, exact undo/redo pixels,
  arrow and Shift-arrow nudges, Escape / tool-change / window-close
  cancellation with a consumed release, snapped move via the existing
  planner on the captured FS bounds, stale same-id refusal after a
  native Detach, two documents (B front, gesture lands in A, B
  untouched), accepted stroke ordering before a queued move, close
  draining an accepted move, and the palette's Anchor / New Layer /
  Discard buttons — found by accessibility label through the recursive
  `descendant(of:as:)` helper — still resolving correctly after moves.
  Oracles are independent session reads (`floatingSelection`,
  `selectionBounds`, `copyPixels`, `render`-backed `pixel`).
- **Pure tests**: `Tests/GlimsKitTests/FloatingMovePolicyTests.swift`
  covers readiness gates, exact fresh-state matching (including the
  detached-same-id case), whole-pixel delta rounding, the
  cancel/stale release decision, capture-bounds validity, and the
  planner/pixelMove reuse on captured floating bounds.

## Queue and safety semantics

- Acceptance gates (cached only): not closing, not busy (engine
  activity / plug-in / filter preview / clipboard / close-save), no
  pending target command, multi-selection refusal, and an active cached
  floating state. Refusals report through the completion and never
  queue.
- Every queued job is counted in `pendingWork` (and `pendingInput`), so
  **every queue gate releases on all paths** through the existing
  `jobDidFinish`, and `closeImageWhenDrained` drains queued moves before
  destroying the image.
- The worker-side fresh re-read is the same-ID protection; the engine's
  own `layer_move` readiness/lock checks remain the final authority.

## Checks actually run

- `swift build -j 2` — OK ("Build complete!").
- `swift build -j 2 --build-tests` — OK.

Not run here (out of scope for this slice; root owns the serialized
runtime/native/GUI matrix): `swift test`, the `--engine-smoke-test`
runtime including `GLIMS_SMOKE_CASE=floating-move`, adapter/conformance
builds, GUI/desktop runs. The new smoke case and tests compile only.

## Deferred (root)

- No automatic anchor on tool/layer/target switches (switches stay
  resolve-first); no implicit float from a selection; no
  paint-target/alpha/pixel lock changes beyond what native translation
  already enforces.
