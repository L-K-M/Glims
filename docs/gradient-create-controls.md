# Gradient creation controls

Edit ▸ Create Resource ▸ Gradient… creates one saved two-endpoint gradient
from a name and two colors, through facade slot 138
(`EngineSession.createGradient`, API 1). No image, undo history, selection,
clipboard, context or committed ToolState is touched; the new gradient is
never selected and the current gradient choice never moves.

## Rules

- **Validation** (`GradientCreateValidation`, pure, unit-tested): the whole
  draft goes through the same `EngineSession.validateGradientCreation` gate
  the facade applies before its RPC — the name exactly as typed (never
  trimmed), the .ggr ASCII edge-whitespace refusal, and both endpoints with
  every component (alpha included) finite inside 0...1 (never clamped).
  Invalid field values disable Create and show the reason inline; a native
  refusal (including a duplicate name) keeps the draft for retry.
- **Colors**: the wells are seeded from the foreground/background colors
  converted to sRGB on the main thread at open. Create converts the wells to
  immutable `EngineSession.RGBAColor` values HERE on the main thread; the
  worker and the facade see plain data only, never NSColor or AppKit.
- **Gate** (cached, no native call): engine activity, running plug-in,
  closing, saving-for-close, clipboard transfer and an open filter preview.
  The catalog is global, so nothing gates on the selection, the paint
  target, layer/channel targets, a floating selection or the file state.
- **Route** (`ImageDocument.createGradient`): one counted global exclusive
  job modeled on `duplicateResource` — `EngineActivity` drains all accepted
  document input first, the outer `pendingWork` count covers the deferred
  main completion and `enqueueExclusive`'s inner count covers the job, and
  the completion runs on the main actor exactly once, including
  pre-acceptance refusals and close drains. Fields are finished and an open
  stroke ended explicitly before the drain. The optional identity lookup
  after the publish can never turn success into failure.
- **Sheet** (`GradientCreateSheetController`, retained by its
  `DocumentWindowController`): captured document, never a front-window
  retarget; invalid drafts and accepted writes gate the fields and
  Create/Cancel (Cancel only closes, with no mutation); a close after
  acceptance invalidates the sheet while the job drains on the document and
  the late completion is dropped. Layout uses a fixed content size with
  explicit control dimensions — no fittingSize content resize, so no button
  can be clipped outside the panel.
- **Chooser refresh**: after a successful create, `GradientChooser`'s
  focused `reloadCatalog()` refetches the open chooser's rows through the
  picker's stale-generation discipline (pending highlight preserved, the
  new row never auto-selected, committed choice untouched); a closed
  chooser loads the fresh catalog on its next open.

## Tests

- `Tests/GlimsKitTests/GradientCreateControlsTests.swift`: pure
  validation (name contract, edge whitespace, endpoint range), the
  NSColor→RGBA conversion, the cached gate, field acceptance/phase
  transitions and the menu wiring.
- `Sources/GlimsKit/EngineSmokeTestGradientCreateControls.swift`
  (`GLIMS_SMOKE_CASE=gradient-create-controls`, wired by root): drives the
  real menu, sheet and buttons with independent native catalog/identity
  readback — no-selection menu gate, two-document capture with the other
  window front, control bounds, invalid/edge-whitespace names, accepted
  counting with gated controls, exact typed name and authored endpoint
  colors, duplicate retry, the busy gate, Cancel, fresh and open chooser
  visibility, pixels/undo quiet, and close drain with exactly-once
  completion plus a clean late refusal.


## Root acceptance (2026-11-09)

Root completed the timed-out helper's partial implementation. The host now
invalidates and releases its sheet on close; successful publication refreshes
open choosers independently of the originating form. The RGBA data path and
counted close/drain behavior passed on all four engines. Alpha controls use
per-well support on macOS14 and later, with owned shared-panel handling on13.
The older-system UI path has source coverage, not a physical macOS13 run.

All 820 unit tests pass. Final focused controls checks pass on every engine.
The first runtime check found an oversized explanatory label; Root constrained
both labels to330points and allowed error wrapping. A test crash exposed an
attempt to activate a relation before its views had a common ancestor; fixed
constant-width constraints now pass all four runs. These final runs cover
visible field/button bounds, authored endpoint readback, duplicate retry,
Cancel/busy gates, current-choice and pixel preservation, actual host closure,
late global chooser refresh and close drain. The earlier important lifecycle
fixes and critical production bodies have independent source review; Root's
final label-only correction has the runtime geometry checks. Combined full app
and exact-head CI remain pending.
