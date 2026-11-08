# Float Selected Pixels (Select menu controls)

Scope of this slice: the two Select ▸ Float commands on top of the native
`selection_float` slot (121) added earlier (`docs/float-selected-pixels.md`).
No C/header/adapter/dependency changes were made here; everything below is
Swift in `Sources/GlimsKit`, its smoke case and its tests, plus this doc.

## What is implemented

- **Select ▸ Float Selected Pixels (MOVE) and Select ▸ Float a Copy (COPY)**
  (`MainMenu.swift`, `Document/FloatSelectionCommands.swift`). Both are
  plain menu items with **no keyboard shortcut**. The controller action
  drains field/text edits and ends an active stroke first, then captures
  the document, the explicit target drawable and the mode at command time
  and calls `ImageDocument.floatSelectedPixels(mode:target:)` — the queued
  work never falls back to the front document or a layer-0 target. A cached
  refusal is shown in the status bar with a beep; there is no silent
  fallback to another target or mode.
- **Counted, serial target command**
  (`ImageDocument.floatSelectedPixels`): the float queues through
  `enqueueTargetCommand` on the document's input queue, so accepted input
  (including the field commits and the stroke end enqueued just before it)
  drains first and a close waits for the counted job before the image is
  destroyed. The completion's `reload()` makes the cached floating state
  and the paint target authoritative again — the floating layer becomes
  `activeDrawable` while active, as with Paste Into.
- **Cached readiness** (`FloatingControlsLogic.floatTarget`, read through
  `ImageDocument.floatReadiness`): menu validation and the command both
  read only cached state — never the engine — and gate on: not
  busy/closing/preview/save/clipboard (`acceptsEdits`), no pending target
  change, no existing floating selection (resolve-first, never a silent
  anchor), a non-empty cached selection, exactly one selected layer (a
  multi-selection refuses with the choose-one-layer reason), and an
  explicit target id (never 0). The target admission mirrors the native
  preflight: groups refuse; a genuine editable text/link/vector **layer**
  refuses rasterize-first in both modes — the source gate applies to the
  layer's own pixels only, never to its mask or a channel; channels of the
  image's channel list and layer masks are valid targets. MOVE additionally
  honors the target's effective pixel and alpha locks (and, for a mask
  target, the owning layer's pixel lock); COPY is non-destructive and
  checks no locks — the native anchor rechecks them at resolution time.
- **Tooltips** state cut-vs-copy and the selection clear: MOVE "cuts the
  selected pixels out of the target … transparent hole … selection is
  cleared"; COPY "a copy … target is unchanged … selection is cleared".
  Both modes clear the selection mask (the engine owns that); MOVE cuts
  the source, COPY preserves it.
- **Menu validation** (`DocumentWindowController.validateMenuItem`): both
  items enable only when the cached readiness allows; the tooltip carries
  the refusal reason, or the mode's cut-vs-copy copy when allowed.
- **Existing FS bar reused**: a float result is an ordinary floating
  selection, so the Layers palette's Anchor / New Layer / Discard footer,
  the floating row label and the resolve-first gates behave exactly as for
  Paste Into. No move gesture and no auto-anchor were added: while a
  floating selection is active, target switches and layer moves refuse
  resolve-first like the other structural commands.
- **Ordinary Copy/Paste and the multi-selection gates are untouched**:
  Copy/Cut/Paste validation still goes through
  `canPerformClipboardCommand`, Paste Into keeps its explicit-target gate,
  and the Lock toggles keep their `LayerSelectionPolicy` gates.

## Smoke coverage

`GLIMS_SMOKE_CASE=float-selected-pixels` (`EngineSmokeTestFloatSelectedPixels.swift`,
also wired into the full suite) drives the real menu items: menu presence
with empty shortcuts, two-document capture (the command lands in A while B
is front), native pixel/floating-state/selection-bounds oracles, exactly one
undo step, the selection clear, undo/redo restoring selection + pixels and
the same floating id, MOVE's transparent hole after Discard vs COPY's
untouched source, queued stroke input drained before the float (two ordered
undo steps), pixel/alpha lock refusals for MOVE with COPY still allowed,
the choose-one-layer refusal under a multi-selection, rasterize-first on a
genuine text target, mask and channel attachments with explicit target
kinds, BUSY refusal with nothing queued, close draining the accepted float
with a late callback failing cleanly, and the floating-selection footer bar
showing and resolving. Ordinary Copy validation is checked alongside.

## Pure tests

`Tests/GlimsKitTests/FloatSelectedPixelsPolicyTests.swift` pins the cached
policy: explicit-id requirement, all gates, group refusal, the
structured-source gate on layer targets only (not mask/channel), MOVE's
pixel+alpha lock refusals vs COPY's non-destructive allowance, the mask
owner lock gate, and the tooltips' cut-vs-copy + selection-clear copy.

## Checks actually run

- `swift build -j 2` — OK ("Build complete!").
- `swift build --build-tests -j 2` — OK.

Not run (out of scope for this slice; root owns the runtime matrix):
`swift test`, the `--engine-smoke-test` runtime (including
`GLIMS_SMOKE_CASE=float-selected-pixels`), adapter/conformance builds, GUI/
desktop runs. The smoke case and the pure tests compile only.
