<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 2: Review (churn-recount)

Would change recommendation: False

## Summary

I tried to refute AC's API-churn numbers by recounting every tag interval with my own whitespace-immune prototype parser and my own commit classifier. Scripts are in /tmp/gimp-fork-research/skeptic-scripts/ (decls.py, split.py, libapi.py, toolprops.py, proptypes.py, types.py), trees in /tmp/gimp-fork-research/skeptic-work/<tag>, outputs in /tmp/gimp-fork-research/skeptic-work/out_*.txt. I read text only; nothing from GIMP was built or run.

**The binding-churn numbers hold up.** The same functions broke in all 11 intervals, and call sites agree within 2: 3.0.6 gives 59 vs 57, 3.0.8→3.2.0 gives 11 functions and 19 sites exactly, 3.2.8 gives 4, master gives 28 vs 26. Also confirmed:
- micro median 0, mean 8, zero in 5 of 8;
- public libgimp: no removals or signature changes;
- 27 GimpGui hooks at every tag;
- 744 `gimp->` field accesses at master;
- commit counts and the commit split per interval.

**Corrections:**
1. The 32-vs-8 removals dispute is explained by 24 redundant `*_get_type` prototypes deleted under `G_DECLARE_DERIVABLE_TYPE`, not by whitespace. AC's 8 is right.
2. The "silent breaks" class is narrower than the memo implies. It misses:
   - tool-option property renames on the UI side;
   - changed macro values (MAX_CHANNELS, preview size);
   - mid-enum insertions;
   - behaviour changes such as a07fc869 (3.0.8) and a950e630 (3.2.6).

   The startup checks would catch none of these.
3. The "UI-behaviour fixes to port" figures reproduce exactly with AC's focus list, but they depend heavily on the definition. Counting mixed commits and all of app/display and app/tools raises them to about 2–65 per micro and about 190 for the minor. My sample suggests a third to two thirds are platform-specific GTK changes, so they are commits to triage, not fixes.
4. Nobody counted dependency or feature changes in micro releases:
   - 3.0.2 and 3.0.4 required newer GEGL/babl;
   - 3.0.6 swapped appstream-glib for appstream in engine code;
   - 3.2.6 raised the XCF version to 26 and added a tablet rotation dynamics input;
   - 3.2.4 made Crop always non-destructive.

None of this changes the ranking: option 1 is still cheapest to keep compiling. But "trivial" micro updates should be expected to include occasional GEGL/babl rebuilds, XCF-version handling on stable tags, and more triage than the memo states.

## Claims checked

### CONFIRMED: Broken call sites per micro release: median 0, mean about 8, worst 57 (3.0.6), zero in 5 of 8 intervals [M, AC]

**Evidence.** I recounted with my own method, not AC's scripts. /tmp/gimp-fork-research/skeptic-scripts/decls.py parses whole engine headers into normalised prototypes with parameter names dropped, so whitespace cannot affect it, then counts word-boundary references in comment-stripped app/{actions,dialogs,display,gui,menus,tools,widgets,propgui} at the older tag. Trees came from my own git archive of /tmp/gimp-fork-research/full-apichurn.git into /tmp/gimp-fork-research/skeptic-work/<tag>; tag hashes match the separate hist clone. Results for the 8 micro intervals: 0, 0, 59, 0, 0, 1, 0, 4, giving median 0, mean 8.0 and zero in 5 of 8. The functions match AC's exactly: 3.0.6 get_children_type plus 4 gimp_viewable_get_* functions; 3.2.4 gimp_pickable_contiguous_region_by_color; 3.2.8 gimp_image_pick_color. I get 59 sites for 3.0.6 rather than 57 because I count 19 viewable sites where AC counts 17. Outputs are in /tmp/gimp-fork-research/skeptic-work/out_*.txt.

**Correction.** Worst case is 57–59 depending on how references are counted. These are references from GIMP's own UI, used as a stand-in for the adapter's call sites; they are not the adapter's call sites.

### CONFIRMED: 3.0.8→3.2.0 broke 11 surface functions (19 call sites) and moved 34 #include lines in 19 UI files (app/vectors→app/path) [M, AC]

**Evidence.** My count: 3 removed (gimp_curve_set_curve, gimp_image_undo_push_text_layer_modified, gimp_text_layer_discard) plus 8 changed (file_open_image, file_open_layers, file_open_with_proc_and_display, gimp_bezier_stroke_extend, gimp_drawable_transform_paste, gimp_gegl_get_op_classes, gimp_image_merge_down, gimp_layer_add_mask) = 11 functions and 19 call sites. grep at 3.0.8 finds 34 '#include "vectors/' lines in 19 UI files. The full development line 3.0.4→3.2.0 gives 16 functions and 78 call sites (AC: 76), because 3.0.6 had already backported part of that cycle's changes.

### CONFIRMED: 3.2.6→3.2.8: one signature change (gimp_image_pick_color gained GeglBuffer**) with 4 call sites, committed 2026-11-01, tagged 2026-11-02

**Evidence.** decls.py shows 1 changed surface function with 4 references in 4 files; engine-wide 3 removed and 1 changed, as AC reports. git log shows 67084b71 authored and committed 2026-11-01 14:17/14:57 +0100; the GIMP_3_2_8 tag points at 7addd2b7, committed 2026-11-02 19:02. Running 3.2.0→3.2.8 directly gives 2 functions and 5 call sites in total.

### CONFIRMED: 3.2.8→master: 1 rename and 6 signature changes among UI-used functions (26 call sites), plus 1 GimpGui hook

**Evidence.** Mine: gimp_progress_get_window_id removed, and changes to gimp_drawable_get_sub_preview_async, gimp_gegl_buffer_dup and gimp_viewable_get_{pixbuf,new_pixbuf,preview,new_preview}: 7 functions, 28 references. In the GimpGui struct, display_get_window_id became display_get_window_handle (ed668b3e, 2026-10-09).

### OVERSTATED: Disagreement: EH counts 32 engine-wide removals 3.2.8→master, AC counts 8, and AC showed that whitespace realignment produces false positives

**Evidence.** My parser cannot be fooled by whitespace and still finds 32 removed declarations. 24 of them are explicit *_get_type prototypes deleted when classes moved to G_DECLARE_DERIVABLE_TYPE, which still declares them; I checked gimp_clone, template, imagefile, object, viewable, data_factory, pencil_options and others in master headers. The other 8 are real removals: gimp_get_display_by_id, gimp_get_display_id, gimp_get_display_window_id, gimp_plug_in_progress_get_window_id, gimp_progress_get_window_id, gimp_rc_migrate, gimp_cursor_format_get_type and gimp_help_browser_type_get_type.

**Correction.** AC's 8 is the right count of real removals. The gap to 32 is explained by the G_DECLARE get_type prototypes, not by whitespace. I could not check EH's actual method.

### CONFIRMED: Public libgimp: 0 removals and 0 signature changes in every interval [M, AC]

**Evidence.** /tmp/gimp-fork-research/skeptic-scripts/libapi.py compares all .def exports and the prototypes in public headers. For 3.0.4→3.0.6, 3.0.8→3.2.0, 3.2.6→3.2.8 and 3.2.8→master it finds no removed exports and no changed exported prototypes. The libgimpbase headers gimpprotocol.h, gimpwire.h and gimpsignal.h were renamed to *-private.h in 3.2.8 (8f2d34df, 3ff8a195), but libgimpbase/meson.build shows they were never installed. Deprecation-marker counts of 4, 26, 28 and 33 reproduce. The versioning-page quotes match https://developer.gimp.org/core/maintainer/versioning/ (updated 2025-11-21), which says nothing about app/ internals or dependency bumps.

### OVERSTATED: Breaks the compiler cannot see, 3.0.0→master: 1 signal gained an argument and 5 properties were renamed or removed

**Evidence.** For engine signals and UI-used engine property names my count is identical: GimpContainer::reorder went from 2 to 3 parameters in 3.0.6; the properties are children-type (3.0.6), linear, auto-rename and modified (3.2.0), and help-browser (master). No property changed type in any interval (/tmp/gimp-fork-research/skeptic-scripts/proptypes.py). But treating these as the complete set of silent breaks is too narrow. Things it misses: (a) tool-option properties renamed on the UI side in 3.2.0, which tool presets depend on: align-vectors→align-paths, paint-select mode→operation, vectors-edit-mode/vectors-polygonal→path-* (toolprops.py); (b) changed macro values that the UI uses: GIMP_VIEWABLE_MAX_BUTTON_SIZE (3.0.6), MAX_CHANNELS 4→5 and GIMP_VIEWABLE_MAX_PREVIEW_SIZE 2048→8192 (3.2.4); (c) enum values inserted mid-enum: GIMP_LAYER_MODE_OVERWRITE (3.2.0, shifts ANTI_ERASE), GIMP_UNDO_GROUP_VECTOR (3.2.2), and GP_PERSISTENT_ACK on master (shifts GP_HAS_INIT); (d) behaviour changes with unchanged signatures: a07fc869 (3.0.8, saving or exporting no longer requires a selected layer) and a950e630 (3.2.6, new selected-drawables-changed signal that the tool manager now needs to avoid crash #16105).

**Correction.** Say instead: 1 signal and 5 engine properties are the string-keyed breaks found. Macro, enum, UI-side option-property and behaviour changes also occur, and neither the compiler nor the g_signal_query/find_property startup checks catch them.

### OVERSTATED: The adapter's startup checks (g_signal_query arity, g_object_class_find_property) catch the breaks the compiler misses

**Evidence.** Those checks would catch the reorder arity change and the 5 property renames or removals. They would not catch a950e630 (crash fix that depends on subscribing to a new signal), a07fc869 (changed precondition), 568afe80/c480a661 (filter undo and temporary-filter semantics in 3.0.4 and 3.0.6), the 3.2.6 move to XCF version 26 (9bcb0ad5), or macro and enum value changes copied into Swift.

**Correction.** They catch string-keyed renames and arity changes only. Behaviour changes depend on the conformance tests and on triaging GIMP's UI commits.

### OVERSTATED: UI-behaviour fixes to port by hand: 0–39 per micro release (typically 5–25), about 101 per minor [M, AC]

**Evidence.** With AC's 108-file focus list (/tmp/gimp-fork-research/apichurn-out/focus_files.txt) my own commit classifier (/tmp/gimp-fork-research/skeptic-scripts/split.py) reproduces 39 (3.0.6), 101 (3.2.0), 0, 25, 14 and 61. But the figure depends on definitions. (1) It leaves out mixed engine+UI commits that touch focus files: 15 in 3.0.6, 51 in 3.2.0, 10 across 3.2.0→3.2.8. Some of these need hand ports and cause no break, for example a950e630. (2) The focus list has only 15 of about 90 app/display .c files; it omits tool widgets, canvas items and display colour management. Counting all of app/tools and app/display plus mixed commits gives 3, 19, 65, 11, 2, 17, 41 and 24 per micro, and 190 for 3.0.8→3.2.0. (3) These are commits to triage, not fixes. Of the 22 broad-focus commits in 3.2.6→3.2.8, about 13 are GTK, Windows, monitor-scale, X11 or accessibility specific.

**Correction.** The measured figures are commits to triage, not fixes: 0–65 per micro and 100–190 per minor depending on scope. My inferred estimate is that about a third to two thirds need porting.

### CONFIRMED: Triage the 48 editor-relevant UI commits from 3.2.0 to 3.2.8

**Evidence.** split.py with AC's focus list over GIMP_3_2_0..GIMP_3_2_8 gives 48 UI-only focus commits, plus 10 mixed focus commits. With the broader scope it is 69 + 15.

### CONFIRMED: Commit counts per interval and the engine-only / UI-only / mixed split

**Evidence.** git rev-list --count gives 54, 280, 817, 468, 2415, 2436, 200, 258, 871, 300 and 2076, all without merges. My split matches AC within ±1, for example 3.2.8→master: 249 engine-only, 265 UI-only, 43 mixed. Topology is confirmed: gimp-3-0 branched at abfd6cd6 and gimp-3-2 at c246727b; 3.0.6 and 3.0.8 are on gimp-3-0; 3.2.4 is an ancestor of the gimp-3-2 branch point.

### CONFIRMED: GimpGui vtable has 27 hooks at every tag

**Evidence.** Counting function-pointer members of struct _GimpGui in app/core/gimp-gui.h gives 27 at 3.0.0, 3.0.8, 3.2.0, 3.2.8 and master. The struct is identical from 3.0.0 to 3.2.8; master renames one hook.

### CONFIRMED: The UI uses gimp-> 744 times across 39 fields (config 313) and image->gimp 219 times at master; no engine *-private.h is included

**Evidence.** grep -oE 'gimp->[a-z_]+' over the master UI dirs gives 744 uses, 39 unique fields, gimp->config 313; image->gimp 219. The only private headers the UI includes are UI-internal ones (gimpcontainertreeview-, gimpcontainerview-, gimpsessioninfo-private.h) and libgimpcolor/gimpcolor-private.h and libgimpwidgets-private.h.

### OVERSTATED: Not one GObject type name was removed or renamed in any interval

**Evidence.** /tmp/gimp-fork-research/skeptic-scripts/types.py finds no GIMP_TYPE_* object-type macros removed. On master, however, the enum GTypes GIMP_TYPE_CURSOR_FORMAT and GIMP_TYPE_HELP_BROWSER_TYPE (config-enums.h) were removed.

**Correction.** No object type was removed; two enum GTypes were removed on master.

### OVERSTATED: Stable micro releases are usually a rebuild with no adapter edits; new engine features needing native UI come with minor releases (memo §3)

**Evidence.** For the bindings this holds: tag to tag, 5 of 8 micros have zero UI-surface breaks. But micros also ship (1) dependency bumps that the macOS build must follow: 3.0.2 GEGL 0.4.56→0.4.58; 3.0.4 babl 0.1.112→0.1.114 and GEGL →0.4.62; 3.0.6 an engine dependency swap from appstream-glib 0.7.7 to appstream 0.16.1 (c27096db in app/core/gimpextension.c); 3.2.6 gdk-pixbuf 2.30.8→2.32.0 (from the *_minver lines in each tag's meson.build); (2) features: 3.2.6 added a tablet rotation input to dynamics (d633c645, whose cherry-pick note says it 'could kinda be considered a new feature'; new properties use-rotation and rotation-curve) and raised the XCF version to 26 (9bcb0ad5, saving channel filters); 3.2.4 made the Crop tool always non-destructive (82e70694); (3) engine API removals outside GIMP's UI surface: 3.2.4 removed gimp_drawable_get_active_components and gimp_image_get_{active,visible}_array, and 3.2.8 removed the menu-branch API and the menu-branch-added signal.

**Correction.** Treat micros as usually free for the bindings, but sometimes they bring GEGL or babl rebuilds, a new XCF version or a small feature that needs native UI. The XCF watch should cover stable tags too, not only master.

### UNVERIFIABLE: Update cost: micro hours to 1 day; minor 2–5 days to compile and 1–3 weeks for parity [I, AC]

**Evidence.** This is an estimate and cannot be measured from history. The compile-side inputs hold (micro worst 59 GIMP-UI references, 6 in focus files; minor 11–16 functions). The estimate leaves out dependency rebuilds, changes to the GIMP startup files the adapter compiles (3.2.0→3.2.8: about 268 lines in app/main.c, 112 in language.c, 44 in unique.c, 33 in app.c), and parity work that may be up to about 1.9 times AC's count.

### UNVERIFIABLE: Master nightly: about 1 breaking commit per 2 weeks during a dev cycle, about 1 per 6 weeks after a branch point

**Evidence.** I did not rerun the per-commit analysis. The arithmetic follows from AC's own figures: 20 commits in about 43 weeks is 1 per 2.15 weeks, and 5 in 28.5 weeks is 1 per 5.7 weeks. My tag-to-tag results are consistent with these orders of magnitude.

## Missing considerations

- Dependency bumps are an update cost nobody counted, including in micro releases. 3.0.2 and 3.0.4 required newer GEGL/babl; 3.0.6 swapped appstream-glib for appstream in engine code; 3.2.0 bumped babl 0.1.118, GEGL 0.4.66 and libmypaint 1.5.0; 3.2.6 bumped gdk-pixbuf 2.32; master requires json-glib 1.8. The app calls GEGL directly, so GEGL changes reach the adapter as well as the build.
- Mixed engine+UI commits are excluded from the 'fixes to port' count, yet some need hand ports without causing any break, e.g. a950e630 in 3.2.6 (tool_manager must listen to selected-drawables-changed to avoid crash #16105).
- The 108-file focus list leaves out most of app/display (tool widgets, canvas items, display colour management) and parts of app/tools. A broader scope gives about 1.3–1.9 times more commits to triage.
- Micro releases carry features and format changes. Examples: XCF version 26 in 3.2.6, the tablet rotation dynamics input in 3.2.6, Crop always non-destructive in 3.2.4. The conformance plan watches for XCF bumps on master only.
- Tool-option classes live in GTK-bound app/tools, so their properties are outside the engine surface. 3.2.0 renamed 4 of them and added 27; master added 25 (new shape tool). Compatibility with GIMP's tool presets and tool-options files must be tracked by hand. I infer the engine's GimpToolPreset loading needs those option types registered.
- Changed macro values the UI uses (MAX_CHANNELS 4→5 and GIMP_VIEWABLE_MAX_PREVIEW_SIZE 2048→8192 in 3.2.4) and mid-enum insertions (GIMP_UNDO_GROUP_VECTOR in 3.2.2, GIMP_LAYER_MODE_OVERWRITE in 3.2.0, the GP protocol enum on master) are harmless only if neither the adapter API nor the Swift code copies these values.
- GIMP startup files that the adapter compiles unmodified (app/main.c, app.c, language.c, unique.c, errors.c) change materially in micro releases, and no churn metric covers them.
- Engine functions outside GIMP's own UI surface are removed in micros (3.2.4: 3; 3.2.8: the plug-in menu-branch API and its signal). This matters if the adapter calls more than GIMP's UI does.
- 'Call sites' counts GIMP's own UI references, not adapter calls. Focus-file sites are much smaller (worst micro 6), so binding effort could be lower than the headline numbers. Semantic changes are not proportional to call sites.
