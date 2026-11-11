# Lens Blur native contract

Lens Blur has a modeless Blur mask chooser with explicit None for uniform blur. Preview captures the owning document, target and optional map before opening the installed native property form. Apply to Pixels makes one Undo step; Cancel preserves stored pixels and history. Native production `38b37d1` and Swift production `1d8b7af` are integrated with the color-property fixes at `5c0ef00`. Independent native and Swift source reviews found no important issue in their respective production scopes.

## Input and map ownership

Existing facade slot 147, `filter_begin_with_source`, admits `gegl:lens-blur` with an explicit target and either source 0 for **None**, giving uniform blur, or a positive same-image drawable ID for the radius map. Other operations using this slot still require a positive source. Generic Lens begin also routes through this owned None path.

The target must be a pixel layer. Groups and editable structured sources must be rasterized explicitly before serving as merge targets. Indexed images, an unresolved floating selection, conflicting work, pixel locks, and unavailable or grouped Undo are refused through the existing admission policy.

A map is captured with its committed effects into detached native-format storage before preview attachment. Its format, extent and abyss are retained. Coordinates remain those of its native buffer; the adapter adds no translation for the source item's image position. Later source edits, deletion and Undo-history purge cannot change the captured map. The session retains no live source graph.

Lens consumes either linear `Y float` or perceptual `Y' float` luminance in the map's own working space. Both converted views are checked before the snapshot is exposed. Samples must be finite and nonnegative, with an upper allowance of eight float ULPs above 1 for conversion roundoff. This preserves authentic stock white: the observed perceptual conversion was `1.000000119`. The adapter neither clamps samples nor replaces their pixels. Values outside this bounded conversion range are refused.

## Preview, Apply and Cancel

None and mapped Lens are merge-only pixel operations. Attachment keeps both native preview and filter activity disabled while the temporary filter is placed below existing committed effects, at the raw-input end of the stack. The selection mask is frozen there before preview becomes active. A busy fence covers preparation and attachment callbacks.

Changing preview settings creates no Undo entry. Apply merges into target pixels as one native Undo operation, with Undo/Redo restoring the measured pixel states. Cancel removes the temporary preview without changing stored pixels or history. No auxiliary map connection is persisted as an editable XCF effect. Imported Lens effects are not admitted for parameter editing because they have not passed this owned input contract; this restriction does not attest to arbitrary imported graphs' overall safety.

## Geometry and setting limits

Admission validates actual buffer constructor ranges, extent and abyss, tile/storage shifts, native SUPERSET padding, and byte limits before copying or scanning. The snapshot limit is 512 MiB. Target placement and selection-local coordinates are checked using widened arithmetic before native signed-integer operations.

Radius must be finite, nonnegative and at most 46340, with additional image-dependent limits. Both native double and float radius rounding are considered; the geometry envelope includes the bounded map conversion margin. Ring indices, output dimensions, tile increments and allocation products must stay in their native domains. Scratch accounting includes RGBA/weight rings, the optional map ring and output rows, conservatively budgeting for all 64 native workers. Snapshot, converted-scan, output and scratch bounds are distinct; they are not a guarantee about total process memory. Refused image/radius combinations may require a smaller image or Radius even below the arithmetic cap.

Both the legacy numeric setter and typed property setter validate the prospective full Lens tuple before mutating the operation. Native float conversions must remain finite; enabling highlights with a collapsed or nonfinite float threshold denominator is refused. The legacy setter retains its existing parameter-range clamping behavior. Commit repeats the current geometry/settings and Undo-readiness checks before mutation. A refusal leaves the preview available for correction or Cancel.

## Evidence and limits

Fresh raw GEGL graph controls independently cover None, zero and ramp maps: zero is an identity control, while None and ramp produce nontrivial blur. Lifecycle checks cover preview/Apply, Cancel, Undo/Redo, both setter paths, invalid maps and settings, and source edit/delete/purge independence.

The earlier baseline ran 26 checks with two missing-route failures. Geometry refinement retained the metadata-only boundary failures: 160/5, then 162/2, then 162/0. An initial constructor-fixture exit −5 used values outside actual GObject property ranges; that fixture setup was corrected. It is not evidence of a product crash. Boundary fixtures deliberately construct metadata without native copy, read or alignment on those boundary buffers.

The final pinned result is recorded in `/tmp/glims-completion/lens-tile-domain-final-run/{native.log,run.json}`. The other three verified results are indexed by `/tmp/glims-completion/lens-38b37d1-other-three-results.json`; each log contains 162 passing checks and no failures. The source review is `/tmp/glims-completion/lens-blur-38b37d1-independent-native-review.md`.

The combined `5c0ef00` source passes all 1,220 unit tests, 648 focused Lens native checks and 7,454 general native checks across the four engines. The fresh combined runs are indexed by `/tmp/glims-completion/lens-5c0ef00-combined-native/{results,counts}.json`. These results establish the bounded native contract; final standalone packaging and public distribution remain separate gates.

## Captured source controls

None is the initial explicit selection even when the target is offered as a
source. It passes a null map to native Lens; the UI does not invent a white
image. Positive explicit map IDs retain the existing same-image validation.
A removed chosen map stays visible as a disabled missing choice. Refresh
never silently replaces it with None. Late Preview after owner close is
invalidated, and queued native work stays counted until cleanup drains.
Other mandatory single-source and paired-source filter contracts are unchanged.
Imported Lens effects remain excluded from generic parameter editing.

The old real-window baseline failed the installed-menu admission. The new
19-check window fixture drives the actual menu, accessible mask popup,
Radius field, Apply, Cancel, Undo and Redo. It makes a second document the
actual main/key window before Preview and checks the first document remains
the owner. Black is an identity control within one byte; None and the ramp
have distinct measured results. Source removal, forced stale Preview, close
and late Preview preserve the corresponding native history and drain work.
The first fixture wait used only RunLoop polling while the host suspended its
outer AppKit event loop. Pumping actual AppKit events fixed that test setup;
no menu enable override or forged focus state was added.

All 19 actual-window checks pass on each engine, 76 total, using the combined
native adapters and a signed debug host. Raw runs are indexed in
`/tmp/glims-completion/lens-5c0ef00-ui-results.json`; the host's signed and
unsigned binary hashes are retained in `lens-ui-event-pump-host/source.json`.
These runs use explicit source adapters and do not establish standalone
bundle loading. The general native runs retain the older 3.0.8 two-buffer
cleanup diagnostic and master cache-XML cleanup messages; this slice does
not fix those upstream paths.

The combined ordinary editor workflow also passes all 3,233 checks with
no filter case selected: `/tmp/glims-completion/lens-5c0ef00-broad.CO8ywN`.
This uses the signed debug app and explicit current pinned adapter, with
Main's Swift build tree denied; it is not a standalone release check.
Xcode 26 CI initially rejected the fixture's combined channel expression
at type checking. Explicit typed per-channel appends retain the same bytes.
