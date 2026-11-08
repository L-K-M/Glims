# Image ▸ Metadata… controls (this slice)

One bounded UI slice on top of the reviewed metadata backend
([`image-metadata.md`](image-metadata.md)): a per-document sheet opened
from Image ▸ Metadata…, reusing only the existing
`EngineSession.metadataTags` / `metadataValues` / `editMetadata`
wrappers. Swift-only — no C/header/native/buildscript/dependency/Rigi/
production-backend changes.

## Scope

- `Sources/GlimsKit/Document/ImageDocument.swift` — three counted queue
  methods: `readMetadataTags(_:completion:)`,
  `readMetadataValues(_:completion:)`, `editMetadata(_:_:values:completion:)`.
- `Sources/GlimsKit/Document/MetadataSheet.swift` —
  `MetadataSheetLogic` (pure form/policy) and `MetadataSheetController`
  (the sheet).
- `Sources/GlimsKit/Document/DocumentWindowController.swift` — retains the
  sheet per window (`metadataSheet`), the `showMetadata(_:)` action, its
  `validateMenuItem` case, and fan-out lines in the EXISTING `onError`,
  `stateDidChange` and `endPendingEdits` closures (no callback/observer is
  replaced).
- `Sources/GlimsKit/MainMenu.swift` — the `Metadata…` item in Image.
- `Sources/GlimsKit/EngineSmokeTestMetadataControls.swift` +
  `GLIMS_SMOKE_CASE=metadata-controls` dispatch in
  `EngineSmokeTest.swift` (selected case and full run).
- `Tests/GlimsKitTests/MetadataControlsTests.swift` — pure tests.

Not touched: `docs/plan.md`, any completion ledger/milestone, native
code, the adapter, build scripts, Rigi.

## Async, capture, lifetime, close, error behavior

- Reads AND edits are asynchronous COUNTED document work on the
  document's serial `inputQueue` via the existing `enqueue` helper — no
  native RPC on the main thread and none during menu validation (the menu
  case reads only `isClosing` and `attachedSheet`, like Guides/Grid).
  Every job increments `pendingWork`, so `closeImageWhenDrained` drains
  all accepted metadata work before the image is destroyed; a read or
  edit requested after close began fails through its completion with
  `DocumentError.closed`.
- Each accepted edit captures an explicit `MetadataSheetLogic.Capture`:
  the image id, the tag, the action (`.setValues` / `.removeTag`) and the
  ordered value-array snapshot, taken by value at accept time; the queued
  job closes over `[session, image]` like every other document job. The
  sheet acts on the `ImageDocument` it captured at open — never the front
  document — so two documents keep independent sheets and actions land in
  the right image even when the front window changes.
- Before a write is queued, `editMetadata` runs the existing
  `endPendingUserEdits()` + `endStroke()` (finishInput) pattern, so
  in-flight field/text edits and a pending stroke enqueue ahead of it on
  the same serial queue and land in order.
- Admission is cached-only: `refuseWhileEditingUnavailable` (busy /
  closing / saving-for-close / clipboard / running plug-in / open filter
  preview) plus the sheet's `MetadataSheetLogic.writeAdmission`. Image
  metadata is image-level: pixel/alpha locks and layer/mask/channel
  target types never refuse it (no target pick, no lock read). The native
  BUSY gate still applies on the queue.
- Completions report success/refusal accurately. The document reloads
  its cache ONLY after a successful change; a refusal leaves rows, draft
  and cache untouched and the native message (UNSUPPORTED, NOT_FOUND,
  INVALID_ARGUMENT, BUSY) is shown unchanged in the sheet's persistent
  error row (and the status bar via `onError`). No silent
  normalization/clamping/fallback and no automatic rewrite attempts.
- Lifecycle: the window controller retains the sheet; `invalidate()` on
  sheet close makes every late callback a no-op. Tag-list loads carry a
  `tagLoadGeneration` and value loads a `valuesGeneration` plus the tag
  name, so a late result can never overwrite a newer selection/draft or
  resurrect/retarget a closed sheet. Closures capture `owner` and
  `[weak self]`; nothing leaks past the sheet's lifetime.
- Close/Cancel is truthful: closing discards only the unapplied local
  draft; changes already applied stay applied and undoable — the sheet's
  hint says so, and nothing implies a rollback.

## Separate values and exact limits / read-only rules

- The sheet shows the chosen EXIF/IPTC/XMP domain's FULL tag catalog
  (queued `metadataTags` read), searched locally
  (`MetadataSheetLogic.filterTags`) — case-insensitive, order preserved,
  never truncated, no eager large native work on the main thread.
- Selecting a tag loads its ORDERED values (queued `metadataValues`).
  Values are separate LIST ROWS plus a multiline text editor for the
  selected value. Add Value / Remove Value edit a local draft; Apply
  commits the captured WHOLE value array as one SET (one undo step; an
  identical array is a native no-op with no undo). Every empty string,
  duplicate, newline and the order are preserved exactly: a newline is
  never split or joined to encode multiple values (one row == one value),
  and there is no JSON/XML user flow.
- An empty value list is NOT a set: the backend requires at least one
  value (a single empty string is still a value), so Apply refuses an
  empty draft locally with the explanation to use Remove Tag — nothing
  is queued. Remove Tag is an explicit separate action on the selected
  tag by NAME (never a stale row index).
- Add Tag by explicit dotted name: `validateNewTagName` requires the
  current domain's `Exif.`/`Iptc.`/`Xmp.` prefix, non-empty remainder, no
  NUL (mirroring the facade's bridge validation); a tag already listed is
  only selected, an absent one is SET with a single empty-string value,
  and the native registry validates registration/type (NOT_FOUND
  otherwise).
- Read-only: the 13 normalization-protected tags
  (`MetadataSheetLogic.protectedTags`, the exact
  `gimp_image_metadata_update_*` rewrite list from
  `app/core/gimpimage-metadata.c` as recorded in
  [`image-metadata.md`](image-metadata.md)) are shown with a read-only
  note and their write controls disabled. XMP LangAlt tags are not
  enumerated by name (no invented registry guesses): their reads show the
  alternative texts without `xml:lang` qualifiers — the read API is
  text-only — and the sheet's note explains alternatives are read-only;
  their edits come back as the native UNSUPPORTED, displayed unchanged.
  Unknown unsupported kinds likewise surface the native error verbatim.
  Nothing is flattened and no language values are synthesized.

## Source references (own slice)

- `Sources/GlimsKit/Engine/EngineSession.swift` — `MetadataDomain`,
  `MetadataEdit`, `metadataTags/metadataValues/editMetadata`,
  `validateMetadataStrings` (wrappers reused as-is).
- `Sources/GlimsKit/Document/ImageDocument.swift` — `enqueue`/`pendingWork`/
  `jobDidFinish`, `endPendingUserEdits`/`finishInputForEngineActivity`,
  `refuseWhileEditingUnavailable`, `closeImageWhenDrained`, and the
  `setGrid(_:completion:)` completion pattern the new methods mirror.
- `Sources/GlimsKit/Document/GridSheet.swift`, `GuidesSheet.swift`,
  `DocumentWindowController.swift` — sheet ownership, beginSheet
  completion + `invalidate()`, fan-out lines, cached menu validation.
- `docs/image-metadata.md` — backend semantics, the 13 protected tags,
  LangAlt/read limits.

## Checks actually run (this change)

- `swift build -j 2` — PASS (GlimsKit + Glims compile with the new
  sheet, queue methods, menu item and smoke case).
- `swift build -j 2 --build-tests` — PASS (the new
  `MetadataControlsTests` and the smoke-case file compile).

NOT run here (root owns runtime/native execution): `swift test` (no unit
runtime), the app and `--engine-smoke-test` launches (including
`GLIMS_SMOKE_CASE=metadata-controls`), the native adapter build and
conformance suite, and any GUI/desktop run. The smoke case and the unit
tests are COMPILED ONLY in this change; no runtime behavior of the sheet,
the queue or the engine is claimed beyond what the sources above state.
