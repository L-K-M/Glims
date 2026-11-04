<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 2: Hosting GIMP's engine without patches

# Hosting GIMP's engine under a native front-end with zero patches to GIMP

**Answer:** a native AppKit host can run GIMP's engine in-process with **0 patches**. The upstream meson build runs unmodified, and the host links the static libraries that upstream already builds for `gimp-console`. Every change in behaviour the host needs goes through public struct fields, GObject signals, config settings and PDB override rules that GIMP already has. The out-of-process route, which uses only the stable public API, also needs 0 patches. It does not work for an interactive editor that centres on the canvas: it gives no way to read a region or scaled view of the composited image, sends pixels as one synchronous IPC round trip per tile, gives no change notifications, and its paint calls take no pressure.

Tags: [M] means measured from source or git history (paths, lines and commit hashes are given). [I] means inferred and not benchmarked. Nothing was built or run. Sources: master at `/tmp/gimp-fork-research/gimp` (2aef5e7) and history in `/tmp/gimp-fork-research/hist/gimp-hist.git`. My helper script and lists are in `/tmp/gimp-fork-research/work-embed/` (`declcmp.py`, `used_by_*.txt`).

---

## 1. Building from an unmodified tree

**GTK3 is required at configure time.** [M]
- `meson.build:499` declares `gtk3 = dependency('gtk+-3.0', version: '>=3.24.0')` with no `required:` switch.
- Other hard requirements: gobject-introspection (`:493`) plus `g-ir-compiler` (`:1329`), xsltproc (`:1322`), librsvg (`:644`), appstream (`:708`), libarchive (`:710`), poppler, perl, and the `gimp-data` submodule. `app/core/meson.build:272-274` uses `cursors_sources`, `pickers_sources` and `icons_core_sources`, which are defined in that submodule. The shallow clone's submodule is empty, so I could not inspect it.
- `meson_options.txt` has no "no GUI" option. `enable-console-bin` (default true) only adds the extra `gimp-console` binary.
- The GUI binary (`app/meson.build:208`), `libgimpwidgets` and `libgimp`/`libgimpui` (`meson.build:1981-1982`) are always defined.
- GTK3 has to ship anyway, because the file plug-ins are GTK3 processes.

**Only the targets you ask for get built.** [M] Configure still needs every dependency, but `meson compile -C _build gimp-console-3.3 <plug-in targets>` builds only that dependency closure. The `gimp-console` target itself proves that closure contains no GTK:
- it is built from `main.c` plus `libapp_sources`, compiled with `-DGIMP_CONSOLE_COMPILATION` (`app/meson.build:188-206`);
- it links `console_libapps` (14 libraries at `:95-110`, plus `libappconfig` at `:132`) and `app_libgimps` (base, color, config, math, module, thumb).

**The `app/*` libraries are internal, uninstalled static libraries.** [M]
- Every `static_library('app…')` call lacks `install:`.
- The console libraries are compiled once and shared by both binaries. `GIMP_CONSOLE_COMPILATION` appears only in `app/{app,errors,gimp-update,gimp-version,main,unique}.c` and `app/tests/tests.c`, never in core, paint, gegl, pdb, plug-in and so on. So the `.a` files are flag-neutral.
- `libapp.a` (`:72`) is compiled without the console flag and pulls in `gui/gimpapp.h`. The host must **not** link it. Instead it compiles the upstream `app.c`, `errors.c`, `sanity.c`, `language.c`, `gimpcoreapp.c`, `gimpconsoleapp.c`, `gimp-log.c`, `gimp-debug.c` and `gimp-version.c` itself with `-DGIMP_CONSOLE_COMPILATION -DGIMP_APP_GLUE_COMPILATION`. Alternatively it can reuse the `gimp-console` object files minus `main.c.o`.

**An external build works without patches.** [M for the structure, I for the procedure]
1. A script runs upstream `meson setup` / `meson compile` / `meson install` unchanged; `install` covers the dylibs, data and plug-ins.
2. It then reads the `gimp-console` link line from `build.ninja` (or `meson introspect --targets`) to get the exact `.a` list. That list includes things like `libappgegl` linking `libappgegl_loops`.
3. The compile flags come from `compile_commands.json`.
4. The host links those archives, with `-force_load` if it wants a `GimpEngine.framework`.

The macOS CI does nothing special beyond this. `build/macos/2_build-gimp-macports.sh` is a plain `meson setup` + `ninja` + `ninja install`; the only patch it applies is a Homebrew gexiv2 version-pin patch in `1_build-deps-macports.sh`.

**Headers and generated files the host needs.** [M]
- Source root and `app/`: all internal headers, plus `app/gimp-intl.h`. Enum `.c` files are committed in the tree.
- Build root:
  - `config.h`: needed for the few config macros in internal headers, e.g. `GIMP_RELEASE` in `core/gimp-utils.h:21` and `GIMP_UNSTABLE` in `core/gimptemplate.h:28`;
  - `libgimpbase/gimpversion.h`;
  - `app/core/gimpmarshal.h` (genmarshal);
  - `git-version.h`;
  - the pdbgen and mkenums stamp headers.
- Add include paths for gegl, babl, glib, cairo, pango and gexiv2.
- `app.h` refuses to compile unless `GIMP_APP_GLUE_COMPILATION` is defined.
- On macOS, link with `-framework AppKit -ObjC`; `osx_ldflags` is set at `meson.build:213-223`.

**Symbol visibility is not a problem.** [M]
- No `gnu_symbol_visibility` or `-fvisibility` appears anywhere in the meson files, and there is no `G_GNUC_INTERNAL` in the `app/` headers.
- The `.def` export lists only apply on Windows (`vs_module_defs`). On macOS every non-static symbol in `libgimpbase` and the other dylibs is exported, including private ones such as `gimp_env_init` from `gimpbase-private.h`.
- Static archives expose every non-static symbol to the linker anyway.
- One real hazard: **never load `libgimp` (the plug-in library) into the same process.** It defines the same GType and C names as the core (`gimp_image_get_type`, and so on).
- [I] Meson may produce thin archives on Linux; on macOS they are regular archives.

**Licensing.** [I] Linking GPLv3 app code statically makes the host GPLv3+. Rigi's Unlicense is compatible with that.

## 2. Running the engine without GTK

**There is an upstream reference bootstrap.** [M] `app/tests/tests.c:68-82` (`gimp_init_for_testing`) brings up the core in 8 calls, all exported: `gimp_log_init`, `gegl_init`, `gimp_new`, `gimp_load_config`, `gimp_gegl_init`, `gimp_initialize`, `gimp_restore`. `app_run` in `app/app.c:180-360` is also exported via `app.h`, but it blocks inside `g_application_run`, so the host should copy its sequence rather than call it.

**What the host has to reimplement.** [M]
- These are `static` in `main.c` and must be ported:
  - `gimp_macos_setenv` (`:382`), which sets `XDG_*`, `GIO_MODULE_DIR`, `GDK_PIXBUF_MODULE_FILE`, `FONTCONFIG_PATH`, `GS_LIB`, `GI_TYPELIB_PATH`, `PYTHONHOME` and so on, mostly so plug-in processes work;
  - `gimp_init_i18n` (`:122`);
  - `gimp_early_configuration` (`:588`).
- These are exported and can be called: `gimp_env_init`, `gimp_backtrace_init`, `gimp_init_signal_handlers`, `language_init`, `sanity_check_early`/`sanity_check_late`, `errors_init`, `gimp_early_rc_new`, `gimp_user_install_new`/`gimp_user_install_run`, `gimp_console_app_new`.
- Keep `app.c:126-129`: `gegl_config` `use-opencl=FALSE` and `application-license="GPL3"`.
- Set `gimp->app` to a `GimpConsoleApp` that is never run. Core touches it exactly once (`core/gimp.c:1383`).
- Use a separate profile with `-Dgimpdir=` (a build option) or `GIMP3_DIRECTORY`. Path overrides: `GIMP3_DATADIR`, `GIMP3_PLUGINDIR` and friends; relocation uses `[NSBundle mainBundle]` (`libgimpbase/gimpenv.c:420-462`).

**What `no_interface` changes in the GTK-free layers** (complete grep, [M]):

| Site | `no_interface=TRUE` | `FALSE` |
|---|---|---|
| `core/gimp-modules.c:44,68,158,229` | Modules (display filters, colour selectors, controllers, which are GTK `.so` files) never load | Loaded from `module-path` |
| `core/gimp-data-factories.c:437` | Tool presets not loaded (factory still created, `:206`) | Loaded; needs tool-options GTypes registered first |
| `pdb/progress-cmds.c:67,101,129,162,221` | Progress from plug-ins is silently dropped | Routed to `gimp_plug_in_progress_*` and the vtable |
| `pdb/{brush,pattern,palette,font,gradient,drawable,image,item}-select-cmds.c` (24 popup procedures) | Resource and item chooser popups fail | `gui.pdb_dialog_new` is called |
| `file/file-open.c:467` | `file_open_with_proc_and_display` forced to NONINTERACTIVE | INTERACTIVE |
| `display/gimpdisplay.c:378` | (GTK display; host doesn't use it) | n/a |
| `core/gimp.c:1383` | Only the stray-image warning at exit | n/a |

Plug-in launching itself does not branch on `no_interface` (nothing in `app/plug-in`). Persistent 0-argument extensions start in both modes (`gimppluginmanager-restore.c:556-620`). Fonts and data loading depend only on `no_fonts`/`no_data`.

**Zero-patch configuration (recommended).** [M for the mechanisms]
1. Call `gimp_new(..., no_interface=FALSE, ...)` so the progress, popup and preset paths are active.
2. Ship a system gimprc with `(module-path "")` (or set it after `gimp_load_config`). Modules load inside `gimp_restore` (`core/gimp.c:880`), so GTK never enters the process.
3. In a `g_signal_connect_after(gimp, "initialize")` handler, register tool infos with `gimp_tool_info_new` (core). Use GType names that match upstream's tool-options names (e.g. `GimpRectangleSelectOptions`) so presets deserialize (`core/gimptoolpreset.c:424`). This is what `gui.c:312,547` does.
4. In a `"restore"` handler, fill the public `gimp->gui` struct (`core/gimp.h:59`, `GimpGui gui`) the way `gui_vtable_init` does. Every wrapper in `core/gimp-gui.c` only checks for NULL and never gates on `no_interface`.
5. For displays, subclass the core `GimpDisplay` (`core/gimpdisplay.h`), which has `present`/`grab_focus` virtuals and IDs assigned in core (`gimpdisplay.c:117`). Add instances to `gimp->displays`.
6. For progress, implement the core `GimpProgress` interface.
7. If the host ever runs with `TRUE`, it can still shadow any PDB procedure: `gimp_pdb_real_register_procedure` prepends and lookup returns the head of the list (`pdb/gimppdb.c:240-255`), so the 5 progress and 24 popup procedures could be overridden without a patch.

**Main loop.** [I, based on M] The core needs the GLib default context: projection rendering is idle-chunked (`core/gimpprojection.c:128-132`), and plug-in calls nest `g_main_loop_run` (`plug-in/gimppluginmanager-call.c:300-330`). Run the core on the AppKit main thread with a GLib↔CFRunLoop poll integration, modelled on GDK-quartz's poll function. A background core thread is a bad idea: core calls `[NSApp activateIgnoringOtherApps:]` (`gimppluginmanager-call.c:400`), and nothing in core is thread-safe. The host must guard against re-entrancy during nested plug-in loops.

**Is a patch unavoidable?** No; none was found. What stays GTK-bound is reimplementation work, not patching:
- canvas and display colour management;
- every tool's interaction and options;
- the filter-tool orchestration. It sits on core `gimp_drawable_filter_{new,apply,set_preview_split,set_region,commit,abort}`, which exist in `core/gimpdrawablefilter.h`.
- the GEGL property UIs;
- text editing (`GtkTextBuffer` ↔ `GimpText` markup);
- clipboard sync with NSPasteboard, through `gimp_set_clipboard_*` plus the `"clipboard-changed"` signal;
- tablet devices (fill `GimpCoords` pressure, tilt and velocity yourself; `core-types.h:287-296`).

The engine you get is the real thing: the paint core with pressure (`gimp_paint_core_start/interpolate/finish`), the projection with lazy tile validation (`gimpprojection.c:605-611`) and its `"update"` signal, and undo.

**Interactive plug-in dialogs** stay GTK3 windows in separate processes. For file import/export, the host can avoid them by building native dialogs from the procedures' GParamSpecs and running NONINTERACTIVE.

## 3. Out-of-process: unmodified `gimp-console` or `gimp -i` plus a persistent libgimp extension

**Feasible mechanics.** [M]
- A 0-argument `GIMP_PDB_PROC_TYPE_PERSISTENT` procedure is started automatically at launch.
- It can run its own GMainLoop with a socket (`gimp_plug_in_persistent_enable`). `plug-ins/script-fu/server/` is an in-tree socket-server example.
- A third-party project (twelvetake gimp-studio-mcp) does exactly this with `gimp -i` over loopback TCP, tested on GIMP 3.2.4, for automation: https://pypi.org/project/twelvetake-gimp-studio-mcp/

**How pixels move.** [M]
- `libgimp/gimptilebackendplugin.c` uses 128×128 tiles (`plug-in-types.h:25`) and one synchronous exchange per tile.
- A read is TILE_REQ → TILE_DATA → TILE_ACK: the core does `gegl_buffer_get` into shared memory, then libgimp copies it out with `g_memdup2` (`:340-396`). A write is 4 messages (`:398-455`).
- The shared-memory segment is a single 512 KiB tile window (`gimppluginshm.c:74`). Mmap'd POSIX shm on macOS.
- Data that doesn't go through shm (thumbnail bytes, parameters) is written in 512-byte chunks to unbuffered GIOChannels, one `write()` each (`app/plug-in/gimpplugin.c:26,267-330,504-507`).
- The wire protocol is private: headers were renamed `*-private.h` in ee794634 (2026-09-18), and `GIMP_PROTOCOL_VERSION` was bumped 4 times on master in the last year (0x0117 → 0x0119). Only libgimp itself is stable.

**Getting the composite (the deal-breaker).** [M]
- Tile access works only on drawables (`gimpplugin-message.c:344-436`, which uses `gimp_item_get_by_id`).
- The only composite reads are:
  - `gimp_image_get_thumbnail`: the whole image, 1024 px maximum, 8-bit, sent through the pipe (`pdb/groups/image.pdb:3153-3245`);
  - `gimp_layer_new_from_visible`: a full-image composite copy, which you then read tile by tile.
- `drawable_sub_thumbnail` has a region of interest but is per drawable, with a 1024 px maximum output.
- libgimp has no change notifications at all (no image signals) and no dirty counter.

[I] For a 24 MP 8-bit image, one full read is 1,504 tiles, about 4,500 messages and 2–3 copies of 96 MB before the data even reaches the front-end. An update to a 1:1 viewport needs a full-image composite copy first. Pan and zoom at interactive rates against the engine's projection is not achievable. The front-end would have to keep its own mirror and could not reliably tell when the mirror is stale.

**Public API coverage** (806 core PDB procedures [M]):

| Area | Coverage |
|---|---|
| Selection | Good: 10 `image_select_*`, 15 `selection_*`, `drawable_foreground_extract` |
| Transforms | Commit only (10 `item_transform_*`, including matrix and perspective); the live preview would have to be the front-end's |
| Text | 50 `text_layer_*` procedures; no on-canvas editing |
| Painting | 9 tools; strokes are x,y arrays only (`paint_tools.pdb:19-25`), with per-point pressure fixed at default (`app/pdb/paint-tools-cmds.c:84-94`); each call is a complete stroke; no MyPaint, ink, warp or cage strokes |
| Non-destructive filters | `gimp_drawable_filter_new` / `append_filter` / `update` / `merge_filter`, but layers only (`drawable_filter.pdb:47-55`), restricted by `gimp_gegl_op_nde_allowed`; the underlying `_update` PDB call is marked "internal… arguments will likely change"; a "preview" is the appended filter, so you are back to reading the composite |
| Undo | Group start/end exist; `gimp_image_undo`/`redo` exist only on master (4e83c2d6, 2026-06-27), not in 3.2.8; there is no way to list the undo stack, so no History palette |

**Latency.** [I] Each PDB call is at least 2 pipe messages plus GValue serialization, plus the front-end↔extension hop, serialized through a single-threaded core. That is fine for discrete commands. It cannot keep up with streaming 120–240 Hz tablet events with feedback.

**Hybrid** (front-end renders and previews locally, engine commits via the public API). [I] It is viable only for discrete operations: adjustments and filters shown on a downscaled proxy using LGPL GEGL in the front-end. Where it breaks:
- It doubles memory with full layer mirrors.
- GIMP's layer modes and its 56 `gimp:*` GEGL ops are in internal `app/operations` [M], so local compositing either diverges or depends on internal code anyway.
- Committing a stroke is either a pressure-less PDB call or a raw pixel write through a shadow buffer plus `merge_shadow`. The second means GIMP's brush engine isn't used at all.
- Text laid out with CoreText won't match Pango/HarfBuzz.

**GEGL shortcut.** None exists without internal API. The projection and drawables live in in-process memory GeglBuffers with lazy tile handlers (`gimpprojection.c:605-611`), and libgimp only gives you proxy buffers backed by the wire. Direct GeglBuffer access is exactly what the in-process option provides.

## 4. Upstream direction

- **Roadmap** (https://developer.gimp.org/core/roadmap/): nothing about headless, embedding or a library API. It records "no wire protocol redesign in the end" for 3.0.
- **Maintainer statements:** Jehan says `gimp-console` "really serves the purpose of being run on servers" and "doesn't link to GTK at all" (https://discourse.gnome.org/t/gimp-2-99-how-to-run-in-headless-batch-mode-on-a-server/13097). That is batch and server use, not embedding. The project's public-API promise: "any function that's in the public API must continue to work for all future releases of GIMP 3" (https://gimp.org/news/2024/10/05/development-update). I measured 0 removed `.def` symbols from 3.2.0 to master (+2 in 3.2.x, +21 on master).
- **In-tree docs** (`devel-docs/README.md:28,58,73`) describe the GTK-free core layering ("app/tools: User interface part of the tools. Actual tool functionality is in core"), but the core is not offered as an API.
- **GitLab:** I searched the issues API for headless, embed and library terms and found no issue about an embeddable core or a stable embedding API. The GTK4 issues (#6440, #7700, #9242, #10892) are all closed.
- **Other projects:** none embeds GIMP's live `app/` core. Seashore's "GIMPCore" is a handful of copied old GIMP routines (gradient, scale, rotate, matrix, rgb) with no update path (https://github.com/robaho/seashore/tree/master/GIMPCore/source), which is the cautionary example.

## 5. How much the internal API churns (evidence for update cost)

Using `declcmp.py` over about 3,000 internal function declarations in the GTK-free headers [M]:

| Range | Removed | Signature changed | Added | Changed ones the GUI layer uses |
|---|---|---|---|---|
| 3.2.0 → 3.2.8 (stable series) | 6 | 4 | 7 | 2: `gimp_image_pick_color`, `gimp_pickable_contiguous_region_by_color` |
| 3.2.8 → master | 32 | 30 | 90 | 6: `gimp_viewable_get_{new_,}preview`/`pixbuf` gained a `scale_factor` argument, plus `gimp_gegl_buffer_dup` and `gimp_drawable_get_sub_preview_async` |

The script misses some multi-line parameter changes. For example, one `gimp_item.h` lock predicate gained a `checking_children` argument within 3.2.x, so treat these counts as lower bounds.

Other changes within the stable series [M]:
- `gimp_get_temp_file` gained a `GError**` argument;
- a new enum value `GIMP_UNDO_GROUP_VECTOR` was inserted mid-list;
- `MAX_CHANNELS` went from 4 to 5;
- `GimpImageClass` gained a signal;
- `gimp_drawable_get_active_components` was removed.

For scale: app/tools plus app/display call about 596 distinct core functions, and the whole GUI layer about 1,136. A native front-end would depend on a comparable number.

Startup glue the host has to keep in sync, last 12 months [M]: `app/main.c` 33 commits (mostly macOS environment setup), `app/app.c` 4, `core/gimp.[ch]` 7, `gimp-gui.[ch]` 4. `console_libapps` in `app/meson.build` has not changed since 3.2.0.

## Conclusion

| Architecture | Patches to GIMP | API depended on | Expected update cost | UX control | Performance risk |
|---|---|---|---|---|---|
| **A. In-process**: unmodified meson build; host links the `gimp-console` static libs and compiles upstream `libapp_sources` with the console flag; `no_interface=FALSE`, empty `module-path`, own vtable, tools and `GimpDisplay` subclass; native canvas and tools | **0 / 0 LOC** | **Internal**: `Gimp` struct, 27-hook `GimpGui`, core signals and class structs, about 600–1,100 core functions; plus the GLib main loop | Point release: rebuild plus a handful of compile fixes. Minor release: days (dozens of changed or removed declarations), plus re-syncing the copied `main.c`/`app.c` glue and any reimplemented tool logic [I] | **Full** (native canvas, pressure, live previews, palettes) | **Low**: same data paths as GIMP's own GUI (direct projection, lazy validation) |
| A′. Same, but `no_interface=TRUE` | 0 | Internal, plus 29 shadow PDB procedures | Slightly higher than A | Full | Low |
| **B. Out-of-process**: unmodified `gimp-console` or `gimp -i` plus a persistent libgimp 3 extension serving the front-end over a socket or shm | **0** | **Public, stable**: libgimp 3 (0 symbol removals measured) plus 806 PDB procedures | About zero: swap the engine bundle; the extension uses the bundled libgimp | Low for canvas work: no live strokes or pressure, no composite region reads, no change events, no history list, GTK dialogs | **Very high**: per-tile synchronous IPC, full-image composite copies |
| C. Hybrid of B: local GEGL previews and own rasterization; commits via the public API | 0 | Public libgimp plus GEGL/babl (internal `gimp:*` ops are optional) | Low–moderate (keeping the local renderer consistent with GIMP's) | Medium | Medium–high (memory duplication, fidelity drift, mirror sync) |
| Reference: patching GIMP's GTK UI | Large; every GUI directory | Internal GUI code | High (the GUI directories churn constantly) | Limited by GTK3 | Low |

**Recommendation:** use A, and keep all internal-API use behind a thin C engine shim owned by the host, so that upstream churn lands in one place.
- Run CI against GIMP master nightly so breaks show up before releases.
- Treat GIMP's plug-ins exactly as upstream does; they are out-of-process anyway.
- Reserve B for automation, batch work and a crash-isolated "safe mode", not for the interactive editor.

"Trivially easy" updates hold for B and for point releases under A. Under A, each minor release costs bounded but real work (estimated at days), concentrated in the shim.
