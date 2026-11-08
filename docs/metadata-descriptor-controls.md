# Metadata descriptor controls (descriptor adoption in the Metadata sheet)

One bounded UI slice on top of the read-only tag descriptor (facade slot
128, `docs/metadata-tag-info.md`) and the existing Metadata sheet
(`docs/image-metadata-controls.md`): the sheet now reads the selected
tag's native descriptor as counted queued work, displays its native
strings, and gates its controls on the descriptor's own
`valueKind`/`supportsMultiple`/`formatPolicy`. This document covers only
this slice; it does not mark any milestone or ledger entry done.

## What the sheet shows

For the currently selected tag, three compact read-only lines plus a
scrolling description, between the value editor and the button row:

- **descriptor title** (`Metadata tag descriptor`): the native `label`
  (falling back to the dotted tag name when the registry label is empty)
  plus the native `typeName`, e.g. `Artist — Ascii`.
- **presence** (`Metadata tag presence`): `Present on this image.` /
  `Not present on this image yet.`
- **description** (`Metadata tag description`): the native
  `description` in a fixed-height (48 pt) vertically scrolling, word-
  wrapping plain-text view, so a long native description never reflows
  or resizes the sheet under the pointer.

While the descriptor read is in flight the title shows the dotted tag
and the presence line shows `Reading tag descriptor…`.

## Policy bits vs real writability

`MetadataSheetLogic.writeGates(descriptor:valuesReady:locallyProtected:)`
is the single pure gate function (unit-tested in
`Tests/GlimsKitTests/MetadataDescriptorControlsTests.swift`):

- `canSet` = not LangAlt and `formatPolicy.contains(.supportsSet)`;
  `canRemove` = not LangAlt and `.supportsRemove` — **independent**.
- `canAddValue` = `canSet` and a multiple-value kind (not `.single`, not
  LangAlt) and native `supportsMultiple`. A `.single` tag (or one with
  native `supportsMultiple == false`) can never Add Value; an absent
  single scalar's local draft still starts with its one initial value
  from Add Tag.
- LangAlt (`valueKind == .langAlt`) is read-only **from the descriptor
  itself**, before any native edit could fail, despite its native
  multiple flag. No language qualifiers are invented and no alternative
  text is flattened into a setter.
- An absent XMP container (bag/seq/alt, `present == false`, REMOVE bit
  only) keeps **Remove Tag enabled** (the native no-op) while **Apply
  stays disabled**; SET is not globally disabled with it. The note names
  Remove Tag as the available action.
- The protected-tag list stays as the conservative fallback while the
  descriptor is unknown; once the descriptor is successfully known, its
  policy is authoritative.
- The bits describe **format only**: a real accepted write can still
  refuse (BUSY, copy preservation, native validation) and that native
  refusal is shown unchanged in the error row with the draft preserved.

## Fail-closed reads, generation and capture

- `ImageDocument.readMetadataTagInfo(_:completion:)` is a new counted
  async READ on the same input queue as `readMetadataValues`: explicit
  captured session/image/tag, no native RPC on the main thread, counted
  in `pendingWork` so close drains it before the image is destroyed, and
  a post-close call fails through its completion with `closed`.
- The descriptor and the values must **both** have been read
  successfully for the **same currently selected tag at a valid
  generation** (`MetadataSheetLogic.readIsCurrent`) before any write
  control is enabled. A pending or failed descriptor OR values query
  leaves Apply / Remove Tag / Add Value disabled with an actionable
  reason in the note line; there is no fallback to stale info or a
  hardcoded permissive policy. Native NOT_FOUND/UNSUPPORTED/query errors
  are shown in the persistent error row.
- On selection change, domain change, deselection, Remove Tag, or close,
  the old descriptor and its generation are invalidated; a completion
  from an older generation or another tag is dropped. Close still drains
  the counted jobs, but the invalidated sheet never updates or reopens.
- The descriptor refreshes after Apply and Remove Tag and when the undo
  signature moves (Undo/Redo) — including while a dirty local draft is
  kept: only format facts (presence/policy/strings) refresh, the user's
  draft is never overwritten merely to refresh them. Local draft edits
  are never clobbered by async descriptor results.

## Add Tag behavior (unchanged semantics, now descriptor-validated)

Add Tag still starts only a local draft — no native empty SET. The
registered-absent tag is validated by its values read AND its

 descriptor read: an absent scalar becomes a local one-value draft with
Apply opening once the descriptor lands; an absent bag/seq/alt can be
selected/read/explained, Apply stays disabled, Remove Tag stays allowed.
An unregistered name shows the native NOT_FOUND and creates no row, no
capture and no native write. Exact empty strings, duplicate and
multiline ordered values remain preserved exactly; nothing is split,
joined or rendered as developer JSON/XML.

## Test scope and checks

- `Tests/GlimsKitTests/MetadataDescriptorControlsTests.swift` (new,
  pure): single cannot add a second value (with or without a stray
  native multiple flag); repeatable/bag/seq/alt allow Add Value where the
  native multiple flag allows; LangAlt read-only despite the multiple
  flag (even with bits set); SET/REMOVE independence; absent container
  Remove-only with reason; absent scalar keeps its one-value SET;
  protected fallback; descriptor missing/pending/failed and values
  pending/failed fail closed with reasons; read currency (same tag +
  generation); native label/typeName/presence strings in the display
  helpers. The tests use only the typed `EngineSession.MetadataTagInfo`
  and pure helpers — no NSApplication, windows, engine or GUI.
- `Sources/GlimsKit/EngineSmokeTestMetadataDescriptors.swift` (new,
  OPTIONAL, **not wired**): a modular smoke that would compile the
  descriptor display, the gates, the query-failure and close cases
  against a real engine. The dispatcher in `EngineSmokeTest.swift` is
  untouched — the root owns wiring and the runtime run.

## Checks actually run (this slice)

- `swift build -j 2` — passes.
- `swift build -j 2 --build-tests` — passes (new test file compiles).
- `swift test -j 2 --filter MetadataDescriptorControlsTests` — passes
  (the new pure filter only; the full XCTest/AppKit suite was NOT run).

NOT run: any GUI, the app, `--engine-smoke-test` (including the new
unwired smoke file), adapter/engine/native builds, and the full existing
test suite. `_engine/` and `_deps/` are absent in this UI-only checkout
and were not needed for the Swift build. Runtime UI/native acceptance is
serialized by the root.

## Acceptance fixes and runtime checks

A test-only facade proxy forwards editing to a real v128 adapter but refuses
Credit's descriptor. It reproduced two failures: Add Tag created a draft
before descriptor validation, and Undo's successful value reload erased an
earlier descriptor-query error. The controller now commits a local new-tag
draft only after both queries succeed and retains descriptor errors through
later value results. All four forced-error checks pass on every engine.

The actual descriptor controls and previous metadata controls pass their
focused runs on every engine, and all 635 unit tests pass. LangAlt is inspected
as a registered absent tag; no fabricated present XMP fixture is assumed.
Undo actually removes a seeded native tag while preserving a dirty local
draft, proving the descriptor's presence transition. Broad integrated smoke
and final CI are still pending.

To reproduce descriptor failures, compile Engine/tests/metadata-descriptor-proxy.c
as a dylib with this checkout's facade include directory. Run the app's
metadata-descriptor-failures smoke case with GLIMS_ENGINE_LIBRARY pointing to
that proxy and GLIMS_REAL_ENGINE_LIBRARY pointing to a real v128 adapter.
The proxy is test-only and is never part of the engine or bundled app.
