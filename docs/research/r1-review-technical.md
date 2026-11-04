<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 1: Review (technical)

Would change recommendation: True

## Summary

I checked against a GIMP master clone (2aef5e7, 2026-11-03), the GIMP_3_2_8 tag, and a blobless clone of the last year's history. Most of the memo's raw numbers hold: about 385–392k GTK-free lines, 14 console libraries, 27 vtable hooks, 36 shell functions, 265 core and 212 widgets commits a year, and a 1,325-line theme. The no-AI checkbox dates from 2026-10-03.

Several claims that drive the decision are overstated or wrong:
1. **Tool coupling is understated.** GimpDisplayShell is a GTK widget, and tool widgets, canvas items and all 36 tool-options files depend on GTK. A tool stand-in without GTK isn't possible without patching GIMP, so the memo's own B no-go condition is already met and the tools must be rewritten.
2. **Filter undo is not in core.** GimpDrawableFilter's undo behavior lives in the GUI-side gimpfiltertool.c and must be reimplemented.
3. **The popover-versus-filter argument is wrong.** Filters are non-destructive by default in GIMP 3, so committing doesn't trigger a full-resolution render.
4. **'Link like gimp-console' hides a runtime path never exercised.** A GUI host needs no_interface=FALSE, which no shipping binary runs without GTK, and which enables modules and tool presets that depend on GTK.
5. **The main-loop plan points the wrong way for nested loops.** It needs a GLib poll function that also services AppKit.
6. **Core churn is not small.** It is larger in lines than GUI churn.
7. **GTK4 is only light preparation.** No port has started, and app/tools is untouched beyond show/hide changes.
8. **Layer multi-select already exists** in GIMP 3.0.
9. **Option D needs corrections.** Ship a theme directory, not theme.css, which GIMP regenerates. Plug-in dialogs do follow the theme. Menus can't be changed from user config.

The two-track plan (D now, a B spike in parallel) can stay, but B should be re-scoped and re-costed as a native rewrite of all tools and filter UIs over GIMP's core. It still has to ship GTK3 for the file-format and interactive plug-ins.

Sources: https://developer.gimp.org/core/roadmap/ , https://www.phoronix.com/news/GIMP-3.2.6-Released , https://www.omgubuntu.co.uk/2026/08/gimp-new-project-file-format , https://gitlab.gnome.org/GNOME/gimp/-/blob/master/.gitlab/merge_request_templates/default.md . Local evidence: /tmp/gimp-fork-research/gimp (app/core/gimp-gui.h, app/meson.build, app/tools/gimpfiltertool.c, app/core/gimpdrawablefilter.c, app/display/gimpdisplayshell.h, app/gui/themes.c, libgimp/gimpui.c, app/widgets/gimpuimanager.c) and /tmp/gimp-fork-research/hist/gimp-hist.git.

## Claims checked

### OVERSTATED: About 394k lines of GIMP (core, pdb, paint, gegl, xcf, plug-in host, config, text, base libraries) are free of GTK and can be linked the way gimp-console does it.

**Evidence.** The line count and GTK-freeness hold. In the master clone (commit 2aef5e7, 2026-11-03), app/{core,file,file-data,gegl,pdb,plug-in,paint,path,text,xcf,operations,config} plus libgimp{base,color,config,math,module,thumb} come to 385,272 lines of .c/.h; app/*.c at the top level adds about 7.2k. None of those directories include gtk/, gdk/, widgets/, display/ or tools/ headers, and none of their meson dependency lists contain gtk3. What is overstated is 'linked the way gimp-console does it'. gimp-console builds app.c and main.c with -DGIMP_CONSOLE_COMPILATION and forces no_interface=TRUE. With that flag, core never creates displays (app/display/gimpdisplay.c:378), file-open is forced to RUN_NONINTERACTIVE (app/file/file-open.c:467), tool presets are skipped (core/gimp-data-factories.c:437), modules are not loaded (core/gimp-modules.c:68), and the progress and resource-select PDB calls become no-ops. A GUI front end has to run with no_interface=FALSE. No shipping binary runs that code path without GTK, and the front end needs its own replacement for app.c's startup, whose GUI branches are #ifdef'd onto GTK. The memo's own figure is also inconsistent: section 3 says 394k, section 4 says ~350k.

**Correction.** The GTK-free set is about 385–392k lines. Linking it is easy. Running it as a GUI host with no_interface=FALSE, and without GTK in the process, has never been exercised and is the real risk the spike should test.

### OVERSTATED: GIMP's GUI-free part is 14 static libraries, and the intended front-end entry point is the 27-hook GimpGui vtable plus a GimpDisplay subclass.

**Evidence.** The counts are right. app/meson.build has console_libapps = 14 libraries (core, file, filedata, gegl, internalprocs, layermodes, layermodeslegacy, operations, paint, path, pdb, plugin, text, xcf); libappconfig is appended later, making 15. app/core/gimp-gui.h has exactly 27 function pointers in both GIMP_3_2_8 and master. core/gimpdisplay.h is a GimpObject base class, and app/display subclasses it as GimpDisplayImpl. 'Intended' goes too far. This is an undocumented internal interface, and it changed between 3.2.8 and master: display_get_window_id was renamed to display_get_window_handle in commit ed668b3e (2026-10-09). The vtable also only carries callbacks from core to the GUI. Everything going the other way (about 40k lines of app/actions command logic and about 40k of app/dialogs) has to be rewritten.

**Correction.** It is a workable seam, but an internal one, not a supported API. The rebase drill should expect breaks like the ed668b3e rename.

### OVERSTATED: The tools have 770 GDK references and use 36 display-shell functions, so they must be rewritten or run through a stand-in for the display shell.

**Evidence.** The 36 distinct gimp_display_shell_* functions used in app/tools are confirmed exactly. My regex finds 863 GDK references, not 770 (212 GDK_/gdk_ macros and functions, 651 Gdk* types). The bigger problem is that the claim understates the coupling. app/tools also has 4,049 GTK references; 100 of its 116 .c files include widgets/ headers; there are 154 calls to gimp_display_get_shell. GimpDisplayShell is a GtkEventBox (gimpdisplayshell.h:50). GimpToolWidget and GimpCanvasItem keep GimpDisplayShell pointers. All 36 *options*.c files (13.5k lines), which define the tool-options GObjects, live in app/tools and #include <gtk/gtk.h>. So a stand-in without GTK is not possible without patching GIMP, and the realistic path is to rewrite app/tools (82k lines), the display tool widgets (21.8k) and canvas items (12.6k) on top of app/paint and core.

**Correction.** Treat the tools as a full rewrite in Swift on top of gimp_paint_core_* and core item APIs. The memo's own no-go condition ('tools or display need deep stand-ins for GTK-bound code') is already met by reading the source.

### OVERSTATED: GimpDrawableFilter already has preview, split, commit and abort, which maps almost exactly onto Rigi's try-on contract of one undo step per session.

**Evidence.** The API exists in app/core/gimpdrawablefilter.h: set_preview, set_preview_split, commit(non_destructive, progress, cancellable) and abort. But commit with non_destructive=TRUE pushes no undo at all (gimpdrawablefilter.c:1566-1628). The undo steps (gimp_image_undo_push_filter_add and filter_modified), the choice between non-destructive and merged, editing an existing filter, and the exceptions for aux pads and gegl:gegl all live in app/tools/gimpfiltertool.c (2,632 lines, lines 553-616 and 1242-1380). That file is GUI code and depends on GTK and the display shell.

**Correction.** The building blocks are in core, but the commit and undo logic in gimpfiltertool.c has to be reimplemented in the bridge.

### REFUTED: Rigi's popover try-on is wrong for filters, because a click outside the popover commits a full-resolution render.

**Evidence.** In GIMP 3 the default commit is non-destructive. The merge-filter option defaults to FALSE (app/tools/gimpfilteroptions.c:113-118). A non-destructive commit does not merge (gimpdrawablefilter.c:1589-1612); the filter stays live in the graph. The projection renders lazily from GLib idle handlers in chunks, visible area first (core/gimpprojection.c:522, 692, 743). A full-resolution render only happens on merge, flatten or export.

**Correction.** The real argument for dialogs is the size of the parameter UI, on-canvas controllers, and accidental filter-stack entries on dismissal. Render cost is not the issue.

### OVERSTATED: Native dialogs can be generated automatically from parameter specs, for plug-in procedures and GEGL operations.

**Evidence.** Core does receive full GParamSpecs for plug-in procedures. GPParamDef is converted to a pspec in app/plug-in/gimpplugin-message.c:820, and GimpProcedure has num_args and args. GEGL operation pspecs are available too. But aux arguments (27 plug-in source files) exist only in the plug-in process and are never sent to core. GimpProcedureDialog layouts and previews also exist only in the plug-in. Fifteen GEGL operations have hand-written GTK property UIs in app/propgui/gimppropgui.c:459-487 (channel mixer, color balance, hue-saturation, shadows-highlights and others), some with on-canvas controllers. Curves, Levels, Threshold, Brightness-Contrast and Offset are dedicated filter tools with custom GUIs. All common file formats (PNG, JPEG, TIFF, WebP, HEIF, PSD, RAW) are plug-ins in plug-ins/, so their export dialogs are GTK.

**Correction.** Generic dialogs cover the long tail. Export dialogs, Curves, Levels and about 15 GEGL operations need hand-built native UI, or else they open GTK windows.

### OVERSTATED: Synchronous plug-in calls run nested main loops, and the spike will drive GLib's main loop from NSRunLoop.

**Evidence.** The nested loops are confirmed: g_main_loop_new(NULL, FALSE) followed by g_main_loop_run in app/plug-in/gimppluginmanager-call.c:308-326 and gimpplugin.c:879-881, all on the default context. But a nested g_main_loop_run inside core blocks AppKit unless GLib's poll function also pumps NSApp events. That is the other direction from 'drive GLib from NSRunLoop'. It needs g_main_context_set_poll_func integration, as in GDK's Quartz event loop. That is public GLib API, so no patch is needed, but it is subtle code.

**Correction.** The spike should integrate in both directions (a custom GPollFunc that services NSApp), not just add a timer or source on NSRunLoop.

### CONFIRMED: Upstream churn over the last 12 months: core 265 commits, app/widgets 212, about 372 app/ commits touching only GUI code, about 27.5k GUI lines changed.

**Evidence.** From a blobless clone covering 2025-11-04 to 2026-11-04: app/core 265, app/widgets 212, 367 app/ commits touching only GUI directories. The net GUI diff over the year is +16,572/−8,949 lines across 744 files. However, core changed more lines than the GUI did: +22,754/−6,519 across 522 files. That undercuts the memo's framing that core churn is a minor maintenance burden for Option B.

**Correction.** Core churn is at least as large as GUI churn. B swaps merge conflicts for API breakage of a similar size.

### OVERSTATED: GTK4 preparation is editing the event APIs the tools depend on.

**Evidence.** Commit messages describe 'a preparatory step ahead of a potential GTK 4 port'. The GdkEvent-accessor commit fcaaa097 changed 4 lines in gimpdisplayshell-tool-events.c and no files in app/tools. The only GTK4-prep changes to app/tools were the mechanical gtk_widget_show/hide → set_visible replacements (860dc22f, 08e4539d). meson.build still requires gtk+-3.0 >= 3.24. The roadmap (https://developer.gimp.org/core/roadmap/) names no GTK4 target. Phoronix calls the 3.2.6 work 'early preparations toward eventual GTK4 port' (https://www.phoronix.com/news/GIMP-3.2.6-Released).

**Correction.** There is no GTK4 port. GTK3 is stable for the foreseeable future, which lowers the risk of A and D in the near term.

### REFUTED: Option A: layer multi-select is a behavior change that needs C patches.

**Evidence.** GIMP 3.0 already has multi-item selection. NEWS.pre-3-0 says 'All code is now multi-item aware', and gimp_image_get_selected_layers is used in 29 app files.

**Correction.** Remove it from the list. Several Glimpse-era complaints are already fixed in GIMP 3: multi-select, non-destructive filters, and native file choosers.

### OVERSTATED: GIMP's Default theme is 1,325 lines of CSS; Option D ships a Rigi-look theme.css, and whether the theme also applies to plug-in dialogs is unverified.

**Evidence.** 1,325 is confirmed: themes/Default/*.css = 1021+48+47+64+69+76. But theme.css is generated and overwritten by GIMP (app/gui/themes.c:488-600), and its header tells users to edit gimp.css instead. A theme should ship as themes/<Name>/gimp-light|gray|dark.css or as a user gimp.css. The open question can be settled: libgimpui loads the same generated theme.css from the user's GIMP directory and watches it for changes (libgimp/gimpui.c:333-341, 556-590), so plug-in dialogs do pick up the theme.

**Correction.** Ship a theme directory, not theme.css. Plug-in dialogs will follow it.

### CONFIRMED: GIMP requires a 'no AI-generated content' checkbox on every merge request, mandatory since 2026-10-03.

**Evidence.** Commit d09bff26 (2026-10-03) turned the guideline into a checklist. The checkbox reads 'I declare this MR have no AI-generated content', and the template marks it as '(for contributors without Developer role)'; it is also in GIMP_3_2_8. Before that the no-AI rule was a guideline in the same template. README commit 04e7f69d (2026-10-01) adds: 'no genAI-generated contents is allowed in any repository managed by the GIMP project'. That README line extends the rule beyond MRs, so even data-file contributions upstream are excluded.

### OVERSTATED: XCF is being replaced by a zipped-XML format, and CMYK is coming in 3.4.

**Evidence.** Master NEWS says 'New project format for GIMP (meant to replace XCF) is under development', but no new-format code is in master. The press reports zipped XML (https://www.omgubuntu.co.uk/2026/08/gimp-new-project-file-format). The roadmap lists high-end CMYK backend storage as WIP for 3.4 and lists the new XCF as 'Discussed' (https://developer.gimp.org/core/roadmap/). Roadmaps there are not commitments. Link and vector layers already shipped in 3.2.

**Correction.** Both the new format and CMYK are WIP with no fixed version.

### UNVERIFIABLE: Effort estimates: B is 4–8 PM to a beta of the focused subset and 12–24 PM to parity; the front end is 50–80k Swift lines (30–150k across reports).

**Evidence.** No source data can settle this. For scale, the GTK GUI being replaced is about 467k lines of C: widgets 158.7k, tools 81.7k, display 69.1k, libgimpwidgets 59.3k, dialogs 40.4k, actions 40.2k, gui 8.0k, propgui 6.8k, menus 2.6k. That includes the tool layer, which has to be rewritten (see above), and text editing, which is built on GtkTextBuffer (GimpTextBuffer subclasses GTK_TYPE_TEXT_BUFFER, widgets/gimptextbuffer.c:58) and GtkIMContext. The parity range looks low.

### OVERSTATED: Lucerne's Qt port 'follows the same guidelines' doesn't hold up: it has no Rigi-like code and was written two months before Rigi existed.

**Evidence.** The dates are right: Rigi's first commit is 2026-10-28 and Lucerne's linux/ Qt port is 2026-08-23. But Rigi's second commit is titled 'Extract shared native UI toolkit', which suggests it was extracted from existing app UI, plausibly Lucerne's Mac UI. If so, the design guidelines are older than the Rigi repo. I did not verify which code was extracted. Shared code was never claimed; Rigi's README explicitly rules it out.

**Correction.** Having no shared code is expected. Whether the Qt port follows the same design guidelines is a design question, and the dates don't settle it.

## Missing considerations

- The memo's no-go condition for B is already met by the source. GimpDisplayShell is a GtkEventBox, tool widgets and canvas items hold shell pointers, and the tool-options classes are in app/tools with gtk.h. B should be re-scoped up front as 'rewrite every tool in Swift on top of app/paint and core' and costed that way. It should not be framed as a spike that might reuse tools.
- Basic file I/O depends on plug-ins. PNG, JPEG, TIFF, WebP, HEIF, PSD and RAW are all separate plug-in processes that use GTK3 and libgimpui. Interactive export opens GTK dialogs, and JPEG's size and quality preview lives in the plug-in. B therefore has to bundle GTK3, Python and PyGObject anyway, so the app will be about the size of the GIMP .dmg, and export UX needs native replacements that run plug-ins non-interactively.
- Running with no_interface=FALSE turns on module loading. The modules in modules/ (color selectors, display filters, MIDI and Linux-input controllers) are GTK-based and must be blocked through the front end's own module path or modulerc. Losing them also removes display filters such as color-blind simulation and clip warning unless they are reimplemented.
- Tool presets and toolrc depend on tool-info and tool-options types registered by app/tools/gimp-tools.c, which is GTK code. Core skips loading tool presets when no_interface=TRUE. A front end needs its own tool registry, which breaks compatibility with GIMP's presets and toolrc.
- Text editing uses GimpTextBuffer (a GtkTextBuffer subclass) and GtkIMContext. A native text tool must convert NSTextStorage to and from GIMP's Pango markup, including IME input.
- Copy and paste between apps goes through the GtkClipboard-based widgets/gimpclipboard.c and must be rewritten with NSPasteboard. Core's global buffer can be reused.
- Display color management (monitor profile, soft-proofing, display filters) lives in app/display and libgimpwidgets. Core libgimpcolor transforms can be reused, but the code that queries the monitor profile and the render path through gimpdisplayshell-render.c is tied to the shell struct.
- Projection rendering runs from GLib idle handlers at GIMP_PRIORITY_PROJECTION_IDLE. Integrating GLib with AppKit (poll function versus run-loop source, priorities) directly affects go criterion 3 on latency. The upside is that core already supports a priority rectangle, so visible area first comes for free.
- Option D cannot reorganize menus. Menu .ui files load only from the installed data directory or the testing-only GIMP_TESTING_MENUS_PATH environment variable (app/widgets/gimpuimanager.c:503-533). D can change shortcuts (shortcutsrc), toolbox groups (toolrc), dock layout (sessionrc), gimprc and the theme, but nothing else.
- GTK3 CSS can't change layout or widget types, but D's look can also include an icon theme. Icon themes are user-installable and extensions can now ship them (master NEWS).
- If GIMP ever ports to GTK4, GTK3 CSS selectors and properties won't carry over, so D needs a full re-port at that point. No port is scheduled.
- For the rebase drill: master is still at meson version 3.3.1, its NEWS is headed 3.3.2, and no 3.3.x tag exists, so 'master (3.3.1)' is a moving target. Pick a fixed commit.
- In B, the 15 GEGL operations with custom propgui code, plus the Curves, Levels, Threshold and Offset tools, need hand-designed Rigi UIs. They are also the most-used adjustments, so the auto-generated dialog only covers the long tail.
- The README's no-genAI rule covers 'any repository managed by the GIMP project', not just code MRs. Even data or theme contributions written with agents can't go upstream, which matters for D's 'upstream-friendly' framing.
