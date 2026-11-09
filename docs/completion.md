# Glims completion ledger

The user requested a complete editor on 2026-11-07 after the ordinary build
opened a disabled placeholder. This ledger distinguishes working features
from the remaining design in `design.md`. Compilation alone does not close
an item. Work proceeds in reviewable slices with engine and on-screen checks.

## Implemented and checked (including the current integration candidate)

These entries describe merged main through #127, plus explicitly identified
integration candidates. Trackpad pinch/rotate, Option-scroll, typed language
metadata and guarded saved-resource management are merged and verified. The whole editor
remains in progress; each checked entry covers its stated behavior.
The #126 release passes 1,917 native and 2,391 app checks in a self-contained
bundle with the native and Swift build outputs inaccessible.

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
- [x] The editor candidate merged through #95 passes 1,917 native and 1,891
      app checks in a self-contained bundle with development trees inaccessible.
      Pointer painting, keyboard editing, Save, Quit/reopen, masks/channels and
      PDF printing have separate on-screen evidence. The newer combined
      release from main `e7c7fb0` passes1,917 native and2,190 app checks,
      with native and Swift build trees inaccessible. The rotation candidate
      passes831 unit tests, all four focused runtime cases and2,237 full app checks.

## Remaining implementation and final verification

- [x] Layer to Image Size and Trim Layer to Content, with pixel-only policy.
- [x] Explicit Rasterize Layer and Restore Layer Source controls.
- [x] Layer-palette multi-selection with exact native selections and explicit
      single-layer command gates.
- [x] Fixed layer/channel/path set management with native Undo, runtime tokens
      and fresh-token layer recall; weak live identity and Undo memory limits.
- [x] Channel/path saved-set recall with ordered native mirrors and guarded
      single-target edits, including arrow-key and floating-selection cases.
- [x] Captured ordinary pixel-layer batch duplication as one native Undo,
      ordered selection restoration, Command-J and Layers palette controls (#122).
- [x] Captured ordinary pixel-layer batch deletion as one native Undo, with
      ordered selection restoration and mask/effect admission guards (#125).
- [x] Captured pixel-layer batch Fit to Image with native masks, one Undo,
      exact selection preservation and whole-request admission (candidate).
- [ ] Remaining batch operations and consistent gesture-time rasterize/revert policy.
- [x] Adjustment layer creation as an empty pass-through group with a filter,
      explicit placement and editable filter settings.
- [x] Bump Map height-map chooser with immutable same-image snapshots,
      pixel Apply/Undo/Redo and native source validation (#126).
- [x] Native Brightness/Contrast paired controls and committed-effect editing,
      with immutable settings, Undo and XCF preservation (current candidate).
- [x] Dedicated Color Balance controls with whole-range native configuration,
      immutable editing and delayed-write refusal handling (current candidate).
- [x] Dedicated Brightness/Contrast, Color Balance, Hue/Saturation and Levels
      editors, with immutable whole configurations, existing-effect editing,
      Undo/Redo and XCF (reviewed integration candidates #129/#131/#133/#134).
- [ ] Remaining custom filter forms, including Curves, histogram/automatic
      Levels controls and other auxiliary inputs.
- [ ] Preserve nondefault native-only effect blend/composite settings when
      opening XCF; upstream currently normalizes them to AUTO.
- [x] Path fill, vector layers and vector style controls.
- [x] Multi-anchor path editing with group move/delete and Undo.
- [x] Searchable brush, pattern and gradient resource choosers, with
      thumbnails, retained identities and captured gesture settings.
- [x] Tool preset storage and controls.
- [x] Brush/pattern creation from selections and brush/pattern/gradient
      duplication controls, with checked persistence and current-choice refresh.
- [x] New gradients from explicit endpoint colors, with native persistence and owned creation forms.
- [x] Guarded resource Rename/Delete controls, explicit Retry/Refresh and exact
      saved-choice/preset reference migration (#124).
- [x] Color profile assignment and conversion with explicit rasterization consent.
- [x] Indexed conversion with generated/custom palettes, dithering and
      explicit structured-source consent.
- [x] Per-window RGB destination-ICC canvas rendering, stale-generation
      rejection and independent wide-source pixel-preservation checks.
- [ ] LUT/physical-display and higher-precision verification, HDR and soft proofing.
- [x] Native guides with undo/XCF persistence, per-document management
      sheets and a per-window Show Guides overlay toggle.
- [x] Pixel rulers, grid controls/overlay and canvas guide dragging.
- [x] Per-window snap toggles and captured canvas-gesture snapping to
      guides, grid and canvas.
- [x] Initial New/Open document placement and fitting around visible palettes.
- [x] Per-window view rotation with projected rulers, fit/zoom/centering, real selection/paint/Undo,
      angle forms, guide drags and Hand panning (merged #115).
- [x] Per-window trackpad pinch/rotation and pointer-anchored Option-scroll zoom.
- [x] Live Shift-constrained and Option-centered rectangle/ellipse selection,
      stationary modifier preview, captured selection modes and Escape cancellation
      (#127).
- [ ] Remaining snapping interactions and other modifier behavior.
- [x] Stroke Selection and explicit Paste Into/Anchor/New Layer/Discard.
- [x] Float Selected Pixels (move/copy), existing floating-selection drag
      and arrow nudges with captured target validation.
- [ ] Interaction-specific automatic anchoring. A blanket tool-switch anchor
      policy is unsupported.
- [x] Shortcut customization and menu integration using immutable defaults.
- [x] Registered image metadata editing with descriptor gates and value
      preservation; layer-boundary and selection-edge view toggles.
- [x] Typed existing language-alternative editing, with native preservation/Undo
      guards and independent per-key drafts in the metadata controls.
- [x] Image > Adjust placement for native Threshold and perceptual/linear
      Invert, with shared plug-in categories (current candidate).
- [x] Typed capture-date metadata, descriptor-gated and preserving timezone
      and subsecond companions (#132).
- [ ] Remaining typed metadata editors, Image Adjust commands, proof view controls
      and complete menu/keyboard coverage.
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

2026-11-08 later checkpoint: color controls are merged at `f5998f5`.
The source launch, actual grayscale/RGB titles, profile information,
16-bit float linear conversion and undo/redo have on-screen evidence.
The adapter now provides path fill and vector creation on all supported
engines with the appropriate capability gates. The Paths interface branch
passes 305 unit tests and 677/666/677/677 interface checks, including actual
opacity control actions, layer/mask/channel targets, history, vector path
updates and XCF persistence. Its review found no important defects; native
vector style editing and multi-anchor selection are still outstanding.

2026-11-08 Fill integration: Edit > Fill provides foreground/background,
white/black/custom and opacity. The two-document binding regression was
observed failing in the draft and passes after per-sheet retention. The
Paths-integrated build passes 305 unit tests and 689/678/689/689 interface
checks. On screen, half-opacity Fill works and cancelling the Custom
color well closes the panel it opened. Pattern fill remains resource work.

2026-11-08 profile controls (branch `feat/color-profile-controls`, ICC
backend `79a26c5`): Image ▸ Color Profile ▸ Assign…/Convert… open one
native form seeded from the cached color state — built-in profile or an
ICC file chosen with an open panel (.icc/.icm, full path), plus the four
facade rendering intents and black-point compensation on Convert. The
sheet reads no engine state and no file on the main thread; Apply
captures the document, finishes field edits, revalidates busy/closed and
runs through the same counted engine-wide exclusive admission as the
mode and precision conversions, so close/Quit wait, refusals report and
file identity is preserved. Assign explains reinterpretation, Convert
explains appearance preservation. Convert is disabled in the menu and
refused by the document guard on indexed images (the native palette
conversion ignores intent/BPC); Assign stays allowed there for a
compatible RGB profile. `EngineSession` gained the typed
`ProfileIntent` (facade values 1–4) and the `assignProfile`/
`convertProfile` wrappers over the appended facade slots; no C changes.
Pure unit tests cover the menu entries, source/intent choices, ICC path
validation, the indexed guard, the cached profile summary and the
Codable captured settings; `exerciseColorProfiles` in the engine smoke
covers typed assign/convert on the generated fixtures, form
seed/Cancel/Apply/error, undo, XCF round trip and per-sheet document
capture. Only `swift build` and `swift build --build-tests` were run in
this worktree; `swift test`, the smoke run and on-screen QA were not (the
default engine has no ICC support). Proof/display transforms and indexed
conversion remain separate slices.

2026-11-08 Pattern fill source: Edit > Fill gains Pattern (index 5), an
embedded searchable list of the engine's full pattern catalog with lazy
32 px thumbnails rendered off the main thread through the engine gate.
The choice persists as a ResourceIdentity only and resolves fresh on the
input queue at execution; a removed pattern is reported missing and the
fill refused, never substituted. Pure model/store/queue checks and actual
sheet-driving checks cover selection, previews, source toggling, pixels,
undo, persistence, refusals and cleanup. Final matrix verification is pending.

2026-11-08 selection and layout checkpoint: Stroke Selection (#66),
Paste Into and Float Selected Pixels backends (#67–#68), direct guide
dragging (#69), ordered layer-selection backend (#70) and preset storage
(#71) are merged. Floating-selection controls integrate those changes with
521 passing unit tests, 53 focused checks on each engine and 1,367 full
pinned workflow checks. Native ordered-selection suites pass 1,777 / 1,563 /
1,777 / 1,777 checks. UI preset controls and layer multi-selection remain in
progress; snapping has a checked pure planner but no merged gesture UI yet.
The assembled app at 4ba46ee includes its engine and later controls, but
has not had a new self-contained bundle check; it is an intermediate build.
Final combined bundle and real editing verification remain open.


2026-11-09 integration checkpoint: #75 (layer multi-selection), #76 (canvas
snapping), #78/#83 (shortcut customization/menu routing), #79 (native error
ownership), #80/#82 (metadata value/descriptor backend), #84 (weak saved-set
lifetimes), and #87 (Float Selected Pixels, also integrating existing floating
moves from #85) are merged. The ordinary app is an editor rather than the
initial engine-free placeholder, but the final completion gate remains open.

Open reviewed slices are tracked in #81/#86 (metadata controls), #88/#92
(resource creation and selection controls), #89 (paint-target view boundary),
#90 (native floating interaction policy) and #91 (adjustment group backend).
Their separate local acceptance runs are not final integrated-bundle evidence.
The updated metadata UI head passes 701 unit/build checks, 45 existing controls,
24 descriptors and four injected-failure checks on every engine, and 1,769
full pinned app checks. The resource UI head passes 696 units, 65 focused
checks on every engine and 1,765 full pinned checks. Native adjustment creation
passes 95 standalone checks on every engine. Exact-head hosted CI and merge
state remain per-PR gates; the visible checkboxes describe merged main only.

The intermediate dist/Glims.app is not the final verified revision. Final
engine/runtime matrices, self-contained packaging and real editing/file
workflows must run again after the remaining feature integrations.

The combined controls candidate additionally reproduced a host-window-close
metadata callback defect. Explicit form invalidation in `windowWillClose`
fixes the failing real-window oracle. Its integrated pinned app smoke run
passes 1,891 checks, including metadata/resource/adjustment forms and the
paint-target boundary. These checks cover the candidate, not the remaining
A–Z completion work or a final distributable bundle.


2026-11-09 state integration: reviewed source includes per-window ICC canvas,
resource duplication and saved-set management. Individual runtime evidence:
789 combined units; 58 duplicate, 27 destination and 62 saved-set focused app
checks per engine; separate full slices pass 1,949 / 1,918 / 1,953 app checks.
Every combined native engine passes 1,917 / 1,703 / 1,917 / 1,917 general checks,
155 Undo, 146 edit, 56 read and 188 lifetime checks. Corrected wide-source
harness passes 40 display checks on every engine; an actual forced legacy
sRGB-u8 roundtrip fails exactly the wide identity check. The combined pinned app run passes 2,038 checks; the remaining three engines
also pass every combined focused control case. The self-contained release
bundle passes 1,917 native and 2,038 app checks with native and Swift build
outputs denied. Fourteen packaging tests pass. Independent integration
review found no important issue. Exact-head hosted CI remains pending;
these results do not close the broader unchecked work above.

2026-11-09 metadata API checkpoint: PR118 adds the owned single-existing-language
writer and counted document wrappers. Each of all four native engines passes
39 public edit/Undo/no-op/busy/save/reopen checks and13 native Undo-admission
checks. A reproduced plug-in-left Undo-disabled state now refuses changed
metadata edits in both writers while allowing exact no-ops. Hosted CI passed.
Dedicated language controls pass14 real-window checks and counted-document
work passes13 checks perengine. The trackpad candidate passes22 window checks
perengine. Combined release validation remains pending.


2026-11-09 snapshot-input candidate: API v1 appends slot147 for captured
Bump Map inputs. The real chooser and merged-pixel editor pass20 focused
checks on each of all four engines; the self-contained bundle passes1,917
native and2,370 app checks with build outputs blocked, and871 unit tests
pass. Independent native/UI source reviews report no important remaining
findings after the Undo admission and idle Escape corrections. Expanded
source-kind, sparse-budget and XCF acceptance is recorded in
`filter-inputs.md`; this entry does not close the other auxiliary/config
forms or the final whole-editor gate.


2026-11-09 adjustment integration candidate: source `e65a01d` includes the
reviewed Brightness/Contrast, Color Balance, Hue/Saturation and Levels
controls plus the complete AOM text. All 956 unit tests pass. Levels' final
native suites pass 492 focused/1,917 general checks per 3.2/master engine
and 475 focused/1,703 general on 3.0.8. Its 21 focused UI checks pass on
each engine, and the final self-contained bundle passes 1,917 native and
2,520 app checks with native and Swift build trees inaccessible. A generic
TRC-write/new-commit invariant gap was reproduced with four failing
assertions, fixed and checked across the matrix. Latest-head CI and merge
remain pending. The remaining unchecked items above are not complete.
