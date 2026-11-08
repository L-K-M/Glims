# Glims completion ledger

The user requested a complete editor on 2026-11-07 after the ordinary build
opened a disabled placeholder. This ledger distinguishes working features
from the remaining design in `design.md`. Compilation alone does not close
an item. Work proceeds in reviewable slices with engine and on-screen checks.

## Implemented and checked

These entries describe the merged implementation as of 2026-11-08. The
whole editor remains in progress; each checked entry covers the stated
behavior, not every adjacent feature in `design.md`.

- [x] Ordinary builds bundle the pinned engine; unavailable prerequisites
      fail before packaging. Hosted CI explicitly builds only the interface.
- [x] First-window tiled drawing, New Image dimensions, deferred file opens,
      Save/Save As, imported/native identity, close and Quit protection.
- [x] Fit Image, Open Recent, repeat export and file-command validation.
- [x] Cut, Copy, Copy Merged, Paste, Paste in Place, Paste as New Image and
      Clear, including selection alpha and undo.
- [x] Nested layer groups, masks and paint targets, thumbnails, rename,
      drag reparent/reorder, visibility and pixel/position/transparency locks.
- [x] Component channels, saved selection channels and paintable Quick Mask.
- [x] History palette, undo/redo traversal and image snapshots.
- [x] Periodic private recovery copies, startup recovery/discard and original
      file identity and dirty-state preservation.
- [x] Native filter discovery and supported property forms, plus committed
      effect rows with visibility, parameter editing, reorder, remove and merge.
- [x] Open as Layers and native link-layer Place, including failure recovery,
      undo and source refresh. Link layers require an engine with that feature.
- [x] Save a Copy, Revert, native Print/Page Setup, layer properties and editor preferences.
- [x] Retina Actual Pixels and display-density changes.
- [x] Searchable native help content.
- [x] RGB/Grayscale conversion, native precision controls, accurate mode titles
      and read-only working-profile information, with undo and XCF persistence.
- [x] A self-contained bundle at `ff5cc54` passes 697 native and 597 interface checks
      with the development trees inaccessible. Pointer painting, keyboard editing,
      Save, Quit/reopen, mask/channel controls and PDF printing have separate
      on-screen evidence below and in the reviewed changes. The final
      combined revision, including the color controls, still needs this pass.

## Remaining implementation and final verification

- [ ] Layer multi-selection and saved sets, fit/trim, and consistent
      rasterize/revert policy for structured layers.
- [ ] Adjustment layers/groups, remaining custom filter forms and filter inputs.
- [ ] Path fill, vector layers and multi-anchor editing.
- [ ] Brush, pattern and gradient resource choosers and presets.
- [ ] Indexed conversion policy, profile assignment/conversion, display color
      management and soft proofing.
- [ ] Rulers, guides, grid, snapping, view rotation, trackpad/modifier behavior
      and initial fit that avoids palettes.
- [ ] Paste Into/floating selection controls, Stroke Selection and resource
      creation from selections.
- [ ] Image metadata editing, Fill dialog, remaining Image Adjust commands,
      layer-boundary/selection-edge/proof view toggles, complete menu and
      keyboard coverage and shortcut customization.
- [ ] Recorder and semantic command replay.
- [ ] Full accessibility/focus, appearance and English-copy audit.
- [ ] Public distribution checks from `plan.md`: corresponding sources,
      remaining license texts, signing/notarization and update process.
- [ ] Final combined build, engine matrix, self-contained bundles and real
      end-to-end editing/file workflows on the final integrated revision.

## Evidence and initial implementation reports

The dated reports below retain the checks and open work at each slice. The
status above and later checkpoints supersede earlier pending-check notes.

Initial inspection: tools, engine-backed layers, selections, transformations,
text, paths, Gaussian Blur and plug-in commands already existed. The ordinary
build omitted the engine. The old smoke test forced synchronous rendering,
masking an independent gray-first-canvas bug. Neither normal Save nor a dirty
close/quit prompt nor clipboard editing existed.

2026-11-07 baseline: the existing engine bundle passed 198 adapter checks and
87 interface checks with the development engine/dependency trees denied.
A new first-draw check then failed on the baseline; a real window reproduced
it and a zoom command made the canvas appear. New Image dimension tests were
observed failing before implementation and pass after it. Packaging preflight
checks cover default, explicit engine, shell-only and invalid combinations.

The expanded engine smoke now passes 96 checks, including automatic first
draw, save/reopen of queued input, export dirty-state preservation, ordinary
Save, close Cancel, failed Save on close and teardown after queued work.
The unit suite currently passes 60 checks. Quit still needs an on-screen
check and independent lifecycle review before this slice is closed.

Current completion slice: 98 unit checks and eight packaging checks pass.
Clipboard transport preserves straight-alpha bytes through a native private
format and standard PNG/TIFF for other apps. Its 210 adapter checks and 104
interface checks passed on all four engine sets before the final save guards.
The uncommitted-filter-save regression reproduced a file write from a live
preview; the adapter now refuses it. A clipboard/main-queue wait cycle was
reproduced with a timeout and replaced with an asynchronous transaction whose
encoding work is also counted during teardown. Close-triggered Save gates new
edits until completion; failed/cancelled saves restore editing. Empty text
commits as an undoable layer deletion instead of being silently resurrected
on Save. The save/close/clipboard smoke passes locally with these changes.

On screen, the bundled app opened a layered XCF through Finder, rendered it
without a zoom workaround, created a custom-sized document, and painted a
pointer stroke. Quit Cancel preserved the edited image, and Don't Save
completed the quit. Layer rows now offer visibility and inline rename; their
stable snapshot rejects removed/retargeted rows while reloads are deferred.
Final review and updated bundle/matrix checks are in progress.

Stabilization: cancellation during clipboard transfer reproduced an orphaned
preview that prevented saving and running plug-ins. Preview finalization now
keeps refused/failed commits editable and always queues cancellation as
non-dirty cleanup. Image destruction also releases unfinished sessions. A
clean document with a preview closes without a false save prompt. All 212
adapter checks and the expanded interface smoke pass on the pinned engine.
Inline rename reproduced a separate focus defect in nonactivating palettes;
the field now makes its panel key before typing. Its regression passes.
Registered `.xcfgz`/`.xcfbz2`/`.xcfxz` aliases and `.xcf.xz` preserve native
file identity too. The final review found no important remaining defects;
its minor xz-suffix omission was added to the existing identity regression.
The actual bundled Save As panel wrote a new XCF and updated the window's
name and represented file. A final on-screen rename check remains pending.

The launch slice merged as PR #4. The on-screen rename check also passed:
typing stayed in the palette, produced one Rename Layer undo step, and
survived Save, Quit and reopening the native file.

Retina navigation: render scale now counts physical pixels; pointer input,
overlays and frame geometry account for backing density. Fit Image uses
viewport device pixels, and display-density changes preserve the image
center. The actual canvas in a simulated 2x window failed on the old scale
and pointer mapping, then passed with the corrected implementation. The
110 unit tests and 120 pinned-engine interface checks pass. Real Retina
hardware was not available for an on-screen check.

Printing: File ▸ Page Setup… edits a per-document NSPrintInfo through the
standard sheet; File ▸ Print… (⌘P) flushes pending strokes, text and field
commits, then renders the committed composite into an immutable snapshot in
bounded stripes behind accepted input on the exclusive engine queue, sized
to the imageable area at 300 dpi under fixed pixel caps. The snapshot drives
a one-page NSView whose own drawing composites the image over white paper —
no canvas checks, overlays or palettes — through NSPrintOperation's document
sheet, and AppKit's PDF write produced the same page with the queued stroke
in place. A second Print during a job is refused, a close requested while
the snapshot renders drops the job, and printing never adds an undo step or
touches file identity. A later on-screen pass exercised Page Setup Apply
and Cancel, Print Cancel, and a one-page landscape A4 PDF with correct
quadrant placement and paper margins. A physical printer was not available.

2026-11-08: facade support for Open as Layers and Place, engine side only.
Two additive calls (`image_open_layers`, `image_place_link`) route through
`file_open_layers` and `gimp_image_add_layers`, the path GIMP's own open
dialog takes, so a file's layers land above the selected layer — or inside
a selected group — centered on the canvas, in one undo step, with order,
hierarchy, modes, masks and relative offsets kept and the temporary load
image unreffed. Place makes a real link layer where the engine has them
(3.2 and later): file reference kept, live re-render when the source
changes, saved and reread as a link in XCF. On 3.0 the call returns the
new UNSUPPORTED status and adds nothing; it never degrades to a raster
copy. The adapter resolves the file's loader before calling in, because
the link path's circular-reference check dereferences a NULL procedure
when a saved destination meets a file nothing loads. EngineSession grew
`openLayers` and `placeLink`. 603 adapter checks pass on 3.2.0, 3.2.8 and master; 585 pass on
3.0.8, including a monitored reread of a rewritten source; the menu
commands that would call them are not wired yet.

2026-11-08: facade slice for image color state and conversions, engine side
only. Three additive slots after `filter_edit_begin` (API version stays 1):
`image_color_info` fills a caller-owned `GlimsColorInfo` (facade-owned
`GlimsColorMode`/`GlimsColorComponent`/`GlimsColorTRC` enums, never the
engine's, plus the effective profile's label and whether an ICC profile is
embedded) with fixed UTF-8 buffers; `GlimsImageInfo.precision` keeps the
engine's nick string unchanged. `image_convert_mode` and
`image_convert_precision` are each one validated call into the GUI-free
core (`gimp_image_convert_type`, `gimp_image_convert_precision` with
no-dither defaults), so each is exactly one undo step with no partial
failure path; both honor `glims_edit_ready` (BUSY during a stroke, preview
or plug-in), validate enums and combinations before mutating (unknown
enums INVALID_ARGUMENT, closed images NOT_FOUND, no-ops OK with no undo),
and refuse indexed targets (mode) and non-u8-non-linear precision on
indexed images (UNSUPPORTED) while indexed info still reports accurately.
Conformance tests cover fresh-state info, RGB/grayscale round trips,
precision and TRC changes with pixel/layer/size preservation, undo/redo,
XCF save/reopen of the color state, no-op and invalid-enum side-effect
freedom, BUSY during a stroke and a preview, a closed image, and an
indexed PNG fixture. Not run here: the native matrix — the shared engine
lock and libraries are in use, so `build-adapter.sh --test` on the four
engine sets is left to the root pass; what was checked in this worktree is
a `clang -fsyntax-only` pass of the changed C files against all four
engine source trees plus the header-only TU and the test file.
Profile assignment/conversion, soft proofing, the indexed palette dialog
and the Swift forms are deliberately out of this slice.
2026-11-08: File ▸ Revert reloads the last saved XCF — or the original
file an imported image came from, titled Revert to Saved… / Revert… —
only after a confirmation sheet and a successful engine load. A saved
file wins over the imported original; an untitled image disables the
item. The confirmed discard counts as close approval, so no second
Save prompt appears, while Cancel, an unreadable source, a close that
wins the load or a Quit leaves the document and its unsaved state
fully usable. The reload is a file operation on the global engine
queue: accepted strokes, text and field commits on every document
drain first, the busy label shows in the status bar, and the count
holds Quit until the load resolves. Adoption is all or nothing — a
fresh document opens through the ordinary path, takes the old window's
frame, zoom and image-center, and only then does the old document
close and its image drain; a window gone or a close/Quit requested
during the load destroys the loaded image unadopted on the same queue.
A re-import keeps imported (unsaved) identity; a native reload is
clean with fresh history. Recovery follows the same close path: the
old record is removed and the replacement registers its own. Source
bytes are only read. Unit tests cover the source/title rules; the
engine smoke exercise covers cancel, confirmed native reload with
restored frame/zoom and discarded edits, external rewrite, missing
source, untitled, re-import identity, cross-document drain and a
direct close during the load. `swift build` and `swift test` (246
tests) pass; the engine smoke run and interactive QA were not run in
this session.
2026-11-08: the File menu commands are wired. Open as Layers… and Place
as Link Layer… sit below Open Recent and run through
`DocumentWindowController`'s single-file panel into
`ImageDocument.openLayers`/`placeLink`, which take the same
`EngineActivity` exclusive admission a file write gets: accepted strokes,
text and field edits end first, every document's input drains, the
engine-wide busy label holds for the whole load including a plug-in's
modal dialog, and the work counts toward close and Quit. The engine's
native selection of the imported result becomes the target only through
the completion's reload — no selection is issued on the main thread —
file identity and the on-disk XCF stay untouched, and one undo step
covers the import. A failed or cancelled load adds nothing and reports
the engine's own message; a loader cancel surfaces as a cancelled
outcome rather than an error. Place consults the engine's verified
version (`EngineSession.supportsLinkLayers`, link layers need 3.2) to
disable its menu item and guard the action, and an unparsable version
leaves the facade's UNSUPPORTED answer to report; there is no raster
fallback. `EngineSmokeTest.exerciseFileImports` covers the drain,
refusals, identity, undo grouping, failure recovery, close during the
load and the link layer's save/reload/reread; it was added but not run —
engine smoke stays with the desktop pass against the private adapters.
`swift build` and `swift test` (229 tests, including new menu-placement
and version-parsing cases) pass headless.
2026-11-08: the Image menu's color controls are wired on the existing
facade. `EngineSession` gains typed `ColorInfo`/`ColorMode`/
`ColorComponent`/`ColorTRC` and wrappers for `image_color_info`,
`image_convert_mode` and `image_convert_precision` — facade values only,
unknowns map to `.unknown`, and the precision nick `ImageInfo.precision`
reports is preserved. `ImageDocument` caches the color info with the rest
of its state, and `handle` no longer reloads synchronously on layers/
channels/undo/size events: the refreshes coalesce into one pending run
through `EngineActivity.whenIdle` while an exclusive activity is busy —
a large conversion emits events before its worker returns, and a main-
thread reload would have waited on it — while selection and size
callbacks survive and a closing document is skipped. Projection redraws
stay asynchronous. The window title now shows the image's real mode
(RGB, Grayscale, Indexed, or Unknown) instead of hard-coded RGB, after
undo/redo and reopen alike. Image ▸ Mode ▸ RGB / Grayscale check the
cached mode live in validation — no engine call there — and run the
conversion through counted exclusive admission, so accepted input in
every document drains first and close/Quit wait; Image ▸ Precision…
opens a sheet with component (8/16/32 integer, 16/32/64 float) and
transfer-curve (linear/non-linear/perceptual) popups seeded from the
cache, with a disabled Unknown row when the state cannot be named, and
Image ▸ Image Information… shows mode, precision, the effective profile
label and embedded-vs-builtin honestly. Converting to the current mode
or seeded precision queues nothing and pushes no undo; indexed precision
stays fixed at u8 non-linear (the Precision item stays listed but
disabled and says why) and no Indexed menu entry exists — palette and
dither policy are a later slice. Refusals (closing, clipboard transfer,
save-for-close, plug-in, active preview, a busy gate) report busy or the
facade's own actionable message, and a failed conversion leaves the
image usable. Unit tests cover non-RGB titles, menu structure and tags,
choice lists, seeding and unknowns, the indexed restriction and the
information rows; `exerciseColorConversions` in the engine smoke covers
fresh state, RGB↔grayscale with pixel verification, form seeding/cancel/
no-op/pick, undo/redo, XCF roundtrip, file identity, preview refusal,
cross-document drain, close during a conversion and deferred event
refresh — it compiles here and the desktop pass runs it. `swift build`
and `swift build --build-tests` pass; `swift test`, the smoke run and
interactive QA were not run in this worktree.

2026-11-08 verification checkpoint: the checked self-contained bundle at
`9deb9ae` passed 603 native and 474 interface checks with development trees
denied. The later existing-effect backend passed 662 native checks on
3.2.8/3.2.0/master and 644 on 3.0.8. The file-placement interface passed
517 checks on 3.2.8/3.2.0/master and 514 on 3.0.8. These are separate
revisions and checks, not a claim that the final combined editor is done.
The implementation PRs and their verification comments retain the exact
heads, review findings and remaining manual gaps.

Revert verification: 495 interface checks passed on each engine before
integration; the placement-integrated head passed 248 unit tests and 538
pinned-engine interface checks. Manual confirmation-sheet checks remain.

2026-11-08 integrated verification: bundle `ff5cc54` passes 697 native and
597 interface checks with development trees inaccessible. Running two
interface apps together caused two focus-sensitive checks to fail; the
isolated run passes. The desktop pass opened a layered XCF, added a PNG
through Open as Layers, placed a genuine link layer, cancelled Revert
without losing the seven-layer edited state, then confirmed Revert and
restored the original five-layer clean image at the same frame and zoom.
A Gaussian Blur on the text layer appears as an effect row; double-click
opens its native parameters, setting both radii to zero restores sharp
text and keeps the text layer and effect. Selection edges are visible.
Quit prompted for the edited documents and Don't Save completed cleanup.

The color controls pass 283 unit tests and 640 interface checks on
3.2.8/3.2.0/master, 637 on 3.0.8. Independent review reproduced silent
Precision-sheet refusal while another document holds the engine and on
a native conversion error. Both regressions failed before the fix and
pass afterward. A raw facade conversion now tests deferred refresh
without relying on the document command's own completion reload: state,
selection and size events coalesce once after the activity. The accepted
stroke in another document is checked by its changed pixels. Follow-up
review reports no important findings. A grayscale PNG opened in the old
bundle reproduced its incorrect RGB title; interactive verification of
the corrected title and conversion sheets remains pending.
