# Floating-selection controls (UI slice)

Scope of this slice: the explicit Paste Into command and the
floating-resolution UI, on top of the native backend slots
(`image_floating_selection`, `image_paste_into`, `floating_command`)
added earlier. No C/header/adapter/dependency changes were made here;
everything below is Swift in `Sources/GlimsKit`, its smoke case and its
tests.

## What is implemented

- **Edit ▸ Paste Into** (`MainMenu.swift`, `ClipboardCommands.swift`,
  `ImageDocument.pasteIntoPixels`): reuses the clipboard payload pipeline
  (`ClipboardImage.readPayload`, decoded on the input queue like an
  ordinary Paste). The document, the explicit target drawable and the
  payload are captured at command time; the target is never 0 and never
  resolved as the front document or a layer-0 fallback at execution. The
  paste queues as a counted, serial target command
  (`enqueueTargetCommand`), so accepted input lands first and a close
  drains it before the image is destroyed. Menu validation
  (`canPerformClipboardCommand`, `validateMenuItem`) reads only cached
  state and shows the refusal reason as the tooltip.
- **Cached floating state**: `ImageDocument.floatingState`
  (`EngineSession.FloatingState`) is refreshed in `reload()`, which the
  undo-changed event schedules — so Paste Into, every resolution,
  Undo/Redo and history moves all refresh it.
- **Paint target**: while a floating selection is active, `paintTarget`
  is the floating layer, even when the floating selection is attached to
  a mask or channel — the previous channel-priority (and mask-editing)
  branches no longer redirect paint away from it.
- **Resolution commands**: `ImageDocument.resolveFloatingSelection`
  (Anchor / New Layer / Discard) passes the cached floating id explicitly
  as `expected`; zero/stale ids never fall back. Cached readiness
  (`FloatingControlsLogic.resolution`) gates on busy/preview/closing/
  pending-target, rechecks the target's pixel locks for Anchor (the
  native side rechecks them again after an actual resolution), refuses
  New Layer for mask/channel attachments with a reason, and refuses
  genuine editable text/link/vector targets with the rasterize-first
  reason. The New Layer tooltip is honest: detaching removes the
  selection clipping and reveals the full pasted payload, so the result
  is not necessarily identical to the clipped preview.
- **Layers palette**: the native floating row is labelled
  "(floating selection)" (`detailsSuffix(for:floating:)`); a footer bar
  (`FloatingSelectionBar`) shows Anchor / New Layer / Discard while the
  cached state is active, and the palette menu gains a Floating Selection
  submenu. Enabled state, tooltips and menu validation all read the
  cached readiness only. The structural button-bar commands are disabled
  while floating is active.
- **Resolve-first gate**: while a floating selection is active, target
  switches (`selectLayer`/`editMask`/`selectChannel`), structural
  layer/mask/channel commands, text/vector edits, ordinary Paste,
  image-wide pixel/color operations and layer moves/transforms are
  refused with the explicit resolve-first reason instead of implicitly
  anchoring. Undo/Redo stay available; painting, fills, Copy and Clear
  land on the floating layer. With no floating selection, every command
  behaves exactly as before.
- **Smoke coverage**: `GLIMS_SMOKE_CASE=floating-controls` (wired, also
  in the full suite) drives the real menu item and palette buttons:
  two-document capture, selection-clipped preview vs. unchanged target
  pixels, unchanged selection outline, explicit expected-id refusals and
  Undo/Redo cache refresh, BUSY refusal without queueing, pixel-lock
  refusals for Paste Into and Anchor, rasterize-first refusal, the
  mask/channel New Layer gates, a stroke accepted onto the floating
  layer, and close draining accepted work with a late callback failing
  cleanly. Oracles are independent session pixel/floating-state/
  selection reads plus accessibility-label queries.
- **Pure tests**: `Tests/GlimsKitTests/FloatingControlsLogicTests.swift`
  covers the cached policy (explicit target, gates, locks, mask/channel
  New Layer, tooltips).

## Deferred policies (for root)

- **No automatic anchor on tool/layer switch** — switches are refused
  resolve-first instead. Root owns any auto-anchor policy.
- **Moving the floating selection's pixels** (move/transform gestures on
  the floating layer) is not implemented; it is gated resolve-first.
- Selection-modifying commands and guides/grid metadata remain allowed
  while floating is active (they never anchor); if the engine anchors
  on any of them, root should add them to the gate list.
- The floating row is identified by label + footer only; no dedicated
  row widget, drag or rename behavior for it.
- Anchor's cached lock recheck covers the layer and the mask's owning
  layer; channel targets hold no locks.

## Checks actually run

- `swift build -j 2` — OK ("Build complete!", no warnings in the touched files).
- `swift build -j 2 --build-tests` — OK.

Not run (out of scope for this slice): `swift test`, the
`--engine-smoke-test` runtime (including `GLIMS_SMOKE_CASE=floating-controls`),
adapter/conformance builds, GUI/desktop runs. The smoke case and tests
compile only; root owns the runtime matrix.

## Root acceptance checkpoint

The first interface run exposed fixture assumptions, not native mutation:
selection_outline follows the active floating boundary; drawable thumbnails
include applied effects and the floating preview; To Layer preserves the
existing floating layer ID and row count. The fixture now compares selection
mask bounds, verifies the untouched target after Undo/Discard, and checks
successful conversion of that same row. The focused pinned run passes after
these corrections. The general clipboard is preserved and restored around
the private test payload. Nine pure policy tests also pass. Final parent
integration and four-engine/full runs remain pending.

Minimum-size acceptance reproduced clipped native button bounds in the
200 × 160 point Layers palette. The resolution controls now use a vertical
stack with enough inset for the native bezel outsets. All three complete
buttons are visible in the real minimum-size palette; the 55 focused
pinned-engine checks pass. The first small-control-only correction still
clipped Anchor by two points and was rejected by the same regression.
