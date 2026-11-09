# Resource duplicate controls (Duplicate…)

The Duplicate… controls use the checked native resource backend (slot 131,
API version 1), including the accepted VBR/GGR name and PAT format guards.
This branch includes the current editor main and the fixed backend.

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
  and the brush panel reloads — preserving the latest highlight/explicit
  selection when its row survives, including choices made during the load (programmatic selection callback
  suppression via the existing `updatingTable` guard). A refresh failure is
  the model's own error state, separate from the successful publication.

## Validation

The focused `resource-duplicate-controls` smoke case is wired into the full
app suite. It drives real buttons/forms, captured-document/source behavior,
inline native errors and retry, busy-to-idle refresh, counted close/drain,
host closure, and unchanged committed preferences. Controlled document
barriers prove that a newer Default or native-row choice survives an
in-flight catalog refresh for brushes, gradients and patterns. Selection is
captured at delivery, before the model resolves its original saved choice.

Root acceptance fixed hidden child-panel retention, document-state fanout,
Default restoration, gradient row state and the asynchronous selection race.
The initial independent source helper found no important issue; subsequent
relay inspection identified the race and Root added the barrier regressions.

- All 764 unit tests pass; app build passes.
- Every supported engine passes all 58 focused checks.
- The final full pinned-engine app suite passes all 1,949 checks, including
  the added in-flight selection regressions.
- Native backend durability is covered separately by 261 duplication and
  177 persistence checks on every engine. The optional UI evidence/restart
  helper remains unwired and brush-only; this slice claims no new UI restart
  proof.

The forms preserve drafts and errors through unrelated busy activity, refresh
automatically as document state changes, and invalidate when their host
window closes. Completion remains counted even if the form is gone; a closed
document returns refusal through its completion without a late window error.
