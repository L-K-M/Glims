# Resource duplicate controls (Duplicate…)

Status: UI slice on `feat/resource-duplicate-controls`. Backend facade slot
131 (`EngineSession.duplicateResource`, commit `b080628`) is merged into this
branch's parent; **the final backend policy fixes (source-specific VBR/GGR
edge-whitespace refusal, unsupported PAT-format errors) are owned and merged
by Root later — this worktree's backend parent is the old one, so no runtime
against it was attempted here and native behavior is pending that final
merge.** This document describes what this slice adds and exactly what was
and was not verified.

## UI scope (duplication only)

- An accessible **Duplicate…** button in the existing `BrushChooserPanel`
  ("Duplicate brush"), `GradientChooserPanel` ("Duplicate gradient") and the
  `PatternFillPicker` embedded in the Edit ▸ Fill sheet ("Duplicate
  pattern"). No rename/delete/new-manager UI, no preferences UI, no
  create-default.
- One shared form, `ResourceDuplicateFormController`
  (`Sources/GlimsKit/Document/ResourceDuplicateForm.swift`): a **nonmodal
  child panel** of the host's window — never a nested AppKit sheet, so the
  pattern picker inside the Fill sheet can use it too. It shows the captured
  source (read-only) and an editable name draft with **Create** / **Cancel**
  and inline native/local errors. Accessible labels: "Duplicate source",
  "Duplicate resource name", "Create duplicate", "Cancel duplicate",
  "Duplicate message"; button labels "Duplicate brush/gradient/pattern".
- The Default row (nil resource) is not duplicatable: the button disables
  with the reason as tooltip (`ResourceDuplicateValidation.sourceRefusal`).
- Duplicating does **not** choose the new item and does not touch committed
  `ToolState` brush/gradient choices or the persisted pattern-fill
  preference; only explicit Choose/Fill applies a selection.

## Captured lifecycle and counters

- When Duplicate opens, the host captures **once, by value**: the document
  (the picker's own captured document, never the front document), the
  source's persistent `ResourceIdentity`, its session-local native handle
  and its kind (`ResourceDuplicateValidation.Source`). Later highlight,
  tool, document or front-window changes cannot alter that source. Handles
  are never persisted.
- `ImageDocument.duplicateResource(source:name:completion:)` mirrors
  `createResourceFromSelection` exactly: local validation through the shared
  `EngineSession.validateResourceName` (nonempty UTF-8, no NUL, ≤255 UTF-8
  bytes, no Cc controls; **no trimming/normalization**), cached
  isClosing/busy/preview/plug-in gate (`duplicateResourceRefusal`), explicit
  finish of field edits and the own stroke, then an **outer `pendingWork`
  count** for the deferred UI completion plus `enqueueExclusive`'s **inner
  count**. `EngineActivity` finishes/drains ALL accepted document input
  globally; on the worker the captured identity is resolved freshly with the
  captured kind (no name-only fallback; native internal localized-name
  semantics honored), the source is revalidated through the facade, and the
  synchronous slot 131 `duplicateResource` runs **off main** with the full
  UInt64, result captured by value; then main → `EngineActivity.whenIdle` →
  `onError`/completion → `jobDidFinish`. Rejection balances outer + inner
  counts and completes exactly once. A successful publish never becomes a
  false failure through the optional identity/thumbnail follow-up.
- Create/Cancel are disabled during an accepted write (no fake accepted
  cancellation); dismissing the picker/document/window/shutdown invalidates
  the form, the counted job still drains fully, and late callbacks cannot
  resurrect stale views or retarget. Errors (local, gate, or native
  source-specific refusals) stay inline across unrelated busy gates and are
  cleared only after successful local validation — mirroring
  `ResourceSelectionForm`'s corrected behavior; the editable draft is kept
  for retry.
- After success the host refetches its catalog off the main thread through
  the existing `EngineActivity`/read controllers — `ResourcePickerController
  .reloadCatalog()` force-refreshes even the `loadOnlyOnce` pattern picker,
  and the brush panel reloads — preserving the current highlight/explicit
  selection when its row survives (programmatic selection callback
  suppression via the existing `updatingTable` guard). A refresh failure is
  the model's own error state, separate from the successful publication.

## Tests

- `Tests/GlimsKitTests/ResourceDuplicateControlsTests.swift`: pure tests for
  the name contract (through the shared `validateResourceName`), captured
  source value semantics, proposed draft, Default-row refusal, cached gate
  and the reused phase machine.
- `Sources/GlimsKit/EngineSmokeTestResourceDuplicateControls.swift` (350
  lines, new module; shared `EngineSmokeTest.swift` untouched):
  `exerciseResourceDuplicateControls` drives the real Duplicate… buttons and
  form for brush/pattern/gradient with native catalog/thumbnail oracles,
  two-doc/front-window retarget safety, Default-row refusal, inline
  duplicate-name error with retry, Cancel, accepted-count/drain/close with
  exactly-one completion, and unchanged ToolState/preferences until
  Choose/Fill; it records created identity+kind+thumbnail evidence to the
  work dir. `verifyPersistedResourceDuplicate(record:session:)` is the
  distinct fresh-session phase for Root to wire/run with a genuinely fresh
  `EngineSession` (verifies persisted exact name/catalog/thumbnail via the
  recorded `ResourceIdentity`, no saved handles; the shared smoke engine is
  never stopped/restarted by this module).

## Verification actually run in this worktree

- `swift build -j 2` — passes.
- `swift build -j 2 --build-tests` — passes.

## NOT run here (Root-owned)

- No engine commands, no native compile/build/relink, no app/runtime/AppKit
  or unit-test execution, no GUI: the smoke module and the unit tests were
  compile-checked only. Root wires `GLIMS_SMOKE_CASE=resource-duplicate-
  controls` (and the full suite) and runs `verifyPersistedResourceDuplicate`
  with a fresh session against the **final merged backend**; this worktree's
  backend parent predates Root's native VBR/GGR/PAT policy fixes, so native
  refusal texts asserted at runtime are pending that merge.
- Engine matrix runs happen in Root's other worktrees.
