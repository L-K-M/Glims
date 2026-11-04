<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 2: Review (hosting-check)

Would change recommendation: False

## Summary

Option 1 survives: I found no source patch the in-process approach needs. The hooks the plan relies on all exist upstream: no_interface=FALSE, an empty module-path, handlers on the 'initialize' and 'restore' signals, a GimpDisplay subclass, GimpProgress, and PDB override. The console libraries are flag-neutral, and the out-of-process limits are as described: 4,512 messages per 24 MP read, no pressure, no undo/redo before master. Several decision-relevant claims are still overstated.

- **Building unmodified on macOS:** this works only on MacPorts. Homebrew's gexiv2 0.16 fails GIMP's <0.15 requirement, and upstream's own script patches the checkout to get around it. At GIMP_3_2_0, the spike's target, upstream also patched app/main.c, libgimpbase/gimpenv.c and meson.build.
- **Bootstrap:** tests.c runs with no_interface=TRUE, so it does not exercise the recommended path. Model startup on app.c instead.
- **Glue file list:** EH's list misses gimp-update.c, signals.c and the -ObjC flag.
- **Threading:** "nothing in core is thread-safe" is wrong. GIMP paints on a dedicated thread with a 10 ms flush, and that GTK-side scheduling must be ported.
- **Performance:** "Low risk, same data paths" is unbenchmarked and covers only the engine half.

Keep the recommendation, but change the spike to use MacPorts. Separate packaging workarounds from engine patches in the go criteria. Consider an internal-API helper process as the fallback, rather than libgimp.

## Claims checked

### UNVERIFIABLE: Zero patches to GIMP are needed to host its engine in-process (EH/memo headline)

**Evidence.** Nothing has been built or run by EH, the memo, or me. Structurally I found no blocker in the GTK-free libraries: no GTK and no display/ references, and the gimp-console executable links only console_libapps plus app_libgimps (app/meson.build:188-206). The hook mechanisms below all exist. The claim stays an inference until the week-1 build succeeds.

**Correction.** Restate it as: 'no source patch found to be necessary; build-system and packaging workarounds are needed (see the macOS build claim)'.

### CONFIRMED: Behaviour can be changed only through existing hooks: no_interface=FALSE, (module-path ""), tool infos on 'initialize', the gui vtable on 'restore', a GimpDisplay subclass, GimpProgress, and PDB override

**Evidence.** Checked each mechanism:
- 'initialize' and 'restore' are G_SIGNAL_RUN_LAST (core/gimp.c:159-175). A normal handler therefore runs before gimp_real_restore starts plug-ins (gimp.c:573-585). gui.c:316/563 does the same thing upstream.
- Modules load from config->module_path in gimp_modules_load (gimp-modules.c:150), called at gimp.c:880.
- The core GimpDisplay has present/grab_focus virtuals, and its ID is assigned in core (core/gimpdisplay.c:110-123).
- PDB register prepends (pdb/gimppdb.c:151-163) and lookup returns the list head (:241-255).
- core/gimp-gui.c never tests no_interface.

### OVERSTATED: The upstream macOS build is plain meson setup + ninja; the only patch it applies is a Homebrew gexiv2 pin, so GIMP builds unmodified on macOS (including GIMP_3_2_0 in spike week 1)

**Evidence.** On master, build/macos/1_build-deps-macports.sh:63 runs `git apply` of 0001-build-macos-Do-not-require-gexiv2-0.14-on-homebrew.patch on the GIMP checkout itself. That patch rewrites 8 files, including meson.build and app/core/meson.build. meson.build:471-473 requires gexiv2 >=0.14,<0.15, but Homebrew ships gexiv2 0.16.2 (formulae.brew.sh), so an unmodified tree does not configure on Homebrew. MacPorts ships 0.14.7 (ports.macports.org), so MacPorts works.

At GIMP_3_2_0, the upstream deps script also applied two more patches to the tree:
- 0001-app-libgimpwidgets-meson-plug-ins-Patch-macOS-bundle.patch, applied unconditionally. It edits app/main.c and libgimpbase/gimpenv.c, the bundle relocation code in a library the host links.
- a python3.13 pin, on MacPorts.

Configure fails hard without PyGObject+GExiv2 (meson.build:1226-1228).

**Correction.** Use MacPorts, or build gexiv2 0.14 yourself. Run meson under a Python that has PyGObject. Pick your own bundle layout or set GIMP3_* environment variables instead of relying on upstream's bundle patches. Never run upstream's deps script, because it patches the checkout. The go criterion 'zero patches at every tag' should separate engine-source patches from packaging and toolchain workarounds for old tags.

### CONFIRMED: The console static libraries are flag-neutral: GIMP_CONSOLE_COMPILATION appears only in app/{app,errors,gimp-update,gimp-version,main,unique}.c and app/tests/tests.c

**Evidence.** A grep of all .c/.h/.m/meson.build files finds the macro only in those files. The GUI binary links the same archives (gui_libapps includes console_libapps, app/meson.build:142-153).

### OVERSTATED: The host should compile app.c, errors.c, sanity.c, language.c, gimpcoreapp.c, gimpconsoleapp.c, gimp-log.c, gimp-debug.c and gimp-version.c with -DGIMP_CONSOLE_COMPILATION -DGIMP_APP_GLUE_COMPILATION

**Evidence.** The list is incomplete:
- app.c:496 calls gimp_update_auto_check, which is defined in gimp-update.c.
- gimp_init_signal_handlers, which EH says to call, is in signals.c.
- libapp_sources (app/meson.build:32-47) also contains unique.c and gimpdbusservice_gen.
- On macOS every C file is compiled with -ObjC (libgimpbase/meson.build:2, add_project_arguments), because the core #imports Cocoa.

**Correction.** Add gimp-update.c and signals.c, plus -ObjC on macOS. A simpler fix is EH's own alternative: reuse the gimp-console object files minus main.c.o, with flags taken from compile_commands.json.

### OVERSTATED: app/tests/tests.c:68-82 is the reference bootstrap ('8 calls'); spike startup is modelled on it

**Evidence.** It makes 7 calls: gimp_log_init, gegl_init, gimp_new, gimp_load_config, gimp_gegl_init, gimp_initialize and gimp_restore. It passes no_data=TRUE, no_fonts=TRUE and no_interface=TRUE, and never sets gimp->app. Under the recommended no_interface=FALSE, gimp.c:1383 calls gimp_core_app_get_quit(GIMP_CORE_APP(gimp->app)), and tool presets, modules, progress and popups all become active. The test bootstrap exercises none of that.

**Correction.** Model startup on app.c app_run plus app_activate_callback (app.c:230-500), with gimp->app set to a GimpConsoleApp that is never run.

### CONFIRMED: EH's table of no_interface effects in the GTK-free layers is complete

**Evidence.** The only other hits are errors.c:354 and :462 and gimp-update.c:547. All three sit inside #ifndef GIMP_CONSOLE_COMPILATION blocks or Windows-only blocks. There are 24 popup sites (8 *-select-cmds.c files × 3) and 5 progress-cmds sites, as stated. The plug-in code has no no_interface branches.

### OVERSTATED: Registering tool-options GTypes with upstream names makes presets deserialize

**Evidence.** gimptoolpreset.c:395-450 resolves the type with g_type_from_name and checks that it is a GimpToolOptions subclass. It then deserializes properties, so the host's types must also reproduce the upstream property names and types. Presets load before 'restore' (gimp.c:870 versus :882), so the tool-info and type registration in the 'initialize'-after handler comes early enough.

### CONFIRMED: The core needs the GLib main context: plug-in calls nest g_main_loop_run, and the core calls [NSApp activateIgnoringOtherApps:]

**Evidence.** gimppluginmanager-call.c:306-330 runs g_main_loop_run for persistent and synchronous calls. Line 409 calls [NSApp activateIgnoringOtherApps:YES] under __APPLE__ after temporary procedures return, so it can pull focus to the host app. Fonts load through gimp_parallel_run_async (text/gimpfontfactory.c), so startup also depends on pumping the GLib context.

### OVERSTATED: A background core thread is a bad idea because nothing in core is thread-safe

**Evidence.** GIMP's own paint tool runs gimp_paint_core_interpolate on a dedicated 'paint' GThread (app/tools/gimppainttool-paint.c:83-118, 211-217, 483-571). It uses mutexes and a 10 ms display flush timer (DISPLAY_UPDATE_INTERVAL, :45, :374). The core also uses gimp_parallel_run_async in fonts, histogram, line art and drawable previews.

**Correction.** Keep the engine on the main thread, but plan to re-create GIMP's paint-thread and flush scheduling in the adapter. It lives in GTK-bound app/tools code that you will not link.

### OVERSTATED: In-process performance risk is Low because the host uses the same data paths as GIMP's own UI

**Evidence.** Only the engine side is shared: projection, lazy validation and paint core. The scheduling that makes GIMP's canvas responsive is in code the host must rewrite:
- the paint thread and 10 ms flush (app/tools);
- the projection priority rect, set from app/display/gimpdisplayshell.c:1142;
- the render cache and chunking (gimpdisplayshell-render.c);
- display colour transforms (libgimpwidgets).
Nothing is benchmarked. The 60 fps / 24 MP and 16 ms stroke thresholds are not shown to be met even by GIMP itself.

**Correction.** Rate it Low to Medium and depend on the week-3 performance pass.

### CONFIRMED: Out-of-process libgimp needs one blocking round trip per 128 px tile, about 4,500 messages per 24 MP read

**Evidence.** In libgimp/gimptilebackendplugin.c, gimp_tile_get does TILE_REQ → read TILE_DATA → TILE_ACK for each tile, and puts take 4 messages. Tile size is 128×128 (app/plug-in/plug-in-types.h:25-26). The shm window is 128*128*32 = 512 KiB (gimppluginshm.c:72). Arithmetic: ceil(6000/128) × ceil(4000/128) = 47 × 32 = 1,504 tiles × 3 = 4,512 messages. Core channels are unbuffered (gimpplugin.c:504-507) with WRITE_BUFFER_SIZE 512 (gimpplugin.h:26).

### OVERSTATED: Out-of-process gives no reads of the composited image (memo table)

**Evidence.** Composite reads do exist, but only as whole-image or per-pixel calls:
- image_get_thumbnail, at most 1024 px (image.pdb:3154-3193);
- layer_new_from_visible;
- edit_copy_visible and edit_named_copy_visible ('Copy from the projection');
- image_pick_color with sample_merged.
There is no region-of-interest or scaled composite read, and libgimp emits no image signals. EH's narrower wording is correct; the memo's is not.

**Correction.** Say 'no region-of-interest or scaled composite reads'.

### CONFIRMED: PDB paint strokes are x,y only with default pressure; undo/redo exist only on master (4e83c2d6, 2026-06-27); non-destructive filters are layers-only; 806 PDB procedures

**Evidence.** - paint_tools.pdb:19-25 defines strokes as x,y pairs, and paint-tools-cmds.c:84-90 fills each point with default_coords.
- 4e83c2d6 was committed 2026-06-27 (authored 2025-05-25). No tag contains it, and image_undo/image_redo are absent from GIMP_3_2_8:pdb/groups/image_undo.pdb.
- drawable_filter.pdb:47-55 says 'Currently only layers can have non-destructive effects', and :297 marks the update call as internal.
- pdb/groups has 806 procedure definitions.

### OVERSTATED: GIMP_PROTOCOL_VERSION was bumped 4 times on master in the last year (0x0117 → 0x0119); the wire headers were renamed private in ee794634

**Evidence.** Four bumps on master is correct: b87bab9e, 804991a2, 7129e917 and c8e7a43c. The range is 0x0115→0x0119, not 0x0117→0x0119. The private rename is confirmed, and it also reached the stable series: `git diff GIMP_3_2_0 GIMP_3_2_8` shows gimpprotocol.h, gimpwire.h and gimpsignal.h renamed to *-private.h.

**Correction.** 0x0115 → 0x0119. Note that internal header renames happen inside micro releases too.

### CONFIRMED: There is no symbol-visibility obstacle, but libgimp must never be loaded into the host process

**Evidence.** No gnu_symbol_visibility or -fvisibility appears in any meson file, and there is no G_GNUC_INTERNAL in app/. libgimp/gimpimage.c:55 and app/core/gimpimage.c:314 both G_DEFINE_TYPE GimpImage. app/plug-in/gimpgpparams.c:67 compiles libgimp's gimpgpparams-body.c into the core.

### CONFIRMED: GTK3 is required at configure time with no 'no GUI' option; console_libapps is unchanged since 3.2.0

**Evidence.** meson.build:499 declares gtk+-3.0 with no `required:` switch. meson_options.txt has only enable-console-bin. `git diff GIMP_3_2_0 2aef5e7 -- app/meson.build` touches only Windows rc handling (f7229daa).

### CONFIRMED: Micro releases are usually a rebuild with no adapter edits (memo); 3.2.8 changed gimp_image_pick_color

**Evidence.** The GIMP_3_2_0..GIMP_3_2_8 diff adds a `GeglBuffer **picked_buffer_copy` argument to gimp_image_pick_color (app/core/gimpimage-pick-color.h). I could not verify the 'day before the tag' timing: the hist clone has only 1 commit in GIMP_3_2_0..GIMP_3_2_8, so the branch history is missing.

### CONFIRMED: Upstream statements: public API must keep working across GIMP 3; Jehan says gimp-console is for servers and doesn't link GTK; gimp-studio-mcp uses a persistent extension over loopback TCP, tested on 3.2.4

**Evidence.** - gimp.org/news/2024/10/05/development-update: 'Once 3.0 is released however, any function that's in the public API must continue to work for all future releases of GIMP 3.'
- discourse.gnome.org/t/13097 contains both Jehan quotes.
- pypi.org/project/twelvetake-gimp-studio-mcp says 'Tested on GIMP 3.2.4'.
- developer.gimp.org versioning covers only the libraries.

### OVERSTATED: Tool groups come from GIMP's tool list (3.2.8: 22 slots, 44 tools)

**Evidence.** GIMP_3_2_8:etc/toolrc has 22 top-level entries and 45 GimpToolInfo entries, 6 of them hidden. The toolrc parser lives in app/tools/gimp-tools.c (GTK library), so the host has to reimplement it. That is easy, and it is data, not a patch.

## Missing considerations

- Use MacPorts for the build environment, and say so explicitly. Unmodified GIMP does not configure against Homebrew's gexiv2 0.16.2. Upstream's own deps script runs `git apply` on the checkout, so it must never run inside the zero-patch CI.
- Spike week 1 targets GIMP_3_2_0, but upstream's own macOS build at that tag patched app/main.c, libgimpbase/gimpenv.c and meson.build (python pin). Older tags may also need toolchain workarounds on a 2026 SDK. Change go criterion 1 to distinguish engine-source patches from packaging and environment workarounds.
- Bundle relocation logic in libgimpbase/gimpenv.c changed within the 3.2 series and uses [NSBundle mainBundle], which is the host's bundle. Pick a layout that matches unpatched gimpenv.c, or set GIMP3_DATADIR, GIMP3_PLUGINDIR and GIMP3_SYSCONFDIR before the first gimpenv call.
- The latency-critical paint path (paint GThread plus 10 ms flush timer) and the display scheduling (priority rect, render cache, colour transform) are GTK-side code that must be ported. Budget for it in the canvas estimate and the performance pass.
- No one considered a fifth architecture: the internal-API adapter in a separate helper process (XPC), feeding canvas tiles through IOSurface or shared memory. It keeps full engine access and gives crash isolation. It also takes the nested GLib-loop and CFRunLoop problem out of the UI process. It is a better fallback than option 3 if the CFRunLoop integration no-go trigger fires.
- core calls [NSApp activateIgnoringOtherApps:YES] after temporary-procedure returns (gimppluginmanager-call.c:409). That API is deprecated, and the call can steal focus in the host app.
- GPLv3 linking effectively rules out Mac App Store distribution. The GTK3 plug-in executables in the bundle also need to be signed and notarized.
- Fonts load asynchronously via gimp_parallel_run_async, so text features depend on the host pumping the GLib context during and after startup.
