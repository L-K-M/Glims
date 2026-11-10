# Captured batch Rasterize

Layer > Rasterize Layers… captures the owning document's ordered selected
layer IDs and displayed names before committing fields can change selection.
Its document-modal sheet names the captured sources and offers Rasterize and
Cancel. Apply rechecks admission and operates on those IDs even when another
document is key, or the original document's selection has changed. Cancel
queues no conversion. Restore Layer Source remains an individual operation;
batch Restore and the broader gesture policy remain separate work.

API v1 appends slot 165, `image_rasterize_layers`. It accepts 1…256 distinct
positive IDs of attached layers retaining text, link or vector sources.
Already rasterized retained sources are eligible no-ops. Ordinary pixel
layers, groups, masks, channels, missing sources and effective pixel/position
locks refuse the whole request. Floating selections, unavailable writing,
disabled/frozen Undo or an open Undo group also refuse. Every target is
validated and strongly held before the first change. An all-no-op request
does not change history or dirty state.

Changed sources share one native Rasterize Layers Undo group. The native
conversion retains their structured source data, identities, tree position,
offsets and existing pixels/masks/effects. Undo restores editable behavior;
Redo restores rasterized behavior. Unexpected Core failure can leave an
already changed prefix within that Undo group. The error reports this and
refreshes authoritative image state; the command does not promise rollback
of unexpected native failures.

The document rechecks cached admission after ending fields/strokes, then
queues the captured vector through the existing counted target-command
lifecycle. Native code repeats admission after queued work. Close waits for
accepted work and completion, while late sheet Apply cannot enqueue a new
request after close admission. Menu validation reads cached state without
entering the engine.

Recorded validation, 2026-11-10 candidate:

- Each of GIMP 3.2.8, 3.2.0, 3.0.8 and master passes 96 focused native checks.
  These fixtures use retained text sources, with independent native pixels,
  ordered targets, whole-request refusals, no-ops and Undo/Redo. Link/vector
  eligibility is implemented policy, not native link/vector fixture coverage.
- General conformance passes 1,917 checks on 3.2.8/3.2.0/master and 1,703 on
  3.0.8. Initial 3.2.0 and 3.0.8 runs each failed only engine-stop timing at
  5,037 ms and 10,146 ms; retained private repeats pass. No cause is assigned
  to those initial failures. The separately run pinned case passes with a
  45 ms stop. Combined logs retain native/GEGL cleanup diagnostics.
- The pinned 3.2.8 actual UI case passes all 51 checks, exits 0 and releases
  the desktop. It exercises the real sheet, Cancel/Apply, captured A while B
  is genuinely key/main, native selection changes, busy/mask/channel/close
  refusals, exactly-once completion and renderer/native-image teardown.
- An earlier smoke attempt failed before Cancel because the synchronous
  accessory host never completed AppKit launch. Only this focused smoke case
  now uses a private test delegate, normal `NSApplication.run` launch and
  actual event dispatch during waits. The original focus predicates and
  functional assertions remain intact; interactive startup is unchanged.

Evidence paths, hashes, initial failures and producer limits are indexed in
`/tmp/glims-completion/batch-rasterize-native-results.json`. The pinned native
source marker is `8aab95d`; subsequent Main integration imports the separately
reviewed legacy Select Color fix without changing this batch implementation
or its native oracle. The recorded binaries identify their tested tuples;
they are not blanket fresh execution of every later integration byte.
Other-engine UI runs, current unit/integration checks, latest-head CI/review
and merge remain pending. The broader batch/gesture ledger item stays open.
