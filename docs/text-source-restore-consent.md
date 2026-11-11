# Restoring retained text before editing

A Text click on a rasterized layer with a retained text source now offers
Restore or Cancel in the owning document. The confirmation explains that
Restore discards the pixel edits, regenerates the source as one Undo step,
and requires a fresh click to edit. Cancel preserves the complete painted
state. Restore never resumes an old gesture or opens a delayed editor.

The original document, layer, state version, selection and drawable are
captured before consent. The sheet rechecks source availability, locks,
floating state, pending input and close state before admission. The counted
Restore service rechecks the expected state after ending pending field edits.
It retains the existing exclusive native command and its one-Undo behavior.
Closing the window aborts the owned sheet; retained late buttons cannot add
native work. There is no new facade slot or native source change.

## Observed baseline and acceptance

Tests-only `5d9e149` on the old editor ran eight real-window checks with one
failure: the Text click opened an empty new-text editor instead of consent.
Independent native text, Rasterize, Pencil and direct Restore controls passed.
The complete source, pixels, row identities, selection and history snapshots
are retained in `/tmp/glims-completion/text-restore-focused.oZ6mbv`.

Production `14c1616` initially ran 23 checks with one overconstrained status
assertion. The diagnostic in `text-restore-focused.kcaEzq` measured no editor
and the normal Text hint after Restore. Existing `ToolHintPolicy` deliberately
replaces ordinary action feedback on state changes. The fixture author
independently confirmed that requiring the earlier exact action string was
an invalid oracle. The corrected fixture checks the actual alert's fresh-click
instruction and the normal settled Text hint, while preserving the pixel,
no-auto-editor, same-layer fresh editing, Undo and close assertions.

Latest-Main integration `0431845` passes 23 consent checks and the existing
51 floating-Text creation checks on each supported engine: 296 checks total.
The pinned consent result is `text-restore-focused.n3LAKT`; the other runs
are indexed in `text-restore-0431845-matrix-results.json`, all under
`/tmp/glims-completion`. All 1,220 unit tests pass in the private leased run
`text-restore-0431845-full-units.ZYbzE2`.

The acceptance seeds text, rasterizes it and paints distinct stored pixels.
An independently seeded native image supplies direct Restore pixels and
Undo accounting. Cancel leaves the entire original native snapshot unchanged.
A second document really becomes main/key while the first owns consent;
Restore, Undo/Redo and the fresh same-layer edit preserve the second document.
Close destroys the original native image and a retained late Restore refuses.
All owned windows, sheets and native work drain before engine shutdown.

Mistral Large 4 completed an independent source review of production
`14c1616` with no important finding. This is source review, not independent
approval of the fixture or a runtime pass. The temporary signed debug hosts
use explicit source adapters; the native C and facade header match Main's
already checked Lens integration. Final standalone packaging, public
source delivery and whole-editor completion remain separate gates.
