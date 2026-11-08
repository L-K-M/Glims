# Paint tool preset controls

Scope of this slice (branch `feat/tool-preset-controls`, on top of the
`feat/tool-preset-model` value model and store): the **controls** — one
retained presets panel for the global `ToolState`, its Tool Options entry
point, the value-based capture/apply rules, focused compile-only tests, and a
modular engine smoke scenario. No changes to the protected model/store files
(`Sources/GlimsKit/Tools/PaintToolPreset.swift`,
`Sources/GlimsKit/Tools/PaintToolPresetStore.swift`,
`Tests/GlimsKitTests/PaintToolPresetTests.swift`); those are owned by root.

Files:

| Path | Contents |
|---|---|
| `Sources/GlimsKit/Tools/PaintToolPresetControls.swift` | `PaintToolPresetControls` (pure capture/apply/lookup rules) and `PaintToolPresetPanelController` (the one retained panel) |
| `Sources/GlimsKit/Tools/ToolPalettes.swift` | the accessible `Presets…` action in Tool Options for paint tools (`addPaintRows`) |
| `Tests/GlimsKitTests/PaintToolPresetControlsTests.swift` | focused pure + panel-state tests (separate from the protected model/store tests) |
| `Sources/GlimsKit/EngineSmokeTestToolPresets.swift` | `GLIMS_SMOKE_CASE=tool-presets` scenario, hooked into `EngineSmokeTest.swift` (selector + default full run) |

## User behavior

- Tool Options shows a **Presets…** button (accessibility label `Presets…`)
  for every paint tool (`ToolID.paintTool != nil`). It opens the single
  retained `PaintToolPresetPanelController.shared` panel; there is exactly
  one panel for the global `ToolState`, no per-document replicas.
- The panel lists the stored presets in a real table (Name / Tool columns):
  by default only the **current paint tool's** presets; the explicit
  **All tools** checkbox (label `All tools filter`) transparently switches to
  every paint tool's presets.
- Controls: **Save Current**, **Rename**, **Update**, **Delete**, **Apply**,
  **Close**, a name field (`Preset name`), the deliberate **Include
  foreground color** checkbox (`Include foreground color`), and an inline
  message line (`Preset message`). Every control has an accessibility label;
  Return applies (table commit and the Apply button's key equivalent),
  Escape closes, the panel's minimum size fits all controls visibly, and the
  initial first responder is the table (keyboard focus).
- Selection is tracked **by UUID** (`selectedPresetID`), never by row index:
  reloads and reopens preserve the selection by UUID; a deleted or filtered-
  out UUID clears the selection instead of silently substituting the first
  row. Selecting a row fills the name field (unless it is being edited).

## Capture semantics

Save Current / Update capture, by value, from the current paint tool's
`ToolState.brush(for:)`:

- the tool's `ToolID` (the panel is paint-tools only),
- **every stable brush setting**: `size`, `opacity`, `pressureSize`,
  `hardness`, `rate`, `flow`, `exposure`, `tones`, `antiErase`
  (`PaintToolPresetControls.captureSettings`),
- the actual optional `ResourceIdentity` as a typed `.brush` reference
  (`captureBrushResource`); no session `ResourceID` handle is ever stored,
- the foreground color **only when the deliberate checkbox is on**, as sRGB
  primitive RGB components (`captureForeground(_:include:)`). Unchecked, the
  preset carries no color at all.

Never captured: the clone/heal `source` point (a native drawable id plus
transient coordinates), any session handle, transient target coordinates, or
the derived per-read `tool`/color fields of `Brush`.

## Apply semantics

Apply (`PaintToolPresetControls.apply(_:to:)`) on the selected preset:

1. selects the preset's tool (`ToolState.select`),
2. copies **every** stable field into that tool's brush (`ToolState.update`),
3. hands the resource identity to `ToolState.setBrushResource(_:for:)`, so
   the choice **persists through the existing brushStore path**
   (`nil` resets to the native Default brush),
4. changes the global foreground **only when the preset carries an explicit
   color**, restoring its sRGB components.

`ToolState.cloneSource` is preserved **exactly**: neither `update` nor
`setBrushResource` writes it, so the current clone/heal source point survives
an apply unchanged. A clone/heal preset therefore does **not** restore its
source point — the user sets it again with Option-click
(docs/paint-tool-presets.md); nothing claims otherwise.

The resource identity is resolved **only on the normal worker stroke** through
the existing `beginStroke` queue. A missing-resource identity remains selected
after Apply (no hidden fallback, no enumeration, no direct `EngineSession`
call from the panel) and is reported by the existing chooser/engine error
mechanisms. The panel makes **no engine calls** and never touches document
state or an in-flight stroke snapshot; a brush captured before opening or
applying is a value and stays unchanged.

## Lifetime, selection and error behavior

- The panel is retained (one instance for the app, injectable
  `ToolState`/`PaintToolPresetStore` for tests and the smoke scenario). Close
  hides the window; reopening reloads from the store and selection again
  follows UUIDs.
- Store operations (`load`/`create`/`rename`/`replace`/`delete`) are treated
  as throwing. Every failure (duplicate/empty/overlong name, unknown UUID,
  non-paint tool, unreadable or unknown-schema stored document) is shown
  **inline** as the store's actionable `PaintToolPresetError` message. A failed
  mutation never resets, replaces or rewrites the stored bytes: the panel
  keeps the last readable rows and only the message changes. `reset()` is
  never called from the panel.

## Verification status

Allowed and run in this slice: `swift build -j 2 --build-tests` (result
recorded in the commit). **Not run here** (root owns serialized runtime
execution): `swift test`, the app and `--engine-smoke-test` launches (including
`GLIMS_SMOKE_CASE=tool-presets`), any GUI run, and engine/adapter builds. The
unit tests and the smoke scenario are compile-checked only; their runtime
results were not observed in this slice.

Root acceptance: the pure capture fixture incorrectly expected optional
keys from an untouched brush; it now seeds those settings explicitly, and
all 12 capture/apply tests pass. The cross-tool UI fixture explicitly enables
All tools before selecting a different tool.

Actual controls testing reproduced a clipped Delete button, Delete hiding
its own missing-preset error after reload, and Apply using a deleted cached
preset. Buttons now reserve native bezel insets, the list stays within the
content margins, and the panel reserves space for readable errors. Delete
refreshes stale rows before showing its error. Apply rereads the store and
requires the same UUID before changing settings. Four runtime assertions
failed before the fixes; the focused pinned-engine controls scenario now
passes. Current-parent unit, four-engine and full workflow checks follow.
