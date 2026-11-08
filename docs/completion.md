# Glims completion ledger

The user requested a complete editor on 2026-11-07 after the ordinary build
opened a disabled placeholder. This ledger distinguishes working features
from the remaining design in `design.md`. Compilation alone does not close
an item. Work proceeds in reviewable slices with engine and on-screen checks.

## Current slice: make the existing editor usable

- [x] Ordinary builds bundle the pinned engine; missing prerequisites fail
      before packaging. Hosted CI explicitly builds only the interface.
- [x] Real first-window drawing requests tiles without a zoom interaction.
- [x] New Image asks for pixel dimensions; Finder opens wait for startup.
- [x] Save, Save As and native/imported file identity behave consistently.
- [x] Closing and quitting protect unsaved work and drain queued operations.
- [x] Cut, Copy, Copy Merged, Paste, Paste in Place and Clear use the system
      clipboard, honor selection alpha and preserve undo. Keyboard Copy/Paste,
      menu Undo and layer visibility changes were also checked on screen.
- [ ] Fit Image, Open Recent, repeat export and basic file command validation.
- [ ] A bundled app passes engine checks with development trees inaccessible,
      and actual pointer/keyboard editing, save, reopen and export work.

## Remaining implementation from the design

- [ ] Layers: groups, masks and mask targets, thumbnails, inline rename,
      drag reorder, multi-selection, locks, fit/trim and rasterization policy.
- [ ] Channels and saved selections; Quick Mask with paintable overlay.
- [ ] History palette and image snapshots.
- [ ] Periodic recovery copies that preserve native file identity and dirty state.
- [ ] Filter discovery and native property forms; editable, reorderable
      non-destructive filter stacks; adjustments and adjustment groups.
- [ ] Place images as layers and GIMP 3.2 link layers.
- [ ] Path fill, vector layers and multi-anchor editing.
- [ ] Brushes, patterns and gradients: resource choosers and presets.
- [ ] Color management: accurate image mode/precision/profile state,
      conversion/assignment and soft proofing.
- [x] Retina Actual Pixels maps an image pixel to a device pixel, including
      changing displays while a document is open.
- [ ] Canvas navigation: rulers, guides, grid, snapping, rotation and
      consistent modifier/trackpad behavior; initial fit avoids palettes.
- [ ] Complete menu coverage, keyboard settings, preferences and persistence.
- [ ] Save a Copy, Revert, Paste as New Image, print and metadata.
- [ ] Recorder and semantic command replay.
- [ ] Accessibility and help content, English UI copy audit.
- [ ] Public distribution checks from `plan.md`: complete corresponding
      sources, remaining license texts, signing/notarization and update process.

## Evidence

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
touches file identity. On-screen panel and physical-printer behavior were
not exercised.

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
