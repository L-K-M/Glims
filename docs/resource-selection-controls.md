# Resource-selection controls (UI slice)

Scope of this slice: the document-owned creation controls Edit ▸ Create
Resource ▸ **Brush from Selection…** / **Pattern from Selection…** (no
shortcuts), on top of the existing facade slot 129
(`resource_create_pixels`, `EngineSession.createResource`, see
[`resource-pixel-create.md`](resource-pixel-create.md)). No C/header/
upstream/dependency/Rigi changes; everything below is Swift in
`Sources/GlimsKit`, its modular smoke case and its pure tests. No resource
clone/rename/delete/gradient creation, no ToolState/ResourceIdentity/
foreground/background changes.

## What is implemented

- **Menu**: `MainMenu.swift` adds the `Create Resource` submenu to Edit with
  both items, plain entries (no key equivalent). `DocumentWindowController`
  owns `createBrushFromSelection(_:)` / `createPatternFromSelection(_:)`
  and validates both in `validateMenuItem` from cached state only, with the
  refusal reason as the tooltip.
- **Sheet** (`Sources/GlimsKit/Document/ResourceSelectionForm.swift`,
  `ResourceSelectionSheetController`): per-window (retained by the owning
  `DocumentWindowController`, never a singleton), capturing the document and
  the creation kind at open. Fields: name, brush spacing (hidden for
  patterns), a plain-language scope line ("selected visible merged pixels of
  the document; soft selection edges count; pixels, selection, history and
  clipboard are not changed"), Apply/Cancel, inline message — all with
  accessibility labels. The draft stays editable on local and native errors,
  including a duplicate name. Apply/Cancel are gated while an accepted
  write is active (`ResourceSelectionFormValidation.Phase`); the sheet
  closes only on the accepted write's success. Window close invalidates the
  sheet (`isInvalidated`), so a late completion after acceptance cannot
  resurrect UI.
- **Cached gate** (`ImageDocument.createResourceRefusal(kind:)`): reads only
  cached state — engine activity, plug-in, closing, save-for-close, clipboard
  transfer, filter preview, and the root selection mask bounds
  (`selectionBounds`: any nonzero mask value counts, including soft coverage
  below the marching-ants threshold, which has bounds but no outline). No
  gate keys on the paint target, source kind or layer locks: the capture
  reads the merged image, valid for any target. Menu validation and sheet
  open/accept use this cache; no main-thread native calls.
- **Exclusive flow** (`ImageDocument.createResourceFromSelection`): local
  pure validation (name/spacing, the slot-129 pre-RPC rules) before queueing,
  then the established end-field-edits/end-own-stroke pattern, then one
  counted `EngineActivity.perform` job that drains ALL accepted input of
  every document globally before native work. `pendingWork` stays counted
  through the deferred main completion stage, so a close waits for the whole
  job. On the worker: a fresh native `selectionBounds` check (actual nonempty
  selection required — no full-image fallback) and the >10000 px per-side
  dimension refusal BEFORE `copyPixels(image, merged: true)` allocates
  (the private `gimp_selection_extract`, cut FALSE — never the system
  clipboard), then `createResource` (slot 129: private resource, persisted
  then published). The completion runs on the main actor exactly once with
  the created id/name/kind; the optional identity query is `try?` and can
  never turn a successful publish into a failure. Pre-acceptance refusals
  call the completion synchronously with nothing queued; accepted busy/native
  failures come back once through the completion and `onError`, and the
  sheet shows them with the draft preserved.
- **Pure rules** (`ResourceSelectionFormValidation`): name (nonempty UTF-8,
  no NUL, no Cc controls, ≤255 UTF-8 bytes), spacing (brush whole 1…1000,
  pattern 0, gradient unsupported), selection admission (nil/oversized
  refusal), cached menu gate, and the sheet phase machine — all unit-tested
  without windows or engine.
- **Choosers**: no cache change needed. `BrushChooserPanel` and
  `ResourcePickerController`/`PatternFillPicker` load the FULL catalog from
  the engine (`session.resources(_:)`) through `EngineActivity` every time
  they open (`load()` at presentation), so a newly created resource is
  listed the next time the relevant chooser opens — source-backed, no
  main-thread native call, no invalidation hook required.

## Source checkpoints

- `EngineSession.createResource(kind:name:pixels:brushSpacing:)` (slot 129)
  and `validateResourceCreation`, `resourceMaxDimension` (10000),
  `resourceNameMaxUTF8Bytes` (255) — `Engine/EngineSession.swift`; native
  `glims_image_copy_pixels` merged path bounds come from the selection mask
  and extract with `gimp_selection_extract(..., cut=FALSE, ...)`
  (`Engine/clipboard.c`); `glims_selection_bounds` reports nonempty for any
  nonzero mask value via `gimp_channel_is_empty` (`Engine/select.c`).
- `EngineActivity.perform` drains every registered document's `inputQueue`
  before `work` runs; `ImageDocument.enqueueExclusive`/`jobDidFinish` keep
  `pendingWork` counted through deferred main completions
  (`Document/EngineActivity.swift`, `Document/ImageDocument.swift`).
- Sheet pattern follows `StrokeSelectionSheetController`
  (`Document/StrokeSelectionForm.swift`); menu validation follows the
  `strokeSelection(_:)` case in `DocumentWindowController.validateMenuItem`.

## Smoke coverage (compile-only here; root wires and runs it)

`Sources/GlimsKit/EngineSmokeTestResourceSelection.swift` provides
`EngineSmokeTest.exerciseResourceSelection(session:work:documents:)`
(`GLIMS_SMOKE_CASE=resource-selection-controls`, root-owned wiring): real
menu items and sheet controls for brush and pattern creation with native
catalog/thumbnail/selected-pixel oracles; soft selection (bounds without
ants) creating a partial-alpha pattern; invalid name/spacing and duplicate
name with retry and preserved draft; no-selection and >10000 px gates; busy
hold; own-stroke end; Apply/Cancel gating during the accepted write;
two-document capture with the other window front; window-close and
close-drain with exactly-one completion; preservation of pixels, selection,
history, image identity and the system clipboard sentinel.

## Checks actually run

- `swift build -j 2` — OK ("Build complete!").
- `swift build -j 2 --build-tests` — OK.

Not run (out of scope for this slice): `swift test`, the
`--engine-smoke-test` runtime (including the new smoke case), adapter/
conformance builds, GUI/desktop runs. The smoke case and the unit tests
compile only; root owns the runtime matrix and the smoke-selector wiring.

## Known gaps / deferred to root

- The worker-level oversized refusal is defensive: the cached gate refuses
  first, so the smoke exercises the >10000 case at the cache/menu layer only.
- No verification of on-disk persistence path beyond catalog publication
  (slot 129's own conformance tests own the file layout).
- The chooser refresh is by fresh load on open; no live-refresh while a
  chooser stays open.
