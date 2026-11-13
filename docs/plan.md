# Glims plan

Status as of 2026-11-08: phase 0 finished with a go verdict
([`phase0-report.md`](phase0-report.md)); the first implementation of all
five phase 1 items is complete. Rendering follow-up below restores the
100% viewport fast path without giving up fresh pixels. Evidence labels: **[M]**
measured from GIMP source or history, **[I]** inferred or estimated. Sources
are in [`research/`](research/README.md); the round 2 memo and its two reviews
are the main inputs. The active editor-completion work and its remaining
features are tracked in [`completion.md`](completion.md). The phase 1 spike
is not the finished editor. File safety and clipboard editing, groups and
masks, channels and Quick Mask, history/snapshots, recovery, native filter
forms, printing, layer properties, help and image placement have since been
implemented in reviewed slices. Remaining design and final integration
checks stay explicit in that ledger.

## Goals

1. A Mac-native image editor whose whole interface is new: a classic,
   uncluttered, readable professional UI built with RigiUI
   ([`design.md`](design.md)).
2. GIMP as the engine, kept current. Picking up a new GIMP stable release must
   be routine work, not a project.

Non-goals for now: Linux and Windows, the Mac App Store (GPLv3 makes it
impractical), feature parity with GIMP, native replacements for plug-ins that
draw their own custom GTK dialogs.

## Architecture

```
GIMP, GEGL, babl (upstream, unmodified, pinned tags)
        │  internal app/ engine libraries, linked in-process
Engine/            C adapter (GObject-aware, no AppKit, no GTK)
        │  versioned facade C API with opaque handles
Sources/GlimsKit/  Swift: AppKit + RigiUI
```

GIMP is three layers that matter here:

- **GTK-free engine, about 385k lines [M].** `app/core`, `paint`, `gegl`,
  `pdb`, `plug-in`, `file`, `file-data`, `xcf`, `text`, `path`,
  `operations`, `config`, plus `libgimpbase`, `libgimpcolor`,
  `libgimpconfig`, `libgimpmath`, `libgimpmodule`, `libgimpthumb`. The
  headless `gimp-console` binary links exactly these (`console_libapps` in
  `app/meson.build`, 14 libraries plus `libappconfig`). Glims links the same
  archives.
- **GTK interface, about 467k lines [M].** Canvas (`GimpDisplayShell` is a
  `GtkEventBox`), all tools and tool options, filter dialogs and the
  filter commit/undo logic (`app/tools/gimpfiltertool.c`), the text editor
  (`GtkTextBuffer`), clipboard, display color management. Glims replaces
  all of it and links none of it.
- **Plug-ins**, separate processes using GTK3 and libgimpui. File formats
  (PNG, JPEG, TIFF, PSD, WebP, HEIF, RAW) are plug-ins, so the app bundle
  ships GTK3, Python and PyGObject for them regardless.

### Hosting the engine without patches

No source patch was found to be necessary [M for the hooks, I overall until it
builds]. The mechanisms all exist upstream:

- Run the engine with `no_interface=FALSE`, with `gimp->app` set to a
  `GimpConsoleApp` that is never run. Model startup on `app/app.c`
  (`app_run` and `app_activate_callback`), not on `app/tests/tests.c`, which
  uses `no_interface=TRUE`.
- Fill the 27-hook `GimpGui` vtable (`app/core/gimp-gui.h`) from a handler on
  the `"restore"` signal; register tool infos and tool-option types on
  `"initialize"`. Both signals are `G_SIGNAL_RUN_LAST`, so handlers run first.
- Provide a `GimpDisplay` subclass and a `GimpProgress` implementation.
- Set `module-path` empty so GIMP's GTK modules never load.
- Override PDB procedures by registering a replacement (`pdb/gimppdb.c`
  lookups return the most recently registered procedure).
- Link the console libraries from an unmodified upstream build. Either compile
  GIMP's startup glue (`app.c`, `errors.c`, `sanity.c`, `language.c`,
  `gimpcoreapp.c`, `gimpconsoleapp.c`, `gimp-log.c`, `gimp-debug.c`,
  `gimp-version.c`, `gimp-update.c`, `signals.c`) with
  `-DGIMP_CONSOLE_COMPILATION` and `-ObjC`, or reuse the `gimp-console`
  object files minus `main.c.o` with flags from `compile_commands.json`.
  Read the library list from `meson introspect`, never hard-code it.

As built (phase 1, item 1): `no_interface=FALSE`, empty `module-path` and
`tool-preset-path` on the running configuration, and a `GimpProgress` per
plug-in run. Two of the 27 `GimpGui` hooks are set (`show_message`,
`get_icon_theme_dir`); no `GimpDisplay` subclass was needed yet. GIMP treats
the unset hooks as "no window" or "not available".

GIMP 3.2.0's first-run migration scan calls `g_file_test()` on an absent
`SNAP`. The adapter temporarily supplies an empty value only around that
version's user-install constructor, then restores absence; existing values
are preserved. Upstream remains unmodified. Run
`scripts/test-engine-first-start.py ADAPTER` for missing-config startup,
visible GLib diagnostics and exact absent/empty/present `SNAP` preservation.

Known things to rebuild in the adapter or app, because GIMP keeps them in GTK
code:

- The paint thread with its 10 ms display flush
  (`app/tools/gimppainttool-paint.c`), the projection priority rectangle, the
  render cache and chunking, display color transforms.
- Filter session commit and undo (`gimpfiltertool.c`). The building blocks
  (`GimpDrawableFilter` preview, split, commit, abort) are in core.
- A tool registry and `toolrc` parser. GIMP tool presets only load if the
  host registers tool-option types with GIMP's type names and property names.
- Text editing: native text editing converted to and from GIMP's Pango markup,
  including input methods.
- Clipboard through `NSPasteboard`; core's global buffer is reusable.

### Event loop

The engine needs the GLib default main context. Plug-in calls run nested
`g_main_loop_run` loops (`app/plug-in/gimppluginmanager-call.c`), and fonts
load asynchronously. The integration must work in both directions: a GLib
source driven from the Cocoa run loop, and a custom `GPollFunc` so nested
GLib loops keep servicing AppKit events. Core also calls
`[NSApp activateIgnoringOtherApps:YES]` after temporary procedures return,
which can steal focus.

Fallback if this proves unworkable: run the same adapter in a helper process
(XPC) and send canvas tiles through IOSurface or shared memory. That keeps
full engine access and isolates crashes.

### Architectures rejected

| Architecture | Why not |
|---|---|
| Patched GIMP fork with a rebuilt GTK UI | About 300 GTK interface commits landed between 3.2.8 and master [M]; every one can collide with local patches. GTK3 CSS and config can't produce the interface Glims wants. |
| Out-of-process engine over the stable libgimp plug-in API | Never breaks [M], but can't drive a canvas: one blocking round trip per 128 px tile (about 4,500 messages to read a 24 MP image), no region-of-interest composite reads, strokes without pressure, undo only on master [M]. Useful later for automation. |
| Hybrid: local GEGL preview, commits through libgimp | A second renderer to keep consistent with GIMP's; GIMP's brush engine and layer modes go unused. |
| New editor on GEGL and babl only | Rewrites the document model, undo, paint engine and XCF; loses GIMP as the engine. |

## Engine update model

GIMP promises stability only for its public libraries
(https://developer.gimp.org/core/maintainer/versioning/). Glims depends on
internal APIs, so the cost of an update was measured over 11 tag intervals,
3.0.0 to master [M, recounted independently]:

| Update | Engine API breaks (GIMP's own UI call sites, a proxy for the adapter) | Other work |
|---|---|---|
| Stable micro release | Median 0; zero in 5 of 8 intervals; worst 57–59 (3.0.6, a large backport) | 0–65 upstream UI commits to triage, of which perhaps a third to two thirds need porting [I]. Sometimes a GEGL/babl bump, an XCF version bump (3.2.6 moved to version 26) or a small feature (3.2.6 added a tablet rotation input). |
| Minor release (3.0.8 to 3.2.0) | 11 functions, 19 call sites, 34 moved `#include` lines (`app/vectors` to `app/path`); the text-layer model changed (GimpRasterizable) | 100–190 UI commits to triage; new features (link layers, vector layers, filters on groups) need new native UI. |
| Master, during a dev cycle | Roughly one breaking commit every 2 weeks [I] | Early warning only. |

What the compiler does not catch, seen in the same history [M]: a signal that
gained an argument (`GimpContainer::reorder`, 3.0.6), renamed or removed
properties, enum values inserted mid-enum, changed macro values
(`MAX_CHANNELS` 4 to 5), tool-option property renames, and behavior changes
behind unchanged signatures (filter undo semantics in 3.0.4 and 3.0.6).
Startup checks (`g_signal_query` arity, `g_object_class_find_property`)
catch the string-keyed cases; the conformance tests and commit triage must
catch the rest.

**What "trivial" means for Glims [I]:** most stable micro releases are a
rebuild plus a green test run and a short triage. Minor releases, roughly
yearly, are days of adapter work plus one to three weeks of porting behavior
and designing UI for new features. That part never becomes trivial.

### Keeping updates cheap

- Zero engine-source patches; the clean checkout is a CI gate.
- The adapter is the only code that breaks. Keep it small and its facade
  stable; record every facade change.
- Conformance tests through the facade: rendering compared against reference
  images at several zooms; XCF round-trips (watch the XCF version on stable
  tags too); recorded pressure-stroke replays per paint tool; filter commit
  adds exactly one undo step, cancel adds none, temporary filters never reach
  the XCF; text layer edit, rasterize and revert; color picking;
  non-interactive PNG, JPEG, TIFF and PSD import and export.
- An interface diff of the GIMP symbols the adapter actually calls, run before
  each build. [`research/scripts/`](research/scripts/README.md) has the
  research-grade measurement scripts to start from.
- Nightly builds against GIMP master, the latest stable tag and the pinned
  tag. Ship only on stable tags.
- Agent fix loop: on a red build, an agent gets the break list, the upstream
  commits behind it and GIMP's own UI edits in those commits, edits only
  `Engine/`, and reruns the conformance tests. A human reviews the diff.

## Build environment

- Use MacPorts for GIMP's dependencies, not Homebrew. GIMP requires
  `gexiv2 >= 0.14, < 0.15` and Homebrew ships 0.16; upstream works around that
  by patching the checkout [M].
- Upstream's scripts accept a MacPorts prefix other than `/opt/local`
  (`OPT_PREFIX` in `build/macos/1_build-deps-macports.sh`), so a project-local
  prefix built without root privileges is possible. Use the package list in
  `build/macos/all-deps-uni.txt`, but run our own script; do not run upstream's.
- At `GIMP_3_2_0` upstream's own macOS build patched `app/main.c`,
  `libgimpbase/gimpenv.c` and a Python pin. Older tags may need packaging or
  environment workarounds; these are recorded separately from engine patches.
- Bundle relocation in `libgimpbase/gimpenv.c` uses `[NSBundle mainBundle]`,
  which is the Glims bundle. Use a layout that unpatched `gimpenv.c` accepts,
  or set `GIMP3_DATADIR`, `GIMP3_PLUGINDIR` and `GIMP3_SYSCONFDIR` before the
  first call.
- Configure needs PyGObject and GExiv2 available to meson's Python.

Decided 2026-11-04: the prefix lives in the repo's ignored `_deps/macports`,
built by `scripts/bootstrap-deps.sh` from the pins in `scripts/engine.env`
(MacPorts base 2.12.7 from source, checksum-pinned; no root privileges). It
installs the ports of `build/macos/all-deps-uni.txt` at every ref the spike
builds (`GIMP_3_2_8`, `GIMP_3_2_0`, `master`), read from a bare blobless GIMP
mirror in `_engine/gimp.git`. Like upstream, it sets `build_arch` and
`macosx_deployment_target` in `macports.conf` and adds
`-Werror=unguarded-availability-new` to libidn2 (upstream bce467bf). A
non-default prefix cannot use MacPorts' binary archives, so every port builds
from source and the first run takes hours.

The workspace volume (`/Volumes/PaseoData`) is case-sensitive APFS, while
upstream's CI and most Macs are case-insensitive. MacPorts itself builds on
case-sensitive filesystems (its buildbots did as of 2016), and the problems
its developers warn about come from building and installing on filesystems of
different sensitivity, which does not happen here because everything lives on
one volume. If a port still fails for case reasons, move the prefix to the
internal disk (case-insensitive) and rebuild there.

First full run, 2026-11-04: 1 h 56 min on this Mac, 384 active ports, 8.5 GB.
No port failed and no X11 library was installed. Key versions: gexiv2 0.14.7
(inside GIMP's `< 0.15` bound), GTK 3.24.52, GLib 2.88.3 and cairo and pango
built for Quartz, plus Python 3.14 (default) and 3.13 (GIMP 3.2.0's list
names it) with PyGObject for both.

Machine as of 2026-11-04: macOS 27.0.1 on arm64, Xcode 27.2, Swift 6.4.2,
Homebrew present, MacPorts, meson, ninja and pkg-config not installed.

## Phase 0 spike (2–3 weeks of agent work)

Week 1
- Build an unmodified GIMP 3.2.x engine on this Mac. Use `GIMP_3_2_0` if it
  builds without engine-source patches; otherwise the earliest 3.2.x tag that
  does, and record why.
- First adapter: start the engine, open an XCF, read tiles of the projection,
  expose the layer tree and undo stack, run one pressure stroke with the
  paintbrush, run one filter session, export PNG through the plug-in
  non-interactively.
- Grow the existing shell (`Sources/GlimsKit`): replace the placeholder canvas
  with tiles from the adapter and add a Layers palette.
- First conformance tests, with reference images recorded at the starting tag.

Week 2
- Move the adapter to 3.2.8, then to master. Optionally move a second copy
  from 3.0.8 to 3.2.0 to measure a real minor release.
- Log every edit: lines and files changed, agent-hours, and whether the
  compiler, the startup checks or a conformance test caught it.

Week 3
- Triage the editor-relevant upstream UI commits between the starting tag and
  3.2.8 (48 with the research focus list, about 69 with a broader scope [M]).
- Nested plug-in loop under Cocoa: 100 synchronous plug-in calls.
- Performance pass against GIMP 3.2.8 on the same Mac.

### Progress

- 2026-11-04: dependency prefix built (`scripts/bootstrap-deps.sh`; see
  Build environment).
- 2026-11-04: GIMP 3.2.8 with babl 0.1.128 and GEGL 0.4.72 builds from
  unmodified sources with `scripts/build-engine.sh`: no engine-source patches
  and no packaging workarounds. babl, GEGL and GIMP together took about 9
  minutes on this Mac; an incremental rerun takes about 2. After the build the
  zero-patch gate found all three source trees, including the `gimp-data`
  submodule, byte-identical to upstream. `gimp-console` 3.2.8 starts with a
  throwaway user directory, registers all 128 installed plug-ins (233
  procedures, including PNG, JPEG and TIFF export, PSD, PDF and SVG import, and
  the Script-Fu and Python interpreters) and quits cleanly. This is the
  reference engine for the performance comparison.
- 2026-11-04: GIMP 3.2.0 with babl 0.1.124 and GEGL 0.4.68 also builds
  unmodified, with no packaging workarounds (upstream's own macOS build needed
  them at 3.2.0 only for bundling and a Python pin, neither of which applies
  here). Its smoke test passes the same way. Go criterion 1 holds for both
  tags so far. Next: start the adapter at `GIMP_3_2_0`.
- 2026-11-04: `build-engine.sh` hardened after review: sources must be
  pristine (ignored files included) before and after the build; a stamp of
  source commits and options forces a clean rebuild when either changes;
  caller compiler, Python, pkg-config, `DYLD_*` and `GIT_*` settings are
  dropped; one engine script runs at a time; the smoke test runs in its own
  process group with a timeout and a throwaway `HOME`, and build tools cache
  under `_engine/cache`. Earlier runs had left `babl`, `gegl-0.4`,
  `g-ir-scanner` and an empty `gimp` folder in `~/.cache`; they were removed.

- 2026-11-05: adapter v1 (`Engine/`, facade `Sources/CGlimsEngine/include/glims_engine.h`,
  API version 1) built with `scripts/build-adapter.sh` against `GIMP_3_2_0`.
  The engine runs on its own thread that owns GLib's main context; facade
  calls from other threads are queued onto it, so plug-in calls nest loops
  only there. It starts the engine the way `app/app.c` does (minus signal
  handlers, update check and locale changes), and covers new and open,
  rendering the composited image to sRGB at any scale, layer tree, undo and
  redo, paintbrush strokes with pressure (one undo step each), live filter
  sessions (non-destructive commit is one undo step, abort none, reproducing
  `gimp_filter_tool_commit`), XCF save, and export and import through the
  file plug-ins. The library exports one symbol. Its 42 conformance checks
  (`Engine/tests/engine-tests.c`, run through `dlopen` like the app) pass;
  startup takes about 10 s with a fresh user directory (plug-in query).
- 2026-11-05: update drill 3.2.0 to 3.2.8: the unchanged adapter compiles,
  links and passes all 42 checks against 3.2.8. Adapter edits needed: 0.
  The drill also found two environment gaps that GIMP's own smoke test hid
  because the build environment exported them, fixed in the adapter: plug-ins
  need the engine's `bin` on `PATH` (Script-Fu interpreter) and
  `GI_TYPELIB_PATH`. It found one upstream packaging bug: GIMP 3.2.0 to 3.2.4
  install typelibs pointing at the wrong prefix on macOS, breaking Python
  plug-ins (fixed upstream in 3.2.6, 481bf7a998); `scripts/fix-typelibs.py`
  repairs the install tree, a recorded packaging workaround, not a source
  patch. GIMP 3.2.0 itself logs two `g_file_test` GLib CRITICALs at start-up;
  3.2.8 logs none.

- 2026-11-05: update drill 3.2.8 to master (3.3.1-dev, `32c1ddaa2d`, babl and
  GEGL master): master builds unmodified in under 3 minutes; the unchanged
  adapter compiles without warnings and passes all 42 checks. Adapter edits
  needed: 0.
- 2026-11-05: the app uses the engine. `GlimsKit` loads the adapter at run
  time (`GLIMS_ENGINE_LIBRARY`, the `EngineLibraryPath` default, or the
  bundle's Frameworks), starts it in the background, and opens documents in
  windows with an engine-backed canvas (visible area only, at backing scale,
  coalesced background renders), pen-pressure painting, a Rigi Layers
  palette, a modeless Gaussian Blur dialog with live preview, Undo, Redo,
  Save As (XCF) and Export. `Glims --engine-smoke-test` drives all of that
  through the interface code; it passes against 3.2.0, 3.2.8 and master.
- 2026-11-05: go criterion 6 measured in the app process: 100 synchronous
  plug-in calls (PNG exports, 141 to 168 ms each) on a background queue while
  a 10 ms main-thread timer made a synchronous engine call every tick. Worst
  main-thread stall: 5.0 ms (3.2.0), 2.0 ms (3.2.8), 2.0 ms (master); worst
  engine call from the main thread: 9.3, 3.3 and 15.1 ms. The engine thread
  keeps GIMP's nested loops off the main thread entirely, so the
  GPollFunc integration planned under "Event loop" is not needed.
- 2026-11-05: renders checked against GIMP itself. `scripts/make-fixtures.sh`
  has GIMP 3.2.0's `gimp-console` build a layered fixture (a group with a
  masked multiply layer, a non-destructively blurred layer, a text layer) and
  GIMP's own composite of it. The adapter's render equals that composite with
  no differing pixels, and an XCF save and reopen keeps pixels and structure.
- 2026-11-05: rendering fixed. Flushing the whole projection before every
  read made the first frame of a 24 MP image take 3.4 s; reading it directly
  was fast but returned empty tiles on first use and transparent areas when
  zoomed out. The adapter now stops GIMP's chunk renderer, turns its pending
  work into invalid tiles and renders the full-resolution area under a
  zoomed-out view before reading (first frame at 100 %: about 150 ms). A new
  check, that a fresh first render at 50 % equals one made after a full
  render, failed on the old code. The canvas now keeps 256-pixel device tiles
  and draws them as they arrive, from the viewport centre outwards.
- 2026-11-05: guards. `scripts/interface-diff.py` compares the prototypes of
  every GIMP function the compiled adapter calls (101 now) between two engine
  source trees; none changed from 3.2.0 to 3.2.8 or from 3.2.8 to master. At
  start-up the adapter checks the GObject signals it connects to (with
  argument counts) and the properties it sets, and refuses to start on a
  mismatch.
- 2026-11-05: minor-release drill, run in reverse: the adapter, written for
  3.2, moved to GIMP 3.0.8 with babl 0.1.120 and GEGL 0.4.66, across the same
  interface difference as the planned 3.0.8 to 3.2.0 move.
  `interface-diff.py` predicted all three breaks before compiling:
  `file_open_image` has two fewer parameters before 3.2, and link and vector
  layers do not exist. Fix: 15 added lines of `GIMP_CHECK_VERSION`
  conditionals in `Engine/image.c`, one edit round, no facade or Swift change.
  GIMP 3.0.8 builds unmodified once the prefix also has `mypaint-brushes1`
  (MacPorts moved `mypaint-brushes` to 2.0 after 3.0.8), and it needs the
  typelib repair as well (its babl and GEGL typelibs too).
- 2026-11-05: performance pass (`scripts/build-adapter.sh --perf GIMP_3_2_8`)
  on a GIMP-made 6000 × 4000 image with 20 layers in ten blend modes and a
  1440 × 900 device-pixel viewport: panning over rendered areas costs 1.2 to
  7.9 ms per frame (p95) and painting 1.8 ms (p95) from pointer sample to
  pixels, within a 60 fps budget; the first frame of a freshly opened image
  takes 147 ms at 100 % and 1.8 s at fit. Not compared side by side with GIMP
  3.2.8's GTK interface. Full figures in `phase0-report.md`.
- 2026-11-05: final run on all four engines with the finished code: the 52
  conformance checks pass on 3.0.8, 3.2.0, 3.2.8 and master, and so does the
  app's engine smoke test. Worst main-thread stall during 100 plug-in calls:
  3.5, 3.3, 2.0 and 2.0 ms (5.1 ms in an earlier run); worst main-thread
  engine call: 4.8, 3.3, 0.3 and 0.4 ms.
- 2026-11-05: the 58 editor-relevant upstream UI commits from 3.2.0 to 3.2.8
  triaged ([`phase0-triage-3.2.md`](phase0-triage-3.2.md); classified by two
  helper models from the diffs, spot-checked by hand): 28 port, 3 new
  feature, 26 ignore, and 1 that touches behavior the adapter reproduces
  (`d125895a18`, the clip value when committing an existing filter, which the
  adapter does not do yet).

### Go only if all hold

1. Zero engine-source patches at every tag. Packaging and environment
   workarounds are allowed and listed.
2. Moving from the starting tag to 3.2.8 takes at most 1 agent-day and 50
   changed adapter lines, with no facade or Swift change.
3. Moving to master takes at most 3 agent-days, and facade changes only add.
4. The optional 3.0.8 to 3.2.0 move takes at most 5 agent-days.
5. All conformance tests pass after each move.
6. Pan, zoom and brush latency on a 24 MP, multi-layer file are no worse than
   GIMP 3.2.8 on the same Mac, and a plug-in call never stalls the interface
   for more than 100 ms.

**No-go:** an engine-source patch is required, a micro release forces a
facade change, or the GLib and Cocoa loop integration does not work in
process. Then try the helper-process fallback before reconsidering the plan.

**Result, 2026-11-05: go.** Criteria 1 to 5 hold. Criterion 6 holds for
plug-in stalls; latency is within a 60 fps budget but was not compared side
by side with GIMP 3.2.8. Evidence, findings and open risks:
[`phase0-report.md`](phase0-report.md).

## Phase 1

In this order (reasons in `phase0-report.md`):

1. Interactive plug-ins: try the engine with `no_interface` off and a
   `GimpGui` hook table, so plug-ins can show their own dialogs.
2. A self-contained, still unsigned `Glims.app`: engine, dependencies and
   plug-ins bundled with relocatable paths, plus their third-party notices.
3. The palette system and tool palette in Rigi (`design.md`, section 2).
4. Native tools beyond the paintbrush, porting the triaged fixes as each tool
   lands.
5. A nightly engine matrix (pinned tag, latest stable, master) on a
   self-hosted runner with a prebuilt dependency prefix.

### Progress

- 2026-11-05: item 1, interactive plug-ins, works. The engine now runs with
  `no_interface` off. With it on, GIMP drops plug-ins' progress reports and
  window-handle requests (`app/pdb/progress-cmds.c`) and fails their
  resource choosers, so dialogs could not be parented, show progress or be
  cancelled. Turning it off would also load GIMP's GTK modules and its tool
  presets (which need the GTK tools and crashed the engine); the adapter
  gives both empty search paths on the running configuration, and checks
  those property names at start-up. No engine patch, no GimpGui display
  hooks: a progress object per run (`Engine/progress.c`) supplies progress,
  Cancel and the parent-window handle that makes libgimpui float a plug-in's
  dialog over Glims and hide it when Glims is not active; the icon-theme
  hook and a `theme.css` written at start-up give dialogs GIMP's light
  theme. Facade v1 gained `procedures`, `procedure_run` and
  `procedure_cancel`, a PROGRESS event and a CANCELLED status, all
  appended. While a plug-in runs, edits of any image report BUSY, so its
  dialog acts as a modal filter dialog (`design.md`, Filter menu row).
  The app builds Filter, Image ▸ Adjust (GIMP's Colors), Image, Layer,
  Select and File entries from the 90 plug-in commands' menu paths, with
  Last Filter (⌘F), Last Filter Settings… (⌥⌘F), Recently Used, progress
  with Stop in the status strip, and a plain refusal for edits while a
  plug-in runs. Stopping the engine closes running plug-ins first, so
  quitting Glims with a plug-in dialog open does not hang. A review by two
  helper models found four real defects, all fixed with a check each: the
  run-time overrides leaked into the saved gimprc (GIMP copies running
  settings into the saved ones; the adapter now blocks that copy), File ▸
  Open could start a second plug-in inside a run, a plug-in could start
  while a filter preview was open, and context-menu procedures (`<Layers>`
  and the like) were offered with the wrong items; only `<Image>` entries
  are now. Checked: 74 conformance checks on all four engines (listing,
  last-values runs as one undo step, a Python and a Script-Fu plug-in,
  progress, BUSY while running, cancel, stop during a run, gimprc), the
  app's engine smoke test (24 checks) on all four, and by hand on screen
  with GIMP 3.2.8: Checkerboard's own dialog appeared in front with live
  preview, OK applied it, Escape cancelled it, ⌘Z and ⌘F worked. Not
  checked: resource choosers in plug-in dialogs (brush, font, pattern;
  they still fail without a native chooser), and Script-Fu and Python
  dialogs.
- 2026-11-05: fixed a phase 0 bug found on screen: Edit ▸ Undo and Redo
  never reached the engine, because `NSWindow` answers `undo:` and `redo:`
  from its own empty undo manager before the window controller sees them;
  the phase 0 smoke check had called the document directly. The document
  window's undo manager now forwards to the engine
  (`EngineUndoManager`), which also titles the items ("Undo Gaussian
  Blur"); filter steps are now named by the operation's title, as GIMP's
  filter tools do. The smoke test now goes through the window.
- 2026-11-05: `interface-diff.py` also compares the members of GIMP structs
  the adapter names, after master renamed `GimpProgressInterface`'s
  `get_window_id` slot to `get_window_handle` (upstream ed668b3e2d), which
  only the compiler caught. It reports that rename now.
- 2026-11-05: item 2, a self-contained app, works.
  `scripts/build-app.sh --engine GIMP_REF` runs `scripts/bundle-engine.py`,
  which copies the engine and everything it needs into `Glims.app`: the
  adapter in `Contents/Frameworks`, 124 MacPorts libraries flat in
  `Contents/lib` with GEGL, babl, GTK and GIO modules, the plug-ins, a
  pruned Python 3.13 framework with `gi` and `cairo`, 19 typelibs
  recompiled with `@rpath` library names, and GIMP's data, fontconfig
  and GTK data. Every Mach-O file gets `@rpath` names and one rpath back
  to `Contents/lib`, and is signed ad hoc; the bundler fails if any load
  command still names a build path. GIMP 3.2.8's bundle is 318 MB, 106 MB
  zipped. The adapter recognizes the layout and does what GIMP's own
  `app/main.c` does for its relocatable build: it points the engine,
  GEGL, babl, GTK, GIO, fontconfig, Python and Ghostscript at the bundle
  through the environment, which plug-ins inherit, and moves the MyPaint
  brush folder; a development build keeps using the install tree. The
  engine build itself is unchanged (`relocatable-bundle=no`).
  `Contents/Resources/Engine-Notices.txt` lists 119 components (GIMP,
  GEGL, babl and every MacPorts port owning a bundled file) with version,
  license, homepage and license text, from the port's docs or source
  archive; a license outside the reviewed list in `bundle-engine.py`
  stops the build. `scripts/check-bundle.sh` runs the conformance tests
  and the app's smoke test against the bundle under a sandbox profile
  that denies every read of `_engine/` and `_deps/`: 74 and 24 checks pass
  for bundles of GIMP 3.0.8, 3.2.0, 3.2.8 and master (3.0.8's older GEGL
  needed `GEGL_PATH` and `BABL_PATH`). Not done or not checked: Developer
  ID signing and notarization, running on another Mac, engine
  translations (left out; Glims is English-only), aom's license text (its
  port fetched the source with git, so there is no archive), Poppler's
  CJK data and iso-codes language names (compiled-in prefix paths), and
  the source offer the GPL and LGPL components need before any release.
- 2026-11-05: item 5, the nightly engine matrix. `scripts/engine-matrix.sh`
  runs the whole update chain for each set in `MATRIX_SETS` (the pinned
  GIMP 3.2.8 and master): engine build, adapter conformance tests,
  interface diff against the pinned engine, the app with that engine
  bundled, and the bundle check with the build trees unreadable.
  `.github/workflows/engine-nightly.yml` runs it every night on a
  self-hosted Mac labelled `glims-engine` (setup in `CICD.md`), never on
  pull requests. Run locally: both sets pass every step in 8.5 minutes,
  including master moved to `5374deeec1`. Not checked: the workflow itself,
  which needs the runner to be registered.
- 2026-11-05: items 3 and 4, first slice. Engine: strokes run with any of
  GIMP's paint cores (paintbrush, pencil, airbrush, eraser with
  anti-erase, smudge, blur, sharpen, dodge, burn, clone, heal), with each
  tool's settings appended to `GlimsBrushSettings`; selections by
  rectangle, rounded rectangle, ellipse, polygon and color (contiguous or
  global) with the four operations, feather and antialias; the Select
  commands; the selection's bounds and outline; a SELECTION_CHANGED
  event. 108 conformance checks pass on all four engines. Found and
  worked around an engine bug present in 3.2.8 and master: after a
  selection fills the mask, combining a new shape keeps the mask's cached
  "full" flag, so Grow, Shrink, Border and Feather do nothing and Invert
  clears the selection (`gimp_channel_combine_end`); the adapter drops the
  cache after each change (`Engine/select.c`), and the checks were seen
  failing without that. Interface: a Tools palette (`ClassicToolGrid`, 11
  cells and 19 tools with groups, flyouts, Option-click cycling, tooltips,
  radio-group accessibility, written by a helper model and reviewed; one
  drawing bug fixed), a Tool Options palette for the current tool, the
  canvas tools (all paint tools with Option-click for the clone source,
  rectangle and ellipse select with Shift, Option and Shift-Option at drag
  start, lasso, magic wand, select by color, eyedropper, hand and Space for
  it, zoom), marching ants, the Select menu, tool shortcuts and `[`/`]` for
  brush size, and the classic first-launch layout of the palettes. Checked:
  the app's smoke test (33 checks, tools path included) and by hand on
  screen (rectangle selection with ants, a brush stroke confined to it).
  Not done: tabbed palette groups, docking, workspaces, the color pair,
  move, crop, transform, text, paths, fill and gradient tools, and
  painting on a worker thread.
- 2026-11-05: items 3 and 4, second slice. Engine: paint-bucket fill
  (similar colors or the whole selection), gradients, the Layer commands
  (new, duplicate, delete, arrange, merge down, flatten), layer name,
  visibility, opacity and blend mode, layer selection in the engine,
  layer moves, image crop and a SIZE_CHANGED event; 132 conformance checks
  pass on all four engines, twice each. Interface: Move (V), Crop (C) and
  Gradient and Paint Bucket (G) tools, a background color (X swaps, D
  resets), the Layer menu with Layer Properties (name, opacity, all 35
  blend modes, visibility), Image ▸ Crop to Selection and Flatten Image,
  and canvas resizing after crops and their undo. Fixed on the way: the
  Layers palette chose layers only in the app, so plug-ins and fills
  still acted on the engine's selection; it now selects in the engine too.
  Fixed a stale-render bug: reads that validated projection tiles now and
  then returned pixels from before a change, and kept them (about one
  round in 23 in a probe, intermittent in the tests). The adapter now
  validates the requested area explicitly before reading. That costs
  speed for never-rendered areas at 100 % on a loaded machine (first frame
  580 ms instead of 167, panning into new areas 158 ms instead of 31 at
  p95) and gains it zoomed out (1.2 s instead of 2.3 to fit); panning over
  rendered areas and painting are unchanged. Restoring the fast path needs
  the root cause in GEGL's tile handling, which is open. One bucket-fill
  check failed once in five runs on GIMP 3.2.0 before the fix and not
  since; its cause is not known.
- 2026-11-05: Image ▸ Image Size (constrained proportions), Canvas Size
  (centered; image-sized layers grow and take the background color, as in
  classic editors), Rotate and Flip for the image, and Layer ▸ Transform
  (rotate and flip around the layer's center). 142 conformance checks on
  all four engines and the app's smoke test (45 checks) pass.
- 2026-11-06: item 3, palette groups and docking, built in Rigi as the
  user decided (L-K-M/Rigi#8, merged as `833170b`): tabs in the palette
  title bar with drag to reorder, tear off and merge; magnetic snapping;
  docked columns; double-click collapse; `hideAll`/`restoreAll`; default
  groups and placements; a saved, validated layout seeded once from the
  old frame autosave names. Five review rounds by helper models (Devin,
  GLM 5.3 and others, each finding checked by a second model) found 12
  real defects, all fixed with regression tests; the last round found
  none. Checked by hand in Rigi's gallery with real pointer drags.
  Rigi's CI had to move to `macos-15` first (L-K-M/Rigi#9): GitHub now
  rejects `macos-14` jobs. Sion (L-K-M/Sion#99) and Lucerne
  (L-K-M/Lucerne#85, after L-K-M/Lucerne#86 moved its CI to `macos-15`
  and fixed a macOS 15 paste bug that move exposed) adopted it; all
  merged. Glims pins `833170b`: Tools at the top left
  with Tool Options docked under it, Layers at the top right, replacing
  the hand-written first-launch placement; Tab and Shift-Tab hide all
  palettes or all but Tools while the canvas has focus; Window ▸ Hide
  Palettes and Reset Palettes. Not done: workspaces (named layouts) and
  the per-palette flyout menu (`design.md`, section 2), and Glims run by
  hand with the new arrangement.
- 2026-11-06: item 3, the rest of the Rigi side. `ClassicToolGrid` moved
  from the incubator into Rigi with `ClassicColorPair`
  (L-K-M/Rigi#10, merged as `6a2d830`); the Tools palette uses both, and
  the color pair's swap and reset share X and D's code. Palette menus and
  named workspaces (L-K-M/Rigi#11, `cb32da9`) and `ClassicValueSlider`,
  `ClassicPaletteButtonBar` and status bar progress, accessories and an
  editable zoom (L-K-M/Rigi#12, `084e116`) are merged, and Glims uses
  them: menus on the Layers and Paths palettes, Window ▸ Workspaces, value
  sliders in Tool Options, button bars on Layers and Paths, a zoom typed
  into the status bar, and plug-in progress with Stop in the status bar
  (Glims's own progress view is gone). Each Rigi PR went through
  helper-model review rounds with a second model verifying every finding
  until a round found nothing; every confirmed defect was fixed with a
  regression test, among them palette title bar menu items that raised an
  exception (`perform(_:)` resolved to NSObject's `performSelector:`) and
  a typed zoom of "-1e20" that trapped converting to Int. Trying the
  menus by hand found one more: AppKit's own resize zones on a resizable
  borderless panel swallowed clicks on the menu triangle
  (L-K-M/Rigi#13, merged as `9cc460d` after four review rounds; Glims
  pins it, and the Layers menu now opens from its triangle).
- 2026-11-06: item 4, Transform and Text tools. Engine: an additive facade
  call applies an affine matrix to a layer with `gimp_item_transform` as
  one undo step (`layer_transform_matrix`, five interpolations), and
  text layers through GIMP's own text code: the font list, adding a text
  layer, reading its plain text and look, and changing them
  (`fonts`, `text_layer_new`, `text_layer_get`, `text_layer_set`). Fixed
  on the way: Layer Properties offered the paint-only Behind mode, which
  GIMP asserts on and ignores for layers; the adapter now refuses paint-only
  modes and the menu leaves Behind out. 168 conformance checks pass on
  all four engines. Interface: a Transform tool (Shift-V from Move) with
  corner and edge handles (Shift keeps proportions), move inside, rotate
  outside (Shift: 15° steps), a live outline and grid, Return or a
  double-click to apply and Escape to cancel; its geometry is a value type
  with unit tests. A Text tool (T): click to type new text in the
  foreground color, or click a text layer to edit it, in an editor laid
  over the canvas; font, size, alignment and spacing in Tool Options; the
  engine's fonts load in the background at the first document. The
  canvas now draws light checks under transparent pixels, so what a
  transform uncovers reads apart from the gray around the image. Checked
  by hand with a real pointer and keys: scaling the background layer by
  its corner and applying with a double-click, typing new text and
  editing it. That found two defects, fixed with regression tests: the
  first keystroke in the text editor crashed the app (the editor
  registered typing undo with the document window's undo manager, the
  engine's, which raises; the editor now keeps its own typing history,
  which Edit ▸ Undo uses while typing), and the font popup showed and
  set the wrong font because the engine repeats some of its 2622 font
  names (the list is now deduplicated, without macOS's private
  "."-fonts). The app's engine smoke test (56 checks) drives the Text
  tool through the canvas and checks the checks. Painting already runs on its own
  queue (`ImageDocument.inputQueue`). Fixed since: a new document window
  opened exactly over the previous one; it now cascades.
- 2026-11-06: item 4, the triaged upstream fixes
  ([`phase0-triage-3.2.md`](phase0-triage-3.2.md)) checked against the
  tools that landed. None needed code: the text tool fixes for Alt
  shortcuts, span font sizes and cursor stepping with negative kerning
  concern GIMP's own text editor, which Glims replaces with NSTextView;
  clicking a text layer's mask already picks the text layer, since the
  Text tool hit-tests the layer list; selections read Shift and Option
  when the press starts, which is what GIMP issue #1589 fixed; the crop
  change is in the engine (`gimp_image_crop`), and Glims's crop has no Delete
  Pixels option; the canvas does not rotate, so the checkerboard fix does
  not apply. Still to port with their features: the vector layer
  commits (path tool undo grouping, fill visibility), filters refused on
  invisible layers (`6a33e2998e`), and the rest of the list.
- 2026-11-06: item 4, painting off the main thread, measured
  (`build-adapter.sh --perf GIMP_3_2_8`, 24 MP, 20 layers, Mac16,9). While
  another thread paints a 500-sample stroke at pointer rate (8 ms apart),
  back-to-back 1440 × 900 renders at 100 % take 3.6 ms on average and
  12.5 ms at p95 (1.2 ms idle), within the 60 fps budget, with one
  180 ms outlier. The engine runs one call at a time, so the stroke
  falls behind instead: its 4 s of input took 6.9 s under that
  continuous rendering. The canvas renders only damaged tiles at most
  once a frame, so real use sits between the two; a stroke that lags
  its pointer under heavy redraws is the cost to watch.
- 2026-11-06: item 4, paths. Engine: seven additive facade calls list
  paths, read and replace their Bézier subpaths (each anchor with its two
  handles, GIMP's control, anchor, control), rename, show, select and
  delete them, and make a path the selection or draw it as a line, each
  change one undo step; GIMP 3.2 moved `app/vectors` to `app/path`, the
  only version difference. 187 conformance checks pass on all four
  engines, an XCF round trip included. Interface: a Path tool (P) that
  adds corners by clicking and smooth anchors by dragging, closes on the
  first anchor, moves anchors and handles, pulls out handles with
  Option, starts subpaths with Shift and deletes anchors with Delete,
  every press-drag-release one undo step; visible paths draw on the
  canvas with any tool; a Paths palette, tabbed with Layers by default,
  with visibility, renaming, New, Delete, Select (path to selection) and
  Stroke (foreground color, the tool's width); Select ▸ From Path and
  Edit ▸ Stroke Path. The path geometry is a value type with unit tests,
  and the engine smoke test (66 checks, all four engines) drives the
  tool through the canvas and the palette's commands. Checked by hand:
  drawing, closing, Select and Stroke. Not done: filling a path, paths to
  vector layers (GIMP 3.2), and editing several anchors at once. A
  layout saved before the Paths palette existed shows it as its own
  panel rather than as a tab of Layers; Rigi places a new kind by its
  default group only when the other kinds have no group yet.

- 2026-11-07: Glims pins Rigi `4b4762f`, including the merged picker,
  activation and restore-layout fixes (L-K-M/Rigi#4, #5, #6 and #15).
  Restoring palettes saves repaired off-screen positions immediately;
  pickers remember their invoking editor; changing window activation
  invalidates chrome, not document content. Rigi's 103 tests, gallery
  smoke test and release build pass at this revision.

## Completion work (2026-11-07)

The user requested the complete editor after a normal build opened the
engine-free placeholder. The remaining work and evidence are tracked in
[`completion.md`](completion.md). Phase 1's implemented tools did not make
the application complete: basic file lifecycle and clipboard workflows,
and substantial parts of `design.md`, still need implementation and checks.

### Resource enumeration and identity (2026-11-08)

Engine side only, on `feat/resource-catalog`, the first slice of the
brush/pattern/gradient resource choosers (completion.md item 4): three
additive facade slots appended after the table's end
(`resources`, `resource_identifiers`, `resource_resolve`), API version 1
unchanged and no settings struct touched. New facade-owned types:
`GlimsResourceKind` (BRUSH=1, PATTERN=2, GRADIENT=3), `GlimsResourceID`
(= `uint64_t`, an opaque session handle over the native ephemeral
`gimp_data_get_id` value: zero and out-of-native-gint-range handles are
refused before the native id table, and each call re-resolves fresh
through `gimp_data_get_by_id` and revalidates type plus membership in
this engine's own factory container, since the native id table is
global), and `GlimsResourceInfo` (`id`, `kind`, `name[256]`).
`resources()` enumerates names and handles only from
`gimp_data_factory_get_container` in native order, with the existing
count/short-buffer conventions and labels truncated only at valid
UTF-8 boundaries. `resource_identifiers()` hands over the
`gimp_data_get_identifiers` triplet as owned strings released with
`free_string`, preserving a NULL collection distinctly from an empty
one, and reports FAILED with the outputs reset when the identity is
unusable (a missing or invalid name, or a non-UTF-8 collection).
`resource_resolve()` matches exactly as `gimp_data_identify` does
within one kind's factory container: internal resources match without
their (localized) name, there is no name-only fallback, and unknown
identities report NOT_FOUND with `outID` reset to 0. Wrong kinds,
invalid identity text and missing required outputs are
INVALID_ARGUMENT. Every call is read-only and marshaled onto the
engine thread like the rest of the facade; nothing mutates factories,
contexts or files. The native calls (`gimp_data_get_id/get_by_id`,
`gimp_data_get_identifiers`, `gimp_data_identify`,
`gimp_data_factory_get_container`, `gimp_container_have`, the
`GIMP_IS_BRUSH/PATTERN/GRADIENT` checks) were confirmed identical in
GIMP 3.2.8, 3.2.0, 3.0.8 and master sources; master's `gimpdata.h`
macro-ization needs no `GimpDataClass` use. Bounded conformance tests
call through the facade only: counts, rows, short buffers, current
handles, identity round trips including the internal localized-name
semantics, the refusal of name-only fallback, cross-kind identities,
wrong kinds, unissued and out-of-range handles, bad arguments, output
resets and owned strings freed. All four engine prefixes built by
`scripts/build-engine.sh` install stock brush, pattern and gradient
files (47/58/78), and the tests require at least one file-backed and
one built-in resource per kind, so a built-in-only listing cannot pass.
Validation: all four private adapter builds and native conformance runs
pass: 820 checks on 3.2.8, 3.2.0 and master, and 787 on 3.0.8. The
installed stock files (47/58/78 above) differ from loaded factory totals:
the pinned runtime lists 58 brushes, 59 patterns and 77 gradients. Added
high-bit handle regressions prove that a 64-bit handle is rejected before
narrowing it to a live 32-bit native id. Independent Mistral Large 4
review found no important issues. Swift build and unit integration are
recorded in the PR; thumbnails, resource selection and application,
settings, management and chooser UI remain later slices.

### Swift resource wrappers (2026-11-08)

Session side of the same slice, on `feat/resource-session`: three typed
`EngineSession` wrappers over the three facade slots
(`resources(_:)`, `resourceIdentifiers(_:)`,
`resolveResource(_:kind:)`) with facade-owned `ResourceKind`
(brush/pattern/gradient, UInt32 tags 1/2/3, unknown engine row kinds
rejected), `ResourceID` (`UInt64`, the full range so no handle
truncates lossily), `Resource` and a Codable/Equatable
`ResourceIdentity` whose `collection` keeps NULL (nil) distinct from
an empty string through persisted JSON. A short resource buffer is
retried at the reported count, and the owned identity strings are
freed on every path, error paths included; errors go through the
existing `check`/`free_string` handling. Returned ids are local to the
running engine session: persisted selections store identities, never
ids, and nothing enumerates the catalog eagerly on the main thread or
at startup. The `--engine-smoke-test` gains a bounded catalog scenario
after the existing checks: counts and rows for all three kinds, one
identity/resolve round trip per kind, a wrong identity and a high-bit
handle; `ResourceIdentityTests` covers the persisted nil-versus-empty
distinction and the kind tags. Root validation passes 308 unit tests and
696 interface checks on 3.2.8/3.2.0/master, 685 on 3.0.8. The two
embedded-NUL identity checks first failed because CString truncation
resolved another identity. The wrapper now rejects the text before C.
After merging Fill, the source-discovered pinned engine passes 708
interface checks and all 308 unit tests. Independent Mistral Large 4
review found no important issue. Preview and chooser UI remain separate.


### Stroke with a selected brush resource (2026-11-08)

Engine side only, on `feat/brush-resource-strokes`: one additive facade
slot appended after the table's end, `stroke_begin_with_brush_resource`,
API version 1 unchanged, no existing struct layout or signature touched
(no padding repurposed). It takes the opaque `GlimsResourceID` brush plus
the existing `GlimsBrushSettings` and `GlimsStrokePoint`, and the stroke
runs through the same `stroke_continue`/`stroke_end`. `stroke_begin` is
unchanged in behavior, including the inherited default brush resource.

Implementation, all native C:

- `Engine/resource.c` keeps its id validation private but now exposes one
  narrowly typed internal helper, `glims_lookup_brush()`
  (`Engine/engine-private.h`), which reuses `lookup_resource()` — so a
  zero handle or one outside the native gint id range is still refused
  with INVALID_ARGUMENT before the native id table, and a stale handle or
  a brush absent from the current engine's own brush factory still
  reports NOT_FOUND — and then requires `GIMP_IS_BRUSH`, so a live handle
  of another resource kind is INVALID_ARGUMENT. No duplicated
  ID-truncation validation anywhere.
- `Engine/paint.c` splits the old `glims_stroke_begin` body into a static
  `stroke_begin_common()` taking an optional `GimpBrush *`; all existing
  guards (image/drawable lookup, settings validation, busy, group
  refusal, lock checks, clone/heal source, paint-info lookup, undo
  grouping, start/paint/flush sequence) are untouched, and every refused
  call now also sets `*out = 0` and mutates no image or history.
  `make_options()` gained the optional brush: when given, it defines
  `GIMP_CONTEXT_PROP_BRUSH` locally on the stroke's own paint-options
  context BEFORE `gimp_context_set_brush()` — an undefined property would
  make the setter walk up to the parent, which is the shared user context
  and must never be mutated — so the local definition both pins the brush
  and shields the stroke from later parent/caller changes; the context
  then holds the brush strongly (`g_set_object`) for the whole stroke.
  The shared user context and factory resources are never written, and
  painting stays GIMP's own paint core (`gimp_brush_core_start` reads the
  brush from the options' context), so native colored-brush semantics are
  preserved with no bitmap reimplementation.
- The brush is resolved exactly once, at begin, on the engine thread.
- `Engine/engine.c` marshals the entry with a dedicated
  `GlimsStrokeResourceArgs` whose `brush` field is a typed
  `GlimsResourceID` (`uint64_t`); the id never travels in an int32-width
  field of `GlimsArgs`.
- `Engine/tests/engine-tests.c` gains `test_stroke_brush_resource()`:
  stock file-backed parametric brushes "Hardness 025" and "Block 01"
  (not pipes or the clipboard brush) with `pressure_size=false`; the
  selected brush paints its band and undo restores the exact pixels as
  one undo step; the two distinct brushes paint differently at the same
  place; an open resource stroke keeps its brush across an interleaved
  legacy stroke on another image, and legacy default strokes before and
  after all resource strokes paint identically (the inherited brush
  context is unchanged); refusals cover zero, high-bit
  (`1<<40`, all-ones, `0x80000000`, `(1<<32)|id`), wrong-kind (a pattern
  handle), stale/unissued `0x7FFFFFFF`, unknown image, missing
  point/settings/output, non-positive size, pixel LOCKED and plug-in
  BUSY, each resetting the out stroke to 0 with no undo or pixel change;
  the brushes' persistent identities are unchanged and still resolve to
  the same handles.

Compile status (private root, `GLIMS_ADAPTER_ROOT=$PWD/.build/engine-adapters`,
no `--check`/`--test`, shared `_engine/.lock` was free each time):
`scripts/build-adapter.sh GIMP_3_2_8`, `GIMP_3_2_0`, `GIMP_3_0_8` and
`master` all compiled and linked `libglimsengine.dylib` (exports only
`glims_engine_get_api`) plus the `glims-engine-tests` runner; the only
warning is the pre-existing `clipboard.c` declaration-after-statement.
Runtime conformance (`--test`), engine startup, Swift builds and app
smoke tests were NOT run here: root runtime validation is pending.

### Resource thumbnails (2026-11-08)

Engine side only, on `feat/resource-previews`: one additive footer slot
appended after `resource_resolve` (the root's slot 68),
`resource_thumbnail(engine, id, max_size, foreground, background, out,
error)`. API version 1 and every existing layout and signature are
unchanged. It renders a fresh thumbnail of the resource `id` names into
an owned straight-alpha sRGB RGBA `GlimsPixelBuffer` (released with the
existing `free_pixels`), fitted into a `max_size` x `max_size` box
(`max_size` restricted to 1 ... 512): gradients fill exactly
`max_size` x `max(1, max_size / 2)`, brushes and patterns keep their
source aspect inside the box without upscaling, matching their native
preview. `foreground` and `background` are optional explicit colors
(every component finite inside 0 ... 1, the filter-property
convention): the foreground recolors mask-only brushes and both feed
gradients with foreground/background segments; NULL uses the core's
canonical black foreground and white background. The handle path
reuses `lookup_resource` exactly (zero and out-of-native-gint-range
refused before the native id table with "This handle cannot name a
resource.", stale or foreign NOT_FOUND, fresh re-resolution and
factory-membership revalidation per call), and the dispatcher carries
the handle in a typed `uint64_t` `GlimsResourceArgs`. Everything is
read-only: no image, factory or global context is touched.

The render deliberately avoids the cached preview paths. Verified in
the pinned sources: `gimp_viewable_get_new_pixbuf`'s default runs the
cached `gimp_viewable_get_preview`, whose cache key (width, height,
foreground) omits the background, so same-size gradient thumbnails
would come back stale when only the background changes. Instead each
call takes the fresh, owned `gimp_viewable_get_new_preview` (all three
resource classes override it; it never consults the cache) followed by
`gimp_temp_buf_create_pixbuf` for format normalization, unrefing the
TempBuf (`gimp_temp_buf_unref`) and the pixbuf (`g_object_unref`). On
master (3.3.x) `get_new_preview` takes `scale_factor` before
`fg_color` (passed as 1); the three released trees take five
arguments. The per-call `GimpContext` is parentless
(`gimp_context_new (gimp, ..., NULL)`) and carries explicit per-call
FG/BG `GeglColor`s, so the user and global contexts are never read or
changed. The pixbuf's rows are copied rowstride-safe into the owned
buffer, RGB previews expanded to RGBA with opaque alpha; allocation
overflow and OOM are checked and `out` is reset on entry and on every
failure.

Bounded conformance tests (facade only) cover stock brushes, patterns
and gradients: dimensions, bounds, byte counts, pixel and alpha
coverage, exact gradient strips at 15 and 1, the same-id same-size
FG/BG gradient proof (only the background changed, then only the
foreground, must change the pixels, and identical colors must agree),
invalid/stale/high-bit handles, bad sizes and colors, missing outputs,
error text, output resets and five repeated allocate/free rounds.
Checked here (compile only, private adapter root
`$PWD/.build/engine-adapters`): `scripts/build-adapter.sh --check` for
GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8 and master; every `Engine/*.c`
against all four sets' `compile.rsp` flags with `-fsyntax-only`;
`engine-tests.c` with its `-std=c11 -O2 -Wall -Wextra -Werror` flags;
the facade header standalone in C11 and C++17; and full
`scripts/build-adapter.sh` builds per set (compile, link, the
exports-only check) in the private root. Not run here (the root owns
the native runtime): `scripts/build-adapter.sh --test` per engine set,
bundle checks and any Swift build. Pending root runtime validation:
the four conformance runs, including the fresh-per-call gradient proof
and the exact gradient strip dimensions.

### Swift resource thumbnail wrapper (2026-11-08)

Session side of the same branch, `feat/resource-previews`: one typed
`EngineSession` wrapper, `resourceThumbnail(_:maxSize:foreground:background:)`,
over the facade's `resource_thumbnail` slot, returning an owned
`ResourceThumbnail` — checked `width`/`height`, a straight-alpha sRGB
RGBA `Data` of exactly `width * height * 4` bytes, and a CGImage over
the same bytes with `CGImageAlphaInfo.last`, an sRGB space and a
`width * 4` row stride, matching `drawableThumbnail`'s straight-alpha
contract. The opaque `UInt64` handle passes through unnarrowed;
`foreground`/`background` are optional `NSColor`s converted with the
existing `color(_:)` helper and documented as opaque in native FG/BG
contexts (alpha comes from the resource's brush mask or transparent
gradient stops, never from the colors). The native buffer is freed
with `free_pixels` on every path, validation and CGImage-construction
failures included, and the dimensions and byte count are checked with
overflow-reporting multiplies before the copy; native errors surface
through the existing `check`/`EngineError` handling. No UI flow calls
the wrapper; its doc marks it off the main thread, like
`resources(_:)`. The `--engine-smoke-test` gains
`exerciseResourceThumbnails`: stock brushes, patterns and gradients of
each kind through the wrapper (box fit, byte counts, CGImage
dimensions/row stride and first-pixel readback), exact gradient strips
at maxSize 15 and 1, stable handles and identity round trips across
calls, the built-in FG/BG gradient resolved by its exact internal
identity with the fresh-render proof (same colors agree byte for byte;
background-only and foreground-only changes re-render; explicit colors
differ from the defaults and leave the defaults untouched, so no
global context is mutated), zero/all-high/high-bit ids refused as
INVALID_ARGUMENT without narrowing, a well-shaped unissued id as
NOT_FOUND, maxSize 0/-1/513 refused, and an open image's undo state,
pixels and every catalog unchanged after the calls. Verified here with
`swift build` and `swift build --build-tests` only (both pass, no new
warnings); the root owns the engine lock and the desktop, so the
smoke-test scenario's runtime execution is pending root validation,
after the root's ICC integration to keep the append-only ABI order.
### Stroke with a selected brush resource (2026-11-08)


### Brush chooser in Tool Options (2026-11-08)

Interface side of the brush resource work, on `feat/brush-chooser`. One
brush chooser only, attached to the paint tools' Tool Options rows; no
pattern/gradient application and no presets. No C API or C implementation
change: the slice is Swift-only over the existing append-only facade
(`resources`, `resource_identifiers`, `resource_resolve`,
`resource_thumbnail`, `stroke_begin_with_brush_resource`).

- `Sources/GlimsKit/Tools/BrushSelectionStore.swift`: the per-tool brush
  choice persisted through UserDefaults as Codable JSON — ONLY a
  `ResourceIdentity` per `ToolID`, never a session `ResourceID` (handles
  are engine-local and reused after a restart). A nil choice removes the
  key and means the original native default brush.
- `Sources/GlimsKit/Tools/Tools.swift` (`ToolState`): `brushStore` (tests
  inject a suite), `baseBrush(for:)` seeds a tool's brush with the
  persisted identity so it restores after a restart, and
  `setBrushResource(_:for:)` persists the identity and updates only that
  tool's `brush.resource`. `EngineSession.beginStroke` already resolves
  the identity fresh on the engine worker, so a stale or removed resource
  fails explicitly (native queued tests passed) instead of painting with a
  different brush.
- `Sources/GlimsKit/Tools/BrushChooserModel.swift`: the pure model. It
  captures the `ToolID` at open, holds the FULL catalog (every engine
  brush — no 512-row cap), the lazily rendered 32 px thumbnails, the
  in-memory case-insensitive search over the whole catalog, the selection
  (none / native Default / a row), the missing-identity marker and a
  generation counter that closing bumps so late native results are
  dropped. `pendingIdentity()` maps the selection to the identity to
  commit; a selected row absent from the loaded rows falls back to the
  unchanged current identity, so filtering, partial rows or an unlisted
  current choice never reset the preference to Default. Applying writes
  only the captured tool, so switching tools while the chooser is open
  never retargets the selection, and cancel applies nothing, preserving
  the previous choice. The current identity is marked missing ONLY when
  native resolution returns NOT_FOUND; any other resolution error is kept
  distinctly in `resolutionError`, and an engine-resolved identity outside
  the loaded rows stays valid.
- `Sources/GlimsKit/Tools/BrushThumbnailQueue.swift`: the pure lazy
  thumbnail pipeline. Rows are requested as they appear (the resolved
  current brush first), native batches are bounded to 32, never overlap,
  and succeeded/failed attempts are cached for the generation so a single
  bad thumbnail shows a placeholder and is never retried. Refused batches
  (gate busy) are requeued and re-pumped once when idle; `invalidate()`
  drops everything on close and stale generations are rejected.
- `Sources/GlimsKit/Tools/BrushChooserPanel.swift`: `BrushChooser.shared`
  owns the one open panel (closed on shutdown from
  `applicationWillTerminate`, on palette dismiss, and on retarget to a
  different/closing document). The panel is an owned NSPanel with a search
  field, a one-column list of native 32 px thumbnails and names (row 0 is
  the native Default), a status line for the loading / engine-busy / error
  / empty states with a Retry, and Choose (Return) / Cancel (Escape). The
  catalog load runs OFF the main thread through
  `EngineActivity.perform`/`whenIdle` (the global exclusive gate) and
  reads EVERY brush's name and persistent identity — no thumbnails in
  that batch. Thumbnails render lazily in bounded batches of 32 through
  the same gate (`resourceThumbnail` is a synchronous RPC and is never
  called on main), recolored with the FG/BG captured from `ToolState` at
  open; only `ResourceThumbnail.image` is displayed, and no shared global
  context is mutated. If the gate is busy the panel shows the busy state
  and retries once when idle, then an error with a manual Retry; delivery
  checks the generation and that the document is still alive, so
  document/parent closing or picker closing invalidates stale results.
  The status line reports the full catalog count and the current search
  result count ("N of M brushes"), plus the missing / resolution-error
  marker when one applies.
- `Sources/GlimsKit/Tools/ToolPalettes.swift`
  (`ToolOptionsPaletteController`): the no-op `retarget` now retains a
  weak document as the chooser's session/loading source; paint tools get a
  "Brush" row with a button showing the current choice (name plus the
  loaded thumbnail, or "Missing: …" when the persisted identity does not
  resolve — never silently defaulted) and an explicit Reset button that
  stores nil (native Default).
- Tests: `Tests/GlimsKitTests/BrushChooserTests.swift` covers the
  identity-only encode/restore (raw JSON carries no session handle),
  invalid stored data, the in-memory search, stale-generation delivery,
  current/missing selection, a >512-row catalog searched and selected in
  full, missing reported only for native NOT_FOUND (other errors
  distinguished), a resolved current identity outside the loaded rows, the
  lazy thumbnail queue (dedupe, 32-row batches, no overlap, failure
  caching, priority, stale generations), and captured-tool apply / cancel
  / restore / reset through a fresh `ToolState`. `EngineSmokeTest` gains
  `exerciseBrushChooserSelection`: captured tool vs tool switching, the UI
  choice painted through the document queue with undo restoring exact
  pixels, cancel preserving the selection, a missing identity reported
  without paint or undo, and reset restoring the default stroke path.

Compile status (private root, `GLIMS_ADAPTER_ROOT=$PWD/.build/engine-adapters`,
no `--check`/`--test`, shared `_engine/.lock` was free each time):
`scripts/build-adapter.sh GIMP_3_2_8`, `GIMP_3_2_0`, `GIMP_3_0_8` and
`master` all compiled and linked `libglimsengine.dylib` (exports only
`glims_engine_get_api`) plus the `glims-engine-tests` runner; the only
warning is the pre-existing `clipboard.c` declaration-after-statement.
Runtime conformance (`--test`), engine startup, Swift builds and app
smoke tests were NOT run here: root runtime validation is pending.

Build status (this slice): `swift build` and `swift build --build-tests`
run once after the change (see the commit); unit tests were NOT executed
(AppKit initializes in the test bundle), and no engine startup, native
smoke test, adapter build or GUI run happened here — root owns the
runtime, GUI and native matrices. Gaps: the chooser's runtime behavior,
thumbnail rendering through the panel, keyboard handling and the
smoke-test scenario are unverified at runtime; pattern/gradient choosers,
presets and resource management remain later slices.

### Guides interface (2026-11-08)

Image > Guides… opens a per-window management sheet (GuidesSheetController,
retained by its DocumentWindowController) listing the cached
ImageDocument.guides by orientation and position. Inline orientation plus
a strictly parsed integer position feed Add, Move selected, Remove
selected and Close; each edit goes through the queued
addGuide/moveGuide/removeGuide as one undo step, so Close is not Cancel
and the sheet says changes can be undone. Orientation is fixed at
creation: a move sends the guide's own cached orientation, never a
reorienting put. Reload/error/close fan out through the window's existing
onStateChange/onError/windowWillClose hooks; the selected row is preserved
by guide id across asynchronous reloads and an active field edit is never
overwritten; write controls disable on the cached busy/closing state and
refusals show in the sheet. View > Show Guides is a cached per-window
Boolean (default on) whose checkmark reads the cache; toggling redraws
only the canvas overlay (drawn from document.guides through the
CanvasGeometry image/view mapping, clipped to the displayed image) and
never touches pixels, dirty state, export or print — printing draws an
immutable PrintSnapshot, not the canvas view. Rulers, snapping and canvas
guide dragging are later work. Compile-checked here (swift build,
--build-tests); unit tests cover parsing, range/orientation, menu state,
row/edit preservation and overlay geometry; the GLIMS_SMOKE_CASE=
guides-controls scenario is wired but NOT run — root owns the runtime
matrix against the native-guides libraries.

### Pixel rulers (2026-11-08)

View > Show Rulers (default on) puts app-specific pixel rulers in the
scroll view's native ruler slots: `DocumentWindowController` assigns two
`PixelRulerView`s (an `NSRulerView` subclass) to
`scrollView.horizontalRulerView`/`verticalRulerView` with
`hasHorizontalRuler`/`hasVerticalRuler`, so AppKit keeps the scroll
layout (toggling relayouts the viewport around the ruler thickness) and
the rulers' accessibility semantics. The toggle state is a cached
per-window `RulerViewState` (default on), separate from
`guidesViewState`; the menu checkmark reads the cache via
`RulerMenuLogic.validate`, which deliberately takes `engineIsBusy` and
ignores it, so the item stays enabled and the toggle works while the
engine is busy. Drawing is display-only: `PixelRulerView` reads the
canvas's live geometry (weak `canvas` reference, cached image size) and
maps image pixels through `NSView.convert(_:from:)` from the canvas —
never assuming a vertical direction — so scroll, zoom, backing scale,
image extent and flips come out right; no facade call, pixel, file,
dirty, history, selection, export or print path is touched (printing
draws an immutable PrintSnapshot, not the scroll view). Ruler
invalidation rides the existing content-bounds notification (scroll and
ruler toggles), plus canvas frame changes (zoom, image extent) and the
window's backing-properties notification; the selector observers are
removed in `windowWillClose` and in `deinit` (`rulerObserversActive`
tracks them), and the ruler holds the canvas weakly, so closing a window
leaves no observation or dangling geometry source behind. There is no
global ruler controller.

Ticks and labels come from a pure bounded planner, `PixelRulerPlan`: it
validates all inputs finite (nil for non-finite inputs, non-positive
scale, negative extent or an inverted range), clamps the visible range
to the image extent `0...extent` (an off-image range or zero extent is
the deliberate empty-plan fallback), picks the major spacing as the
smallest whole 1/2/5 * 10^n reaching ~50 view points (whole pixels, so
labels are whole image pixels), plans minor ticks at major/5 only when
they land at least 4 view points apart, and caps the output at 512
ticks with a progress guard, so extreme zoom, nonzero origins and
damaged huge sizes terminate with a finite, sorted, bounded plan.
`PixelRulerGeometry.deviceAligned` snaps strokes to the half-device-
pixel grid (at most half a device pixel) without changing the ticks'
image coordinates. Guides keep working independently; their state and
overlay are untouched.

Compile-checked here: `swift build` and `swift build --build-tests`
both pass. Unit tests (`PixelRulerTests`) cover the planner against
independent oracles (brute-force nice spacing, CanvasGeometry zoom/
backing point scale, explicit range arithmetic) across nonzero origins,
zoom and backing, clamping, cap/finiteness at extremes, damaged inputs,
label semantics, device alignment, and the per-window default plus the
busy-independent menu-validation contract. The smoke scenario
`GLIMS_SMOKE_CASE=pixel-rulers` (`exercisePixelRulers`, also in the
default engine-smoke run) is wired but NOT run here — it drives the
real ruler slots and menu action (on/off viewport and checkmark changes,
independent two-window state, busy-independent toggling, scroll/zoom
tick movement and a ruler view bitmap against the geometry oracle,
pixel/dirty/history/selection isolation, observer removal on close);
root owns the runtime matrix against the native libraries.

### Path tool multi-anchor selection (2026-11-08)

Scope: `Sources/GlimsKit/Tools/VectorPath.swift`,
`Sources/GlimsKit/Document/PathTool.swift`, `Tests/GlimsKitTests/
VectorPathTests.swift`, `Sources/GlimsKit/EngineSmokeTest.swift` and this
log only — no C/header/dependency/facade change and no other feature.
`VectorPath` gains three pure batch helpers: `moveAnchors(_:by:)` (moves
every anchor in a set with its handles), `removeAnchors(_:)` (removes a set
descending by subpath then anchor, so earlier removals cannot shift later
indices; empty subpaths drop and one-anchor closed subpaths open through
the existing `removeAnchor(at:)`), and `pruned(_:)` (keeps only indices
that still name an anchor). `PathTool` replaces the single `selected`
anchor with `selectedAnchors: Set<AnchorIndex>` (`private(set)`; no other
file read the old property): Shift-click on an existing anchor toggles
membership, ends the subpath being drawn and neither closes, edits nor
pushes an undo; Shift-blank still starts a new subpath. A normal click on
a selected anchor keeps the whole set for a group drag, a click on any
other anchor single-selects, and Option-pull single-selects. A drag moves
all selected anchors and their handles by the delta from the press
baseline — the shape is rebuilt from the anchors captured at the press on
every motion event, so repeated motion cannot drift — and commits as one
queued `updatePath`/one undo on release; the shape-changed-during-drag
refusal is unchanged. Delete removes the whole set in one update/undo,
adjusting or clearing `extending` for dropped subpaths. The set is pruned
of invalid indices and cleared on an active-path switch in
`syncWithDocument`. Drawing shows handles for every selected anchor and
fills selected anchors with the path color. Old single-anchor behavior
(closure, extension from either end, handle mirroring with Shift,
Option-pull, Return/Escape) is retained.

Tests: `VectorPathTests` gains pure batch tests (set move across subpaths
with handles, descending batch delete across subpaths with
drop/open/ignore-invalid, pruning). `EngineSmokeTest` gains
`exercisePathAnchors`, wired both as `GLIMS_SMOKE_CASE=path-anchors` and
into the full run, driving the real canvas events: selecting two anchors
across subpaths, Option-pull single-select, a group drag with wandering
intermediate points as one undo moving anchors and handles by the final
delta only, a release at the press baseline with no drift and no undo,
Shift-toggle-off with no undo, active-path switch clearing the set and a
mid-drag switch refusing the drag, and a batch delete as one undo whose
undo restores the exact engine shape. All runtime shape oracles read
`session.path` from the engine, never the document's cached working state.

Build status (this slice): `swift build` and `swift build --build-tests`
both completed clean (only pre-existing warnings) on this branch. Unit
tests, `GLIMS_SMOKE_CASE=path-anchors` and the full `--engine-smoke-test`
were NOT run here — root owns all runtime; no GUI, adapter build, engine
run or push happened in this slice.

## Later, before any public release

- Verify the ad-hoc signatures of the app and bundled executables. The user
  explicitly excluded notarization; Developer ID signing and notarization are
  not release gates for this task.
- A process for shipping engine security fixes within days. GIMP's file
  loaders had high-severity bugs in 2025 (for example CVE-2025-14424 in XCF
  and CVE-2025-10925 in ILBM).
- A written offer or download of the complete corresponding source for
  every GPL, LGPL and AGPL component in the bundle (the engine notices,
  generated since phase 1, list them), aom's license text, and a release
  check that the notices match the bundle.
- Accessibility, localization and help content for the new interface.

## Rendering follow-up

- 2026-11-07: the user reopened the slower-first-render issue. Found the
  stale-read root cause in GEGL's `gegl_buffer_get_pixel`
  (`gegl/buffer/gegl-buffer-access.c`): its 1 × 1 shortcut reuses a hot
  tile without asking GIMP's validate handler. Ordinary multi-pixel
  reads do ask the handler. Limiting explicit validation to scaled reads
  reproduced 36 stale single-pixel reads out of 60, and zero stale
  multi-pixel reads. The adapter now leaves explicit validation on for
  single-pixel and scaled reads, while 1:1 viewport reads again render
  directly into tiles. No upstream patches or private cache access.
  The conformance test covers both paths separately; the performance
  pass repeats the cold 100% viewport on five freshly opened images.
  On this Mac's 24 MP, 20-layer fixture, their mean fell from 517 to
  219 ms (first sample 574 to 162 ms), and cold-pan p95 from 237 to
  39 ms. Machine load was high and variable (roughly 40 to 60), so these
  are not a controlled speed guarantee: each performance pass also had
  one measurement over the 60 fps budget. Zoomed-out rendering keeps
  its existing path. The initial GitHub build also exposed a Swift
  6.2 tuple-conversion error in path hit testing; its distance now
  explicitly uses Double, matching the stored distance type.
- 2026-11-08: two more additive path facade calls, engine side only, on
  `feat/path-fill-vector`. `path_fill` fills a path onto an explicit
  drawable (layer, mask or channel; 0 = the selected drawable) through
  the core's `gimp_item_fill`/`GimpFillOptions` — the same call GIMP's
  Fill Path actions make (`app/actions/items-commands.c`) — with a new
  facade-owned `GlimsPathFillSettings` (color, opacity, antialias; no
  fill rule or pattern), one undo step, selection and mask honored by
  the core, pixel locks (group-inherited) refused up front, unusable
  paths failed before any undo group opens. `path_to_vector_layer`
  makes a genuine vector layer via `gimp_vector_layer_new` +
  `gimp_image_add_layer`, as Paths > New Vector Layer does
  (`app/actions/paths-commands.c`), one undo step, the layer selected;
  before GIMP 3.2 it reports UNSUPPORTED without mutating. Ownership as
  the core keeps it: the layer's options reference the same path object
  while the image is open (`g_value_dup_object` in
  `app/path/gimpvectorlayeroptions.c`), so editing the path re-renders
  the layer; XCF stores the path once in the image's path list and the
  layer by tattoo (`PROP_VECTOR_LAYER` in `app/xcf/xcf-save.c`,
  re-associated in `app/xcf/xcf-load.c`), so the layer survives save
  and reopen as structured content. Conformance tests cover both; the
  four-engine run is left to the root checkout.
- 2026-11-08: the frontend slice for the two new facade calls, on this
  worktree branch. `EngineSession` gained typed `fillPath` and
  `toVectorLayer` wrappers and a `supportsVectorLayers` version
  capability (one shared parser with `supportsLinkLayers`).
  `ImageDocument.fillPath` queues on the input queue behind accepted
  input, passing the explicit current drawable (layer, editing mask or
  channel) and refusing groups, stale path rows, missing, pixel-locked,
  busy and closed states with an error instead of silent success; the
  native call revalidates path and target, is one undo step and clips to
  the selection. `ImageDocument.toVectorLayer` queues as a target
  command, so the completion's authoritative reload makes the
  engine-selected vector layer the active one; on a pre-3.2 engine it
  reports the honest 3.2 requirement and never degrades to a raster.
  The Paths palette has Fill Path and To Vector Layer buttons and menu
  items (membership-guarded, the vector item capability-gated, its
  tooltip stating the engine's default white-fill/black-stroke style,
  not the foreground color), as do Edit ▸ Fill Path and Edit ▸ To
  Vector Layer; the bundled manual documents both. No engine or facade
  change, no global native context mutation. Added scoped engine smoke
  cases (real pixels and fill color, selection clipping, one undo step,
  vector kind / selection / name, re-render after a path edit, XCF
  round trip and target reconcile, pre-3.2 UNSUPPORTED, missing, busy
  and closed guards) and pure unit tests for the capability parser, the
  palette command metadata and the fill settings. Checked on this
  branch: `swift build --build-tests` compiles only — no adapter
  rebuild, no library relink, no test or smoke run (the root checkout
  serializes desktop tests). Pending: the runtime run of the new smoke
  cases and `swift test` on all four engines in the root checkout.
- 2026-11-08: two more additive facade calls, engine side only, on
  `feat/vector-layer-style`. `vector_layer_style_get` /
  `vector_layer_style_set` read and change a genuine vector layer's
  native style (GIMP 3.2+; pre-3.2 UNSUPPORTED, nothing mutated) through
  the layer's own `GimpVectorLayerOptions` — new facade-owned
  `GlimsVectorStyle` / `GlimsVectorStyleChange` with own cap/join enums
  and a `properties` bitmask, `struct_size` guards, no raw GIMP types.
  First slice is solid paint only: enable flags, explicit RGBA fill and
  stroke colors, antialias, and stroke width plus cap/join/miter — exactly
  the fields XCF persists in `PROP_VECTOR_LAYER`; opacity, paint mode,
  unit, dash offset, feather and method are not persisted and are not
  exposed. A native pattern fill or stroke reports UNSUPPORTED on read
  and write, never converted (the setter never writes `custom-style`).
  The setter validates everything before mutating (busy/edit-ready
  first, then struct and finite RGBA / width / miter / enum guards),
  treats an all-equal change as a no-op with no undo, and otherwise
  applies the flagged fields as exactly one native undo group — manual
  `gimp_image_undo_group_start` + freeze notify + whole-options
  `gimp_image_undo_push_vector_layer(…, NULL)` snapshot + thaw +
  `gimp_image_undo_group_end` + refresh + flush, the same sequence as
  3.2.8+'s `gimp_vector_layer_set`, with `GIMP_UNDO_GROUP_VECTOR` where
  it exists and `GIMP_UNDO_GROUP_DRAWABLE_MOD` on 3.2.0. Pixel and
  group-inherited locks refuse with LOCKED; the layer's name, auto-rename
  policy and path association are untouched. The getter is a borrowed
  read (no refs taken). Conformance tests cover pixels changed, getter
  round trip, one undo/redo, no-op/invalid/locked no-history, name and
  path association with a live path edit, XCF save/reopen of style and
  name inside a group, and pre-3.2 UNSUPPORTED/unmutated. Checked on
  this branch: the adapter compiles against all four engine sets with a
  private `GLIMS_ADAPTER_ROOT`; the runtime conformance run is left to
  the root checkout.
- 2026-11-08: the frontend Vector Style sheet, on this worktree branch
  (`feat/vector-style-controls`). `EngineSession` gained typed
  `vectorLayerStyle` / `changeVectorLayerStyle` wrappers over the facade's
  `GlimsVectorStyle` / `GlimsVectorStyleChange`, with own cap/join enums
  and a `VectorStyleProperty` bitmask — stable facade values only, no GIMP
  types. `ImageDocument.changeVectorLayerStyle` queues the apply as
  counted input off the main thread behind accepted edits, treats an
  empty `properties` as a no-op that queues nothing, refuses a layer no
  longer cached as a genuine vector layer with targetChanged, and reports
  busy/closed and the engine's LOCKED/UNSUPPORTED answers; it never
  rasterizes. The new `VectorStyleForm` sheet (Layer ▸ Vector Style…,
  gated in menu validation on the cached layer kind plus the 3.2
  capability, old engines unsupported with no raster fallback) captures
  document, layer id and the read style per sheet — no shared state, no
  retarget. The style read runs off the main thread through the global
  EngineActivity after accepted input drains, with close/window/target
  guards; a native pattern style or a pre-3.2 engine reports UNSUPPORTED
  and the sheet closes with the reason. Controls are fill
  enable/color/antialias and stroke enable/color/antialias/width/cap/join/
  miter — no opacity, paint mode, dashes or pattern claims; validation
  mirrors the facade's exact finite/range flags and never reads a
  disabled section's fields; the color panel is cleaned up only for the
  sheet's own activation. Pure unit tests cover the parser, the guards,
  change building and the facade values; compiled engine smoke cases cover
  cancel, no-op, invalid input, real fill+stroke pixels, one undo step,
  XCF round trip, busy-after-open and a captured target deleted mid-sheet.
  Checked on this branch: `swift build` and `swift build --build-tests`
  compile only — no test or smoke run, no adapter rebuild, no library
  change (the root checkout runs the tests and the four-engine matrix).

## Open decisions

- Whether new generic controls go into Rigi immediately or incubate here
  first. Provisionally (2026-11-05): they incubate in
  `Sources/GlimsKit/RigiIncubator/` (generic, AppKit and RigiUI only) and
  move to Rigi, with its gallery, guidelines and tests, once they settle.
  `ClassicToolGrid` is the first. Decided by the user for the palette
  system: tabbed palette groups and docking go into Rigi directly and are
  adopted by Lucerne, Sion and Glims.
- Rigi currently mandates light Aqua; `design.md` proposes neutral gray and
  dark schemes for image work.
- Save and Export model (see `design.md`).
- Whether to keep compatibility with GIMP tool presets and `toolrc`.

## Engine update log

| Date | From | To | Adapter lines/files | Facade change | Agent-hours | Caught by | Notes |
|---|---|---|---|---|---|---|---|
| 2026-11-05 | GIMP_3_2_0 | GIMP_3_2_8 | 0 / 0 | none | not timed; build and tests about 3 min | no break | Found two host-environment gaps (`PATH`, `GI_TYPELIB_PATH`), fixed in the adapter, and the upstream typelib bug |
| 2026-11-05 | GIMP_3_2_8 | master `32c1ddaa2d` (3.3.1-dev) | 0 / 0 | none | not timed; build under 3 min | no break | babl and GEGL master |
| 2026-11-05 | GIMP_3_2_x | GIMP_3_0_8 | +15 / 1 | none | not timed; one edit round | `interface-diff.py` (all 3, before compiling), then the compiler | Reverse minor-release drill; environment: `mypaint-brushes1` port, typelib repair |
| 2026-11-05 | GIMP_3_2_8 (adapter with plug-in procedures) | master `32c1ddaa2d` | +5 / 1 | none | minutes | the compiler; `interface-diff.py` did not compare struct members then, and does now | `GimpProgressInterface.get_window_id` renamed `get_window_handle` (ed668b3e2d); 3.0.8 and 3.2.0 needed nothing |
| 2026-11-05 | master `32c1ddaa2d` | master `5374deeec1` | 0 / 0 | none | none (matrix run) | no break; `interface-diff.py` reports only the known rename | First run of `scripts/engine-matrix.sh` |

### Vector-layer load compatibility (2026-11-08)

The path-fill/vector slice exposed GIMP 3.2.0's XCF loader replacing an
explicit vector-layer name with its path name during conversion. The new
name-preservation assertion reproduced this after save/reopen. A scoped
adapter hook now observes native layer-container insertion while loading,
before the core refresh can rename the converted layer. It also covers
nested groups and imported layers; existing destination layers retain
their naming policy. Hooks disconnect on success and failure. The guard
is compiled only for 3.2.0; later engines restore the saved name themselves.
No upstream source, file metadata, dirty state or undo history changes.
Pinned and cross-version checks plus independent review are recorded in
the PR before merge. Frontend path controls remain a separate slice.

The same 3.2.0 loader guard now also retains, until loading finishes, every
source layer that carries the `gimp-vector-layer-data` qdata. GIMP 3.2.0's
`xcf-load.c` reads `vdata->modified` after `gimp_layer_from_layer()` has
unref'd and finalized the original plain layer that owns that data (3.2.8
snapshots the flag before converting), so the read was a use-after-free:
depending on heap contents it crashed the load or rasterized the reopened
vector layer, which made the style facade refuse it with NOT_FOUND. The
XCF bytes themselves were always correct — `PROP_VECTOR_LAYER` stores
width/miter as float32 in every 3.2.x, and a 3.2.0-written file reopens
with 12.3/5.2 intact once the source layer stays alive. Fractional
persistence is therefore a native guarantee on 3.2.0+ (float32 precision),
not an adapter addition.

Pinned runtime validation passes 867 native checks after one observed
sRGB input regression: plain GEGL RGBA setters interpreted the requested
midtone as linear and produced 188/137/225 instead of 128/64/191. Matching
sRGB setters now preserve the facade color. The empty native clipboard
brushes legitimately have transparent masks; the content fixture now
recognizes their exact internal identities, while file-backed brushes
still need content. FG/BG gradient selection now uses its exact builtin
identity instead of scanning a short buffer with the total catalog count.

A separate observed conformance-runner defect called engine functions after
rejecting a too-small API table. The runner now exits immediately. The
engine-free `scripts/test-conformance-abi.sh` reproduced the invalid call
before the guard and passes after it; CI runs this regression. Initial
independent and follow-up reviews found no important issue. Final native
runs pass 867 checks on 3.2.8/3.2.0/master and 834 on 3.0.8. The follow-up
review also identified the existing Clear color mismatch, now tracked in
a separate fix. Swift integration is recorded in the PR.

### Color Fill sheet (2026-11-08)

Edit > Fill opens a native sheet for foreground, background, white, black
or a custom color and opacity. It fills the selection, or the active
layer, mask or channel without one, through the existing counted target
queue. A sheet keeps its document and its own control bindings; cancelling
or refusing a busy/closed target produces no edit. Native lock failures
reach the caller. The custom color well releases its own panel interaction
without hiding an already open panel or another active well.

The original draft's shared binding target failed a two-document native
regression. Per-sheet retention passes that regression and ten isolated
pinned-engine checks, including pixels, selection clipping, undo, custom
color and busy/native refusals. Review found no important issues. The
expanded checks include independent background color and invalid opacity.
The integrated four-engine run passes 652 checks on 3.2.8, 3.2.0 and master,
649 on 3.0.8, before the Paths interface merge. After that integration,
305 unit tests and 689 interface checks on 3.2.8/3.2.0/master, 678 on
3.0.8 pass. An actual 50-percent Fill paints the document; cancelling
Custom after opening its color well closes the sheet's color panel.
The test app quit without saving. Pattern fill and resource selection
are a separate slice.

### Paths interface verification (2026-11-08)

The Paths palette and Edit menu expose Fill Path and To Vector Layer.
Fill uses the current layer, mask or saved channel; the Path options now
include opacity and antialias controls. Vector creation adopts the native
selected layer after reload and reports unsupported engines explicitly.
Independent review found no important issues. The integrated branch passes
305 unit tests and 677 interface checks on 3.2.8/3.2.0/master, 666 on 3.0.8.
The first mask test failure was a fixture retaining a selection after undo;
the corrected history reset verifies white pixels and the original history
position. Real control actions now verify 50-percent fill pixels and saved
channel isolation. Vector styling and multi-anchor editing remain later
work; initial vector creation uses the native context's defaults.

Pinned runtime validation now passes 780 native checks. Native sRGB style
getters were initially paired with a linear-RGB read; the new midtone
regression failed with 0.078/0.187/0.462 instead of 0.31/0.47/0.71 while
rendered bytes correctly stayed 79/120/181. Matching sRGB reads fix the
round trip. Separate observed no-op failures are fixed by normalizing
native opaque alpha and tolerating sub-micro-unit float color round trips.
The stroke-busy fixture now checks history before finishing its actual
stroke, which legitimately creates an undo entry. Cross-engine runtime
and independent review of these changes are pending.

### ICC assignment and conversion (2026-11-08)

Two additive native facade calls assign/discard an ICC profile or convert
pixels to a selected profile with a facade-owned rendering intent and explicit
black-point compensation. NULL selects the model/precision's builtin profile;
assignment discards embedded and hidden profiles. File paths are absolute,
nonempty UTF-8 and loaded on the engine thread. The core validates model
compatibility before opening its own undo group. Active strokes and previews
refuse the call, equal-profile operations add no history, and every owned
profile is released after the operation. No upstream edits or GTK calls.

The first pinned conformance run passes 841 checks, including changed midtone
interpretation on assignment (128/64 to 188/137), appearance preservation on
conversion, undo/redo, XCF round trip, RGB/gray compatibility, invalid files and
busy refusals. Fixtures are original deterministic LittleCMS profiles generated
by `scripts/make-icc-fixtures.py`. Final native runs pass 843 checks on
3.2.8/3.2.0/master and 810 on 3.0.8, plus Swift build and 305 unit tests.
Independent Beam review found no important issues. Its BPC observation was
verified: RGB/gray forwards the flag to the full native color transform;
indexed palette conversion ignores intent/BPC. A new regression reproduced
that unsupported conversion succeeding. The facade now refuses indexed
conversion before changing the palette profile, while compatible profile
assignment remains supported. Convert indexed images to RGB first. Swift
controls and display/proof transforms remain separate work.

Structured-layer safety: a new regression reproduced ordinary profile
conversion silently rasterizing editable text. The normal entry point now
returns REQUIRES_RASTERIZE without mutation when conversion would affect
editable text, vector or linked layers; equal-profile no-ops remain safe.
The separate image_convert_profile_rasterizing entry point records explicit
caller consent and keeps the native conversion/rasterization in one undo
step. Pinned checks verify text content and all three editable layer kinds
return on undo. Those checks also exposed the layer list reporting native
link/vector classes after rasterization; it now reports current editability,
consistent with text layers. Full cross-engine rechecks and UI consent
coverage follow before merge.

### Color profile controls and consent (2026-11-08)

Image > Color Profile now provides Assign and Convert sheets with a built-in
profile or an ICC file, rendering intent and black-point compensation.
The per-sheet captured document and settings feed counted exclusive work;
file loading stays off the main thread. Both form and typed facade reject
embedded NUL paths before CString conversion. An observed failing path test
passes after that validation.

Conversion first preserves editable layers. A native rasterization refusal
opens a separate Rasterize and Convert confirmation after the engine gate
drains. Cancel preserves the image; approval rechecks admission and performs
conversion/rasterization as one undoable edit. The pinned interface run
passes 758 checks including Cancel, approval, undo restoration, busy-engine
refusal, direct facade NUL validation and late-close suppression while
accepted input drains. All 324 unit tests pass. Independent Beam review of
the consent delta found no important issues.

In a real window the ICC source enabled its path and Choose controls;
cancelling the file picker returned to the form. Assignment embedded the
fixture. Conversion of newly typed text asked for rasterization; Cancel
kept text editable, approval converted, and Undo restored the text layer
and its embedded source profile. The test app quit with Don't Save and left
no dialog. Cross-engine interface validation follows before merge.

### Clear color and mutation readiness (2026-11-08)

Three regressions reproduced on the previous implementation: an opaque RGB
layer cleared with a midtone background produced 188/137/225 instead of
sRGB 128/64/191, and Clear proceeded during a native filter preview or
active stroke. Clear now uses the shared edit-ready guard and an explicit
sRGB color setter. All four native runs pass: 830 checks on GIMP 3.2.8,
3.2.0 and master, and 797 on 3.0.8, including selection clipping,
undo/redo, the RGB sample and both busy refusals. Independent source
review found no important issues.

### Pattern fill backend (2026-11-08)

`fill_pattern` is the facade's one additive footer API: it fills the
selected drawable (active layer, editing mask or selected channel, the
same target `fill` uses) with a pattern handle, through
`gimp_drawable_edit_fill` for Selection/full drawable and
`gimp_drawable_bucket_fill` for SimilarColors, exactly as `glims_fill`
does for solid color. `GlimsPatternFillSettings` carries struct_size,
mode, opacity, threshold, sample_merged and antialias — no color fields.
The pattern handle is revalidated on every call by a narrow
`lookup_pattern` in resource.c on top of the generic resource admission
(full UInt64 range check before any native narrowing, kind table,
membership in this engine's own factory container); a brush or gradient
handle is NOT_FOUND, a malformed or high-bit one INVALID_ARGUMENT. The
pattern lives on a private per-call context whose PATTERN property bit is
defined before the pattern is set, so the shared user context is never
touched; options and context are released on every path. Inputs are
validated (finite seed, mode, opacity/threshold in 0...1 — refused, not
clamped) and `glims_edit_ready` gates the mutation, so an active stroke,
filter preview or plug-in refuses BUSY with no pixel or undo change. An
alpha lock alone does not refuse, matching the painting policy; a pixel
lock does (LOCKED). One native undo step per fill. Observed native
behavior: opacity 0 succeeds, records the undo step and changes no
pixels; Select None means no selection, so the whole drawable is filled, while a selection disjoint
from the drawable succeeds as a no-op with no undo step and no pixel change. An alpha lock is not a
refusal: the engine enforces it through the drawable's active components, so on an opaque layer the
fill changes color but not alpha.
Conformance compares the fill against a `resource_thumbnail` of a stock
opaque pattern at its native size below 512, tiled across the image, and
covers selection clipping, layer offset, SimilarColors, undo/redo,
mask/channel routing, locks, invalid handles/settings and the three BUSY
states. Swift adds `PatternFillSettings` and `EngineSession.fillPattern`
plus a queued `ImageDocument.fillPattern(_:at:_:)` that resolves the
persisted `ResourceIdentity` on the input queue; EngineSmoke exercises
that path. No chooser UI and no gradient work yet.

Final ICC/native compatibility validation: 894 conformance checks pass on
3.2.8, 3.2.0 and master; 834 pass on 3.0.8. The added older-engine fixture
now creates a valid path before expecting UNSUPPORTED; its earlier invented
path id correctly returned NOT_FOUND and was a test error.

New save/reopen and Open as Layers regressions reproduced three 3.2.0
loader defects: a freed rasterization flag, overwriting edited rasterized
vector pixels, and imported vector paths retaining a dead loading image.
The exact-version load guard retains source metadata, restores verified
modified buffers at native load completion before copying, and converts
imported paths in place into their destination, as later native releases
do. One undo/redo preserves imported pixels; resaving retains editable
geometry and raster edits. No upstream source is changed. The image-lifetime
criticals are gone; two existing startup g_file_test(NULL) diagnostics remain.

The initial style interface run passed 322 pure/unit tests but failed nine
native interface assertions: the Swift getter left the caller's output
struct_size at zero, so the facade correctly refused every style snapshot.
The getter now initializes its output size before the call. A full native
interface rerun follows; compilation alone did not establish this workflow.

After integration with the merged ICC/vector loader fixes, resource previews
pass 941 native checks on 3.2.8, 3.2.0 and master, and 881 on 3.0.8. The
Swift build, 308 unit tests, complete pinned interface smoke and older-table
ABI refusal regression pass. Native preview and Swift ownership reviews
found no important issues. Native context colors remain opaque; resource
alpha is preserved in the straight-alpha output.

Final integrated native vector style runs pass 979 checks on 3.2.8, 3.2.0
and master, and 884 on 3.0.8. The preserved ICC/load guard fixes keep imported
paths in their destination and retain raster edits; style changes keep
fractional float32 XCF width/miter values and avoid empty undo on reapplying
the displayed values. Native style colors stay opaque sRGB. The sheet is a
separate interface slice, with independent wrapper/runtime verification.

The completed style interface passes 322 unit tests and 790/764/790/790
interface checks across the four engines, including actual fill/outline
pixels, undo and XCF persistence. The remaining three refusal failures were
fixture errors: window construction replaced the test error callback, and
the invalid-width case had its stroke disabled. Correcting the fixture
makes invalid input, busy-engine and removed-target checks pass. Follow-up
independent review found no important issues.


Brush chooser verification and fixes: a native AppKit row regression first
failed because fresh table cells had no text field or image view. The cells
now render names and previews, and the test passes. The full catalog is
searchable without a 512-row truncation; native thumbnails load lazily in
batches of 32, with failed attempts cached for the generation.

A focused real-panel regression reproduced Reset and choosing Default
leaving a stale Missing label. Both now pass: presentation data is tied to
the exact persistent identity, Default clears it, and an unchanged missing
choice preserves its warning. A late preview cannot describe a different
choice. All 326 unit tests pass. Two new lazy-queue test fixtures initially
omitted the required begin/complete lifecycle; correcting those fixtures
preserved the queue's no-overlap contract. GLIMS_SMOKE_CASE=brush-chooser
selects this bounded interface scenario; ordinary engine smoke still runs
all scenarios. Full interface/matrix and on-screen chooser checks follow.

The real-panel browse scenario confirms lazy thumbnails preserve the scroll
position. It then reproduced a missing Tool Options preview after choosing a
rendered brush. Presentation revisions now notify the palette when preview
data changes even if the identity stays the same; that regression passes.
Preview images retain their native aspect ratio. The focused scenario also
drains its close work before stopping the native engine.

Follow-up shutdown review found that isBusy does not cover unlabelled
image-close work on the activity queue. The focused scenario now awaits
closeImageWhenDrained's completion in its own cleanup and confirms the image
is gone before engine shutdown; the completed callback regression passes.
The thumbnail-batch fixture excludes the Default row when counting brushes.

### Fill pattern source (2026-11-08)

Interface slice on `feat/pattern-chooser`, frontend only: Edit ▸ Fill…
appends Pattern (index 5) to the fill source popup and embeds a
searchable one-column list of the engine's FULL pattern catalog —
`resources(.pattern)` plus `resource_identifiers` read off the main
thread through the exclusive `EngineActivity` gate — with lazy 32 px
`resourceThumbnail` renders in bounded batches as rows appear. The
picker is owned by the sheet's sync object for exactly the sheet's
lifetime; cancel or close invalidates its generation so late deliveries
are dropped, and it opens no child panel or nested sheet. Only the
persistent `ResourceIdentity` is committed (`PatternFillStore`,
UserDefaults JSON) and `ImageDocument.fillPattern` re-resolves it on the
input queue at execution, so a removed pattern is reported missing and
refused — no default substitution. Existing fill choices 0-4 and their
behavior are unchanged. Pure `PatternChooserModel`/`PatternThumbnailQueue`/
`PatternFillStore` unit checks cover search, selection, missing-identity,
generation drops, queue batching and persistence. The initial model-only
scenario was replaced by actual sheet checks, wired into the smoke run.
Those checks cover names/previews, full search, fill pixels and undo,
persisted selection, source toggling, missing-resource refusal and cleanup.

### Selected-resource gradients (2026-11-08)

Engine and session slices of the resource gradient backend on
`feat/resource-gradients`, one additive footer slot appended after
the vector style calls: `gradient_resource(engine, image, gradient, from,
to, settings, error)`. API version 1 and every existing layout and
signature are unchanged; `gradient()` still draws only the built-in
FG-to-BG RGB ramp. `GlimsResourceGradientSettings` carries
`struct_size`, a `GlimsGradientShape`, opaque `foreground`/`background`
`GlimsColor`s, `opacity`, `reverse` and a facade-owned
`GlimsGradientBlendSpace` (RGB perceptual, RGB linear, CIE Lab) mapped
to the named `GIMP_GRADIENT_BLEND_*` constants inside the adapter; no
native enum value crosses the facade. The full `GlimsResourceID`
passes through a typed `GlimsGradientResourceArgs` marshal, and
`glims_lookup_gradient` in `resource.c` admits the handle through the
existing fresh range/kind/current-engine-factory checks before the
native id narrows — a wrong-kind handle is NOT_FOUND, never a fallback.

`gimp_drawable_gradient` returns void, so the adapter validates
everything before the mutation: the settings struct, known enums,
finite noncoincident endpoints, finite 0 ... 1 color components with
alpha exactly 1 (the engine's FG/BG context is opaque; transparency
comes from the resource's own stop types), a finite 0 ... 1 opacity,
the handle's admission, `glims_edit_ready` (stroke, filter preview and
plug-in BUSY) and the shared paintable-drawable check with its pixel
locks — alpha-locked layers are not blanket-rejected. The call shares
the existing routing: the selected layer, its mask while mask editing
is on, or a selected channel; the selection clips; endpoints are image
coordinates shifted by the drawable's offset; one "Gradient" undo step.
A per-call `GimpContext` pins explicit sRGB FG/BG colors before the
draw — nothing shared is read or changed and the resource's segments
are never mutated. Native edge cases are documented, not papered over:
a selection disjoint from the drawable draws nothing and pushes no
undo (`gimp_item_mask_intersect` fails and the native function returns
early), while opacity 0 still renders and pushes an undo step.

Session side: `EngineSession.GradientBlendSpace`,
`ResourceGradientSettings` and a checked `gradient(image:resource:from:to:settings:)`
wrapper over the slot, plus `ImageDocument.gradientResource(_:from:to:settings:)`
which takes a persistent `ResourceIdentity`, resolves it inside the
queued paint-target job and captures settings and endpoints by value —
no synchronous native call on the main thread, no persisted handles.

Facade-only conformance adds `test_resource_gradient`: the dynamic
builtin resolved by its `gimp-gradient-fg-bg-rgb` internal identity,
black-to-white endpoint/midpoint oracles derived from the native
blending rules (perceptual ~128 and Lab ~119 at the pixel
center t = 0.505), reverse, a second stock gradient rendering different
stops, opacity, selection clipping, the layer-offset coordinate space,
mask and channel routing, pixel/alpha locks, invalid/stale/high-bit/
wrong-kind handles, every settings refusal, group targets, and BUSY
under an open stroke and a filter preview with unchanged pixels and
history.

Linear-light resource blending is explicitly UNSUPPORTED on the supported
engines: their gradient sampler overwrites linear endpoint components
through switch fallthrough, and later readback differs between tags.
A version-adjusted midpoint oracle would have accepted incorrect output;
the regression instead requires refusal with pixels and undo unchanged.
Perceptual RGB and Lab rendering remain available. No upstream source was
modified.

### Native image guides (2026-11-08)

Backend-and-cache slice on `feat/native-guides`: no canvas, ruler, menu
or chooser UI. Three append-only facade slots follow the canonical
footer (`gradient_resource`): `image_guides` (rows/capacity/count),
`guide_put` (`id` 0 creates at `orientation`/`position`, nonzero moves
an existing ordinary guide) and `guide_remove`. Own
`GlimsGuideOrientation` (HORIZONTAL=1, VERTICAL=2) mapped to
`GIMP_ORIENTATION_HORIZONTAL`/`VERTICAL`, own int32 `GlimsGuideID` (the
engine's GimpAuxItem id) and `GlimsGuideInfo`; no native enum value or
pointer crosses the facade. Verified identical across the pinned
GIMP_3_2_8 and GIMP_3_0_8 trees: `gimp_image_add_hguide`/`add_vguide`/
`move_guide`/`remove_guide`/`get_guides`/`get_guide`,
`gimp_guide_get_orientation`/`get_position`/`is_custom`,
`gimp_aux_item_get_id`, and the `guide-added`/`guide-removed`/
`guide-moved` signals, each with one `GIMP_TYPE_GUIDE` parameter (also
asserted by `check_engine_interface`).

Every put/remove validates struct, orientation, id and position
(0 ... image height horizontal, 0 ... image width vertical) plus
`glims_edit_ready` before any mutation — stroke, filter session and
plug-in report BUSY. A nonzero `id` must resolve through
`gimp_image_get_guide` to a non-custom guide of this image: stale,
foreign, custom tool-owned and never-issued ids are NOT_FOUND, and a
put whose orientation differs from the guide's own is refused rather
than reoriented. A same-position move is a no-op that pushes no undo.
Each applied change is exactly one native undo step ("Add
Horizontal/Vertical Guide", "Move Guide", "Remove Guide"); undo/redo
restore position and orientation through the same guide object and id.
Guide edits are metadata: pixels and the selection are untouched and
pixel locks do not refuse. `image_guides` lists ordinary guides only —
`gimp_guide_is_custom` rows are skipped — and is a plain read.
A new `GLIMS_EVENT_GUIDES` (= 9) fires for all three signals on every
adopted image, disconnected in `open_image_free`; it carries only the
image id, never the native pointer.

Session side: `EngineSession.GuideOrientation`, `Guide`, `guides(_:)`,
`putGuide(_:image:)`, `removeGuide(_:image:)` and a `guidesChanged`
event; `ImageDocument` caches `guides` in `reload`, refreshes the list
alone through the deferred `PendingRefresh.guides` kind (one re-read
per busy period, never synchronously in an event or menu validation)
and queues `addGuide`/`moveGuide`/`removeGuide` edits on the input
queue. The C facade gained an event kind, so engine-adapter and app
must be rebuilt together — an older app simply never receives kind 9.

Facade-only conformance adds `test_guides`: both axes and boundary
positions; create/move/remove with undo/redo; the same-position no-op;
rendered pixels and selection bounds byte-identical across guide
changes; XCF save/reopen compared by (orientation, position) sets
rather than runtime ids; invalid orientation/position/id/struct
refusals; unknown, foreign, stale and closed-image NOT_FOUND; BUSY
under an open stroke with reads still allowed; and GUIDES event
delivery. `swift build` and `swift build --build-tests` pass. With the
shared-lock grant, private-adapter-root conformance runs pass on both
pinned engines (`build-adapter.sh --test` with
`GLIMS_ADAPTER_ROOT=$PWD/.build/engine-adapters`): all checks green on
GIMP_3_2_8 and GIMP_3_0_8, including the full `test_guides` block. The
first 3.2.8 run caught one test-expectation error — undo of a removal
restores the position the guide was removed at (65), not an earlier
one — fixed in the test, not the adapter. Custom-guide exclusion has
no facade-reachable creation path, so it is covered by the `is_custom`
filter in code and code review only.

Integration validation after the layer-boundary commands merged: native
conformance passes 1,212 / 1,117 / 1,212 / 1,212 checks on GIMP 3.2.8,
3.0.8, 3.2.0 and master. The compiled `native-guides` interface scenario
passes ten checks on each engine: queued creation/move/removal, undo,
unchanged rendered pixels, busy refusal, deferred cache refresh while
the input worker is occupied, and close completion. All 369 unit tests
passed before the unrelated layer-boundary integration; the combined
Guides interface will receive its own unit and window checks. The
independent backend review found no important issues.

### Native image grid (2026-11-08)

Backend-and-cache slice on `feat/native-grid`: no canvas overlay, grid
dialog or snap support. Two append-only facade slots follow the
canonical footer (`image_convert_indexed`): `image_grid` (a read of
the current state into a size-versioned `GlimsGrid`) and
`image_set_grid`. Own `GlimsGridStyle` (DOTS=1, INTERSECTIONS=2,
ON_OFF_DASH=3, DOUBLE_DASH=4, SOLID=5) mapped by name to
`GIMP_GRID_DOTS`/`GIMP_GRID_INTERSECTIONS`/`GIMP_GRID_ON_OFF_DASH`/
`GIMP_GRID_DOUBLE_DASH`/`GIMP_GRID_SOLID`
(libgimpbase/gimpbaseenums.h:522-530, identical in all four trees); no
native enum value, struct layout or pointer crosses the facade.
`GlimsGrid` carries `struct_size`, the style, `spacing_x/y`,
`offset_x/y` and `foreground`/`background` as `GlimsColor` (sRGB 0...1,
alpha included).

Verified identical across GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8 and
master: `gimp_image_get_grid`/`gimp_image_set_grid(image, grid, TRUE)`
(app/core/gimpimage-grid.h/.c — set compares with
`gimp_config_is_equal_to`, returns with no undo when equal, otherwise
pushes exactly one "Grid" undo via `gimp_image_undo_push_image_grid`
with `GIMP_DIRTY_IMAGE_META` and syncs), the getters
`gimp_grid_get_style`/`get_fgcolor`/`get_bgcolor`/`get_spacing`/
`get_offset` (app/core/gimpgrid.h), `gimp_config_duplicate` and
`gimp_config_is_equal_to` (libgimpconfig/gimpconfig-iface.h:124-125),
and the property names and bounds in `gimp_grid_class_init`
(app/core/gimpgrid.c): `style` (enum, default SOLID), `fgcolor`/
`bgcolor` (color, has alpha, defaults black/white), `xspacing`/
`yspacing` (double, 0.0 ... GIMP_MAX_IMAGE_SIZE, default 10.0),
`spacing-unit`, `xoffset`/`yoffset` (double, -GIMP_MAX_IMAGE_SIZE ...
GIMP_MAX_IMAGE_SIZE, default 0.0), `offset-unit`, with
GIMP_MAX_IMAGE_SIZE = 524288 in all four trees
(libgimpbase/gimplimits.h:57). `check_engine_interface` now asserts
all nine property names and types on `GIMP_TYPE_GRID` at start-up.
XCF persists the grid as a parasite (app/xcf/xcf-save.c:559-561 via
`gimp_grid_to_parasite`, xcf-load.c:784-789 via
`gimp_grid_from_parasite`).

The adapter (Engine/grid.c) clones the image's borrowed grid with
`gimp_config_duplicate`, so the unexposed units are retained, and
validates the whole request before any `g_object_set` — so the native
clamps can neither hide invalid input nor leave a partial mutation:
INVALID_ARGUMENT for a missing/short struct, an unknown style, a
non-finite spacing/offset, a spacing that is zero, negative or outside
the native bounds, an offset outside the native signed range, or a
non-finite/out-of-range color component (alpha included). The bounds
are read from the engine's own `GParamSpecDouble` at call time, not
hard-coded. Colors are set on freshly created `GeglColor` objects
through `gegl_color_set_rgba_with_space(..., NULL)` — a NULL space is
non-linear sRGB (gegl/gegl/property-types/gegl-color.h) — so the
engine's shared default color objects are never mutated; the native
color setter duplicates the passed object into the grid
(gimpgrid.c, PROP_FGCOLOR/PROP_BGCOLOR), and the adapter releases its
own references right after `g_object_set`. Readback borrows the grid
and its colors and reads them with `gegl_color_get_rgba_with_space(...,
NULL)`. An identical native config is detected with
`gimp_config_is_equal_to` before the readiness gate (like guide_put's
same-position no-op) and returns OK with no undo; a changed config
goes through `gimp_image_set_grid(image, clone, TRUE)` — exactly one
native undo step, pixels and selection untouched. Mutations are
guarded by `glims_edit_ready` (BUSY during a stroke, a filter session
or a plug-in); the read is allowed at any time. No new event kind: the
native undo push emits "undo-event", forwarded as the existing
GLIMS_EVENT_UNDO_CHANGED, and ImageDocument's `.state` refresh runs
`reload`, which re-reads the grid.

Session side: `EngineSession.GridStyle`, `Grid`, `grid(_:)` and
`setGrid(_:image:)` over the facade types (struct_size set, colors via
the existing sRGB `NSColor` conversion, no synchronous native call
outside the queued job); `ImageDocument` caches `grid` in `reload` and
queues `setGrid` edits through `run` on the input queue.

Facade-only conformance adds `test_grid`: the native default readback
(solid, black/white, 10/10, 0/0); all five styles with numeric, color
and alpha readback, each exactly one undo; undo/redo restoring the
previous grid; the identical no-op; rendered pixels, selection bounds,
dirty flag and undo depth unchanged across every refusal (missing/short
struct, unknown styles, zero/negative/NaN/infinite/over-maximum
spacings, out-of-range and non-finite offsets, out-of-range and invalid
alpha colors); the native range edges (±524288) accepted; BUSY under
an open stroke and an open filter preview with reads still allowed;
XCF save/reopen preserving the whole config; NOT_FOUND for unknown and
closed images. Comparisons are against the values set and the engine
defaults from source, not against the adapter's storage. There is no
`source_id` anywhere in this facade (grep over the header, adapter and
session finds none) — the concept is not invented here; the nearest
existing notion is `layer_source_info`'s structured-source report,
which the grid slice does not use.

Checks actually run on this branch: `swift build -j 2` and
`swift build -j 2 --build-tests` pass; `clang -fsyntax-only` with the
existing adapter flags (from `_engine/adapter/<ref>/compile.rsp`,
paths rewritten to this worktree) is clean for `Engine/grid.c` and
`Engine/engine.c` on both GIMP_3_2_8 and GIMP_3_0_8, for
`Engine/grid.c` also under `-Wall -Wextra -Werror`, and
`Engine/tests/engine-tests.c` under `-std=c11 -O2 -Wall -Wextra
-Werror -fsyntax-only` plus `abi.c`. NOT run here (the shared
engine/adapter lock belongs to the root job): `build-adapter.sh
--test` conformance, any adapter compile/link, `swift test`, the app's
`--engine-smoke-test`, the engine matrix and any on-screen check —
no runtime behavior of the new slots was executed in this slice.

### Grid controls (2026-11-08)

Interface slice on `feat/grid-controls`, frontend only over the cached
`ImageDocument.grid` / queued `ImageDocument.setGrid` — no native call
from the UI or menu validation, no C/header change. Three pieces:

- **Image ▸ Configure Grid…** (`GridSheetController`, one per window,
  retained by its `DocumentWindowController` like the guides sheet). The
  sheet captures its document and seeds a local draft (spacing X/Y,
  offset X/Y, style popup with all five native styles, foreground and
  background color wells) from the cached grid. All edits stay local
  until Apply commits the field edits, parses strictly, and performs
  ONE queued atomic `setGrid` (one undo step when changed; an identical
  grid is a no-op). Cancel and window close write nothing. Parsing is
  whole-field `Double` plus finiteness; spacings must additionally be
  strictly positive; offsets only finite. The native range bounds are
  deliberately not checked client-side — the adapter refuses them and
  the refusal is fanned out through the document's existing `onError`
  to the sheet's message label and the status bar, never clamped, and
  the draft is preserved so the values can be corrected. A reload
  re-seeds the draft only while it is clean (Undo/Redo and a
  successful Apply's refresh land in the sheet; a dirty draft is
  never clobbered). Color wells follow the Vector Style conventions:
  the sheet records whether the shared color panel was already visible
  at open and, on invalidate, closes only a panel its own wells
  activated, deactivating both. Late close callbacks are discarded
  (`isInvalidated` + identity-checked `beginSheet` completion). Menu
  validation allows the item whenever the document is not closing and
  no other sheet is attached — grid configuration is image metadata,
  so a selected channel does not restrict it.
- **View ▸ Show Grid** (`GridViewState`, cached per window, default
  OFF): the checkmark reads the cached flag and the toggle stays
  available while the engine is busy. It is pure view state — no image
  pixels, file, dirty, history, selection, export or print mutation
  (print draws an immutable `PrintSnapshot`, never the canvas).
- **Canvas overlay** (`EngineCanvasView.drawGridOverlay`, drawn between
  the image tiles and the selection/path/guide overlays) over the pure,
  bounded `GridOverlayPlanner`: the visible rect is clipped to the
  image FIRST, line positions come from closed-form `ceil`/`floor` of
  `offset + k*spacing` inside the visible range (never a walk over the
  whole image), with finite/overflow guards and fixed caps (4096 lines
  per axis, 65536 intersections — over-cap axes/dot products are
  suppressed as illegible, reported via plan flags). An axis whose
  scaled spacing drops below 2 device pixels is suppressed, matching
  the engine's own threshold (gimpcanvasgrid.c, bug #599267); Dots and
  Intersections need both axes and draw only at intersections (1-device-
  px mark / crosshair with the engine's CROSSHAIR reach); the three
  line styles draw visible-length segments per legible axis. Foreground
  colors everything; the background color is used only by Double Dash
  as the interleaved second dash. Dash phase is anchored to image
  coordinates (`fmod(from * viewScale, period)`), so scrolled segments
  keep the pattern glued to the image. Invalid cached metadata (NaN,
  non-positive spacing) is suppressed, never clamped. Image
  coordinates map straight to view points, so zoom, backing scale,
  scroll and the flipped canvas all stay aligned.

Tests: `GridControlsTests` covers the strict parser, draft validation
(including that over-maximum spacings pass to the engine rather than
being clamped), the toggle policy, the five style names, and planner
oracles — modular line positions, offset non-clamping, visible-rect
clipping, the 2-device-px legibility boundary, per-axis suppression,
dot Cartesian products, both caps, invalid-input guards and the
dash-phase anchoring invariant against a closed-form oracle.
`GLIMS_SMOKE_CASE=grid-controls` (and the default smoke run) drives
`exerciseGridControls`: real sheet Apply/Cancel/invalid/native-refusal
paths, view-bitmap toggle and style differences with native pixel
isolation, undo/redo cache refresh, two-document ownership, busy and
late-close paths, all controls reached by accessibility label; waits
are predicate-based with queue gates released on every path.

Checks actually run on this branch: `swift build -j 2` and
`swift build -j 2 --build-tests` pass. NOT run here (owned by the root
job): `swift test`, `--smoke-test`, `--engine-smoke-test` (including
`GLIMS_SMOKE_CASE=grid-controls`), the adapter conformance tests and any
native/engine command — no runtime behavior of the new UI was executed


### Stroke selection backend (2026-11-08)

Backend slice on `feat/stroke-selection`: no UI and no action
recording. One append-only facade footer slot after `image_set_grid`
(slot 117): `selection_stroke(engine, image, drawable, brush,
settings, error)`, API version 1 unchanged. The signature follows
`path_stroke`'s target convention and `stroke_begin_with_brush_resource`'s
resource convention: `drawable` 0 is the image's selected layer and an
explicit id must be an attached layer of this image (a group, a layer
mask or a channel is refused with FAILED, exactly as `path_stroke`
refuses them); `brush` is a full-width `GlimsResourceID` — 0 keeps
`stroke_begin`'s established convention of inheriting the shared user
context's current brush, while a non-zero handle goes through
`glims_lookup_brush`'s strict admission (INVALID_ARGUMENT for
out-of-native-range or wrong-kind handles, NOT_FOUND for stale ones)
with no silent default replacement; `settings` is the existing
`GlimsBrushSettings`, no new struct and no native enum crosses the
facade.

The adapter (Engine/select.c, `glims_selection_stroke`) drives the GUI-
free core path, not a hand-rendered bitmap: `gimp_item_stroke()` on the
image's mask (`GIMP_ITEM (gimp_image_get_mask (image))`) with
`push_undo` TRUE, exactly as the PDB's `drawable-edit-stroke-selection`
invoker does (app/pdb/drawable-edit-cmds.c). Verified identical in all
four engine trees (GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8, master):
`GimpSelection`'s stroke vfunc (app/core/gimpselection.c) fails with
"There is no selection to stroke." when `gimp_channel_boundary` finds
no boundary, then suspends the selection, calls `GimpChannel`'s stroke
vfunc and resumes — so the stroke straddles the boundary (pixels on
both sides change), the selection mask is never modified, and
`gimp_item_stroke`'s own undo group makes the whole call exactly one
"Stroke Selection" undo step. The adapter pre-checks the same boundary
so an empty selection fails with FAILED before the native undo group
opens. The stroke is painted through the stroke options' paint method
(`GIMP_STROKE_PAINT_METHOD`, `gimp_paint_core_stroke_boundary`): a
temporary context inheriting the user context carries the tool's paint
info — defined locally (`gimp_context_define_property` before
`gimp_context_set_paint_info`, so the setter cannot walk up to the
shared user context) — and the tool's own paint options are built by
paint.c's `glims_make_paint_options`/`glims_set_tool_options` (now shared
with `stroke_begin_common`) and passed explicitly, as the PDB invoker
does, with the selected brush pinned locally exactly as
`stroke_begin_with_brush_resource` pins it. All temporary context,
options and paint-options references are released on every path.
Readiness is `glims_edit_ready` (BUSY during a stroke, a filter
session or a plug-in); locks are `glims_check_item_locks` with
`GLIMS_LOCK_PIXELS`, plus `GLIMS_LOCK_ALPHA` for the eraser on a layer
with alpha — the same policy as `stroke_begin`. The whole request
(settings, brush handle, target, locks, empty selection) is validated
before any mutation, so refusals change no pixels and push no undo.
No new event kind: the usual UNDO_CHANGED follows a success.

Session side: `EngineSession.strokeSelection(image:drawable:brush:)`
over the slot, reusing the captured `EngineSession.Brush` settings (via
the new shared `nativeBrush` helper, also used by `beginStroke`) and the
existing `ResourceIdentity` resolve — a nil resource passes 0 (the
documented inherit convention) and a non-nil one is resolved on the
worker with `resolveResource(_:kind: .brush)`; session ids are never
stored. `ImageDocument.strokeSelection(_:)` queues the call as counted
input on the input queue behind already accepted input, capturing the
brush settings, the resource identity and the target drawable id by
value, requiring the paint target inside the job and reporting errors
through the usual path; mask/channel/group targets are refused up
front like `strokePath`, and no synchronous native call runs on the
main thread.

Facade-only conformance adds `test_selection_stroke` (engine-tests.c,
no engine headers): rectangular and elliptical selections; the boundary
stroke visible on both sides of the edge while the interior and the
far outside stay untouched; the selection's bounds AND outline
segments (the shape invariant, not just pixels) unchanged across the
stroke and across undo/redo; exact pixel undo/redo by full-render
compare; an empty selection failing with an error before any undo;
invalid/stale/foreign image and drawable ids; out-of-range, stale and
wrong-kind brush handles; NULL/short settings, zero/NaN size, unknown
tool, NaN opacity/color; group, mask and channel targets refused like
path_stroke's; pixel lock LOCKED with unchanged pixels and history and
the eraser on an alpha-locked alpha layer LOCKED; BUSY under an open
stroke and an open filter session. Not covered by this test: a
polygon-shaped selection (same boundary machinery as the ellipse), a
clone/heal source drawable, XCF round trips of the stroke's result
(covered by the existing undo/redo checks), and any on-screen result.

Checks actually run on this branch: `swift build -j 2` and
`swift build -j 2 --build-tests` pass; `clang -fsyntax-only` with the
existing adapter flags (from `_engine/adapter/<ref>/compile.rsp`,
paths rewritten to this worktree, plus the build's
`-I Engine -I Sources/CGlimsEngine/include` and the two
`GLIMS_ENGINE_*_PATH` defines from `scripts/build-adapter.sh`) is clean
for `Engine/select.c`, `Engine/paint.c` and `Engine/engine.c` on all
four refs (GIMP_3_2_8, GIMP_3_2_0, GIMP_3_0_8, master), and
`Engine/select.c`/`Engine/paint.c` are also clean under the added
`-Wextra -Werror` (the only -Wextra diagnostic in paint.c is
pre-existing in untouched `to_coords`); `Engine/tests/engine-tests.c`
and `Sources/CGlimsEngine/abi.c` pass `-std=c11 -O2 -Wall -Wextra
-Werror -fsyntax-only -I Sources/CGlimsEngine/include`. NOT run here
(the shared engine/adapter lock belongs to the root fixture job):
`build-adapter.sh --test` conformance, any adapter compile/link,
`swift test`, the app's `--engine-smoke-test`, the engine matrix and
any on-screen check — no runtime behavior of the new slot was executed

in this slice.

### Stroke selection controls (2026-11-08)

Interface slice on `feat/stroke-selection-controls`, frontend only: no
facade, C, header or dependency change. Edit ▸ Stroke Selection… (listed
in docs/design.md's Edit menu since the plan) now exists:
`MainMenu` wires it to `DocumentWindowController.strokeSelection(_:)`,
which opens a per-document sheet
(`StrokeSelectionSheetController`, owned by the window controller exactly
like the guides sheet — two documents keep independent sheets and
controllers, and the document's existing onError/onStateChange/
onWillChangeLayers/windowWillClose callbacks fan out to it alongside the
guides sheet instead of being replaced). The sheet captures the document
and each offered paint tool's brush — resource identity, size, opacity,
color — BY VALUE at open from `ToolState.brush(for:)`; opening, editing
or cancelling the sheet never mutates the global ToolState, the brush
row shows the captured identity's real name ("Default", or the chooser's
verified "Missing: …" marker — never silently replaced, never a session
handle), and an accepted stroke carries the captured
`ResourceIdentity`, resolved on the engine worker as before. Local
fields are the paint tool (paintbrush/pencil/eraser), size, opacity and
a color well owned by the sheet (deactivated and ordered out on close
only when the sheet opened it). Validation is strict finite whole-string
parsing with inline reasons (`StrokeSelectionFormValidation`): junk,
whitespace, NaN/inf and out-of-range size (0 < s ≤ 500) or opacity
(0…100 %) keep the sheet open with the reason; Cancel mutates nothing.
Accept is one-shot: a reentry flag goes up before anything that can call
back into the UI (ending field edits, ending pending input), so a
duplicate/reentrant accept is blocked before it can mutate; on success
exactly one counted input job is enqueued through
`ImageDocument.strokeSelection` and the sheet closes. Native errors use
the document's existing onError path.

Gates read only cached state — no synchronous native RPC from menu
validation, sheet open or accept (`ImageDocument.strokeSelectionRefusal`
plus `validateMenuItem`, the refusal as tool tip): busy/plug-in, filter
preview, closing/saving/clipboard, empty selection (cached
`selectionOutline`), mask/channel/group targets, effective pixel locks,
and an editable structured source from the cached `layerSources`
(`hasSource && !isRasterized`) which refuses with a rasterize-first
explanation — the rasterize UI is a separate pending change and is not
adopted here.

Queue-defect fix in the same slice: `ImageDocument.strokeSelection` now
ends pending user edits and an active stroke (`endPendingUserEdits()` +
`endStroke()`) before enqueueing, the `finishInput` convention — both
land as input-queue jobs ahead of the selection stroke, so an active
stroke and queued accepted input finish BEFORE it (previously the native
readiness check could report BUSY under the open stroke). Counted
input-queue ordering, captured identity/settings/target and the error
path are unchanged.

Tests: `StrokeSelectionFormTests` (pure parser ranges/reasons, by-value
brush build with identity, menu wiring) and `EngineSmokeTest` gains
`exerciseStrokeSelectionControls`, wired as
`GLIMS_SMOKE_CASE=stroke-selection-controls` and into the default run:
menu wiring and cached validation; two independent documents/sheets;
non-default resource/size/opacity/color capture shown and used; accept
while the other window is front; unchanged selection; exact one-step
undo/redo; cancel and invalid input; busy (held gate, released on every
path), busy-after-open, preview, empty-selection, mask, channel, group,
pixel-lock and structured-source gates; the queue-order regression
(active stroke + accepted fill behind a controlled gate finish before
the selection stroke — no BUSY, three undo steps, "Stroke Selection"
last); duplicate/reentrant accept and in-flight-field-edit accept
enqueue exactly once; late callbacks after close; close-drain.

Checks actually run on this branch: `swift build -j 2` and
`swift build -j 2 --build-tests` pass. NOT run here (root owns all
runtime): `swift test`, `GLIMS_SMOKE_CASE=stroke-selection-controls`,
the full `--engine-smoke-test`, the engine matrix, any GUI/on-screen
check, any adapter build — no runtime behavior of the new sheet, menu
item, gate or queue fix was executed in this slice.


### Grid controls (2026-11-08)

Interface slice on `feat/grid-controls`, frontend only over the cached
`ImageDocument.grid` / queued `ImageDocument.setGrid` — no native call
from the UI or menu validation, no C/header change. Three pieces:

- **Image ▸ Configure Grid…** (`GridSheetController`, one per window,
  retained by its `DocumentWindowController` like the guides sheet). The
  sheet captures its document and seeds a local draft (spacing X/Y,
  offset X/Y, style popup with all five native styles, foreground and
  background color wells) from the cached grid. All edits stay local
  until Apply commits the field edits, parses strictly, and performs
  ONE queued atomic `setGrid` (one undo step when changed; an identical
  grid is a no-op). Cancel and window close write nothing. Parsing is
  whole-field `Double` plus finiteness; spacings must additionally be
  strictly positive; offsets only finite. The native range bounds are
  deliberately not checked client-side — the adapter refuses them and
  the refusal is fanned out through the document's existing `onError`
  to the sheet's message label and the status bar, never clamped, and
  the draft is preserved so the values can be corrected. A reload
  re-seeds the draft only while it is clean (Undo/Redo and a
  successful Apply's refresh land in the sheet; a dirty draft is
  never clobbered). Color wells follow the Vector Style conventions:
  the sheet records whether the shared color panel was already visible
  at open and, on invalidate, closes only a panel its own wells
  activated, deactivating both. Late close callbacks are discarded
  (`isInvalidated` + identity-checked `beginSheet` completion). Menu
  validation allows the item whenever the document is not closing and
  no other sheet is attached — grid configuration is image metadata,
  so a selected channel does not restrict it.
- **View ▸ Show Grid** (`GridViewState`, cached per window, default
  OFF): the checkmark reads the cached flag and the toggle stays
  available while the engine is busy. It is pure view state — no image
  pixels, file, dirty, history, selection, export or print mutation
  (print draws an immutable `PrintSnapshot`, never the canvas).
- **Canvas overlay** (`EngineCanvasView.drawGridOverlay`, drawn between
  the image tiles and the selection/path/guide overlays) over the pure,
  bounded `GridOverlayPlanner`: the visible rect is clipped to the
  image FIRST, line positions come from closed-form `ceil`/`floor` of
  `offset + k*spacing` inside the visible range (never a walk over the
  whole image), with finite/overflow guards and fixed caps (4096 lines
  per axis, 65536 intersections — over-cap axes/dot products are
  suppressed as illegible, reported via plan flags). An axis whose
  scaled spacing drops below 2 device pixels is suppressed, matching
  the engine's own threshold (gimpcanvasgrid.c, bug #599267); Dots and
  Intersections need both axes and draw only at intersections (1-device-
  px mark / crosshair with the engine's CROSSHAIR reach); the three
  line styles draw visible-length segments per legible axis. Foreground
  colors everything; the background color is used only by Double Dash
  as the interleaved second dash. Dash phase is anchored to image
  coordinates (`fmod(from * viewScale, period)`), so scrolled segments
  keep the pattern glued to the image. Invalid cached metadata (NaN,
  non-positive spacing) is suppressed, never clamped. Image
  coordinates map straight to view points, so zoom, backing scale,
  scroll and the flipped canvas all stay aligned.

Tests: `GridControlsTests` covers the strict parser, draft validation
(including that over-maximum spacings pass to the engine rather than
being clamped), the toggle policy, the five style names, and planner
oracles — modular line positions, offset non-clamping, visible-rect
clipping, the 2-device-px legibility boundary, per-axis suppression,
dot Cartesian products, both caps, invalid-input guards and the
dash-phase anchoring invariant against a closed-form oracle.
`GLIMS_SMOKE_CASE=grid-controls` (and the default smoke run) drives
`exerciseGridControls`: real sheet Apply/Cancel/invalid/native-refusal
paths, view-bitmap toggle and style differences with native pixel
isolation, undo/redo cache refresh, two-document ownership, busy and
late-close paths, all controls reached by accessibility label; waits
are predicate-based with queue gates released on every path.

Checks actually run on this branch: `swift build -j 2` and
`swift build -j 2 --build-tests` pass. NOT run here (owned by the root
job): `swift test`, `--smoke-test`, `--engine-smoke-test` (including
`GLIMS_SMOKE_CASE=grid-controls`), the adapter conformance tests and any
native/engine command — no runtime behavior of the new UI was executed
in this slice.


### Fill pattern source (2026-11-08)

Interface slice on `feat/pattern-chooser`, frontend only: Edit ▸ Fill…
appends Pattern (index 5) to the fill source popup and embeds a
searchable one-column list of the engine's FULL pattern catalog —
`resources(.pattern)` plus `resource_identifiers` read off the main
thread through the exclusive `EngineActivity` gate — with lazy 32 px
`resourceThumbnail` renders in bounded batches as rows appear. The
picker is owned by the sheet's sync object for exactly the sheet's
lifetime; cancel or close invalidates its generation so late deliveries
are dropped, and it opens no child panel or nested sheet. Only the
persistent `ResourceIdentity` is committed (`PatternFillStore`,
UserDefaults JSON) and `ImageDocument.fillPattern` re-resolves it on the
input queue at execution, so a removed pattern is reported missing and
refused — no default substitution. Existing fill choices 0-4 and their
behavior are unchanged. Pure `PatternChooserModel`/`PatternThumbnailQueue`/
`PatternFillStore` unit checks cover search, selection, missing-identity,
generation drops, queue batching and persistence. The initial model-only
scenario was replaced by actual sheet checks, wired into the smoke run.
Those checks cover names/previews, full search, fill pixels and undo,
persisted selection, source toggling, missing-resource refusal and cleanup.

Brush chooser verification and fixes: a native AppKit row regression first
failed because fresh table cells had no text field or image view. The cells
now render names and previews, and the test passes. The full catalog is
searchable without a 512-row truncation; native thumbnails load lazily in
batches of 32, with failed attempts cached for the generation.

A focused real-panel regression reproduced Reset and choosing Default
leaving a stale Missing label. Both now pass: presentation data is tied to
the exact persistent identity, Default clears it, and an unchanged missing
choice preserves its warning. A late preview cannot describe a different
choice. All 326 unit tests pass. Two new lazy-queue test fixtures initially
omitted the required begin/complete lifecycle; correcting those fixtures
preserved the queue's no-overlap contract. GLIMS_SMOKE_CASE=brush-chooser
selects this bounded interface scenario; ordinary engine smoke still runs
all scenarios. Full interface/matrix and on-screen chooser checks follow.

The real-panel browse scenario confirms lazy thumbnails preserve the scroll
position. It then reproduced a missing Tool Options preview after choosing a
rendered brush. Presentation revisions now notify the palette when preview
data changes even if the identity stays the same; that regression passes.
Preview images retain their native aspect ratio. The focused scenario also
drains its close work before stopping the native engine.

Follow-up shutdown review found that isBusy does not cover unlabelled
image-close work on the activity queue. The focused scenario now awaits
closeImageWhenDrained's completion in its own cleanup and confirms the image
is gone before engine shutdown; the completed callback regression passes.
The thumbnail-batch fixture excludes the Default row when counting brushes.

### Gradient chooser and canvas wiring (2026-11-08)

Interface slice on `feat/gradient-chooser`, frontend only. The pattern
picker's machinery is now resource-kind parameterized instead of copied a
third time: `ResourceRow`/`ResourceChooserState`/`ResourceChooserModel`/
`ResourceThumbnailQueue` (in `Document/ResourceChooserModel.swift`, with
`PatternRow`/`PatternChooserState`/`PatternChooserModel`/
`PatternThumbnailQueue` as compatibility aliases, so all pattern behavior
and tests are unchanged) carry a `kind` and drive `resources(kind)`,
`resolveResource(_:kind:)` and the bounded 32-thumbnail batches. The
off-main engine driving that the embedded `PatternFillPicker` owned is
extracted into the shared `ResourcePickerController` (one catalog load at
a time, one batch in flight, busy → one whenIdle retry, failed attempts
cached per generation, close-generation invalidation, document-captured-at-open,
abandon on document close); `PatternFillPicker` keeps its exact view and
load-once semantics on top of it, and `BrushChoiceCache` became the generic
`ResourceChoiceCache<Key>` (alias kept) so previews and missing markers
stay tagged to the exact persistent identity.

The Gradient tool's Tool Options rows (`ToolPalettes.swift`) are a resource
row (button with the choice's real name and identity-tagged preview, a
"Missing: …" marker for a verified NOT_FOUND, "Foreground to Background"
for the Default, plus an explicit Reset), the three shapes, a blend popup
offering ONLY Perceptual RGB and Lab (the backend returns UNSUPPORTED for
RGB Linear, so it is never offered), Reverse, and opacity. The owned
`GradientChooser` panel (row 0 = Foreground-to-Background Default) captures
the document at open; Tool Options retarget/palette dismiss close it, and
close bumps the model generation so no late native result can restore a
stale view. Choosing commits only a persistent `ResourceIdentity`; nil is
the Default, persisted in `GradientToolStore` together with the tool's own
primitive settings (shape/reverse/blend/opacity) — never a session handle,
a CGImage, or the FG/BG colors (the global color behavior is unchanged).

The real canvas gradient gesture (`CanvasTools.swift`) captures a
`GradientGestureSnapshot` once at the press — identity (nil → the built-in
`gimp-gradient-fg-bg-rgb` internal identity, so the Default also gets
reverse/blend/opacity), shape, reverse, blend space, opacity, and the
global FG/BG colors forced opaque per the backend contract — and commits
through the counted `ImageDocument.gradientResource` queue at release with
only the endpoints moving; the identity resolves on the engine worker
inside the queued job, never on main, and no mutable `ToolState` is read
from the worker closure. Default settings (perceptual, non-reversed,
opacity 1) preserve the previous FG-to-BG appearance; the low-level
`gradient(from:to:shape:fromColor:toColor:)` API is untouched.

Pure `GradientChooserTests` cover the store's default/reset and
identity-only persistence, the allowed blend/shape settings, the Default
identity, snapshot capture semantics (value capture, opaque colors,
endpoint move, ToolState write-through) and the shared kind-parameterized
model (pending choice through search/reload, missing-only-on-NOT_FOUND,
bounded batches, stale-generation drops). The smoke scenario
`GLIMS_SMOKE_CASE=gradient-chooser` (`exerciseGradientChooser`, also in the
default run) drives the real palette controls and panel — catalog, Default
row, search, lazy previews, Choose, Reset, missing marker, cancel/retarget
close — and the actual canvas drag: chosen gradient changes pixels as one
undo step and undo restores them, and the Default gesture paints the
built-in FG-to-BG midpoint even when the colors change mid-drag (capture
at the press). Runtime/desktop verification of these scenarios is owned by
the root harness; here only `swift build` and `swift build --build-tests`
were run.

Guides controls integration validation: 399 unit tests pass. The actual
Guides sheet and canvas-overlay scenario passes 28 checks on each of
GIMP 3.2.8, 3.0.8, 3.2.0 and master. The complete interface suite passes
963 checks on the pinned engine, including all three resource choosers
and the native guide cache checks. The first unit run caught an incorrect
expected sorted row index in its fixture; correcting that expectation
required no production-code change. The active-field-edit and overlay
bitmap scenarios both ran successfully. Rulers, grid, snapping and direct
canvas guide dragging remain separate work.

### Canvas overlay visibility (2026-11-08)

View now offers Show Layer Boundary (off by default) and Show Selection
Edges (on by default). Both are cached on each canvas and work while
engine work is busy. The layer boundary draws the cached active layer's
bounds in image coordinates through the same zoom/backing scale as
other overlays. Hidden selection edges stop the marching-ants timer;
showing them restores the unchanged cached contour. These switches never
change engine pixels, selection, file state or history; printing and
export use the engine projection rather than canvas drawing.

The focused `canvas-overlays` interface scenario checks menu defaults and
wiring, bitmap changes/restoration, independent canvas settings,
unchanged engine pixels/selection/dirty state/history, busy availability
and drained image cleanup. All 399 unit tests pass, and the focused scenario passes ten checks on
each of GIMP 3.2.8, 3.0.8, 3.2.0 and master. The full pinned-engine
interface suite passes 973 checks. An independent Command Code Glyph
review found no important issues; its minor test-geometry suggestions
are deferred.

### Layer source-info and explicit rasterize (2026-11-08)

Backend slice on `feat/layer-source-policy`, engine plus typed Swift
wrappers, no UI. One facade footer slot appended after `guide_remove`
(unchanged ABI otherwise): `layer_source_info(engine, image, layer, out,
error)` fills a size-versioned `GlimsLayerSourceInfo` — `source_kind`
(the layer's own class mapped to the existing `GlimsLayerKind`, so a
rasterized text/link/vector instance keeps TEXT/LINK/VECTOR while
`GlimsLayerInfo.kind` already reports PIXEL), `is_rasterized` (the
class's current editable predicate is off: the text layer's "modified"
flag, an unmonitored link, a rasterized vector — computed as class plus
negated predicate exactly as `gimp_item_is_rasterized` does in
app/core/gimpitem.c, never the generic rasterizable flag alone, so an
unmonitored link counts even when that flag stays false), and
`has_source` (a retained `GimpText`, an associated path via
`gimp_vector_layer_get_path`, or a `GimpLink` via
`gimp_link_layer_get_link`, which outlives the monitor). Pixel and group
layers report PIXEL/GROUP with both flags false. The read is always
allowed, validates `out` by `struct_size`, and reports NOT_FOUND for
stale, foreign or closed image/layer identities (`layer` 0 resolves the
selected layer).

`GLIMS_LAYER_RASTERIZE = 12` on `layer_command`: readiness first
(stroke/filter/plug-in BUSY via `glims_edit_ready`), then inherited
PIXELS|POSITION locks (`glims_check_item_locks`), then the kind
decision. A genuine editable text/link/vector becomes pixel-behaving in
one native undo step keeping its source, pixels, bounds and selection;
an already-rasterized instance (retained source or not) is a no-op
without history; ordinary pixels and groups get UNSUPPORTED with an
actionable message; an explicit stale/foreign layer id gets NOT_FOUND.
On GIMP 3.2+ the mutation is `gimp_rasterizable_rasterize(…, TRUE)`
(app/core/gimprasterizable.c): one "Rasterize …" undo group around the
rasterizable undo record — text and vector `set_rasterized` handlers
only act on restore, so `GimpText` and the path association stay, and a
link is frozen (`gimp_link_freeze`) keeping the `GimpLink` while the
monitor stops. On GIMP 3.0.8 (text only) it reproduces the native
modified-undo path verbatim — `gimp_image_undo_group_start`
(GIMP_UNDO_GROUP_DRAWABLE_MOD),
`gimp_image_undo_push_text_layer_modified`, `"modified"=TRUE`,
`gimp_image_undo_group_end` — exactly as `gimp_text_layer_set_buffer`
records it (app/text/gimptextlayer.c), preserving the `GimpText`;
`gimp_text_layer_discard` is deliberately never used. Undo restores the
editable predicate natively on both paths; a repeated command while the
predicate stays off pushes nothing.

The own source-kind state is deliberately distinct from the UI kind:
`glims_layer_kind`/image_layers keep reporting PIXEL for rasterized
instances (their content is pixels); `source_kind` reports the class.

Swift: `EngineSession.LayerCommand.rasterize = 12`,
`EngineSession.LayerSource` + `layerSource(_:image:)` decoding the
facade kind by value (an unknown kind throws instead of mapping), and
`ImageDocument` caches `layerSources` per layer id in the same reload
pass that reads locks/masks/effects (refreshed by the
undo/layers-changed → `.state` refresh) and routes `.rasterize` through
the same guarded path as fit/trim. No chooser, prompt, restore or
indexed conversion — root owns restore/consent policy.

Tests: `test_layer_source` in `Engine/tests/engine-tests.c` covers the
read's kind/state on every class, the retained source after pixel
painting, rasterize + undo + redo, pixel-identical render and unchanged
selection/bounds, repeat no-op history, own and inherited locks,
invalid/foreign/closed ids, BUSY during a stroke and a filter preview,
and an XCF round trip for rasterized text (plus vector/link paths on
GIMP 3.2+). The adapter and these tests were NOT compiled or run in
this slice — only `swift build --build-tests` (the facade header
compiles through CGlimsEngine).

Root native validation passes 1,251 / 1,146 / 1,251 / 1,251 checks on
GIMP 3.2.8 / 3.0.8 / 3.2.0 / master. The first run exposed four test
assertions that assumed a nested or newly inserted layer was the tree's
first row. Resolving the exact layer id corrects those fixtures; the
production implementation required no change. All retained-source,
undo/redo, unchanged pixels/selection/bounds, XCF, lock and busy assertions
now pass. The compiled `layer-source` interface scenario additionally
checks queued document cache refresh and busy admission; its runtime
execution and the unit suite are pending the shared desktop.

Ruler runtime validation caught overlapping native ruler/clip rectangles:
this AppKit build left the viewport full-sized even with zero content
insets. CanvasScrollView now reserves only rectangles that actually
overlap, leaving traditional native tiling alone, and preserves the
scrolled position across repeated tiling. The focused checks pass on all
four engines, including real scrolling and rectangle separation.
Independent reviews of the original rulers and the layout fix found no
important issues. All 417 unit tests pass.

The first full run exposed a stale synthetic text click: after layout
changed, its old window coordinates mapped to image (4,-17), outside the
saved text at (4,4). Recomputing a click inside the current text bounds
reopens that exact layer; deleting its content then saves correctly. The
focused file-safety scenario passes. Unknown smoke selectors now fail
explicitly rather than silently running the full suite. The integrated
full run is repeated after adopting the Guides field fix.

### Retained-source restore (2026-11-08)

Backend slice on `feat/layer-source-restore`, engine plus a typed Swift
case, no UI and no document dispatch. `GLIMS_LAYER_RESTORE_SOURCE = 13`
on `layer_command` (purely additive enum value, ABI version stays 1) is
the inverse of RASTERIZE for layers that still retain their structured
source: it discards the pixel edits and regenerates the content from the
retained text, link or path as ONE undo step, preserving the selection,
the item id, the source kind and a mask attachment. Dispatch in
`glims_layer_command` (Engine/edit.c) mirrors RASTERIZE exactly:
`glims_edit_ready` first (BUSY during stroke/filter/plug-in), then
`glims_check_item_locks` with PIXELS|POSITION (LOCKED, own or inherited),
then `glims_layer_restore_source` (Engine/layer-source.c). An explicit
layer id that names no attached layer of the image is NOT_FOUND before
the switch, like RASTERIZE.

Kind decision in `glims_layer_restore_source`: ordinary pixel layers,
groups and structured layers whose source is gone (`source_is_retained`
is false) report UNSUPPORTED with an actionable message before any
mutation; an already editable instance (`source_is_editable`, the
core's own `gimp_item_is_text/link/vector_layer` predicates) is a no-op
that pushes no undo.

On GIMP 3.2+ with the genuine rasterizable flag TRUE — text and vector
always (their predicates ARE the flag), and a link rasterized
explicitly — the mutation is `gimp_rasterizable_restore`
(app/core/gimprasterizable.c): one "Revert Rasterize …" undo group
around the rasterizable undo plus `gimp_image_undo_push_drawable_mod`
(copy TRUE), then `set_rasterized(FALSE)`, whose handlers re-render
the retained text (app/text/gimptextlayer.c), re-render the path
(app/path/gimpvectorlayer.c) or thaw the link, reset its matrix and
render its buffer (app/core/gimplinklayer.c).

A link layer whose monitor stopped while the generic flag stayed FALSE
— native pixel edits or an indexed conversion call
`gimp_link_freeze` from `gimp_link_layer_set_buffer`, and
`gimp_item_is_link_layer` computes `gimp_link_layer_is_monitored`, so
`gimp_item_is_rasterized` sees it without the flag — never touches the
restore guard or fakes the flag. The restore is assembled from public
core headers as one undo group: `gimp_image_undo_push_drawable_mod`
(copy TRUE) BEFORE `gimp_image_undo_push_link_layer`, so undo first
stops the monitor (the link undo restores the unmonitored duplicate)
and then restores the painted buffer; then `gimp_link_thaw` on the
retained link and `gimp_link_layer_set_link(layer, same_link, FALSE)`,
which resets the transform matrix to identity and re-renders the
retained source. Link policy, stated exactly: the file is RELOADED when
it is readable; on a read failure the RETAINED SOURCE BUFFER is kept and
monitoring resumes — a missing file is NOT an error
(`gimp_link_update_buffer` keeps the old buffer when the load fails,
app/core/gimplink.c). The static `gimp_link_update_buffer` and the
private flag setter are never called. `gimp_link_layer_set_link` returns
FALSE only when the link has no buffer or the buffer's extents are zero
(`gimp_link_layer_render_link`), so the retained link's GFile
(`gimp_link_get_file`) and nonempty buffer (`gimp_link_get_buffer`) are
prevalidated BEFORE the undo group; an unexpected FALSE after that is
reported as FAILED with a message disclosing the gap, never silently
OK.

Before GIMP 3.2 only text exists; the restore reproduces
`gimp_text_layer_set`'s own undo group (app/text/gimptextlayer.c):
`gimp_image_undo_push_text_layer_modified` plus
`gimp_image_undo_push_drawable_mod` (copy TRUE) in one
GIMP_UNDO_GROUP_TEXT group, alpha added when the painted layer lost it,
`"modified"=FALSE`, then the GimpText `"changed"` signal (no args)
re-triggers the layer's existing private render callback.
`gimp_text_layer_set` itself cannot be used while modified is TRUE —
its `gimp_item_is_text_layer` predicate guard refuses — and
`gimp_text_layer_discard` is never used: it would destroy the text.

Swift: `EngineSession.LayerCommand.restoreSource = 13` (typed, routed
through the existing `layerCommand(_:image:layer:)` call), but
`ImageDocument.layerCommand` REFUSES `.restoreSource` with "Use the
confirmed restore command." until the root's global confirmed-restore
dispatch exists — the input queue must not run native file I/O (a link
restore can reload its file). No new footer slots; no palette or menu
entry.

Tests: `test_layer_restore_source` in `Engine/tests/engine-tests.c`
(exact oracles, rows matched by identity via `source_test_row`): edited
pixels -> source restoration (pixel-identical render) -> UNDO exact
edited pixels + retained raster state -> REDO source again, for the
explicit-rasterize text on every engine (3.0's modified-flag path
included), the vector on 3.2+, the explicitly rasterized link (flag
TRUE) and the painted link (flag FALSE, monitor stopped); no-op without
history on already editable layers; unchanged selection/bounds/item
id/source kind/mask attachment; UNSUPPORTED for pixel/group and
NOT_FOUND for stale/foreign/closed ids before any mutation; own and
inherited PIXELS/POSITION locks LOCKED; BUSY during a stroke and a
filter preview; the reload-file policy (rewritten file renders blue) and
the missing-file retained-buffer policy (deleted file restores the
exact retained render, monitoring resumed, no error). The adapter and
these tests were NOT compiled or run in this slice — only
`swift build --build-tests` (the facade header compiles through
CGlimsEngine). Root compiles the C matrix.

Root validation: the native restore suite passes 1,314 / 1,170 / 1,314 /
1,314 checks on GIMP 3.2.8 / 3.0.8 / 3.2.0 / master. The first run's
retained-source assertions used an uninitialized size-versioned output
struct. Initializing `struct_size` fixes those tests; the independent
pixel-restoration and exact undo assertions already passed. No runtime
restore behavior required a change. User-facing confirmed dispatch and
its interface checks follow separately.

### Layer source controls: Rasterize Layer… / Restore Layer Source… (2026-11-08)

UI slice on `feat/layer-source-controls`, Swift-only over the existing
C API 113 (`LayerCommand.rasterize = 12`, `.restoreSource = 13`,
`layer_source_info`): no C, header or dependency change.

- `Sources/GlimsKit/Document/LayerSourceMenuPolicy.swift`: pure
  cached-state gating. Rasterize only on genuine TEXT/LINK/VECTOR with
  `hasSource && !isRasterized`; Restore only on `hasSource &&
  isRasterized`; ordinary pixels/groups and a missing cache entry offer
  neither; inherited (effective) PIXELS|POSITION locks, mask/channel
  targets and the caller-composed closing/busy/pending-target/preview/
  attached-sheet states disable. No synchronous native RPC in
  validation or UI.
- `ImageDocument`: `targetCommandIsPending` cached flag;
  `rasterizeLayerSource(_:completion:)` — counted, explicit-id, routed on
  the input queue behind accepted edits; `restoreLayerSource(_:completion:)`
  — same explicit-id rules, but through the existing `enqueueExclusive`
  mechanism like `convertProfile`: pending edits end, accepted input in
  every document drains first, `pendingWork` holds until completion, and
  the restore never goes through the ordinary input queue (a link
  restore may load a file). Both deliver the `Result` on main exactly
  once, reload when the document is alive, report failures through
  `onError`, refuse closed/busy without queueing, and pass a stale id to
  the engine untouched so it comes back NOT_FOUND, never retargeted.
  `layerCommand(.restoreSource)` still refuses unconfirmed calls.
- `MainMenu` Layer menu gains "Rasterize Layer…" and "Restore Layer
  Source…"; `DocumentWindowController` owns the per-window NSAlert
  confirmation sheets (no singleton, no callback-hook clobbering): the
  document and explicit layer id are captured by value before the alert,
  so Apply never uses layer 0, the front window or the current selection;
  Cancel queues nothing; a close since the sheet opened wins over a late
  Apply. Rasterize's text explains pixel behavior with the source
  retained and linked layers stopping source updates; Restore's text
  explains discarded pixel edits, undo availability, retained
  text/path/linked source, and the native link contract (reload when
  readable, otherwise retained source with monitoring resumed). Sheet
  buttons carry explicit accessibility labels. `validateMenuItem` gates
  both items through the policy over `layerSources`/`layerLocks` and the
  existing mask/channel/busy/closing/preview/attached-sheet guards.
- Tests: `LayerSourceMenuPolicyTests` (pure policy: kinds, source
  states, missing cache, locks, target and blocked states),
  `LayerMenuTests` gains the Layer-menu wiring for both selectors, and
  `EngineSmokeTest` gains `GLIMS_SMOKE_CASE=layer-source-controls` plus
  `exerciseLayerSourceControls` in the full suite: menu wiring and
  cached gating (text/pixel/locks/attached-sheet/busy), sheet Cancel
  changing nothing, Rasterize Apply as one undo with the cached kind
  flipped, retarget-before-Apply and a second document staying untouched,
  a pixel stroke then Restore giving the exact source pixels plus one
  undo, undo restoring the painted pixels, BUSY refusal under a
  controlled semaphore pause, the admitted restore counted in
  `pendingWork` and draining the other document's accepted stroke first,
  stale-id native NOT_FOUND, and late-close Apply queueing nothing.
  Pixel/kind oracles read the session directly (`copyPixels`,
  `layerSource`, `layers`), never the cache under test.

Checked in this slice: `swift build -j 2` — Build complete;
`swift build -j 2 --build-tests` — Build complete (the new
`LayerSourceMenuPolicyTests.o` is in the build tree). NOT RUN here (the
Mac's shared process limits; root owns runtime): `swift test`, the
`GLIMS_SMOKE_CASE=layer-source-controls` and full `--engine-smoke-test`
runs, all AppKit/GUI execution, and every native adapter/engine build —
the four-engine suite 1314/1170/1314/1314 green under root predates
this slice and does not validate it. Remaining gaps: runtime behavior
of the sheets, the restore's link-file reload path through the UI, and
mask/channel-target gating exercised only in the pure policy tests, not
against a live mask/channel target.

Guide field refresh regression: undoing a selected guide's move updated
the list but left its idle position field stale because reselecting the
same table row does not notify its delegate. The new actual-sheet check
failed before the fix. Reload now synchronizes the selected guide's input
fields explicitly while preserving an active text edit. Both Undo/Redo
field checks and the existing active-edit preservation check pass on the
pinned engine (30 focused checks). Before this fix, the source-cache
integration passed 399 unit tests, all-four-engine guide checks and 971
full pinned interface checks. Follow-up review and matrix are running.

### Linked-load admission and object lifetime (2026-11-08)

A controlled Python file loader reproduced edits being admitted during
Restore Source, Undo, history navigation and automatic linked-file refresh.
Restore/Undo/history now hold balanced native busy counters. RPC dispatch
from a nested engine loop also raises busy for the call so mutation gates
refuse while reads and cancellation remain deliverable. This is not a
blanket dispatch block; existing stroke delivery keeps its prior contract.
The public event callback contract already forbids synchronous reentry.

A second red regression showed close destroying images during a load.
Native close now returns BUSY and leaves the image alive; EngineActivity
retries asynchronously without occupying its queue or reporting a false
completion. The session stays retained until a real close result arrives.
The retry intentionally waits for native completion; a permanently wedged
loader can therefore keep the close pending while cancellation remains
available.

GIMP 3.2's link finalizer leaves a changed idle with bare link userdata.
The adapter tracks links in current layers, detached undo-owned layers,
link undo records and nested undo/redo stacks. A weak notification removes
pending sources only when the link object actually dies, preserving live
shared owners and future monitoring. Adoption, undo events and final image
release install the hooks. Master cancels the idle natively, so this
compatibility cleanup applies only to the pinned 3.2 engines. No upstream
source was modified. Re-audit the workaround when updating those pins.

Native suites pass 1,361 / 1,171 / 1,361 / 1,361 checks on GIMP 3.2.8 /
3.0.8 / 3.2.0 / master, including close BUSY/no destruction, post-load
close, unchanged pixels/history after refused edits, reads/cancel delivery
and native monitor reload. The fixture now observes native close status
rather than assuming a Python marker or a fixed delay proves completion.
Independent review of the lifetime change found no important issues.
Swift targets compile; application-side retry runtime remains part of
subsequent interface integration.


### Native indexed conversion (2026-11-08)

Backend slice on `feat/indexed-conversion`, adapter plus typed Swift
wrapper, no UI. One facade footer slot appended after
`layer_source_info` (unchanged ABI otherwise):
`image_convert_indexed(engine, image, settings, colors, color_count,
error)` runs the core's `gimp_image_convert_indexed`
(app/core/gimpimage-convert-indexed.c; identical signature and
semantics in GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8 and master — the header
is byte-identical up to `#pragma once`/cleanup-attribute cosmetics and
the .c differs only in a `gimp_gegl_buffer_new` internal on master) as
its own single "Convert Image to Indexed" undo group. No adapter undo
group is added and upstream is unpatched.

Settings cross the facade as the size-versioned `GlimsIndexedSettings`
with facade-owned enums only: `GlimsIndexedPalette` GENERATED/WEB/MONO/
CUSTOM → `GIMP_CONVERT_PALETTE_*` (libgimpbase/gimpbaseenums.h),
`GlimsIndexedDither` NONE/FS/FS_LOW_BLEED/FIXED →
`GIMP_CONVERT_DITHER_*` (app/core/core-enums.h; the internal
NODESTRUCT value is never exposed), and `GlimsIndexedPreservation`
PRESERVE_EDITABLE/ALLOW_RASTERIZE. `max_colors` is validated 2 ... 256
for GENERATED and ignored otherwise (the core sizes its quantizer from
it only on the GENERATE path; the call passes the native maximum for
the fixed palettes, as the engine's own dialog default does).
`remove_unused` maps to the core's `remove_duplicates`, which the
native post-pass applies to WEB and CUSTOM only and skips for
GENERATED and MONO — forwarded verbatim and documented as ignored
there. `dither_alpha` and `dither_text` map to the same-named core
arguments. FIXED dithering uses the engine's current ordered-dither
matrix, whose native default is initialized statically. Conversion does
not reset process-wide state configured by another command.

CUSTOM takes a caller-owned `colors`/`color_count` argument (1 ... 256
opaque sRGB entries), validated element-wise — finite, 0 ... 1, alpha
exactly 1 — before any mutation. The adapter builds a private
`GimpPalette` per call (`gimp_palette_new(NULL, "Custom")` +
`gimp_palette_add_entry` of `GeglColor`s set in sRGB), passes it as
the borrowed `custom_palette` argument and unrefs it right after the
synchronous call; the core copies the entries out in `custompal_pass1`
(gimpimage-convert-indexed.c:2950), so nothing outlives the call.
The palette is therefore never NULL for CUSTOM, which also makes the
core's silent CUSTOM→MONO fallback unreachable; an empty list is
refused by our own validation, the only CUSTOM error the core would
report. No resource id or native pointer crosses the facade.

Validation order: image identity (NOT_FOUND), whole settings —
struct_size, all three enum fields, GENERATED's `max_colors`, CUSTOM's
list and per-color components (INVALID_ARGUMENT) — then
`glims_edit_ready` (stroke/filter/plug-in BUSY), then the image gates:
an already indexed base type is a history-free no-op (the core refuses
it with no GError); precision must be exactly
`GIMP_PRECISION_U8_NON_LINEAR` — the only one `gimp_babl_is_valid`
accepts for indexed — and the layer stack must be flat
(`gimp_item_stack_is_flat` on `gimp_image_get_layers`, the identical
gate the engine's own menu action and PDB invoker apply;
image-actions.c:484,536, image-convert-cmds.c:143). Both report
UNSUPPORTED with an actionable message. All of the core's
`g_return_val_if_fail` preconditions are thus excluded before the
call; a remaining FALSE return reports through `glims_fail` with the
core's GError.

Editable-layer policy: the core's quantize path rasterizes every
non-text layer (vector/link `set_buffer` keeps the `GimpRasterizable`
flag/link object — source retained, monitor frozen for links) and
text only when `dither_text` is on; with it off,
`gimp_drawable_convert_type`/`gimp_text_layer_convert_type` re-renders
the text in indexed format and it stays editable
(gimpimage-convert-indexed.c:1054-1099). PRESERVE_EDITABLE refuses
genuine editable vector or link layers always, and genuine editable
text when `dither_text` is on, with REQUIRES_RASTERIZE — the same
actionable consent status `image_convert_profile` uses — before any
mutation. ALLOW_RASTERIZE admits them inside the conversion's one
undo; undo restores RGB/gray pixels, the mode and each layer's
structured kind and editable predicate.

Swift: `EngineSession.IndexedPalette/IndexedDither/
IndexedPreservation/IndexedSettings` and
`convertToIndexed(_:settings:)`; `customColors` (`[NSColor]`, opaque)
marshals to a `GlimsColor` array whose `withUnsafeBufferPointer`
covers the complete synchronous C call. `EngineError.requiresRasterization`
classifies the consent refusal. `convertMode(.indexed)` stays
UNSUPPORTED and now points at `convertToIndexed`.

Conformance (`test_indexed_conversion`, registered after
`test_color_state`): GENERATED on a painted two-color image pins exact
quantized pixels plus indexed mode/u8-non-linear precision and
undo/redo pixel-for-pixel restoration; WEB pins 6×6×6-step components;
MONO pins black/white; a known red/blue CUSTOM palette pins the exact
rendered AND copied bytes of an `image_from_pixels` source with no
colormap-read API; FS vs NONE diverge on a ramp; FS_LOW_BLEED, FIXED
and `dither_alpha` on a translucent ramp are exercised; the
already-indexed no-op runs after full validation. Negatives: missing/
short settings, every unknown enum, `max_colors` 1/257, CUSTOM
missing/empty/257 colors and non-finite/out-of-range/non-opaque
entries, unknown image, u16 precision, a grouped stack, and BUSY under
stroke and filter — all assert unchanged mode and undo depth. Text:
dither_text off converts and keeps the text editable (source_kind
TEXT, not rasterized, source retained); dithered text under preserve
is refused actionably; allowRasterize converts in one undo with source
retained and undo restores the editable kind. On GIMP 3.2+ a genuine
vector plus placed link layer are refused under preserve even with
dither_text off, rasterize under consent in one undo with sources
retained, and undo restores both kinds; the whole block is skipped on
3.0.8, which lacks the classes.

The initial helper compiled the Swift targets only. Root subsequently
built and ran the adapter and native suites on this same changeset, as
recorded in the integrated validation below.

Owner review retains the existing facade's REQUIRES_RASTERIZE status
for the preservation refusal, matching profile conversion and allowing
the interface to offer explicit consent without treating other
unsupported states as rasterization requests. The first native run
confirmed the refusal happens before mutation. Its filter-busy fixture
initially compared history against the depth before a preceding stroke
was committed; it now captures the depth after that stroke. FIXED
dithering passed using the native statically initialized matrix after
removing the unnecessary per-conversion global reset.

Integrated validation passes 1,319 / 1,208 / 1,319 / 1,319 native checks
on GIMP 3.2.8 / 3.0.8 / 3.2.0 / master, plus 387 unit tests and nine
typed-wrapper checks on each engine. The full pinned interface suite
passes 952 checks. An actual pattern-color palette input reproduced an
AppKit component-access exception in the shared NSColor serializer: a
failed RGB conversion fell back to a generic-gray black, then read RGB
components. Serialization now throws INVALID_ARGUMENT before component
access or engine mutation; throwing propagation covers its existing typed
callers. Non-custom palettes ignore the unused custom-color list.
Independent native and shared-color reviews found no important issues.
One minor existing wrapper caveat remains deferred: vector-style changes
serialize both colors even when their property bits are absent; current
forms supply valid captured colors for those unused fields.

Guide field refresh regression: undoing a selected guide's move updated
the list but left its idle position field stale because reselecting the
same table row does not notify its delegate. The new actual-sheet check
failed before the fix. Reload now synchronizes the selected guide's input
fields explicitly while preserving an active text edit. Both Undo/Redo
field checks and the existing active-edit preservation check pass on the
pinned engine (30 focused checks). Before this fix, the source-cache
integration passed 399 unit tests, all-four-engine guide checks and 971
full pinned interface checks. Follow-up review and matrix are running.

The combined rulers/Guides-field revision passes all 417 unit tests and
1,021 full pinned-engine interface checks. The focused rulers scenario
passes 47 checks on each of the four supported engines.

Pinned CI uses Swift 6.2 and requires explicit CGFloat-to-Double tuple
conversion in the ruler axis mapping; the newer local compiler had
accepted it implicitly. The conversions are now explicit.

### Indexed conversion controls (2026-11-08)

UI slice on `feat/indexed-controls`, Swift only — no C/header/dependency
change; the facade's `image_convert_indexed` and the typed wrapper from
the backend slice are reused as they are.

Image ▸ Mode ▸ Indexed… (`MainMenu` adds the entry to the Mode submenu;
`DocumentWindowController.convertImageToIndexed`) opens a
document-owned per-window policy sheet (`IndexedSheetController`,
retained by its window like the guides sheet; the DOCUMENT is captured
at sheet open, so Apply and the rasterization confirmation act on the
captured document, never on the global/front one). Cached menu gates in
`validateMenuItem`: the checkmark reads `colorInfo.mode` (already indexed
is checked and disabled — the document method no-ops too), and the item
is unavailable while BUSY/closing/preview or another sheet is attached,
and while the cached native eligibility fails — u8 non-linear precision
and no layer groups — with the reason in the tooltip. Precision is never
auto-converted and groups are never auto-flattened; the sheet's
informative text says the same. The action itself re-checks the cached
eligibility (silent no-op when already indexed, refusal with the reason
otherwise).

Form controls, each with an accessibility label used by the actual
control queries: Palette popup Generated/Web/Monochrome/Custom; Maximum
colors field + stepper (2 ... 256, enabled only for Generated); Custom
plain multiline `#RRGGBB` text (exactly one color per nonblank line,
blank lines allowed, 1 ... 256 colors, enabled only for Custom); Remove
unused colors (enabled only for Web/Custom); Dithering popup
None/FS/Reduced Bleeding/Ordered; Dither transparency and Dither text
toggles. `IndexedFormLogic` is the pure, unit-tested layer: a strict
parser (ASCII hex only, no trimming, NUL refused before any color is
built, count 1 ... 256, per-line error messages; opaque
`NSColor(srgbRed:green:blue:alpha: 1)` values), the eligibility gate,
the choice lists and `makeSettings` (max colors checked only for
Generated; `removeUnused` forced off for Generated/Mono; Custom text
parsed strictly).

Apply always builds settings with `preservation.preserveEditable` and
runs them through the new counted exclusive
`ImageDocument.convertToIndexed(settings:completion:)` — the same
`enqueueExclusive` admission as the other color conversions: accepted
input in every document drains first, the work counts toward close and
Quit (`pendingWork`), busy/closing refusals report through the
completion, an already indexed image is a no-op, and success reloads
the document on main before the exactly-once completion. Local invalid
input shows an inline error in the sheet: no mutation, no sheet close.
ONLY an `EngineError.requiresRasterization` failure admits the second
explicit consent step — an inline confirmation region in the SAME sheet
(no nested sheet): the validated settings are preserved, the fields stay
disabled, and Rasterize and Convert / Back / Cancel are offered. Confirm
re-runs the captured settings with only `allowRasterize` on the captured
document. Back returns to the form; Cancel closes with no mutation. Any
other UNSUPPORTED/native error stays visible inline and returns to the
form — never reinterpreted as consent. Once native work is accepted the
mutating controls stay disabled and no Cancel is offered; the sheet and
window close invalidate the controller (`invalidate()`), so late
completions touch no UI while the accepted work remains counted and
drained before the image is destroyed. Success closes the sheet.

Wired `GLIMS_SMOKE_CASE=indexed-controls` plus a full-suite
`exerciseIndexedControls`: actual-sheet Generated and Custom conversions
pinned against independent session pixel/mode/undo oracles with one undo
step; Cancel and invalid Custom change nothing; text with Dither text
off stays editable; Dither text triggers the consent region, Back/Cancel
mutate nothing, explicit confirm rasterizes and undo restores; BUSY
refusal, exclusive counts and the global accepted-input drain; two
documents retaining their captured owner across a retarget; menu gates
for indexed/u16/grouped/preview/busy; late close safety. Controls are
queried by accessibility label; admission pauses follow the existing
profile tests. No production debug flows.

Checked here: `swift build -j 2` and `swift build -j 2 --build-tests`
both complete (compile only). NOT RUN: `swift test`, every
GLIMS_SMOKE_CASE including indexed-controls, any GUI/native/adapter run —
no engine or adapter was started in this worktree; root owns the unit,
native and full-suite validation.

Indexed controls validation passes 425 unit tests, 64 focused actual-sheet
checks on every engine and 1,045 full pinned interface checks. A real
numeric-prefix bug accepted “12px” as 12; complete canonical integer
parsing now rejects it before conversion. The first fixture also skipped
nested action stacks and tried to open a new sheet while already busy;
its traversal/action setup and controlled input-drain gates are corrected.
Root reviewed form state, explicit consent, captured settings/document,
validation, exclusive work and close handling. The separate independent
UI review failed without findings and provides no approval.


Integrated with the merged Guides/source cache: all 402 unit tests,
focused anchor checks on all four engines and 1,000 full pinned interface
checks pass. The synthetic Escape key now also carries the correct ESC
character; key-code dispatch was already correct.


Post-merge validation with Guides passes 399 unit tests, all-four-engine
typed wrapper checks and 982 full pinned interface checks. Review also
hardened the dither fixture against unexpected short pixel-copy results;
comparison now requires both buffers to have the expected byte count.

### Profiled display pixels (2026-11-08)

The existing renderer converts the image projection from its effective ICC
space to 8-bit premultiplied sRGB. The native chain is
`gimp_image_get_proj_format` / `gimp_image_get_layer_space`, with ICC spaces
created by `gimp_color_profile_get_space` and `babl_space_from_icc`;
EngineSession tags the resulting CGImage with sRGB. Quartz performs the
subsequent conversion to the destination display context. Reference:
https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_color/dq_color.html

A new independent analytic oracle assigns the existing linear-TRC profile
with sRGB primaries to opaque and translucent midtones. Expected sRGB
transfer values are calculated directly, rather than through another native
render. All four engine suites pass (1,261 / 1,156 / 1,261 / 1,261), including
premultiplied render bytes, straight-alpha clipboard bytes, unchanged
history/dirty state on reads and profile-assignment Undo/Redo appearance.
No production renderer change was needed. This verifies the in-gamut sRGB
path; physical monitor calibration, wide-gamut/HDR output, proof profiles,
proof intents and gamut warnings remain unverified or unimplemented.


Ruler review reproduced a major/minor classification defect at large
scrolled coordinates: a magnitude-relative tolerance eventually exceeded
the distance between ticks. At image coordinate 1,000,000 and 3,200% zoom,
the actual planner mislabeled all 26 visible ticks as major. Classification
now uses exact divisibility of the integral tick index. The independent
six-position oracle passes, as do all 421 unit tests and 47 focused pinned
interface checks. The four-engine focused and 1,067 full integration checks
above preceded this pure planner correction.

Grid controls integration passes 417 unit tests, all 38 focused checks on
all four engines and 1,030 full pinned interface checks. A controlled
probe of the actual planner reproduced an infinite loop when a Double
index could not advance by one; indices outside the exact-integer range
are now suppressed and iteration has an integer bound. Its regression
passes. An actual-sheet regression also reproduced idle fields staying
stale after Apply then Undo. The document now reports counted completion;
the sheet marks the committed draft clean only on success and refreshes
it from the cache. Accepted work disables its controls through completion.
Close discards unapplied edits, while applied changes remain undoable.
Own color editing ends on Apply and close without hiding another owner's
panel. Parent integration and independent review of this fix follow.

A second grid regression reproduced the cache/completion stage becoming
uncounted while another document held exclusive engine work. That stage
now retains its own pending-work count through the deferred callback,
including close and failure paths. All 39 focused checks pass on each of
the four engines. A focused independent review of the supplied exact diff
and surrounding source found no important findings; the helper could not
independently execute Git. The broader current-file review was also clean.

The source-controls integration passes 407 unit tests, all 33 focused
sheet/dispatch checks on each supported engine, and the full pinned
interface suite. Initial failures were assertions against the wrong
state: ordinary pixels have a source-info cache entry, and the menu
was still aimed at the retargeted pixel layer. Correcting those fixture
expectations required no production change. Root reviewed the source
controls, admission/drain and close paths. The independent broad UI
helper timed out without a verdict and is not counted as approval.


Ruler review reproduced a major/minor classification defect at large
scrolled coordinates: a magnitude-relative tolerance eventually exceeded
the distance between ticks. At image coordinate 1,000,000 and 3,200% zoom,
the actual planner mislabeled all 26 visible ticks as major. Classification
now uses exact divisibility of the integral tick index. The independent
six-position oracle passes, as do all 421 unit tests and 47 focused pinned
interface checks. The four-engine focused and 1,067 full integration checks
above preceded this pure planner correction.



Grid integration validation passes 1,380 / 1,269 / 1,380 / 1,380 native
checks on GIMP 3.2.8 / 3.0.8 / 3.2.0 / master. The initial failures were
fixture errors: the color oracle required double precision although
GEGL's RGBA-with-space accessors store floats, and the preview busy probe
submitted an identical no-op and short-circuited its cleanup. Color
comparisons now allow float rounding; the busy probe requests a genuine
change and always closes its preview. No production grid code changed.
Independent review found no important issue. Nondefault unit retention
is verified from clone semantics in the sources; it is not directly
covered by the facade-only XCF fixture. Swift/cache runtime follows with
the configuration interface.


Ruler review reproduced a major/minor classification defect at large
scrolled coordinates: a magnitude-relative tolerance eventually exceeded
the distance between ticks. At image coordinate 1,000,000 and 3,200% zoom,
the actual planner mislabeled all 26 visible ticks as major. Classification
now uses exact divisibility of the integral tick index. The independent
six-position oracle passes, as do all 421 unit tests and 47 focused pinned
interface checks. The four-engine focused and 1,067 full integration checks
above preceded this pure planner correction.


Stroke Selection runtime validation supersedes the compile-only report
above: native suites pass 1,422 / 1,311 / 1,422 / 1,422 checks on GIMP
3.2.8 / 3.0.8 / 3.2.0 / master. Runtime tests reproduced invalid settings
returning FAILED instead of INVALID_ARGUMENT and native stroke preparation
replacing the requested translucent red with opaque black. The adapter now
returns the specified validation status and pins the paint properties on
the private context before preparation reparents the options. A separate
ordinary paint stroke supplies the color/opacity oracle. Clone/heal source
coordinates are checked for finite, native-integer range before conversion.
The 3.2.0 suite still logs two startup GLib filename assertions before the
checks, as recorded in its log; it reports zero failed checks. Swift document
queue execution and user-facing Stroke Selection controls remain to verify.





### Floating-selection / Paste Into backend (2026-11-08)

Backend slice on `feat/floating-selection`: no UI, no ImageDocument,
cache, menu or controller changes, and the normal Paste path
(`image_paste_pixels`, independent new layer) is untouched. Three
append-only facade footer slots follow the canonical `selection_stroke`
(slot 117): `image_floating_selection` (slot 118, the size-versioned
`GlimsFloatingState` read: active flag, floating layer id, target id and
own `GlimsFloatingTargetKind` target kind), `image_paste_into`
(slot 119) and `floating_command` (slot 120, a `GlimsFloatingCommand`:
ANCHOR / TO_LAYER / DISCARD with an explicit `expected` floating id).
API version 1 unchanged — purely additive, so `struct_size` grows with
the table and `abi.c`'s assert stands; no existing struct layout or ABI
order changed and no native raw enum, layout or pointer crosses the
facade: the new enums map to the engine's named constants
(`GIMP_PASTE_TYPE_FLOATING_INTO`, the `GimpLayerMask`/`GimpChannel`/
`GimpLayer` classes, `floating_sel_*`) inside `Engine/floating.c` only.

Source contracts, verified identical in all four engine trees
(GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8, master): `gimp_edit_paste` with
`GIMP_PASTE_TYPE_FLOATING_INTO` wraps the paste in exactly one "Paste"
undo group, attaches through `floating_sel_attach` and — unlike
`FLOATING` — never clears the image selection; with no viewport (the
PDB passes -1,-1,-1,-1) it centers the floating layer on the target's
bounds intersected with the selection (`gimp_item_mask_intersect`). The
caller's straight-alpha R'G'B'A u8 pixels go into a private per-call
`GeglBuffer` + `GimpBuffer` (`gimp_buffer_new(..., copy_pixels=TRUE)`,
so no caller memory is retained and no color profile is attached — core
converts to the target's format-with-alpha and precision), the returned
`GList` is a caller-owned container released with `g_list_free` (objects
belong to the image), and the temporary context is a private
`gimp_context_new` child of the user context. Resolution verbs are the
core's own one-undo operations: `floating_sel_anchor` ("Anchor Floating
Selection"), `floating_sel_to_layer` ("Floating Selection to Layer",
which fails before its undo group opens for mask/channel-attached
floating selections) and `gimp_image_remove_layer(..., TRUE, ...)`
("Remove Floating Selection"). XCF saves and reloads the attachment
natively (`xcf-save.c`/`xcf-load.c` `floating_sel_attach`), so
persistence needs no adapter code.

Admission in `glims_image_paste_into`, all before any native call, so
every refusal changes no pixels, pushes no undo and resets its outputs:
INVALID_ARGUMENT for missing pixels, a byte count that is not exactly
width*height*4 (shared `glims_pixel_bytes` overflow guard), bad
dimensions or out-of-range offsets; NOT_FOUND for an unknown image or a
stale/foreign/detached target (`glims_lookup_drawable`); FAILED with an
actionable message when a floating selection already exists — core's
`floating_sel_attach` would silently anchor it inside the "Paste" group
— when there is no selection (`gimp_channel_is_empty`; Select All counts
as a full, non-empty selection, as core treats it) or it does not
intersect the target, when the target is the selection mask itself, a
layer group, or not a channel of the image's channel list, or when the
core paste fails; LOCKED for a content-locked target or ancestor group
(core would silently downgrade to NEW_LAYER — never done here);
REQUIRES_RASTERIZE for a genuine editable text/link/vector layer target
(new `glims_layer_editable_source_kind` in layer-source.c; plain pixel
layers and already rasterized instances are accepted); BUSY via
`glims_edit_ready`. `floating_command` requires the `expected` id to be
the actually active floating layer of the image: 0 is INVALID_ARGUMENT,
a stale/foreign/mismatching id NOT_FOUND, no floating selection NOT_FOUND
— never a fallback to whichever floating selection is active; an unknown
command is INVALID_ARGUMENT; TO_LAYER on a mask/channel attachment is
FAILED with the engine's error and no mutation.

Session side: `EngineSession.FloatingTargetKind` /
`FloatingState` / `FloatingCommand` and the wrappers
`floatingSelection(_:)`, `pasteInto(_:target:pixels:)` (reusing
`ClipboardImage`, like `pastePixels`) and
`floatingCommand(_:image:expected:)` over the three slots, with
`struct_size` set and unknown target kinds refused. No queued document
wrapper yet — that is the UI slice.

Facade-only conformance adds `test_floating_selection` (engine-tests.c,
no engine headers): the read's validation and inactive answer; every
admission refusal (no/disjoint selection, existing float, unknown
image, stale/foreign target, group, locked, editable text before and
after rasterize, bad buffers, BUSY under an open stroke and filter)
with no pixel/history/state change and reset outputs; a real Paste Into
with pixel oracles (opaque payload pixel inside the selection, selection
clip outside it, transparent payload pixel, untouched far outside), the
floating row found by exact id at the centered bounds, the selection
unchanged; paste and anchor/discard/to-layer each exactly one undo and
redo restoring the exact composite and floating state (same ids across
undo); stale/zero/foreign `expected` never falling back; mask and channel
attachments with kind layer-mask/channel and actionable to-layer
refusals; an XCF round trip preserving the attachment by kind and target
identity ("Background" row) rather than the runtime id, compositing
identically, anchor working after reload; and the normal-Paste
regression (independent new layer, no floating state, selection
unchanged). Not covered: painting/copying while a floating selection is
active (the fs layer is the forced selected drawable — a later slice),
per-pixel (non-bounds) selection∩target disjointness, and any on-screen
result.

Checks actually run on this branch: `swift build -j 2` and
`swift build -j 2 --build-tests` pass; `clang -fsyntax-only` with the
existing adapter flags (each `_engine/adapter/<ref>/compile.rsp` passed
as `@file`, plus `-I Sources/CGlimsEngine/include -I Engine` and the two
`GLIMS_ENGINE_*_PATH` defines, `-fvisibility=hidden -Wall
-Werror=implicit-function-declaration`, exactly as `build-adapter.sh`
compiles) is clean for `Engine/floating.c`, `Engine/engine.c`,
`Engine/clipboard.c` and `Engine/layer-source.c` on all four refs
(GIMP_3_2_8, GIMP_3_2_0, GIMP_3_0_8, master); `Engine/floating.c` is
additionally clean under `-Wall -Wextra -Werror` on all four;
`Engine/tests/engine-tests.c` and `Sources/CGlimsEngine/abi.c` pass
`-std=c11 -O2 -Wall -Wextra -Werror -fsyntax-only -I
Sources/CGlimsEngine/include`. NOT run here (the shared engine/adapter
lock belongs to the root job): `build-adapter.sh --test` conformance
(including the new `test_floating_selection`), any adapter
compile/link, `swift test`, the app's `--engine-smoke-test`, the engine
matrix, `scripts/test-conformance-abi.sh` and any on-screen check — no
runtime behavior of the new slots was executed in this slice.

Floating-selection runtime validation reproduced two production defects:
layer masks took the saved-channel-only admission branch, and Anchor could
write into a target locked after the paste. Mask admission now respects
its native subtype and Anchor rechecks the current target pixel locks.
The focused lock regression failed before the fix. All four native suites
pass after both fixes. Initial fixture errors are also corrected: choose
an installed font, capture baselines after the setup stroke and preceding
Anchor, and expect native To Layer to reveal the full payload after
removing the selection clip. That appearance uses an independent known
RGBA-cell oracle rather than assuming the clipped preview stays identical.








After integrating Indexed, one native conformance run failed during the
linked-file rewrite fixture and later crashed after cascading failures.
A bounded debugger run did not reproduce the crash and produced no
backtrace; its exact cause is unverified. The fixture did discard image
ids after refused closes and continued dependent setup after BUSY.
Its positive linked-file setup/cleanup now retries only pre-mutation BUSY
with finite deadlines, reports individual statuses, retains owned ids
until a real close, and stops dependent tests on setup/cleanup failure.
Negative BUSY assertions remain single calls. All four suites pass
1,459 / 1,245 / 1,459 / 1,459 checks. These runs observed zero retries in
this fixture; controlled slow-loader tests separately verify the native
BUSY contract. The earlier crash is not presented as a proven new UAF.

### Focused linked-close smoke (2026-11-08)

`GLIMS_SMOKE_CASE=linked-close` runs only `exerciseLinkedClose`
(`Sources/GlimsKit/EngineSmokeTestLinkedClose.swift`). Before the engine
starts, that case installs the slow-loader plug-in named by
`GLIMS_SMOKE_SLOW_LOADER_SCRIPT` into the throwaway user directory, points
`GLIMS_SLOWLOAD_DIR` at the smoke work directory and leaves the release
marker present. The scenario places a `.gslow` link, rewrites the file in
place, waits for the native link monitor's reload to park inside the
loader, then closes through `closeImageWhenDrained`: while parked, the
close stays deferred, the image stays alive (facade read-only oracle) and
the main loop keeps advancing; after the marker is released the close
completes exactly once and the native oracle reports the image gone.
Engines before 3.2 skip explicitly. Added compile-checked only
(`swift build`, `swift build --build-tests`); the runtime run is not
exercised on this branch and happens on the review root.

The linked-close smoke is now exercised. Replacing only EngineActivity's
close method with the earlier one-shot implementation reproduced two
failures: premature close completion during the paused loader and an image
still present after completion. The fixed retry method passes on GIMP
3.2.8, 3.2.0 and master; 3.0.8 explicitly skips unsupported link layers.
The final fixture requires NOT_FOUND specifically, stops on a missing
pause marker, checks that no app activity masks the native busy state,
and cleans up any image left by the deliberate red implementation.


### Ordered channel and path recall (2026-11-09)

The channel/path recall candidate uses the merged slots 136/137 to keep
ordered native selections, resolves saved-set members freshly by token and
uses exact readback. Several selected channels have no single paint target;
several selected paths have no active path. The Path tool consumes arrows
as well as Delete/Return/Escape rather than moving the paint layer or
floating selection. Single row picks narrow a batch safely. The visible
selection rows and Saved Sets panel geometry are checked separately from
button existence. See `item-set-recall-controls.md` for scope and evidence.


### Initial document placement (2026-11-09)

New/Open now materializes palette layout before choosing a document frame.
A pure geometry policy finds usable space around visible palette windows,
keeps later cascades inside it and preserves existing palette positions.
Initial Fit Image follows placement and layout. All four engines pass 15
real window/adoption checks, all 816 units pass, and the integrated pinned
app passes 2,121 checks. See `document-placement.md` for scope and limits.

### Per-window view rotation (2026-11-09)

View ▸ Rotate View rotates the existing AppKit canvas through a bounding host.
Clockwise/counterclockwise steps, fractional angle entry, reset and the window
title expose the state. Image pixels/history remain unchanged; pointer events,
overlays/text, fit/zoom/centering and projected equal-DPI rulers use native view
conversion. Guide orientation remains in image axes, while Hand panning follows
window displacement. Close cancels the owned angle sheet and frame observers.

Actual rotated rectangle gestures found affine noise expanding exact pixel
edges; only sub1e-7-pixel numerical noise is removed. Review found a fractional
tile sliver could create an invalid range or omit a partial tile. The half-open
floor/ceil range now covers both axes with finite/overflow guards.831 unit
tests,47 focused checks on each engine and2237 full app checks pass. Independent
source review covered the integration and corrected tile arithmetic. Exact-head
CI remains the merge gate; physical display transitions remain unverified here.

### Metadata copy fidelity and detached language preparation (2026-11-09)

The metadata equality guard now detects zero-count entries omitted by GExiv2's
public lists, including an empty LangAlt map also omitted by generated XMP.
A version-locked Engine-only C++ inventory bridge reads the pinned dependency's
complete collections; copying refuses conservatively instead of replacing the
image with lossy metadata. See metadata-preservation.md for the reproduced
failure, ABI/version boundary and validation matrix. Native dependency source
stays unchanged. A detached one-existing-language preparation function verifies
all admitted maps, unrelated data, native normalization stability and roundtrip
fidelity. It has no public writer slot or UI yet. Native conformance, 27 preparation
checks and 9 inventory checks pass on every engine; the normalization helper has
124 checks per engine. 838 unit and 14 script tests pass; bundle/CI checks pending.


### Captured plain-layer batch duplication (2026-11-09)

The additive API 1 slot 142 duplicates 1–256 explicit, ordered, unique
ordinary pixel-layer IDs. Preparation resolves the complete set and makes
detached copies before insertion. Each copy lands immediately above its source
in the source's actual parent. Existing locks are retained; structured layers
and groups remain available through individual duplication. Floating selections,
active native editing and disabled/frozen Undo refuse the batch. Ordinary
preflight refusals preserve image facts, pixels, tree, selection and history.

A native layer-add group makes the batch one Undo operation. A companion weak
selection record restores the original ordered selection on Undo and every copy
on Redo, including a reorder of the same members between commands. This is not
a general transaction: an unexpected Core insertion failure may leave a positive
output prefix as one recoverable Undo operation, and callers refresh on failures.

Command-J and the Layers palette capture their own document and cached selection,
refuse a pending replacement target, and refresh the native result through the
counted queue. The deferred refresh/completion remains counted through global
exclusive work, so close waits for accepted commands.

The public harness passes 123 checks on each supported engine, including exact
and shifted buffer overlap, explicit nested parents, one Undo, ordered selection
restoration, known red/blue pixels and independent binary mask pixels/flags.
The private preparation harness passes 101 checks per engine. The pending-target
regression reproduced three failures before its refusal guards were added, then
passed 11 real-window checks per engine. The expanded case passes 15 checks
per engine, including actual palette menu/button actions and pending-target
refusals. The integrated branch passes 863 unit tests; the packaged engine
also passes the 123 public checks with native and Swift build trees denied.
Full isolated app acceptance and exact-head CI remain in progress.

### Trackpad view navigation (2026-11-09)

The canvas responds to AppKit pinch and rotate events for its own visible
window. Pinch retains fractional zoom between events and clamps before
integer conversion; rotation applies the event's counterclockwise delta to
the current view angle, including phase-less events and external menu
changes. Both preserve the pointer's image coordinate when scrolling bounds
allow it. Pending tool interactions, guide drags, strokes and closing windows
refuse navigation; engine-exclusive work does not block these view changes.
No native pixels, metadata or Undo operation changes.

Source review found no important issues and 855 unit tests pass. The synthetic
AppKit-event case passes22 checks on each of all four engines: real windows,
pointer anchoring, two-document capture, busy/stroke/close guards and native
state invariance. The first run exposed AppKit angle quantization; relative
rotation now reads the controller's canonical Double angle. Physical hardware gestures and
wheel/modifier behavior are not certified by these tests.

### Single-language metadata controls (2026-11-09)

Image → Metadata offers Edit Language for a descriptor-confirmed language
alternative. The typed form uses exact existing keys from the owned engine
map, keeps separate local drafts, and applies only the selected key through
the counted document queue. Native refusals retain the draft. Closing a form
invalidates late callbacks while accepted edits still drain; host close
dismisses the child form. The public native API is merged in118, with39 public
and13 Undo-admission checks perengine. The real form passes14 controls checks
and13 counted document checks on every supported engine, including a host-close
regression that now explicitly ends and releases the metadata sheet.


### Option-scroll view zoom (2026-11-09)

Option-scroll zooms around the pointer in the owning document window, including
over the gray canvas surround. Precise trackpad deltas retain fractional zoom
through gesture and momentum phases; ordinary wheel notches use a separate
sensitivity. Normal scrolling still pans. Command/Control combinations, active
strokes, tool or guide drags, hidden windows and closing documents refuse zoom;
exclusive engine work allows these view-only changes. The native image and its
Undo history remain unchanged.

All 863 unit tests pass. The real-window case passes 19 checks on each of all
four supported engines, including native CGEvent panning, pointer anchoring
in a rotated view, event routing from the surround, phase boundaries, two
document capture and engine/stroke/close guards. These synthetic events do
not certify physical mouse or trackpad hardware.


### Preferences save during engine teardown (2026-11-09)

A deterministic regression holds a real RC autosave behind a ready higher-priority
idle until Quit. The old shutdown order then dispatches the save after destroying
the user context: RC save constructs dialog defaults and reaches a fatal
`gimp_fill_options_new` precondition. The adapter now disables future RC autosaves,
removes the exact pending source, and saves it synchronously while its context
is alive. The existing post-exit cleanup drain remains; unrelated queued work
is not dispatched early.

The regression passes five checks on each of all four engines, including exact
pending preference persistence. General conformance and the release bundle check
pass. No upstream source patch or facade slot change.

### Saved resource Rename and Delete (2026-11-09)

Brush, gradient and pattern choosers now manage eligible configured user files
through captured, counted Rename/Delete forms. Writable/deletable native data
must have a known format and a regular nonsymlink file directly in a configured
search-and-write directory. Every write reinspects an observed-state guard;
Duplicate remains available for resources that cannot be changed in place.
Rename preserves native identity/payload and file metadata; Delete commits disk
removal before native catalog removal and explains that image Undo cannot restore
it. Reference migration preserves unrelated settings/newer choices, leaves
malformed data untouched with a warning, and compares identities by native UTF-8
bytes. API version 1 appends slots 143–145.

All 871 unit tests pass. Public facade tests pass 26 checks per supported engine;
real chooser tests pass 38, plus 39 with an injected capability-read failure and
explicit Retry. Native fault/format tests cover failed saves/commits/deletes and
fresh loaders for GBR, GIH, VBR, PAT and GGR. See
[`resource-mutation.md`](resource-mutation.md) for admission, transaction limits
and exact coverage.


### Bump Map snapshot input (2026-11-09)

The source chooser captures a same-image drawable into owned native-format
tiles before creating the target preview. Bump Map applies to pixels with
one native Undo step; existing target effects remain above it. API v1
appends slot147. Other auxiliary/config operations remain unavailable.
See `filter-inputs.md` for policy and coverage. The expanded private/public
harness passes228 checks on all four engines; the actual chooser/editor
passes20 per engine. The self-contained bundle passes1,917 native and2,370
app checks, and871 unit tests pass. Native/UI source reviews have no
important remaining finding.


### Selection drag modifiers (2026-11-09)

Rectangle and Ellipse Select now share one finite image-space calculation
for live preview and commit. Shift keeps equal sides, Option draws about
the press point, and modifier-only events update stationary previews.
The press-time selection operation remains captured. Escape cancels
rectangle, ellipse or lasso drags without mutation, even with modifiers
held. Tool Options shows the hint. See `selection-modifiers.md`.
The baseline reproduced six ignored-modifier failures; the corrected
workflow passes21 real-window checks on all four supported engines and909
unit tests. Independent source review has no important findings. Final
integrated bundle validation remains open.


### Brightness/Contrast configuration (2026-11-09)

The dedicated native editor owns a normalized settings pair and immutable
config replacements, with default seeding before preview and guarded native
Undo. API v1 appends slots 148/149. New and existing-effect controls preserve
captured documents and committed settings. See `brightness-contrast.md`.
All four engines pass 177 dedicated native checks and 15 actual-window
checks. The integrated unit suite passes 909 tests; native and UI integration
reviews have no important remaining findings after the reproduced admission
fix. Final combined bundle verification is still running. Other four custom
config operations remain unavailable pending their dedicated editors.


### Native Color Balance configuration (2026-11-09)

Color Balance has a dedicated three-range editor over all nine corrections
and Preserve Lightness. API v1 appends slots150/151; changed settings replace
a private immutable native config. Delayed failures cannot silently seed
later edits with a refused correction. The real editor passes19 checks on
each engine, including two reproduced/fixed acknowledgement regressions.
See `color-balance.md` for validation and the separately recorded native
XCF blend/composite AUTO-normalization limitation. Other custom config
editors and full integrated release checks remain open.


### Native Image Adjust entries (2026-11-09)

The loaded Threshold and perceptual/linear Invert commands are available
under Image > Adjust as well as Filter > Color. Native and plug-in refreshes
preserve shared categories and unrelated content. Existing preview/Undo/XCF
behavior is reused. See `image-adjust.md`:915 units and27 real-window
checks pass on each supported engine, including independent pixel formulas.
Other custom adjustment editors remain separate implementation work.


### Native Hue/Saturation configuration (2026-11-09 candidate)

Master and six hue ranges have a dedicated degree/percentage editor with
global overlap and whole22-value immutable native configuration. API v1
appends152/153. Independent HSL, overlap/clamp and extended-lightness
oracles pass within387 native checks per supported engine. The actual
editor passes21 checks per engine;948 integrated unit tests pass. See
`hue-saturation.md`. Final bundle checks and CI remain
open; Levels/Curves and other auxiliary forms remain separate work.
### AOM license text discovery (2026-11-09)

The AOM 3.15.1 Git fetch has no MacPorts source archive. The bundler now
requires its original LICENSE from a verified source commit, checking the
reviewed SHA-256 on every cache read. It can use the matching MacPorts Git
worktree or a bounded, immutable upstream LICENSE request with redirects
refused. Unknown versions, missing text and mismatched bytes stop bundling.
The notice records the source URL and digest alongside the original text.

The focused offline suite passes10 checks; all24 packaging tests pass. A
real upstream request and repeated cache read produced the expected1,316
bytes, and actual core-source notices with a controlled AOM ownership entry
include those bytes without a missing-text placeholder. Independent source
review found and verified a redirect-body bound fix. The full self-contained
bundle contains the original AOM text and passes1,917 native and2,418 app
checks with build trees inaccessible. Corresponding-source delivery,
remaining components and signed public distribution remain separate work.

### Required engine license text (2026-11-10 candidate)

Engine notices now require a nonempty body beyond generated file headings
for every MacPorts component and GIMP/GEGL/babl. Blank installed/archive files
are skipped so discovery can continue; old heading-only caches are rejected
or replaced from usable source text. The error names the component and version
before replacing Engine-Notices.txt. Valid text retains the existing output;
AOM's verified commit/digest path is unchanged. Offline fixtures reproduced
the missing-lookup acceptance and the empty-body bypass before their fixes.
All 35 Python packaging checks now pass, including eleven notice-publication
fixtures and the ten AOM checks; valid fixture output is byte-identical before
and after. No engine or app was built or run for this slice. Corresponding-source
delivery and public release checks remain open.


### Typed capture-date metadata (2026-11-09 candidate)

The descriptor-gated DateTimeOriginal action opens a six-field local
calendar editor without changing timezone or subsecond companions. Its
strict fully specified ASCII subset preserves unsupported existing text
until an explicit valid replacement. The counted one-tag writer and
stale-document/close guards retain existing native metadata preservation
policy. See `metadata-capture-date.md`:16 focused model/policy checks and
931 total units pass, plus19 actual-window checks on the pinned engine.
Other engines, legacy-control regressions and final bundle checks remain open.


### Native Levels configuration (2026-11-09 candidate)

Five named channels retain all 25 endpoints/gamma values, global clamps
and an explicit transfer curve in a dedicated editor. API v1 appends
154/155. Equal and reversed endpoints remain valid; native configuration
replacement preserves older snapshots. Generic operation-only TRC writes
are refused, and commit validates both new and existing previews before
history changes. See `levels.md`: 956 unit tests; 492 focused native checks
on each 3.2/master engine, 475 on 3.0.8; 21 actual UI checks per engine;
and 1,917 native/2,520 app checks in the isolated final bundle. Histogram,
automatic stretch and legacy-mismatch editing remain open.


### Captured batch layer Fit (2026-11-09 candidate)

Layers to Image Size captures the ordered pixel-layer vector and preflights
every member before resizing any. API v1 appends 156; Native mask geometry,
selection/tree preservation and one outer Undo follow Core's resize route.
See `batch-layer-fit.md`: 964 units, 163 native and 21 UI checks per engine,
plus 1,917 native/2,542 app checks in the isolated bundle pass. Broader
batch/gesture policy remains open.


Curves candidate (2026-11-09): facade v1 appends157..160 for owned five-channel
snapshots, one-channel point/sample patches and global TRC updates. The dedicated
graph/numeric form and native immutable replacement are under acceptance; see
`curves.md`. Levels and Curves share exact native TRC binding installation.
Main #135 has merged captured batch Fit; its accepted bundle passes1917 native
and2542 app checks. This checkpoint does not close the remaining completion ledger.


2026-11-10 input histogram/Auto candidate: facade v1 appends161..163 for
owned source histograms and native Levels input stretching. Levels and
Curves share the histogram view, captured read controller and transfer-curve
reply fencing. Auto waits for acknowledged fields and keeps Cancel available.
Each engine passes78 native and19 form checks;977 units and existing
Levels/Curves focused regressions pass. See `input-histogram.md`. Final
self-contained bundle and CI remain pending; the broader ledger stays open.


### XCF point-effect supplements (2026-11-10 candidate)

The adapter now regenerates a bounded private supplement for missing Curves
HDR bypass and effect blend/composite state on XCF Save/Save Copy. Complete
load correspondence is validated before mutation; both write outcomes restore
the exact previous live carrier. Native name/mode aliases are normalized, and
unsupported graph/mask/table states refuse before writing. APIv1 stays at163
slots. All four engines pass121 focused checks plus the existing general
conformance suites;75 data-only parser checks pass. See `xcf-effects.md` for
format, ownership, external-editor limits and the remaining unsupported forms.
Final integration review, CI and the self-contained release remain pending.


### Transform modifier previews (2026-11-10 candidate)

Transform now recomputes its captured corner/rotation preview when Shift
changes without pointer movement, and consumes final release coordinates and
modifiers before ending the drag. A press/release within handle hit tolerance
keeps the captured geometry; returning to the press after moving restores it.
Preview and Escape preserve native pixels/history; existing Return admission
and the single-Undo apply path remain unchanged. The actual-event regression
first reproduced four missing routes; review then found the near-handle click
regression, reproduced with event and model checks before correction. All978
units pass, and36 actual-event checks pass on each of all four engines.
Independent final review and CI are pending.


### Typed XMP rights marker (2026-11-10 candidate)

The existing metadata sheet opens a captured scalar marker editor for
Xmp.xmpRights.Marked. Unknown text stays exact until an explicit choice;
absence remains distinct from False. Per-Apply descriptor reads, independent
SET/REMOVE gates and document-version checks precede the counted native edit.
All984 units and19 actual form checks per engine pass. See metadata-rights.md;
remaining metadata forms, review, CI and the final bundle are still open.

### Painting source consent (2026-11-10)

Layer-target painting and the shared pixel-command route now require explicit
rasterization of editable text/link/vector content. A captured owning-window
Rasterize/Cancel prompt consumes the original gesture and asks the user to draw
or apply again. Masks/channels keep their independent pixel targets. Fresh
queued source reads fence an earlier Undo, and captured-state checks reject
queued edits, retargeting and late window closure. The existing explicit source
restore remains available. See `painting-source-consent.md` for the measured
native text Undo/Redo issue and scope. Initial consent and two timing defects
were reproduced before their respective fixes; final integration checks are
in progress. The facade remains APIv1/163 and upstream sources are unchanged.

### Captured Variable Blur mask (2026-11-10 candidate)

Variable Blur now shares the immutable same-image source snapshot and
merge-only preview lifecycle with Bump Map, with blur-mask-specific labels.
Native and actual-menu regressions failed before their respective fixes.
All four engines pass 149 focused native checks and 24 actual UI checks;
existing conformance also passes. See `variable-blur.md` for the independent
pixel oracle, refusal guards and remaining auxiliary roles. The facade keeps
APIv1/163 and upstream sources remain unchanged. CI/review/integration follow.

### Exposure in Image Adjust (2026-11-10 candidate)

Exposure now joins Image > Adjust through the existing generic native filter
route, preserving Filter > Color and loaded-operation support gates. The actual
29-check menu/form fixture first reproduced exactly one failure, the missing
Adjust placement; its other 28 pixel, alpha, effect, Undo/Redo, XCF, ownership
and admission checks passed. The one-entry mapping change leaves those oracles
unchanged. Source `ddcabd4` passes29 actual checks on each engine with external
API165 producers and1,012 proper private leased units. Prior completed review
rounds cover byte-identical feature/fixture inputs; a subsequent reviewer
timeout is explicitly not approval. Latest integration CI and combined release
acceptance remain separate. See `image-adjust.md` for scope and evidence.

### Legacy Select Color source ownership (2026-11-10 candidate)

GIMP 3.0.8's seeded/by-color region algorithms retain an owned source buffer.
An exact-version adapter helper now materializes that buffer and runs the
unchanged algorithm through a private Pickable with owned, counted getters;
it balances only the references that legacy code omits. Modern engines keep
their native path, and upstream sources/facade slots remain unchanged.
The lifetime oracle reproduced one/two surviving buffers for one/two
selections before the fix; patched 3.0.8 passes all 12 ownership cases and 1,703
conformance checks. All 128 actual mask/history files match the immutable
original across 16 bounded RGBA fixtures. See
[`legacy-select-color-ownership.md`](legacy-select-color-ownership.md) for
ownership reasoning, controls and parity limits. Modern validation of the
patched source and independent review remain pending.

### Selective Gaussian contrast reference (2026-11-10 candidate)

Selective Gaussian Blur now has a captured contrast-reference chooser and the
installed numeric property form, using the existing snapshot guards, 512 MiB
bound and merge-only lifecycle. The native baseline reproduced one admission
failure among 33 checks; the actual-menu baseline reproduced one chooser failure
among three checks. All four engines now pass 128 focused native and 28 actual
UI checks, plus general conformance (1,917 checks on 3.2/master; 1,703 on 3.0.8).
Xcode 26 CI then exposed a Swift 6.2 type-checker limit in the fixture generator;
the expression is split into typed byte intermediates without changing its
pixels or oracles. CI rerun and final integration remain pending. Other auxiliary
roles remain separate work. See `filter-inputs.md` for the exact contract.

### Path lifecycle menu commands (2026-11-10 candidate)

Edit now exposes New Path and Delete Path beside Stroke Path and Fill Path.
Each responder action uses its owning document's existing path service,
including default names and native Undo. Validation reads cached edit and
path-selection state; Delete requires exactly one path, while New accepts
an empty or multiple selection. Floating selections preserve path editing.
The actual-menu regression reproduced the missing commands before the fix;
all-four-engine checks and final integration are tracked in the PR.


### Recorder capture, replay and palette (2026-11-10 candidate)

The first Recorder slice captures seven selection/image command families:
shape selection, color selection, selection commands, image transforms, scale,
canvas resize and crop. Immutable values settle in acceptance order behind
counted input; Stop fences new capture without dropping accepted work. Replay
uses the same image, revalidates drawable-sensitive bindings and floating
policy, and preserves normal native Undo behavior rather than guaranteeing an
entry for a no-op. Failure and Cancel stop later scheduling; accepted work may
finish and earlier changes remain.

The palette and Edit/Window menus show the supported scope, pending capture,
ordered outcomes and indexed replay failures. Removable Recorder subscriptions
preserve existing image-state/error callbacks and reject stale retarget replies.
All four engines pass the distinct capture36 (`f03ef62`), replay61 (`6cae7bb`)
and palette43 (`4e3189f`) matrices. The capture logs retain older engine resource
and cache diagnostics; this is not a clean resource-audit claim. See
[recorder.md](recorder.md) for behavior, scope and verification limits.

The subsequent Undo-copy correction awaits integrated validation. Combined
latest-Main/early-close/API164 builds, release checks and the final interactive
accessibility/layout pass remain pending. Long status clipping is an unverified
accessibility check, not a confirmed defect. Strokes, layer/effect capture and
recording persistence/cross-image binding are still open; the broad Recorder
completion item remains unchecked.


### View-local ICC soft proofing (2026-11-10 candidate)

APIv1 appends slot 164 with owned proof/display intents and BPC, preserving
slot132. Window-owned setup/toggle controls capture immutable ICC bytes and
render settings, fence stale tiles and never replace failed proof rendering
with unproofed pixels. Counted off-main profile loading/preflight drains before
image close. Native proof checks pass 293 per engine on all four supported
engines, including local CMYK and actual grayscale/indexed image sources.
An initial Babl encoding-space intent error was reproduced before correction.
The actual form passes 23 checks on each engine; 988 units pass. Integrated
release/CI checks and final review are pending. See `soft-proof-render.md` for the
read-only contract and remaining physical/HDR/proof-control scope.

### Rigi saved-group width growth adoption (2026-11-10 candidate)

Glims stages Rigi revision `a5801f2` for the saved palette-group width growth
fix. Rigi's 134 unit tests, gallery smoke, release build and independent review
passed at that revision. Rigi PR #19 is merged after CI and completed review;
this pin is its exact tested head, now an ancestor of Rigi main. Glims passes
988 unit tests and 2,771 engine-backed app checks with this pin.
Consumer CI, review and adoption merge remain pending.

### Installed MacPorts recipe inventory (2026-11-10 candidate)

The standalone `scripts/installed-port-provenance.py` inventories requested
installed recipes and recorded PortGroups through immutable SQLite reads,
checking exact original hashes/sizes and database/WAL/rollback-journal stability. It refuses
implicit output overwrites and never writes inside the source prefix.
Nineteen temporary-registry fixtures pass; a read-only aom/zlib/libidn2 sample
verified metadata with the registry DB/WAL/SHM unchanged. Source completeness
is explicitly not assessed: no Tcl evaluation, conditional patch inference,
source archive or release integration is added. See
[`installed-port-provenance.md`](installed-port-provenance.md) for usage and
evidence limits. Independent review/integration remain pending.

### Foreign XCF effect fields (2026-11-10 candidate)

The initial plain XCF v22–26 reader binds metadata to the complete unpublished
native layer/group/mask/channel tree before restoring blend space, composite
space and composite mode. Whole-image validation precedes every setter;
source files, raw buffers, Undo and supplement state are unchanged. Native
negative-AUTO encodings and the pinned writer's identical unregistered
triplet have separate, narrow compatibility rules. Size/ETag and available
device/inode comparisons detect observable source changes, without claiming
an FD-bound or adversarial ABA attestation.

The ordinary baseline reproduced four failures among 41 checks. Expanded
admission passes 61 checks and the pure decoder passes 75. A separate
3.2.8/v26 native complex oracle reproduced eight failures among 43 checks,
then passed all 43 with four literal 2/2/3 triplets and zero float deltas.
General conformance passes 1,917 checks on 3.2.8/3.2.0/master and 1,703 on
3.0.8; the existing 121-check supplement suite passes on all four. The actual
Selective Gaussian menu smoke passes 28 checks against the context prefix;
normal foreign-file GUI acceptance is separate. An earlier strict decoder
and native-writer interpretation caused ten general failures, fixed before
this matrix. Source-only loader/binding audits are recorded; this authored
documentation is not another independent approval. See `xcf-effect-fields.md`
for hashes, oracle scope and the later legacy and gzip extensions.
Fresh API165 integration source`c0acf2d` repeats all-four general conformance
and pinned original41/complex43 checks. Independent Glyph review covers the
unchanged seven production files; the earlier hosted timeout is not approval.
A separate ordinary LaunchServices foreign-file event passed; the actual
File Open chooser and final integrated release remain unverified. Required
latest-head CI/review/integration and broader preservation work stay open.

### Legacy XCF effects

Glims opens plain XCF 20 and 21 while preserving explicit effect blend and
composite settings. Those versions do not encode an operation version;
version 22 and later keep the strict existing operation-version check.
Two formerly refused files now match direct native rendered pixels and
preserve their effect masks, original bytes and empty opening history.
See [the native and parser checks](xcf-effect-fields.md#legacy-effect-records).

### Gzip XCF effects

For a local single-member gzip XCF, GIMP and Glims's foreign effect reader
now read the same private decoded stream. A pinned native test reproduced
two failures when the pathname briefly pointed to another image with the
same topology; the shared-spool implementation passes all 117 checks,
including source and rendered pixel equality. The original file identity
and lexical parent still go to GIMP. See
[the gzip scope and evidence](xcf-effect-fields.md#gzip-wrapped-effect-records).

### Accepted RPC caller drain (2026-11-10 candidate)

Native stop now closes external admission, cancels running plug-ins without
quitting the outer context, drains registered callers through caller-side
result acknowledgement, then quits/joins and frees control storage. Explicit
source attachment preserves normal RPC priority; queued unstarted calls get
NOT_RUNNING and direct internal continuations keep their behavior. One external
owner must prevent new lifetime entry racing stop; stale handles, concurrent
stop owners and callback reentry are not added guarantees. No facade slot or
upstream source changed.

The frozen lifetime oracle reproduced two failures among 13 checks, then passed
13/0 with `4d39894`. Separate queued/late admission passes 20/0 at `870e57b`.
All four native suites pass (1,917 each on 3.2.8, 3.2.0 and master; 1,703 on
3.0.8), including the unchanged running-plug-in stop assertion. The 3.0.8
cache-queue/two-buffer and master cached-XML diagnostics remain in the logs.
The earlier 5037/10146 ms outliers remain unlocalized; this fix makes no claim
to explain or resolve them. See [engine-call-drain-oracle.md](engine-call-drain-oracle.md)
and [engine-call-admission-oracle.md](engine-call-admission-oracle.md) for exact
ownership and evidence limits. Independent review is running; CI, PR and
integration remain pending.

### Captured batch Rasterize (2026-11-10 candidate)

API v1 appends slot165 for an explicit ordered retained-source vector. The
owned plural sheet captures document, IDs and names; Cancel queues nothing,
and Apply rechecks cached and native admission before converting those same
sources as one Undo. All targets are validated before normal mutation;
unexpected Core failures can leave a changed prefix and report that limit.
Counted completion drains before close, and late sheet Apply cannot add work.

Each supported engine passes 96 focused native checks using retained text
sources. This is not link/vector fixture coverage. General checks pass
1,917 on 3.2.8/3.2.0/master and 1,703 on 3.0.8. Initial sole stop-timing
failures at 5,037/10,146 ms remain recorded beside passing private repeats,
without a causal claim. The pinned actual UI passes all 51 checks with real
Cancel/Apply, A capture while B is key/main, readiness/refusal and close drain.
Its focused smoke host now completes real AppKit launch and dispatches events;
no production activation defect is inferred from the earlier unlaunched host.
See `batch-layer-rasterize.md` for exact scope, hashes and remaining validation.
Other-engine UI, current units/integration, CI/review and merge remain pending;
batch Restore and the broader gesture-policy item stay open.

### Visible working-profile state (2026-11-10 candidate)

Document titles now include the effective working-profile label from the
existing color-state cache, separate from display/proof configuration.
The actual old window failed five new profile-title checks while retaining
50 existing passes; the corrected window passes all 55 on every engine,
plus 1,015 units. See [working-profile-title.md](working-profile-title.md)
for exact foreground-host and external AX limits. Hosted CI/review and final
integration remain pending.

The Main165 transport integration also passes fresh all-four conformance
and unchanged 13/20 transport fixtures. Completed review identified a test
driver interruption-cleanup gap; eight tests reproduced it before correction
and now pass, with all 62 packaging checks. See the drain oracle's integration
section for exact source/producer limits. Latest-head hosted gates remain
pending after the driver fix.

### Typed XMP Rating controls (2026-11-10 candidate)

Image Metadata adds explicit absent, zero, rejected and one-through-five
choices while retaining unknown original text until an explicit choice.
Fresh scalar descriptor checks and independent SET/REMOVE gates use the
existing counted preservation writer. The focused Rating and batch Rasterize
fixtures share the launched AppKit host. See [metadata-rating.md](metadata-rating.md)
for exact scope, prior checks and current runtime/review gaps. This does not
close the remaining typed metadata or final integration items.

The Main165 Rating integration passes 1,028 units, all 54 actual typed-edit
checks and all 51 shared-host batch Rasterize checks on each of four engines.
Owned processes exit zero and desktop leases are released. The 3.0.8 batch
case's immediate external AX snapshot was incomplete; its owned teardown and
later final desktop checks pass. Present-empty seed refusal remains explicit,
and current hosted CI/completed independent review remain pending.

### Captured Close All (2026-11-10 candidate)

File > Close All uses the existing sequential close/save/drain flow for a
captured document set and stops on Cancel or failed Save without quitting.
A later Quit joins the in-flight close request. The old menu/validation
baseline failed three assertions; the corrected source passes 1,014 units
and all 26 focused checks on every engine. See
[close-all-documents.md](close-all-documents.md) for exact host/review limits
and remaining real responder/Quit/file-completion acceptance. Hosted gates
and final integration remain pending.

### Captured batch Restore sources (2026-11-10 candidate)

The Layer menu and Layers palette confirm a captured ordered source vector,
then regenerate it through appended slot166 as one native Undo with counted
exclusive close draining. All-four focused native163/163/114/163, general
1,917/1,917/1,703/1,917, actual UI48each and1,020 private leased units pass.
The independently measured native linked-file Redo display/source ordering
is explicit. No atomic rollback or self-contained release claim is inferred.
See`batch-layer-restore.md` for exact source/proof scope, AX and fault gaps.

### Layer opacity in Layers (2026-11-10 candidate)

A persistent captured-owner percent field/slider now gives opacity its planned
home in Layers. The modal Properties duplicate alone is removed. Native
property gates, draft/retarget ownership and counted reconciliation preserve
paint targets and close lifetime. Old rowless baseline6/1; actual all-four
controls74each and1,012 private leased units pass. See`layer-opacity-controls.md`
for source, branch counts, AX gaps and remaining hardware/accessibility review.

### Tool Options names and label relationships (2026-11-10 candidate)

Existing setting popups and selection Mode now have explicit accessible
names and their existing visible label association. The actual AppKit control
regression ran two tests with ten baseline failures, then passes both after
the five-line fix; all 1,014 private leased units also pass with final clean
AX snapshot and lease release. Independent review, CI and actual keyboard/
VoiceOver acceptance remain separate gates. See
`tool-options-accessibility.md`; no new control or action was introduced.

### Negative Darkroom captured source (2026-11-10 candidate)

The existing source chooser now offers a detached dodge/burn map for Negative
Darkroom and explains that Apply makes filtered pixels opaque. Old source
admission failed exactly one native check; corrected all-four focused194,
general1,917/1,917/1,703/1,917, actual UI39 each and 1,015 private leased
units pass. No new facade slot or upstream patch. See
`negative-darkroom-source.md` for independent native references, ownership,
Undo and remaining review/AX/final-release gates.

### Channel main-menu parity (2026-11-10 candidate)

Eight existing channel actions now have main-menu routes with shared cached
single-saved-channel and pending-work gates; context clicked-row behavior is
unchanged. Old Main reproduced two missing-submenu failures. Corrected actual
all-four UI56 and 1,016 private leased units pass. A preserved initial fixture
failure led to exact native multi-setter history comparison and a latched wait,
not changed production semantics. See `channel-menu-parity.md` for scope and
remaining independent review, CI and combined-release gates.

### Native layer picking (2026-11-10 candidate)

An additive facade query delegates read-only hit testing to Core, with
checked coordinates/offset arithmetic and reset-on-failure output. The
focused fixture passes 156 checks per engine, old166 reports the expected
missing-slot failure, and all four general runs pass 7,454 checks. Exact
source-bound threshold expectations and the measured converted-mask test
correction are documented in [native-layer-picking.md](native-layer-picking.md).
Canvas gesture consumers, hosted CI/review and final integration remain
pending.

### Temporary hardware eraser (2026-11-10 verified candidate)

Per-device proximity may borrow Eraser for a matching pointer press without
replacing ToolState selection. Space/Command/Option and captured-stroke behavior
remain in their existing paths; no facade, axes or coalescing changes. At
`ca815e1`, the actual launched synthetic-event/native-pixel case passed 21 checks
on each of GIMP 3.2.8, 3.2.0, 3.0.8 and master (84 checks, zero failures), all
with recorded exit 0. A private full-unit run passed 1,059 tests, including nine
tablet tests. The original eight policy passes did not expose a tracking-event
subtype exception; its incomplete/terminated launches and the correction are
retained separately, not relabelled as successful eraser runs.

Focused post-run AX captures and all desktop-release receipts succeeded. The
full-unit immediate AX capture failed with window-not-found despite exit 0 and
release, so that cleanup-verification gap remains explicit. Existing launcher
and engine diagnostics are preserved. Physical hardware, combined integration,
latest-head CI, publication review and merge remain open. See
`tablet-eraser-proximity.md` for the event ownership contract, exact run IDs and
aggregate receipt path.

### Spring-loaded tool letters (2026-11-10 candidate)

Tap selects; Shift+letter cycles; hold or use an interaction temporarily
selects until its captured interaction finishes. New explicit selections and
text focus retain priority. A measured focus-loss regression (two failures)
is corrected; all four engines pass 83 interface checks, plus 18 state tests
and 1,033 isolated full-suite tests. See [spring-tool-letters.md](spring-tool-letters.md)
for exact revisions, review scope and remaining physical-input/release gates.

### Live canvas tool hints (2026-11-10 candidate)

Stationary modifier/tool changes update useful hints while preserving error,
progress and activity priority. Same-window field focus clears lost modifier
releases; its measured six-failure regression is fixed. All four engines pass
51 interface checks and the full isolated suite passes 1,022 tests. See
[live-tool-hints.md](live-tool-hints.md) for scope, AX and integration limits.

### Tool and color menu parity (2026-11-10 candidate)

View > Tools exposes all 26 existing tools plus shared Swap/Default Colors,
with stable command IDs and no factory canvas-letter equivalents. All four
engines pass 106 actual menu/field/native-invariance checks; 1,021 isolated
unit tests pass. See [tool-color-menus.md](tool-color-menus.md) for the scoped
key-equivalent oracle correction and remaining CI/integration limits.

### Per-document screen modes (2026-11-10 candidate)

Canvas F, View > Screen Mode and the Tools palette select Windowed,
Full Screen with Menu and Full Screen Bare. Owned modes resize the document
in place, preserve palette visibility, and restore frame/style/presentation;
native full-screen callbacks cannot acquire owned presentation without a
snapshot. Rigi `13ec06a` provides explicit document focus eligibility.
Normal File > Close routes through the existing save/cancel flow even when
an owned borderless window has no title-bar close button.

The expanded focused fixture passes 77 checks on every engine, 308 total,
and the full XCTest run passes 1,025 tests. Every recorded process exited
zero and released the desktop; immediate screen/AX observations report
Finder and no dialog, without proving a complete desktop inventory.
Earlier native-Space menu-policy and bare-window Close failures remain
recorded. See [screen-modes.md](screen-modes.md) for behavior, source/evidence
scope and limits. Physical interaction, multi-display/accessibility audit,
final combined release, hosted CI/review and integration remain pending.

### Recorder layer property commands (2026-11-10 candidate)

Accepted name, visibility, opacity and mode changes now capture immutable
semantic values with a freshly checked explicit same-document layer
binding. Both write routes retain counted reconciliation/callback order.
The actual old opacity control produces the expected zero-capture RED;
new36 checks and the unchanged Recorder capture/replay/palette checks pass
on all four engines (712 total), plus1,050 unit tests. See
[recorder-layer-properties.md](recorder-layer-properties.md). Persistence,
other command families, hosted CI/review and final integration remain open.

### Captured floating Text creation (2026-11-10 candidate)

A new editor owns its complete original floating expectation. Native168
prepares before anchoring and inserts in one normal Text Undo; stale or
unsafe requests refuse, with truthful reconciliation after late failure.
The old frontend fails18 of51 checks; the unchanged fixture now passes51 on
every engine, plus1,050 units. Native170 checks per engine and all7,454
general checks pass. See [text-floating-creation.md](text-floating-creation.md)
for scope and the existing Escape Apply/close policy. Hosted CI/current
feedback, combined integration and final release remain separate gates.


### Move Target modes

Move keeps Current Layer by default. Pick Layer or Guide uses the native
opacity hit at press and keeps the captured target through release. Escape,
focus loss and an explicit newer target are distinguished, including when
an exclusive engine operation delays restoration. Tool Options and View >
Move Target share one setting. The combined editor passes 1,712 focused
checks across four engines and 1,115 unit tests, including Spring, modifier
hints, Text and the existing Tools menu. See [floating selections](floating-tool-policy.md).


### Oilify source maps (2026-11-11 candidate)

Oilify now has optional same-image Radius and Exponent source choosers.
Plain and mapped applications share native170's owned snapshots,
merge-only preview, cancellation and one-Undo commit. All four engines
pass184 native and44 actual form checks each; the independent oracle
exporter passes20 per engine and general conformance passes7,454 total.
The corrected History fixture and full pinned editor pass3,231 checks.
See [Oilify evidence](oilify-native-oracle.md) for the reproduced fixture
race, source review and remaining integration/release gates.


### Captured floating gestures and stationary picks (2026-11-11 candidate)

Rectangle, ellipse, Lasso, Wand and Select by Color now retain the original
floating identity through their measured pointer-release policies. Native
opacity reads, empty-mask checks, pixel locks and worker admission remain
captured and cancellable. Pick Layer or Guide also preserves geometry,
clean state and Undo when a stationary click is near a snap target; real
drags keep snapping. The combined source passes924 focused checks across
four engines and1,115 unit tests, with independent source review. The
stationary defect was reproduced before its fix. See
[floating-tool-policy.md](floating-tool-policy.md) for exact behavior and
remaining final-release scope.

### Durable recordings and complete ordinary strokes (2026-11-11 candidate)

Recorder files now retain named, settled semantic logs, explicit target
descriptions and guarded cross-image bindings. Save/Load use owned native
panels and bounded atomic file transactions. Close, Quit and Revert separately
protect unsaved recordings and image pixels, including a detached save of
accepted work in an active recording. Cancel leaves the original recording
available.

Pencil, Eraser and Paintbrush gestures capture immutable settings, ordered
V1 samples and supported brush/configuration fingerprints. Replay validates
the brush and explicit pixel-layer binding before painting; unsupported
capture stays a failed row while ordinary live painting can continue.
Successful strokes use the closed version-2 format, preserving version-1
files for other supported semantic commands.

The combined native foundation passes8,870 checks across four engines.
Recorder capture22, saved-file26, actual Paintbrush canvas23, earlier
Pencil/Eraser canvas23, Revert10 and real Quit13 each pass on all four.
Latest-Main source `555792d` passes1,195 units and independent file/consent
source review. See [Recorder](recorder.md), [its file format](recorder-file-format.md)
and [the native boundary](stroke-capture-and-tablet-input.md). Hosted CI,
final publication feedback, optional tablet-axis frontend delivery and the
final combined bundle remain separate gates; other semantic command families
are still outside this capture scope.

### Captured optional tablet axes (2026-11-11 candidate)

Matching proximity capabilities now select a press-fixed V2 input route for
rotation and signed tangential pressure. Mouse/no-capability gestures retain
V1; the accepted document, brush and capabilities cannot be retargeted mid-drag.
Checked timestamps avoid integer traps, invalid release still Ends accepted
work, and portable Recorder capture explicitly refuses optional-axis traces
without preventing live painting.

The admitted baseline's single missing-axis failure is corrected. Latest-Main
source `4129720` passes32 actual pinned-engine checks with41 Core telemetry
rows and all1,205 unit tests; independent source review finds no important
issue. See [optional tablet axes](tablet-optional-axes.md) for the test-only
window-local event correction, physical/coalescing limits and remaining
all-four-engine, CI and final standalone-app gates.

### Complete cold filter discovery (2026-11-11 candidate)

A fresh engine can expand its catalog during enumeration. The reproduced
131-to-183 growth previously left the first menu with a truncated response.
The Swift reader now retries checked growth and refuses invalid or persistently
changing counts. Complete lookup storage retains internal operations, while
human menus omit untitled GIMP infrastructure and give unnamed external
operations useful labels.

The observed old first-response failure and three label assertions are fixed.
Latest-Main integration `bf37550` passes16 fresh native-backed checks across
four engines and all1,216 unit tests, with independent source review. See
[catalog completeness](filter-catalog-completeness.md). Hosted CI and the
standalone application remain final integration gates.

### Revert load fixture ordering (2026-11-11)

The broad bundle's three Revert-close failures were reproduced as an
expired test delay, before Recorder consent and the real load. The test
now holds the real input queue after consent, requests Close while held,
and explicitly releases it with a permanent timeout fence. Production is
unchanged. The original assertions plus two ordering checks pass23 on
each engine; the ordinary full bundled debug workflow passes3,233 with
build trees denied. Source review found no important issue. See
[`revert-load-fixture.md`](revert-load-fixture.md) for the exact sources,
execution scope and final-release limits.

### Native filter colors and linked control readback (2026-11-11)

Colorize, Offset and Semi-flatten expose their GIMP color parameters through
the existing typed facade. Generic forms read actual linked values behind
the write in one counted input job, preserve newer queued/text drafts and
restore refused fields without echoing a value the engine changed. Native
baselines reproduced nine missing-color assertions; the actual Colorize
form reproduced four acknowledgement failures. All four engines now pass
223 focused native, 64 actual form and 7,454 general native checks, with
1,216 unit tests passing. Native and Swift source reviews found no
important issue. See [`gimp-filter-colors.md`](gimp-filter-colors.md) for
source revisions, Offset's native gate differences and release limits.

### Lens Blur optional mask (2026-11-11)

Lens Blur now starts with explicit None for uniform blur or captures a chosen
same-image Blur mask. Its modeless property form applies to the original
target as one pixel Undo, even while another document is main/key. Native
admission bounds real luminance conversions, tile/storage coordinates,
radius arithmetic and aggregate worker scratch before copying or mutation.
Both property setter paths and commit retain the bounded contract; imported
Lens effects remain outside parameter editing.

Combined source `5c0ef00` passes 1,220 unit tests, 648 focused Lens native
checks, 76 actual-window checks and 7,454 general native checks across the
four engines. Independent native and Swift production reviews found no
important issue. See [`lens-blur-source.md`](lens-blur-source.md) for the
observed baselines, captured-map lifetime and exact evidence limits. Final
standalone packaging and whole-editor completion remain separate gates.

### Restore consent for rasterized text (2026-11-11 candidate)

Text clicks now recognize retained rasterized text and offer owned
Restore/Cancel instead of creating an unrelated empty editor. Restore uses
its original document/layer and counted native command, then requires a
fresh Text click; close and stale consent cannot revive old editing work.
The intended old-code failure was observed before implementation. Latest-Main
source `0431845` passes 92 consent and 204 existing floating-Text checks across
four engines, plus 1,220 unit tests. Independent production source review
found no important issue. See [`text-source-restore-consent.md`](text-source-restore-consent.md)
for the independently adjudicated status-oracle correction and exact limits.

Current-source audits also confirm that batch Restore, all planned Image
Adjust placements and the descriptor-supported typed metadata forms are
already present. The completion ledger now names those finite capabilities;
it does not infer blanket batching or every possible metadata schema editor.

### Explicit palette keyboard entry (2026-11-11 candidate)

Window menu palette commands use Rigi's explicit focus API; automatic layout
continues to preserve document focus. The old Recorder key-window failure is
reproduced, then fixed in the normal application host: 12 checks pass on every
engine, including real Tab dispatch, document pixels/Undo preservation and
owned teardown. The consumer's 1,220 unit tests and Rigi's 143 native tests,
Gallery smoke and release build pass. See
[`palette-keyboard-focus.md`](palette-keyboard-focus.md) for exact scope and
the separate full accessibility audit.

### Bzip2 and XZ foreign XCF recovery (2026-11-11 candidate)

Compressed XCF uses one bounded decoded snapshot for native loading and
supported foreign effect fields, retaining the original file identity.
Both previously refused formats now pass the pinned 47-check field/pixel
oracle. All four engines pass 7,454 existing native and 136 codec checks;
the unchanged gzip identity regression passes 117 checks and the ordinary
editor workflow passes 3,233. Independent production source review found no
important issue. See [`compressed-xcf-fields.md`](compressed-xcf-fields.md)
for stream limits, exact coverage and the separate standalone-release gate.

### Accessible committed-filter selection (2026-11-11 candidate)

The filter-selection badge now exposes its existing selected/unselected label
as an accessibility image. Its old AX element/role failures are reproduced
and fixed; all 13 focused AppKit tests and 1,222 integrated unit tests pass.
Independent source review found no important issue. See
[`effect-selection-accessibility.md`](effect-selection-accessibility.md) for
scope and the separate spoken VoiceOver/full-keyboard audit gates.


### Soft-proof gamut warnings (2026-11-11 candidate)

The existing window-owned Soft Proof Setup adds a captured Gamut warnings
option. Owned flag 2 extends slot 164 without changing the 173-slot API layout;
Engine maps it to the native proof transform and leaves LCMS global alarm
settings untouched. Independent gamut pixels, alpha and state preservation
pass484 checks per engine on all four supported engines. The pinned actual
form and Swift bridge pass25 mandatory checks, and all 1,229 units pass.
Independent source review found no important issue. Latest-head CI and final
integration are pending. See [soft-proof rendering](soft-proof-render.md)
for the full contract and hardware/HDR limitations.


### Native float color sampling (2026-11-11 candidate)

The Color Picker and Option-paint sampling now use a straight nonlinear sRGB
double read from the native projection, before display-byte quantization.
Owned output type and slot 174 extend API version 1. Opaque tool colors keep
native fractions and explicitly report clipping of extended samples to the
editing range. Image pixels, profile, selection and Undo stay unchanged.
The independent native fixture passes 480 checks across four engines, and
the actual picker/wide-gamut workflows pass 48. General conformance and codec
checks pass on all four engines; source review found no important issue.
Latest-head unit/CI and final packaging remain pending. See
[the sampling contract](float-color-sampling.md).


### Numeric foreground and background colors (2026-11-11 candidate)

The Tools swatches open an owned editor with simultaneous RGB Percent and
Float entries and a native color well. Full fractions are retained, invalid
drafts preserve the current color, and session/control identities fence late
callbacks across foreground/background switches and close/reopen. All 1,242
unit tests pass, including controller and unsupported-well recovery checks.
Two independent source reviews found no important issue. Latest-head CI and
final integration are pending; see [numeric tool colors](tool-color-numeric.md).


### Final editor integration (2026-11-11 candidate)

The final integration combines the independently reviewed native float
sampling, numeric tool-color editor and status information slices. Glims
pins merged Rigi `3f277226df3b5b66c5198d4cb4acd64fc14fe544`, whose 154
unit tests, gallery smoke, release build and native CI pass. Popovers read
and observe the workspace Reduce Motion policy on the main queue.
The final color-menu check reproduced seven failures with the missing
foreground/background commands. Both menu commands and swatches now share
one editor; all 1,249 combined unit tests pass, including actual panel
switching and foreign-sender refusal. The broad source review found no
important issue; the small menu delta has its own follow-up review. Four-engine ordinary
workflows, latest-head CI, final standalone assembly and interactive checks
remain pending at this checkpoint. The completion ledger separates the
implemented editor from public distribution and physical-display gates.


### Integrated editor verification (2026-11-11)

PR #198 merged the remaining fractional color, numeric editor, status and
Reduce Motion adoption changes. All 1,249 units and 13,166 ordinary workflow
checks across the four engines pass. The pinned release app passes 1,917
native and 3,298 editor checks with development trees denied and no engine
override. Ordinary pointer painting, fractional entries, XCF Save/Quit/reopen,
PNG export and all three appearance schemes have separate on-screen evidence.
A passive normal launch needs no input: the isolated cold run took 58.5 seconds and
the cached restart 1.2 seconds after the launch handshake. The final Help follow-up
corrects the obsolete mask and three-choice Preferences descriptions.
See [editor verification](editor-verification.md) for evidence boundaries,
source-review failures that were not counted as approval, and the public
release, spoken-accessibility and physical-display qualification gates.

### Five-second startup and editor quality targets (2026-11-11 candidate)

The expanded user brief is tracked in [quality-targets.md](quality-targets.md);
notarization is explicitly excluded. The previous verification totals do not
establish Photoshop 4 parity or complete usability.

Startup now packages a relocatable command registry after signing inner
executables. A fresh matching engine/language can seed it exclusively; native
path, mtime and protocol checks still discover changed and custom plug-ins.
A separate native font helper links bundled HarfBuzz and uses CoreText to
locate downloaded font assets. Its config keeps ordinary/user font roots but
omits the broad macOS Assets scans. The original native config remains the
failure fallback. No system-font caches or font outlines are shipped. The
helper alone runs with a non-root working directory to avoid a reproduced
Fontconfig 2.18.3 absolute-glob bug; the application does not change global cwd.
The optional helper has a three-second deadline. A stalled child is killed
and reaped before native discovery resumes; its wait dispatches only a private
GLib context. A CLI regression covers the deadline, reaping, working directory
and success/failure paths without starting the editor. The packaging probe
also confines its working directory and startup diagnostics to its temporary
home, and catalog checks require a newly written report on every run.

Integrated packaged launches reached the document in 2.70 seconds with fresh
Glims data, 1.72 seconds cached, and 4.09 seconds relocated with fresh data.
These are local measurements, not disk-cache-flushed or cross-Mac guarantees.
The startup regression script compares font/command catalogs through corrupt
caches, user font installation/removal, relocation, incompatible registry and
missing-helper fallback. All pass. Corrupt command caches and incompatible
registries use slower native discovery (about eleven seconds). The 128
packaging checks and all four adapter suites pass. The integrated standalone
bundle passes 1,917 native and 3,310 application checks with development
trees denied. Other Macs, old preference collections and arbitrary custom
plug-in changes remain outside this qualification.

### Typed transform controls (2026-11-11 candidate)

Transform options now edit X/Y, Width/Height and clockwise Angle through the
existing pending canvas preview. Apply creates one native Undo step; Cancel
does not edit pixels. Captured document/layer/session identities reject late
field callbacks, while invalid drafts survive refresh and block Apply. The
options scroll in short palettes instead of compressing controls away.

Geometry, draft, accessibility and full unit checks pass. The native AppKit
workflow verifies real text input, preview/cancel, exact Undo/Redo pixels and
stale selection refusal. Independent reviews cover the implementation and
the subsequent focus and palette fixes. See [numeric-transform.md](numeric-transform.md).
This does not close skew, distortion or perspective support.

### Dedicated tonal adjustment layers (2026-11-11)

New Adjustment Layer offers Levels, Curves, Color Balance and Hue-Saturation,
using the same owned native configs and committed-effect editors as ordinary
layer effects. The existing empty pass-through group remains the adjustment
layer: creation is one Undo step; cancelling the subsequent parameter edit
keeps that explicitly created layer.

All four engine sets pass 203 focused native checks, including neutral
creation, unchanged underlying pixels, typed edits, cancellation, exact
Undo/Redo output and editable XCF reopening. The Swift suite passes 1,250
tests. This closes the tonal-picker gap in the broader editor brief; it does
not establish complete Photoshop 4 parity or final application acceptance.

### Projective transform foundation (2026-11-11 candidate)

The owned Swift transform type now carries all nine homogeneous coefficients,
with checked composition, inverse mapping and a rectangle-to-quad solver.
The native boundary normalizes equivalent matrices and refuses horizons,
invalid source/output coordinates and excessive destination storage before
editing. The shared 512 MiB budget includes descendants, attached masks and
containing-group growth, using raw projection extents even behind a group
mask. It bounds destination storage, not total working memory or Undo history.
Active unclipped effects require merge or disable because their future extent
cannot be predicted from their old margins. Ordinary clipped effects retain
their existing path.

All four native suites pass analytic perspective pixels, equivalent positive
and negative matrix multiples, negative source origins, masks, exact Undo/Redo
and XCF reopen. Bounded regressions reproduced both ancestor growth and a
masked raw-projection admission gap before their fixes. The pure geometry has
21 tests; the integrated Swift suite passes 1,287 tests. A focused native
Swift bridge workflow verifies the complete coefficient mapping. Independent
direct review is complete; a timed-out SWE-2 review supplied no verdict and
is not counted as approval.

This foundation does not expose skew/distort/perspective canvas modes yet.
Captured-target atomic commits, the new handles, warped pixel previews,
structured-layer qualification and large-image interaction timing remain
separate work. It does not establish Photoshop 4 parity.

### Readable precision labels (2026-11-11 candidate)

Document titles, the status information selector and Image Information use
the same readable component and transfer-curve labels, such as
"16-bit float · Linear", instead of internal format names. Unknown typed
state remains "Unknown"; profiles and underlying color behavior are unchanged.
All 1,266 unit tests and the existing native conversion/form/Undo/reopen
workflow pass. Independent SWE-2-Flash review found no important issue.
### Threshold in the adjustment chooser (2026-11-12)

New Adjustment Layer also offers Threshold. `gimp:threshold` is a generic
single-input operation — not a dedicated config op — so no engine change was
needed: `adjustment_layer_new` already admits it and the generic
effect-parameter session edits its `low`/`high` properties. The chooser's
known set simply lists it; the runtime catalog's support gate still decides
whether it is offered.

The focused native suite passes 229 checks on each of all four engines, including
threshold creation, non-default low/high edits against a literal
max-channel composite oracle, untouched base pixels, exact Undo/Redo output,
Cancel, an indexed refusal and editable XCF reopening (reloaded parameters
read back within serialization tolerance). Swift and real chooser/editor
checks are pending.

### Recorded affine layer transforms (2026-11-11 candidate)

The Recorder captures committed layer transforms with an explicit layer
symbol, the six image-coordinate coefficients and a named interpolation
choice. Saved format version 4 preserves versions 1 through 3. Loading an
action binds its target explicitly; replay uses fresh native membership,
mode, lock and output-geometry checks before touching pixels. Preview,
identity, cancelled and refused transforms do not become successful actions.

All 1,262 unit tests pass. The focused native workflow passes on all four
engines, including actual asynchronous save/load, rebound targets, exact
pixel/bounds output and Undo/Redo, stale locks, mask/channel/Quick Mask
refusals, deleted targets and accepted-command failure settlement. Independent
production review and follow-up fixture review have no remaining important
findings. These checks do not exercise the binding sheet itself or establish
complete action/batch coverage; filter and text recording remain open.

### Captured projective canvas controls (2026-11-11 candidate)

Transform now exposes Scale / Rotate, Skew, Distort and Perspective in
Tool Options and Layer > Transform. Independent warp geometry survives
numeric frame changes and mode switches. Perspective keeps its first drag
axis through later movement and release; hidden handle kinds do not steal
hits. The overlay uses the actual projected source grid. It is still an
outline preview, not a warped composite pixel preview.

Apply captures the original layer rectangle and uses an additive native
request whose bounds check and mutation share one engine dispatch. It
refuses editable text/link/vector descendants until explicitly rasterized.
Pending Apply disables repeated submission and reports success only after
native completion and cache reconciliation. The same captured API protects
both affine and perspective action replay. Format v6 carries all nine
coefficients and explicit layer bindings; v5 Levels is integrated and mixed files preserve both command families.

All four native conformance suites pass. The 184 focused geometry/Recorder
tests pass; a hidden-handle hit regression reproduced two failures before
its correction. Native canvas testing reproduced a stale-field focus bug
that blocked initial mode changes; unchanged fields now perform no target
command, while edited stale drafts still refuse. The pinned native workflow
passes real canvas events, analytic transformed pixels, single Undo and exact
Undo/Redo, save/load/rebinding, editable text refusal and queued stale bounds.
Independent direct native, UI and Recorder source reviews are complete.
After v5/v6 integration, all 1,351 Swift tests and 111 focused native editor
checks on each of the four engines pass. This includes numeric controls,
affine recording, Levels capture/replay, perspective pointer gestures,
actual v6 file save/load/rebinding, source preservation and exact Undo/Redo.
Independent merge-resolution review confirms both capture paths remain
intact. The frozen integrated controls app also passes the ordinary full
editor workflows on all four engines: 3,315 checks each on 3.2.8, 3.2.0
and master, and 3,289 on 3.0.8, with zero failures.
This does not establish complete Photoshop 4 parity or interaction latency.

### Color-only Posterize (2026-11-12 candidate)

Image > Adjust and New Adjustment Layer offer Posterize with 2–256 levels.
The adapter-owned operation follows the upstream color quantization while
copying alpha unchanged. The older operation remains available under the
explicit name "Posterize Including Transparency". Both use the existing
modeless preview, Apply/Cancel, Undo and editable-effect workflow.

All four engine sets pass native conformance and 41 focused checks covering
partial alpha, unchanged source pixels, cancellation, Undo/Redo, adjustment
groups and editable XCF reopening. The app passes 1,279 units, all four
focused menu/adjustment-layer workflows, and 3,322/3,322/3,296/3,322 full
checks on 3.2.8/3.2.0/3.0.8/master. Independent source review found no
important issue. The owned operation must be present to re-edit this XCF
effect; upstream applications do not provide the `glims:` operation.

### Selective Color (2026-11-12 candidate)

The adapter now provides an owned Selective Color operation with nine color
ranges, four CMYK adjustments per range and Relative/Absolute correction.
The independent implementation follows the published formulas cited in the
kernel; it adds no upstream patch or FFmpeg dependency. Alpha is preserved.
Nonfinite and HDR RGB values outside the documented narrow endpoint-roundoff
tolerance pass through unchanged; zero settings preserve every input bit.

Image > Adjust and New Adjustment Layer share a compact native editor. The
Colors popup switches four percentage rows without discarding other ranges.
Queued acknowledgements preserve active text drafts, and Apply/Cancel keep
the established one-Undo/no-Undo lifecycle. Display rounding alone does not
change stored precision; explicit text edits still commit their typed value.

All four engine sets pass native conformance and 49 focused public-facade
checks, including literal pixels, alpha, cancellation, source preservation,
Undo/Redo, all 36 settings and correction method through editable XCF. The
pure kernel passes 46 ASan/UBSan checks. All four engines pass the focused
real panel and adjustment-layer workflows. Independent native and UI source
reviews found no important issue; full workflows and the final explicit-text
refinement remain in verification at this checkpoint. Owned XCF operations
require Glims for editing. This slice does not establish complete Photoshop 4
mode support or complete Recorder/batch coverage.

### Recorded new Levels adjustments (2026-11-11 candidate)

Apply now records a newly created Levels effect on its original explicit
layer, with the final native settings for all five channels, the transfer
curve and both clamp flags. Saved format version 5 retains versions 1
through 4. Preview updates, Cancel and pre-admission refusals add no row;
an admitted Apply still settles after Stop. Native failures retain the
preview for retry. Applying Levels to a mask/channel or editing an existing
effect remains usable but produces an explicit unsupported recording row.

The focused native workflow passes 33 checks on each of GIMP 3.2.8, 3.2.0,
3.0.8 and master. It verifies queued final settings, selection changes after
preview begins, Stop with a pending Apply, actual save/load and explicit
rebound targets, exact native-reference pixels and Undo/Redo, grayscale
replay, indexed refusal, fresh pixel locks and mask/channel/Quick Mask roles,
failed Apply retry, unsupported existing-effect/mask/channel capture, and
close cleanup. The full Swift suite passes 1,291 tests, including 13 focused
Levels format/binding tests; the valid v5 fixture failed against the prior
codec before implementation. Independent source review found no important
issues. The timed-out helper review supplied no approval and was superseded
by that completed independent review. No engine or facade code changed.

The existing Recorder epoch tests cover stale completions after a new
recording; this native case does not repeat them. Other adjustment families,
existing-effect identity replay and text recording remain open. These
checks establish this Levels slice, not complete action/batch coverage.


### Transform composite pixel preview (2026-11-11 work in progress)

The canvas now previews transformed composite pixels through a private image
copy. It preserves the source raster resolution and uses the same captured
native transform as Apply, including masks and group children. Only the
visible viewport is rendered, with the window display profile and soft proof;
a 4,096-pixel output edge limit bounds unusually large viewports. One native
job and the latest requested mapping replace a queue of pointer samples.
Cancel and source changes invalidate late results; clone destruction remains
counted through document close. The temporary image is never saved or recorded.

Private previews also have a read gate, separate from the edit gate. Native
cache-reading command completions retain document ownership until their
refresh finishes. Deferred Text and color picks retain cancellation and target
generations. Crop to Selection reads the native selection on the input queue,
so later selection changes cannot overtake the accepted crop.

Tests on all four engines compare complete source state and exact preview
pixels against independently committed projective and affine transforms,
including nested masked groups, P3 display conversion, grayscale proofing,
bounded and fractional 2x viewport output, repeated previews, stale bounds,
multi-selection refusal, cancellation, target acknowledgement and close drain.
All pass. The complete 1,360-test Swift suite passes, including nine
preview/coalescing and read-gate tests. Resample invalidation reproduced a
failed observer test before its fix. The 24 MP characterization measured 808 ms affine and 796 ms
projective preview completion for an 800x600 viewport, with idle main-loop
lateness below 7 ms. This is not yet low-latency interaction qualification.

The actual canvas matches an independent transformed viewport on every engine.
Its cancellation checks reproduce the late Text editor after Escape, then pass
with generation checks. All three path-creation UI routes now queue counted
input. The first anchor remains visible while its ID is pending; another click
cannot duplicate it, and Escape ends extension without undoing accepted input.
Selecting a hidden path waits for its geometry before allowing edits. Removing
those guards produces two failing native assertions, including changed path
geometry. Both pass with the guards restored. Mask toggles resolve prior queued
values, and unknown-mask picks retain target admission until reconciliation.
These focused UI and native checks pass on all four engines. Independent API
and caller reviews found no remaining important issues after their fixes.

The ordinary workflow matrix at `526556c` passes 3,315 / 3,315 / 3,289 /
3,315 checks on 3.2.8 / 3.2.0 / 3.0.8 / master. Hosted CI/review and merged
bundle verification remain open. Photoshop 4 parity is still incomplete.

### Lazy transform preview pixels (2026-11-11 work in progress)

Additive facade slot 176 creates an owned private transformed image, with
the same captured target, geometry, storage, lock and editable-source admission
as Apply. Ordinary root raster layers without masks or effects use the upstream
transform matrix and sampler behind GIMP's tile-validation handler. The full
native-resolution result exists logically; only demanded tiles are calculated.
Groups, masked layers, nested layers and effect-bearing layers retain the
ordinary native transform on the private copy. Apply is unchanged.

The tile handler owns its graph and copied input buffer until the result image
closes. The first native equivalence matrix covers all six sampler settings,
opaque and partially transparent RGB, float-linear RGB, 16-bit grayscale and
indexed images. Each source closes before the first preview read; off-origin,
reduced, 2x and complete reads must equal an independently committed result.
Unaligned/future prefixes and invalid/missing/stale requests exercise the API's
admission and cleared output contract. These checks and the existing native
conformance suites pass on all four engines. Independent source review found
no important remaining issue.

An initial 24 MP characterization measured 37.5 ms affine and 26.2 ms projective
preview completion for the existing 800x600 viewport, versus 808 / 796 ms for
the eager copy. Main-loop lateness was below 6 ms. These are single-run results
on this Mac for eligible layers, not a guarantee for structured layers or
arbitrary images. Full app, final packaging and hosted CI/review are pending.


### Whole-value Curves recording (2026-11-12 candidate)

New Curves Apply records its final native TRC and all five channels behind
queued preview edits, retaining its begin-time layer if selection changes.
Each channel stores kind, identity, points and all 256 actual samples,
including inactive points and noncanonical Smooth tables. Format version 7
uses owned named tags and shares the existing point/resource budgets; versions
1 through 6 retain their existing meaning. Cancel records nothing, failed
commits settle failure and retain retry metadata, and mask/channel targets or
existing-effect edits remain explicit unsupported rows.

Additive facade slot 177 installs an independent whole native Curves value.
Validation precedes cloning, raw table/identity restoration happens only in
an unpublished candidate, and the existing atomic configuration binding
installs it. Replay checks the explicitly rebound layer's current membership,
mode, locks and editing role before committing one effect with one Undo.
The native fixtures pass on all four engines, including exact hidden state,
HDR arithmetic, all TRCs, input lifetime, future/unaligned prefixes, invalid
last-channel atomicity, real pixels, Cancel and Undo/Redo. Independent native
review found no important defect; two inexpensive boundary cases and an array
alignment contract note address its useful minor suggestions. All 1,380 Swift
tests and the focused save/load/rebind/replay workflow pass on all four
engines. The complete editor matrix and independent integration review are
running.
This slice does not establish complete Recorder coverage or Photoshop 4 parity.


### Explicit native export controls (2026-11-12 candidate)

File > Export has a format chooser and PNG compression/interlacing/transparent
color, JPEG quality/progressive/optimization/chroma sampling, and lossless TIFF
compression/transparent-color controls. Successful settings belong to the
document and Repeat Export reuses them; Cancel and failed writes do not replace
the last successful request. Save remains XCF-only.

Additive facade slot 178 validates an owned immutable settings prefix and binds
the native file procedure by argument name and type before noninteractive
execution. All four native conformance suites and 60 focused checks per engine pass,
including independent PNG/JPEG/TIFF header checks, exact PNG/TIFF reopen
pixels, invalid-input refusal and preservation of source pixels, document
dirty state and Undo/Redo. Small TIFF round trips reproduced an upstream
loader issue: its embedded thumbnail became an extra 256-pixel layer. This
export path omits that redundant thumbnail. Existing external TIFF files with
thumbnail IFDs still require separate import qualification.

The focused hosted `GLIMS_SMOKE_CASE=export-options` workflow passes on all
four engines through actual native Export button input, including Repeat
Export, a refused write, Cancel, and unchanged source pixels/history/dirty
state. It prints the fixture-only destination and requires an external UI
driver within 90 seconds; it is separate from the headless default suite.
Transparent-color fixtures verify exact hidden RGB and partial alpha in PNG
and TIFF. A regression reproduced JPEG quality losing precision when an
untouched rounded display was accepted. The fix preserves that exact stored
value while applying explicitly typed rounded text; 1,418 Swift tests pass.
The sheet starts in the last successful export folder; isolated UI fixtures
supply their own initial folder before presentation. The final full editor
and packaged export checks remain in progress. This does not establish native
CMYK/Lab editing, complete Photoshop 4 parity or complete Recorder/batch coverage.

### Recorded new Color Balance adjustments (2026-11-12 candidate)

New Color Balance Apply records its final native settings — all nine signed
corrections across shadows, midtones and highlights plus Preserve Lightness —
behind queued preview writes, retaining its begin-time layer if selection
changes. Format version 8 uses owned semantic JSON field names; versions 1
through 7 retain their existing meaning and strict tagged schemas. Cancel
records nothing, a failed commit settles failure while retaining its capture
metadata for retry, and mask/channel targets or existing-effect edits remain
explicit unsupported rows after a successful commit.

`RecorderColorBalanceValue` detaches the owned file value and validates the
finite −1...1 native range at codec decode, encode, both bridge directions
and the snapshot boundary. Replay reuses the shared layer-adjustment
admission: current membership, RGB/grayscale mode, pixel lock and
mask/channel/Quick Mask role checks against the freshly bound layer, then
one new effect with one Undo. No engine or facade code changed and no new
native slot was needed; the typed whole-settings read/set API already
existed.

The focused `GLIMS_SMOKE_CASE=recorder-color-balance` workflow drives the
real panel through openNativeFilter: accepted Apply and Cancel,
successful-only capture, save/load, explicit rebinding on a second image,
exact pixels against an independent native oracle, committed-effect setting
preservation, Undo/Redo, lock and role refusals, failed-Apply retry, and
unsupported existing-effect/mask/channel rows. Twelve focused
codec/value/binding/snapshot tests cover independent all-nine-nonzero
fixtures with both luminosity states, unknown/missing/extra fields, wrong
types, nonfinite and out-of-range corrections, version anchoring and wrong
bindings.

The final code builds and passes 1,401 Swift tests and all 31 focused native
workflow checks on each of GIMP 3.2.8, 3.2.0, 3.0.8 and master. Independent
SWE-2 review found no important product-code defects. Its minor test finding
was addressed by reading the effect identity again after Redo. The first
native run also exposed a fixture assumption: the real panel intentionally
refuses ordinary layer switching. The test now proves that refusal, then
uses the native layer-selection seam to exercise begin-time capture under
an external selection change. No production admission was relaxed.

CI and final integrated-package promotion remain open. This slice adds the
Color Balance family only; other adjustments and existing-effect replay
remain open.


### Recorded new Hue/Saturation adjustments (2026-11-12 candidate, unrun)

New Hue/Saturation Apply records its final native settings — the global
overlap plus all seven named ranges' signed hue, saturation and lightness
corrections (21 values) — behind queued preview writes, retaining its
begin-time layer if selection changes. Format version 9 uses owned semantic
JSON field names; versions 1 through 8 retain their existing meaning and
strict tagged schemas. Cancel records nothing, a failed commit settles
failure while retaining its capture metadata for retry, and mask/channel
targets or existing-effect edits remain explicit unsupported rows after a
successful commit.

`RecorderHueSaturationValue` detaches the owned file value and validates
the finite −1...1 correction and 0...1 overlap contracts at codec decode,
encode, both bridge directions and the snapshot boundary. Replay reuses
the shared layer-adjustment admission: current membership, RGB/grayscale
mode, pixel lock and mask/channel/Quick Mask role checks against the
freshly bound layer, then one new `gimp:hue-saturation` effect with one
Undo; a failed set or commit aborts the fresh session. No engine or
facade code changed and no new native slot was needed; the typed
whole-settings read/set API already existed.

The focused `GLIMS_SMOKE_CASE=recorder-hue-saturation` workflow drives the
real panel through openNativeFilter: accepted Apply and Cancel,
successful-only capture, save/load, explicit rebinding on a second image,
exact pixels against an independent native oracle, committed-effect
setting preservation, Undo/Redo, lock and role refusals, failed-Apply
retry, and unsupported existing-effect/mask/channel rows. Focused
codec/value/binding/snapshot tests cover independent all-nonzero fixtures,
unknown/missing/extra fields, wrong types, nonfinite and out-of-range
corrections and overlap, version anchoring and wrong bindings.

This slice adds the Hue/Saturation family only; other adjustments and
existing-effect replay remain open. Status: the code builds with
`swift build --build-tests`, but no `swift test` run and no GUI or
native-engine check has run on this change yet — the root's full
GUI/native run remains outstanding before this can be called verified.

### TIFF thumbnail import candidate (2026-11-12)

Open and Open as Layers now prepare mixed TIFF main-directory chains in a
private copy, removing only directories explicitly tagged as reduced-image
thumbnails. Ordinary pages and original source bytes are preserved. This
fixes thumbnails becoming layers and enlarging the canvas without modifying
upstream code. Linked Place retains its original monitored source path.
See [TIFF import](tiff-import.md) for the 13 reproduced baseline failures,
parser/cleanup tests and pending integration qualification.

TIFF review follow-up: preparation is restricted to the registered TIFF
loader, so camera-raw containers with TIFF magic retain their preview IFDs.
The scan now also has a 512 MiB cumulative allocation cap. Strict refusal
of malformed/over-limit chains is deliberate; externally compressed TIFFs
remain on the native compressor path. The pinned native and staging tests
pass after these changes; the combined four-engine check is next.

Export qualification follow-up: the full editor suite passes on all four
engines, and the standalone bundle passes native conformance, the 60-check
export fixture, the full editor suite and the externally driven native
Export/Repeat Export workflow with development trees inaccessible. Real
PNG/TIFF/JPEG screenshots exposed tight accessory margins; the form now has
insets and shorter transparent-pixel labels. All 1,418 units and the actual
native picker workflow pass after that layout-only change. The final
combined package will include it.

### File and Recorder integration checkpoint (2026-11-12)

The combined source includes export settings and the native save panel,
recorded Color Balance and Hue/Saturation, and TIFF thumbnail preparation.
Color Balance passes all 1,401 units and 31 dedicated native AppKit checks
per engine. Hue/Saturation passes all 1,413 units and 31 dedicated checks
per engine, including the actual panel, pixel oracle, save/load/rebinding,
Undo/Redo, native role refusals and failed-Apply retry. Its independent
source review found no important defect. These supersede the earlier unrun
notes for those two candidates.

The first combined engine run passed native conformance, 102 TIFF and 60
export checks on all four engines. The final TIFF loader gate/memory bound
and Export sheet spacing are now integrated and are undergoing the affected
checks and final application/package qualification. No completed package is
claimed for this combined revision yet; Photoshop 4 parity, native CMYK/Lab
editing, wider Recorder coverage and folder batch processing remain open.

### Export/Recorder integration qualification and Batch candidate (2026-11-12)

The combined file/adjustment tree at c930487 is qualified locally. All 1,442
Swift tests, full app checks and the focused Color Balance/Hue-Saturation
workflows pass on GIMP 3.2.8, 3.2.0, 3.0.8 and master. Native conformance,
60 export and 102 TIFF checks also pass on each engine. The standalone bundle
passes its native and app workflows, including actual Export/Repeat Export,
with development libraries blocked. Ordinary launch measured 1.656 seconds
with fresh user paths, 1.406 cached and 3.388 after relocation on this Mac.
That candidate is installed locally with the previous bundle preserved;
PR #219 passed hosted macOS CI and merged as 8a9216f. No notarization is requested.

The next candidate adds File > Batch for saved recordings and selected files
or flat folders. Matching is an explicit policy: no targets, exact name/kind,
or exact name/kind/ancestor path. Missing or ambiguous targets refuse the
individual image. A private image is opened, rebound, replayed and drained
before the next input. XCF save-copy or typed PNG/JPEG/TIFF export writes to
a private staging directory; successful publication uses an exclusive rename
to a distinct edited filename and never replaces an input or existing output.
Per-file errors continue to the next source; Cancel fences future inputs and
current publication while accepted work and image close drain. Closing or
quitting waits for that lifetime. Folder scans and recording matching run on
the file queue; folder entries are bounded, flat and deterministic.

Independent reviews of matching and file publication found no important
findings. Service review identified interference from other documents' engine
work and loss of real errors concurrent with Cancel. Both were reproduced in
the native fixture and fixed: Batch opts into a generation-fenced wait between
replay steps, while interactive Replay keeps its existing admission behavior;
real open/apply/export failures retain their diagnostics. The expanded pinned
native fixture passes actual pixel comparisons, partial failure, both Cancel
races, the real Batch window and picker teardown. All 39 new model/filesystem
tests pass. Final cross-engine, full-suite, visual and independent follow-up
qualification is pending. This does not establish complete Recorder coverage,
PSD fidelity or native CMYK/Lab/duotone/multichannel editing.


Batch follow-up qualification: the first combined candidate passed all 1,481
Swift tests and its native Batch workflow on all four engines. Actual desktop
inspection caught long-path layout pressure; the corrected panel stays 620
pixels wide with truncated path fields and selectable full paths in results.
The desktop screenshot is verified, but its accessibility snapshot was
incomplete, so it does not qualify VoiceOver.

A read-only bind can lose admission while another document starts engine
work. The reproduced native failure now retries only pre-work document busy
refusals; native errors and partly applied steps never retry. A plug-in's
completion flag is also respected. Cancel drains accepted document callbacks
but can proceed to cleanup without waiting for that foreign status flag;
native image destruction still queues behind real engine work. The latter
regression failed before the fix. Final checks on this follow-up remain open.

Batch final qualification: all 1,481 unit tests, native conformance, full app
and Batch checks pass across four engines. The standalone bundle passes with
development libraries blocked. Launch measured 1.725 seconds fresh, 1.476
cached and 3.497 after relocation. The cancellation follow-up review found
no important issue. Hosted macOS CI passed and PR #220 merged as 9a30627.

### Typed PSD export candidate (2026-11-12)

PSD now has explicit Layers and Merged appearance choices in the shared
Export form, preserving the choice for Repeat Export. Layers retain the
native writer's raster layers and masks, with baked effects and potentially
changed blending. Merged appearance copies the canvas-clipped visible
projection into one alpha-capable layer of a private image. The source's
layers, selected target, effects, pixels, dirty state and Undo remain intact.
The private duplicate preserves its working profile and image metadata.
The stable engines write 8-bit for u8 source channels and 16-bit for higher
precision; HDR range cannot survive that integer encoding. The development
engine also writes 32-bit PSD for float/u32 sources. XCF remains the editable save.

The additive facade tail retains the historical 48-byte PNG/JPEG/TIFF
settings prefix, accepts unaligned and larger future structs, and requires
an explicit complete PSD layout field. The bounded format accepts RGB and
grayscale, refuses indexed and does not include PSB or CMYK/duotone export.

The first pinned native fixture passed 114 checks, including non-white masks,
effects, negative offsets, hidden content, full transparency, RGB/grayscale
ICC profiles and u8/u16/float sources. Cross-engine qualification reproduced
an older upstream PSD profile mismatch. Upstream fix 62f1d4909f first ships
in 3.2.6; older adapters now refuse profiles outside their default encoding
space before writing. No upstream source is patched. This guard and the
expanded matrix, actual save-panel workflow, full app and bundle checks
remain in progress. Independent C source review found no important issue
before the profile guard; the follow-up and Swift form review remain open.


PSD matrix follow-up: all four native conformance suites pass. The stable
engines pass PSD cases with the explicit old-profile refusals. Master exposed
an overly narrow test/documentation assumption: its PSD writer supports
32-bit float/u32 output, unlike the stable writers. Source inspection and the
actual file headers confirm this improvement; the oracle and copy now state
the engine-specific depth without suppressing the newer capability. All native PSD and existing PNG/JPEG/TIFF export suites now pass on all four
engines. Both independent C and Swift/profile-guard reviews found no important
issues. Actual Export/Repeat Export and combined Batch app qualification
remain in progress.


### Explicit CMYK PSD output (2026-11-12)

The shared Export and Batch form now offers Document RGB/Grayscale or CMYK.
CMYK requires an explicitly selected installed ColorSync ICC profile; discovery
runs lazily off the main thread. Repeat Export and Batch retain the exact
profile bytes, including when the installed catalog changes. No default profile
is silently selected. The RGB editing document and XCF save remain unchanged.

An additive facade function converts a private copy with the native PSD writer,
using relative colorimetric rendering with black-point compensation. Output is
8-bit for u8 and 16-bit for higher precision; HDR range is clipped. Layered and
merged layouts remain explicit. This does not provide native CMYK/Lab editing,
duotone/spot-channel support, or CMYK-preserving import.

Independent LCMS output comparison exposed two native constraints. Babl's
qualified CMYK path always uses relative colorimetric plus BPC, so the interface
does not offer ignored intent choices. Development GIMP 5374deeec1 requests a
float RGBA merged buffer but treats it as bytes in its CMYK PSD preview writer.
The independent raw-plane oracle reproduced differences up to 204/255. The
adapter refuses CMYK output on that 3.3 engine before touching a destination;
the bundled stable engine supports it. No upstream sources are patched.

Native conformance and existing PSD regressions pass on all four engine sets.
The three stable sets pass 35 CMYK checks, including exact ICC embedding,
independent color values, layouts, precision conversion and source preservation.
The development engine passes 21 refusal/source-preservation checks. Independent
native and version-guard source reviews found no important issue. App, actual
save-panel, Batch and standalone bundle qualification remain in progress.

### Recorder Brightness/Contrast candidate (2026-11-12)

A newly applied Brightness/Contrast adjustment now captures the complete
accepted brightness/contrast pair with its explicit layer binding. Recording
format 10 carries the finite values; earlier versions reject the new command,
and mixed recordings choose the highest needed version. Replay retains the
existing native admission, target and lifetime gates. Preview, Cancel and
refused Apply add no successful row; unsupported targets/effect edits and
actual native failures keep their explicit failure behavior.

The standalone candidate passes all 1,493 unit tests and its focused native
fixture across all four engine sets. Independent source review found no
important issue. Combined qualification with CMYK output remains in progress.
This expands Recorder coverage; it does not complete Photoshop 4 actions support.

PSD predecessor qualification completed before this integration: all 1,483
unit tests, actual Export/Repeat Export, full app and Batch checks passed on
four engines. The standalone bundle passed with development trees blocked.
Launch measured 1.634 seconds fresh, 1.379 cached and 3.386 after relocation.
PR #221 passed hosted CI, merged as 4e93a3f, and its qualified bundle is installed.

### Still-image GIF export candidate (2026-11-12)

The explicit Export form now offers GIF with its reduced-color and binary-alpha
policy visible beside the format. Repeat Export and Batch carry the same format.
The native writer receives one canvas-clipped visible layer in a private copy,
with animation metadata removed only from that copy. It writes a still,
non-interlaced GIF with up to 256 colors. This does not provide GIF animation
editing/export; the working source retains layers, profile and precision.

The owned format enum is extended without changing the export-settings layout
or facade ABI. Pinned native checks pass for independent palette pixels and
alpha, RGB/grayscale/indexed/float/profiled input, two-layer composition,
imported looping animation converted to a still, exact source preservation,
and wrong-extension refusal preserving existing destination bytes. The bounded
GIF parser independently checks little-endian dimensions, frame count, loop
extensions and interlace. Native matrix, UI, review and bundle qualification
remain pending.


### BMP and TGA output candidate (2026-11-12)

The Export and Batch form offers BMP and TGA with explicit fixed output
policies. Both export a private canvas-clipped visible projection as 32-bit
sRGB with partial alpha, reducing higher precision to eight-bit channels.
BMP uses uncompressed V5 RGBA with sRGB metadata; TGA uses uncompressed
truecolor, top-left origin and no embedded ICC profile. Gray/indexed sources
are converted to RGB only in the private copy to preserve their transparency.
The source document and XCF save retain their mode, profile, layers and Undo.
Older BMP readers may ignore alpha; this is stated in the form and manual.
PR #225 is merged. Native, actual Export/Repeat Export, Batch and standalone
bundle qualification passed before installing the reviewed build.


### Sponge painting (2026-11-12)

Tools > Dodge/Burn now includes Sponge Desaturate and Sponge Saturate, also
cycled with Shift-O. Each retains its own brush/preset, size, hardness, pressure
and opacity strength. These tools edit RGB pixels and preserve source alpha;
scalar masks/channels, grayscale and indexed targets are refused explicitly.
Recorder capture remains unsupported and visible as such.

An owned GimpBrushCore subclass computes saturation in the document's working
space, then applies native brush masks, selections and component locks through
nonlinear replacement. GIMP's default linear replacement bent hue at partial
strength; its legacy HSV blend could turn neutral/near-neutral samples red.
The new core avoids both paths and never takes color from brush pixmaps or
mutable gradient dynamics. No upstream engine sources are modified.

The pinned native fixture passes 94 checks: chromatic and neutral pixels,
independently encoded near-neutral float TIFF, opaque/partial alpha, exact
Undo/Redo/XCF, a proved color-dynamics counterexample, colored/pipe brushes,
selection strokes and alpha/pixel locks, plus non-RGB refusals. The previous
implementation fails the neutral and dynamics counterexamples. All four native
engines, actual Tool Options/canvas and tool-menu fixtures, full app checks,
1,510 units, independent native/UI review, latest-head CI and standalone bundle
qualification passed. PR #226 is merged at `7bca6be`; its tree is identical to
the qualified `dbeefe9` source. The installed app launched in 1.75 seconds
fresh, 1.47 cached and 3.44 after relocation on this Mac. Native 24 MP stroke
calls averaged 0.309 ms desaturating and 0.335 ms saturating; these are native
call timings, not complete input-to-display latency. No notarization.


### Private component storage foundation (2026-11-12)

The next color-mode prerequisite stores authoritative scalar planes in native
channels, without an editable RGB proxy. This private code does not activate a
Multichannel menu item or document mode. Native CMYK/Lab/duotone editing remains
open work; CMYK export is a separate implemented feature.

A bounded, versioned little-endian metadata codec records dimensions, precision,
intensity encoding, ordered opaque UUIDs and ink preview RGB values. It rejects
unknown versions, extra/truncated bytes, invalid numbers and duplicate/missing
identities. The native resolver also checks dimensions, scalar formats, channel
cardinality and UUID correspondence; unsupported layers or damaged metadata cannot
be mistaken for validated component storage. Names and native list order do not
define the component roles. Intensity is stored directly as 0=full ink, 1=paper;
8-bit, 16-bit and float samples retain their actual native scalar encoding.

The pure codec passes 397 checks both optimized and under Address/Undefined
Behavior Sanitizers. The final native matrix passes 171 checks on each of the
four engines, including real facade Pencil edits, exact one-step Undo/Redo,
layerless XCF save/reopen, all three precisions, decoy names/reordering, metadata
preservation and ten malformed native layouts. Rebuilt adapter conformance
also passes on all four. Codec independent review and direct native review have
no important findings; the native helper timed out before a verdict and is not
counted as a clean independent review. All 1,510 unit tests and full app checks
pass on all four engines. Hosted CI remains in progress: the Mac runner timed
out starting its ASan binary, so the portable codec now runs both sanitizers
on Linux and its optimized checks on macOS. Local sanitizer checks pass.
No upstream source changed.

Before public admission, a central default-deny operation policy must cover both
queued and direct engine-thread calls, all aliases and session owners. Display,
profile/proof rendering, component selection, clipboard/export, history, file
admission and each supported edit need dedicated component routes and independent
oracles. A valid parasite alone must never switch the user-visible mode or allow
ordinary layer/projection operations to edit a derived representation.

### CMYK preview conversion foundation (2026-11-12)

A private per-instance LittleCMS primitive converts authoritative C/M/Y/K ink
intensity into derived linear-sRGB RGBA with explicit percentage units and a
fixed relative-colorimetric/BPC policy. It exposes no new document mode yet.
All four engines pass optimized and sanitized numerical checks against an
independent double-precision oracle, and rebuilt adapter conformance. One
independent source review found no confirmed important issue. See
[cmyk-transform.md](cmyk-transform.md) for the exact contract, measured error,
profile scope and remaining document integration work.


### Private component command admission (2026-11-12)

A single internal manifest now binds every public facade function and its typed
owner before engine-thread execution. The initial policy refuses ordinary image
operations on synthetic component witnesses, including cross-image sources and
handle-only continuations, while preserving cleanup and ordinary-document work.
No new document mode is exposed. See [component-admission.md](component-admission.md)
for boundaries and reproduced review findings. PR #228 merged at `3965d22`
after 214 admission checks and full app checks passed on all four engines,
with latest native CI passing and both direct-review findings closed.

### Multichannel editor qualified (2026-11-12)

New Image now offers Multichannel documents with 1–32 authoritative native ink
channels at 8-bit integer, 16-bit integer or 32-bit float precision. These
documents contain no editable RGB proxy layer. The derived preview combines
linear RGB ink attenuation over paper and passes through the normal display ICC
transform. It is an ink preview, not an ICC press proof. Native CMYK, Lab and
duotone editing remain separate work.

All three scalar formats now use linear native storage: intensity zero means
full ink, one means paper. The earlier private non-linear integer prototype is
refused rather than reinterpreted. A brush foreground maps to numeric intensity
by `0.2126*R + 0.7152*G + 0.0722*B` over its normalized RGB values; equal RGB
values therefore paint that exact intensity. Native Brush/Pencil/Airbrush cores
retain mask geometry, pressure, opacity and Undo, while fixed scalar parameters
exclude inherited blend modes, gradients and brush pixmaps. Other edits remain
behind the explicit component operation policy until separately qualified.

Channels show the persisted ink order and permit single-channel targeting,
preview visibility, naming and ink-color edits. Combined attributes form one
native Undo step and survive XCF reopening. Optional `glims/plate-visible`
metadata contains one persistent byte, zero or one; absence means visible.
Invalid metadata refuses before editing. Channel opacity is not a second ink
coverage control. The preview cache follows both pixels and attributes and is
discarded when native buffer identity changes or validation fails.

All four engines pass adapter conformance, 171 storage checks, 215 facade-policy
checks and 4,060 public editor/native assertions. The latter include 108 numeric
paint cases, raw-plane preservation, exact Undo/Redo, derived full/half-scale
display, XCF reopening, malformed-layout refusal and ink attributes. Fractional
selections, repeated constant Brush/Pencil stamps, stationary Airbrush timers and
hidden-ink reopening have additional coverage. Unselected planes stay byte-exact;
masked samples in the painted plane stay exact for integers and within two float
ULPs. The float tolerance records measured native painting roundoff.

The actual window fixture passes on all four engines at all three precisions:
canvas painting and displayed pixels, palette target changes, one-step Undo,
Save/reopen and unsupported-action refusal. The first window integration exposed
a missing component-model enum; a regression reproduced it and now passes. All
1,516 unit tests pass. Stable disabled tool slots use Rigi PR #23, whose 156 tests,
gallery smoke, release build and latest CI pass; #23 is merged. Ink-specific status and options explain
coverage without advertising unavailable color sampling.

Separate independent source reviews of preview ownership/cache/ICC handling and
factory/paint/admission found no confirmed important findings. Those reviews do
not qualify external native scheduling or runtime behavior. The actual New Image
controls pass for all precisions, including invalid-count refusal and selected
mode delivery. Updated units and focused UI workflows pass on all four engines;
the full app suite passed on all four before the local preview-damage change.

A 4096×3072, 32-ink image exposed whole-image invalidation after a small dab.
The preview now accumulates bounded damage under a mutex and consumes it on the
engine thread; changes arriving later remain pending for the next read. The old
adapter fails two new distant-cache preservation assertions; the fix passes,
including separated edits, single-pixel reads and cached quarter-scale reads.
A separate delta review found no confirmed important issue. With a 1024×768
viewport at 25%, post-dab rendering fell from 489 to 8.7 ms for U8 and 492 to
7.7 ms for float on this Mac. Warm reads took about 7 ms; cold 32-ink fit-view
reads still took about half a second. These are engine timings, not complete
pointer-to-display latency. Reproduce with `python3 scripts/test-component-perf.py --library /absolute/path/to/libglimsengine.dylib --work /tmp/component-perf`.

PR #229 merged at `f890954` after both latest CI jobs passed. The standalone
pinned-engine bundle passed native, full app and focused Multichannel checks
with development libraries and build trees inaccessible. Ordinary New Image,
pointer painting, menu Undo/Redo and keyboard Undo/Redo passed on the packaged
app. The first keyboard probe used US physical Y/Z positions on this Mac's
Swiss German layout; correcting test delivery passed without a product change.
Fresh/cached/relocated launch measured 1.82/1.40/3.40 seconds. The installed
`dist/Glims.app` is qualified source `ee552de`; its unsigned executable and
6,708 payload files/symlinks match the tested copy. The previous app is retained
as a backup. No notarization. Native CMYK work is continuing separately; this
is not Photoshop 4 parity.

### Native CMYK document integration (2026-11-12)

New Image now offers profile-backed CMYK documents at u8/u16/float precision,
with four authoritative ink planes and exact ICC persistence. A bounded lazy
preview converts full-resolution samples before mipmaps; native painting,
channel selection/visibility/naming and XCF preserve the source representation.
The pinned engine passes 181 public and 227 internal CMYK checks, including
independent numeric color, malformed profile admission, failed-cache recovery,
exact raw Undo/Redo and XCF identity. Existing 4,060 Multichannel checks pass.
All four engines now pass the native CMYK/Multichannel/storage/admission suites
and the 177-check actual CMYK window workflow. All 1,519 units pass; the pinned
full editor suite passes 3,352 checks. Three independent source reviews found
no confirmed important findings. A 12 MP CMYK image measured about 7.5 ms for
post-dab redraws and 1.9 seconds for its first fit-view conversion under shared
load. Full app checks now pass on all four engines; one retained 3.2.0 timing
outlier passed isolated and full repeats without changing its threshold. The
standalone package passes native/full/CMYK/Multichannel checks with development
libraries blocked. Fresh/cached/relocated launches measure 1.83/1.52/3.47 seconds;
ordinary profile selection, painting and keyboard Undo/Redo pass. Latest CI and
merge remain pending; the installed app has not yet been replaced. See
[cmyk-documents.md](cmyk-documents.md) for the admitted command scope and tests.

### Private native-CMYK PSD codec (2026-11-12)

A bounded planar PSD serializer is being qualified before enabling native CMYK
export. It preserves U8/U16 ink integers and exact ICC bytes without an RGB
round trip, limits dimensions/file size before output and distinguishes source
from sink failures. It remains private and unused by the editor. Independent
byte-layout/refusal tests and source review are in progress; destination
transaction and actual export UI integration remain separate. The independent
byte fixture now passes 315 checks in optimized and ASan/UBSan builds; source
review found no confirmed important findings. Native adapter and CI checks
remain pending. See
[cmyk-psd-codec.md](cmyk-psd-codec.md).

The private PSD codec now compiles into all four adapters, whose normal
conformance, XCF and TIFF suites pass 9,818 checks in total. Actual native
file export is a separate integration; the codec remains unused by the editor.

### Native CMYK PSD export integration (2026-11-12)

Slot182 writes the four authoritative integer ink planes and exact source ICC
into a flat PSD without RGB conversion. Export/Repeat Export use the source
profile and include hidden inks; float and incompatible settings refuse. A
private sibling transaction commits only after complete write/sync/close and
cancellation checks. Busy/read/cancel/shutdown ownership is explicit, and
progress routes to the activity's document. Pinned numeric/control tests,
portable transaction checks and actual Export UI pass. All four engines pass
the numeric, cancellation, independent reader-appearance and full editor suites.
The standalone package passes native/full/CMYK/Multichannel checks with development
trees blocked; fresh/cached/relocated launch measures 1.73/1.45/3.25 seconds.
Three independent source reviews found no important findings. Qualified source
`40c3b74` is installed after PR #233 passed latest CI and merged; the last
fixture-only compatibility fix leaves the qualified editor behavior unchanged.
See [native-cmyk-psd-export.md](native-cmyk-psd-export.md).

### Private preserving CMYK PSD reader (candidate)

A bounded private reader inspects flat RAW U8/U16 CMYK PSDs and decodes exact
host-endian ink samples. It accepts exactly four channels and one structural
CMYK ICC resource, refusing extra metadata and unsupported compression/layers.
It has no native image or app entry point yet. Independent literal fixtures
pass 485 optimized and 485 ASan/UBSan checks, including row/chunk boundaries,
malformed input, exact intensity orientation and immediate callback failures.
Full profile admission, private input staging, image ownership and preserving
Open/Revert remain subsequent work. Native compatibility checks are in progress.
See [cmyk-psd-import.md](cmyk-psd-import.md).

### Tool Options first-launch visibility (2026-11-12)

The default Tool Options content height increases from 190 to 300 points so the
paint controls and native-ink explanation fit without scrolling. Existing saved
sizes, the 120-point minimum, scrolling and stable sizing across tool switches
remain unchanged. A real CMYK window reproduced the partly hidden explanation;
the revised first-launch window shows it completely and stays outside the canvas.
The debug build passes. This is a default-layout change, not a scrolling repair.

### Native ink Fill, Clear and Invert (2026-11-12)

Selected CMYK and Multichannel ink planes now have explicit scalar Fill, Clear
and linear Invert routes, with selection weighting and exact native Undo. The
Fill sheet accepts ink amount and opacity without changing color-picker state;
other generic filters remain gated. Staging, cancellation and publication retain
source samples and precision. An accepted operation reserves its Recorder entry
before busy observers can Stop or begin another epoch, and drains before Close.

All four engines pass 1,314 numeric and 39 ownership/cancellation checks each;
828 optimized/sanitized scalar checks and a separate 197,397-check numeric probe
pass. The pinned actual-window fixture passes 246 checks, including the observed
and fixed six-failure Recorder regression. All 1,526 units and all 16 actual-window
cases across the four engines pass. The standalone app passes native/full/ink-edit/
CMYK/Multichannel checks with development trees blocked; fresh/cached/relocated
launches take 1.720/1.408/3.202 seconds. The actual Fill sheet is visually usable;
Tool Options scroll presentation is being checked separately. Latest CI and merge
remain pending before installation. See [component-edits.md](component-edits.md).

### Native ink Levels foundation (2026-11-12)

An additive scalar Levels transaction now preserves native CMYK/Multichannel
samples, selection weighting and exact Undo without RGB conversion. The kernel
passes 131,713 optimized/sanitized checks. All four engines pass 1,534 Levels,
1,314 prior scalar-edit and 39 ownership/cancellation checks each, as well as
general conformance. Numeric and native integration reviews found no remaining
important findings. A frozen-source modeless preview and its controls are next;
the foundation does not enable an ink Levels menu by itself. See
[component-levels.md](component-levels.md).

### Native ink Levels preview and controls (2026-11-12)

CMYK and Multichannel documents now route Levels to a modeless scalar panel
with an immutable native baseline, bounded canvas previews, captured-target
Apply, Cancel, and exact Undo. Live field validation blocks stale-value Apply;
pending capture and cleanup hold edit admission through rapid Cancel/reopen.
Recorder labels accepted edits unsupported until replay has a native route.

All four engines pass 662 snapshot checks plus prior native ink edit suites.
Twelve panel/coalescer units pass, including two reproduced retry regressions.
The pinned real-window fixture passes 505 checks across both modes and U8/float,
including actual field editing, supported maximum zoom/pan, stale target refusal,
Cancel, source close, Apply, Undo/Redo and Recorder admission. A cached calculated
image reduces repeated 12 MP preview retrieval from 310–338 ms to 0.87–1.41 ms,
before viewport rendering. Full-engine UI and standalone results are tracked
with the integration pull request. See [ink-levels-preview.md](ink-levels-preview.md).


### Authoritative ink identity candidate (2026-11-12)

Slot 189 exposes validated document-scoped ink UUIDs and canonical CMYK roles
without using display names as identity. Swift also exposes committed scalar
Levels independently of the preview API. The loader now copies only the
advertised API prefix into a zeroed current table; the real older 184-slot
producer first reproduced a load refusal, then passed 27 live checks. All four
current producers pass 1,269 native identity checks and 104 Swift wrapper
checks each, plus general conformance. Twelve decoder/guard-page tests and
130 Python preflight checks pass. Native and Swift independent reviews are
clear after the loader fix. This is a prerequisite for ink Recorder support,
not completed recording/replay. See `ink-channel-identity.md`. CI and full app
qualification remain integration gates.

### Private Lab sample and preview foundation (2026-11-12)

The private candidate uses ICC-v4 U8/U16 samples and physical signed float
L*, a*, b*, with explicit role/format conversion independent of ink intensity.
All 608,467 optimized/sanitized sample checks and a separate 986,850-case
rational boundary probe pass. A private D50-to-linear-sRGB primitive uses
double intermediates to reject real output overflow rather than accepting the
finite sentinel observed in LittleCMS for extreme Lab inputs. Its 7,800
optimized/sanitized checks pass, with separate numeric/source review.

Literal scalar-channel storage checks pass 155 times per engine across all
four engines, retaining signed zero, subnormals and extreme finite floats
through Undo/Redo, duplication and XCF finalization/reopen. Independent codec
and transform reviews found no important issue. These are prerequisites:
public Lab mode, document admission, Lab editing, layers and interchange are
still unavailable. See [lab-samples.md](lab-samples.md) and
[lab-transform.md](lab-transform.md). Hosted CI and native integration of the
new private modules remain qualification gates for this foundation.

### Native Lab document foundation (2026-11-12)

Slot 190 creates fixed-D50 L/a/b documents with exact U8/U16/physical-float
storage, explicit mode adoption, bounded derived previews, and native XCF
persistence. Unsupported ink/RGB commands fail before execution; replacing
the persisted mode cannot bypass the adopted-mode boundary. The app does not
yet expose Lab creation or editing. Its failed-Open path now closes a native
image when document construction refuses it.

All four engine sets pass general conformance and 855 dedicated Lab checks
each: 294 storage, 302 admission, 220 render/history/failure-recovery and 39
mapped XCF roundtrip checks. The map's 1,246 optimized and sanitized checks
pass, as do all 1,554 unit tests. Independent storage and production-seam
reviews found no important issue. Initial render-test stack exhaustion was
resolved by moving fixture snapshots to the heap; the render assertions and
production implementation were unchanged. See [lab-documents.md](lab-documents.md).

Native Lab remains a prerequisite for the interface, editing, recovery,
layers, conversion and interchange work. It is not installed or a claim of
Photoshop 4 parity. Existing Multichannel/CMYK editor and scalar-edit fixtures
also pass on every engine (4,060 / 181 / 1,314 checks each). Hosted CI remains
an integration gate for this candidate.

### Typed Lab axis metadata (2026-11-12)

Slot 191 exposes canonical L/a/b roles, document-scoped UUIDs, current handles,
selection and UTF-8 display names without interpreting them as ink channels.
It reads metadata only and preserves caller output boundaries on success and
failure. Swift validates the returned record and gates Lab creation and axis
metadata independently, retaining support for older producers. The app still
refuses Lab document construction until its editing/UI workflow is ready.

All four engines pass 6,288 native axis checks, 304 admission checks, general
conformance and 26 Swift checks each. Real 189- and 190-slot engines pass five
compatibility checks apiece. All 1,560 Swift tests and 130 Python checks pass;
independent native and Swift source reviews found no important issue. See
[lab-documents.md](lab-documents.md). Hosted CI and subsequent UI qualification
remain integration gates; this is not installed Lab editing or PS4 parity.

### Native Lab channel editing candidate (2026-11-12)

New Image, typed Channels and physical Fill now form the first Lab editing
workflow, with native XCF Save/reopen and Undo/Redo. All four engines pass
1,143 Fill and 306 policy checks; the pure kernel passes 2,998 checks in
each optimized/sanitized run. The initial three-precision UI run passes
after inset correction. Recovery retains explicit unsaved state, and shared
exclusive edits retain pending input until native dirty reconciliation.
Independent production reviews are clear. Integrated recovery, latest-source
UI and bundle qualification remain in progress. Lab Brush, layers, conversion
and interchange are still open; see `lab-channel-editing.md`.

### Native ink Recorder candidate (2026-11-12)

Successful Fill/Clear/Invert and Levels Apply now capture exact semantic values
and authoritative ink bindings. Strict recording version 11 preserves owned
settings and document-scoped identity; explicit Load choices validate CMYK
roles and retain the destination UUID. Replay requires the bound ink already
selected, revalidates natively and stops on failure. Batch name matching
refuses ink recordings. Twenty pure tests and 329 document-service checks on
each of four engines pass, including disk round trips, XCF reopen, independent
scalar oracles, Undo/Redo and stale-target refusal. Independent file/runtime
reviews found no important issue. Full UI, bundle and launch qualification are
in progress. See `ink-recorder.md` for scope and remaining selection/Batch work.


### Private linear RGB to Lab conversion (2026-11-12)

The private transform now converts linear-sRGB float triples into physical
D50 Lab with bounded atomic rows and no clipping or transfer-curve decoding.
Independent forward checks pass 752 cases in optimized and ASan/UBSan builds;
the unchanged reverse suite passes 7,800 in each mode. Source review found
no important issue. This is numeric preparation only: profile admission,
alpha/layer policy and the actual document conversion workflow remain open.
See [lab-transform.md](lab-transform.md).

### Physical Lab Brush candidate (2026-11-12)

Typed Begin/Cancel and a private native brush core now paint one physical
L*, a* or b* value with captured identity, bounded per-dab staging and exact
whole-stroke cancellation. Tool Options keeps per-document/axis drafts;
Escape cancels queued or active gestures. Save refuses tentative native
pixels, and image close retires its strokes. All four engines pass native,
queued Swift and actual-window checks after retained regressions; all 1,598
Swift and 130 Python tests pass. Independent production and fixture reviews
are clear. Bundled and hosted qualification remain in progress. See
[lab-brush.md](lab-brush.md) for the numeric contract and limits.


### Native Lab selections candidate (2026-11-12)

Typed slots 195/196 add native root-mask Rectangle/Ellipse/Lasso selections
with Replace/Add/Subtract/Intersect and All/None/Invert. Physical Lab Fill
and Brush honor that coverage; authoritative axes stay unchanged by selection.
Old general selection APIs remain blocked, and the Swift service and tool/menu
routes require the explicit new capability. All four engines pass 1,380
focused native and 312 Lab admission checks, plus general conformance
(2,268/2,054/2,268/2,268), 34 compressed-XCF and 206 TIFF checks per engine.
The headless Swift case passes 55 checks and actual U8/float selection UI
passes 179 checks on each engine, with surrounding Brush/Fill/axes/Close
regressions green. All 1,599 Swift and 130 Python tests pass; real older
slot192/194 adapters preserve capability refusal. UI qualification reproduced
and fixed a clipped selection-mode control; independent reviews are clear.
Bundle and hosted qualification remain pending, with no Photoshop-parity claim. See
[lab-selections.md](lab-selections.md) for contracts, evidence and limits.

### Lab editor integration (2026-11-12)

The reviewed Brush and selection branches are integrated with the private
forward Lab transform from current main. Their only merge conflict was the
append-only plan log; both entries are retained. The qualified app remains
exact selection source `11dd996`, not a relabelled binary from this merge.
Its 18 standalone cases pass with development paths denied; fresh, cached
and relocated-fresh launches measure 2.044, 1.609 and 3.590 seconds. It adds
physical Lab Fill/Brush and root-mask selection tools to the previously
installed editor. All 1,599 Swift and 130 Python tests pass on that source.
Both feature heads have successful hosted CI. The integrated merge also
requires its own latest-head CI before publication. No notarization.

The only code difference from that qualified source is the separately tested
private RGB-to-Lab arithmetic, with no public caller yet. Actual converted
copies remain a subsequent candidate; layers and broader Lab interchange
remain open. Qualification does not establish full Photoshop 4 parity.

### Scalar ink Curves foundation (candidate)

A private 256-sample scalar lookup table preserves native U8/U16/float ink
precision, blends selection coverage once and validates a complete row before
writing it. It is preparation for selected CMYK/Multichannel Curves; no menu
or native snapshot route is enabled by this numeric slice. The 10,120 literal
checks pass in optimized and ASan/UBSan builds. A separate 6,400-case exact
rational oracle passes for U16 curves and selection coverage. One local 12 MP
U16 kernel run took 133 ms; this is not an end-to-end preview measurement.
See [component-curves.md](component-curves.md).

### Explicit RGB/Lab converted copies (candidate)

Image > Create Lab Copy and Create Linear RGB Copy create a separate,
unsaved 32-bit document while preserving the source. Slot 197 copies the
full canvas and resolution, with opaque standard-sRGB admission and native
physical Lab samples. A confirmation explains the merged pixel-only scope;
unsupported transparency, profiles and linked-layer objects refuse. Private
candidate construction prevents publication of partial results. Source Close
and application Quit wait for accepted work and asynchronous result cleanup.

Independent native checks pass on all four engine sets: 412 conversion
assertions on 3.2.8, 3.2.0 and master; 392 on 3.0.8, where linked layers are
unavailable; and 314 admission assertions each. Fixed LCMS/literal bounds,
source preservation, cancellation, row/chunk boundaries and XCF persistence
are covered. The full Swift suite passes 1,608 tests. A native
AppKit regression reproduced six BUSY-cleanup failures, then passed unchanged
after retaining discarded handles through retries, across all four engines.
The pinned real-menu workflow passes 58 assertions. All-engine menu and final
app/bundle qualification remain in progress. See
[lab-converted-copy.md](lab-converted-copy.md) for the contract and limits.

### Preserving CMYK PSD import (candidate)

File > Open CMYK PSD and additive facade slot 198 import exact U8/U16
process-ink samples and the embedded CMYK profile from flat RAW PSDs. The
source is staged into one private immutable spool; full profile admission
precedes image allocation, and publication follows complete decoding and
cancellation/I/O checks. Unsupported files receive an explicit refusal.
The initial subset accepts only the profile resource, with no layers or
other metadata. Ordinary Open remains the appearance-import route.

The application preserves this import intent through Revert and forces a
native Save As, even for a misleading XCF filename. Save changes Revert to
the new native file; Export does not. Import results remain owned through
adoption or asynchronous cleanup, and Quit waits for accepted work. All
four engines pass 720 independent preservation checks and 62 hosted app
workflow checks each; all 1,623 Swift tests pass. Native and Swift source
reviews are clear. Final packaging/startup and hosted CI remain pending. See [cmyk-psd-import.md](cmyk-psd-import.md) for the exact
subset and qualification limits. This does not establish Photoshop 4 parity.

### Native scalar ink Curves candidate (2026-11-12)

Slots 199–201 add direct selected-ink Curves and snapshot preview/Apply for
CMYK and Multichannel. Owned sample tables preserve native precision and
selection coverage; a calculation-kind tag separates Levels and Curves caches.
The shared lifecycle retains source ownership, stale-state refusal and exact
Undo behavior. Existing conformance and ink Levels/snapshot checks pass on all
four engines. Every producer also passes 741 new literal/public-facade
checks. All 1,632 Swift and 130 Python tests pass, including guarded transport
prefixes and exact sample ownership. Independent native, fixture and Swift
transport reviews are clear. Hosted CI and the application panel remain
separate gates. See
[ink-curves.md](ink-curves.md); this does not claim Photoshop parity.

### Selected-ink freehand Curves panel candidate (2026-11-12)

The actual CMYK/Multichannel Curves menu now routes to a modeless freehand
panel, with whole-table graph edits, explicit sample index/output, Reset,
owned preview, Apply and Cancel. Levels and Curves share counted snapshot
cleanup while retaining separate typed capability gates. All 1,644 Swift
tests pass; all four engines pass 174 Curves and 505 existing Levels workflow
checks each. Independent panel and lifecycle reviews are clear. Hosted CI
remains open. Smooth points and Curves Recorder commands are subsequent work;
this is neither an installed feature nor a Photoshop-parity claim.

### Smooth selected-ink Curves (candidate)

The modeless Curves panel supports Smooth points, corner types, exact numeric
input, pointer and keyboard editing, and Freehand conversion using the checked
sampler. Completed edits preserve the original-image preview/Apply lifecycle;
invalid drafts and excessive point counts refuse visibly. Reset and cancelled
pointer gestures restore defined states. Parent regressions reproduced and
fixed draft-loss, rounding and keyboard ownership defects. Pinned native UI
passes 243 checks and the full prior Swift suite passes 1,665; additional
pointer cancellation tests pass. Independent production review is clear.
Four-engine UI qualification, fixture review and hosted CI remain in progress.

### Recorded selected-ink Curves (candidate)

An admitted Curves Apply now captures its exact owned table and original ink
identity. Version 12 stores 256 finite unit samples with explicit destination
binding; versions 1–11 remain compatible. Preview/Cancel add no rows and
failed native work remains a failure. All 1,650 Swift tests pass. All four
engines pass 423 ink Recorder checks and 186 actual Curves panel checks each.
Independent production review is clear; hosted CI and combined qualification
remain pending. See [ink-recorder.md](ink-recorder.md).

### Preserving compressed CMYK PSD import (candidate)

The explicit CMYK importer now reads flat PackBits/RLE PSDs at 8/16 bits as
well as RAW. The private reader validates every compressed row before native
allocation, retains exact C/M/Y/K samples and the embedded profile, and limits
expanded sample bytes as well as input size. Layered/ZIP PSDs and resources
beyond the single ICC remain outside this preserving subset.
The standalone reader passes 1,011 optimized/sanitized checks and the pinned
native acceptance fixture passes 1,328 checks. Four-engine qualification and
independent review are in progress. See [cmyk-psd-import.md](cmyk-psd-import.md).

### Physical Lab Curves numerical foundation (2026-11-13)

A private row kernel maps normalized 256-sample tables into physical L/a/b
values, retaining integer low bits and explicit physical-space selection
blending. Canonical identity preserves every finite encoding, and invalid
requests leave destination bytes unchanged. Parent regressions reproduced
and fixed unaligned-settings access and an input-alias corruption on refusal.
All 2,551 C checks pass optimized and with ASan/UBSan, including exhaustive
U8/U16 identity on every axis; 10,368 samples match an independent Fraction
oracle. A kernel-only 24 MP float-axis pass measured 0.172 seconds on this Mac;
this excludes native transactions, rendering and UI work. Independent numerical/fixture review found no important issue. Hosted CI
remains pending. This private slice does not yet expose Lab
Curves in the editor. See [lab-curves.md](lab-curves.md).

### Direct physical Lab Curves transaction (candidate)

Additive slot202 applies a normalized 256-sample curve to a captured physical
Lab axis. The existing staged component transaction preserves exact other-axis,
selection, profile and metadata bytes, rejects changed target identities and
publishes one Undo step only after validation and cancellation checks.
Canonical identity still validates affected float samples and mask values.
The first pinned native fixture passes 1,042 checks; the complete four-engine
regression run and independent review are pending. No Lab adjustment panel,
preview or Recorder behavior is enabled by this direct engine operation yet.
See [lab-curves-edit.md](lab-curves-edit.md).

### Captured Lab Curves previews (candidate)

Slots 203–206 add immutable Lab preview baselines and separately owned rendered
copies. Apply shares the staged component transaction and verifies every source
axis, selection and captured target before one Undo publication. Cancel keeps
source pixels and history intact. Ink and Lab preview tokens use one unique
engine counter. The pinned native fixture passes 819 checks after reproducing
and fixing a token collision; all 1,677 Swift tests pass with the new transport.
The remaining engine regression run and independent reviews are in progress.
The Lab panel and Recorder route remain subsequent work. See
[lab-curves-preview.md](lab-curves-preview.md).

### Physical Lab Curves panel (candidate)

The shared sampled-curve panel now has a typed Lab route with physical L/a/b
numeric coordinates, immutable native previews and ordered Apply/Cancel/close
cleanup. All 1,682 Swift tests and 251 pinned-engine GUI checks pass, including
all axes/precisions and pending-work cancellation. The four-engine Lab/ink
panel matrix and independent reviews are running. Lab Recorder replay and
standalone release qualification remain separate follow-up work. See
[lab-curves-ui.md](lab-curves-ui.md).

### Physical Lab Recorder capture and replay (2026-11-13)

A candidate adds version 13 Lab Fill/Curves recording, explicit axis/precision
binding, typed Lab descriptions and queued UUID admission. The pinned fixture
passes 355 checks, including actual binding-sheet choices, physical Fill
oracles, save/load, refusal and Undo. All 1,687 Swift tests pass; source review
and the reproduced channel-reader correction are scoped in
[lab-recorder.md](lab-recorder.md). Four-engine runtime and final installed
qualification are still pending; Lab brush/selection recording stays open.

### Physical Lab Brush capture foundation (candidate)

Slot207 adds atomic actual-brush/configuration capture before physical Lab
painting, with pre-dab mismatch refusal for guarded replay. Swift transports
owned facts and V2 input without dropping optional axes; bounded tablet traces
preserve accepted batch boundaries and timestamp semantics. The old producer
fails the missing-slot regression. All four engines pass 1,268 native checks
plus conformance, and all 1,702 Swift and 141 Python tests pass. Independent
source review and hosted CI remain open. Recorder file and document wiring
remain a subsequent slice.
See [lab-brush.md](lab-brush.md).


### Physical Lab Brush Recorder integration (candidate)

The document now captures complete physical Lab gestures with the effective
native brush facts, owned settings and exact V2 sample batches. Version 14
files preserve optional tablet axes and require an explicit role/precision
binding. Replay validates resource/configuration before painting and cancels
failed strokes. The initial pinned native app fixture passes 325 checks; an
actual older producer preserves live paint and explicitly refuses recording.
All 1,714 Swift and 141 Python tests pass; document/replay review is clear.
Four-engine checks, codec/fixture review and hosted CI remain open.
See [lab-recorder.md](lab-recorder.md). No installed-app change is claimed.


### Lab selection Recorder integration (candidate)

Version 15 adds explicit Lab-only Rectangle/Ellipse/Lasso and All/None/Invert
recording. Geometry and meaningful selection options remain owned, with the
root mask independent of selected axes; no RGB/ink fallback is admitted.
The initial pinned app fixture passes 647 checks, including exact file values,
independent native and Boolean-grid coverage oracles, Undo/Redo and wrong-mode
refusal. All 1,721 Swift and 141 Python tests pass; document/value review is
clear. Codec/fixture review, four-engine checks and hosted CI are pending.
See [lab-recorder.md](lab-recorder.md); installed-app qualification is
separate.

### Lab Recorder qualification fixture correction (2026-11-13)

The combined Recorder release run reproduced one stale Lab Fill assertion:
its older document fixture expected recording to be unavailable. Lab recording
is now supported by the typed Fill/Curves/Brush/selection routes. The fixture
now checks that recording starts, stops, and refuses replay of the empty log.
Its other pixel, Undo, save, recovery and close assertions remain in place.
The failed release evidence is preserved; a fresh release qualification is
required after this fixture-only change. No installed app is replaced here.

### Typed ink brush capture foundation (candidate)

Slots 208–209 add captured CMYK/Multichannel Brush/Pencil begin and rollback,
using the existing scalar painter and complete V2 input. All four engines
pass general conformance, 921 Ink capture and 1,268 Lab brush checks after
reproducing and fixing selection-buffer retention on cancellation.
All 1,729 Swift and 141 Python tests pass. Final review and hosted CI remain
open. Recorder document/file wiring and installed-app qualification are
subsequent work. See [ink-stroke-capture.md](ink-stroke-capture.md).

### Ink Brush and Pencil Recorder integration (candidate)

The document records complete CMYK/Multichannel Brush and Pencil gestures,
including accepted colored settings and exact V2 samples, through version 16
files and explicit ink bindings. Replay validates the same owned target and
brush before painting; typed cancellation restores the tentative gesture.
An actual older 207-slot engine still paints and reports a failed recording
row. The initial pinned app run passes 359 checks across both modes, all three
precisions, both tools and mouse/tablet input. The subsequent fixture also
checks exact command equality after actual disk Save/Load. Seven new codec
tests and seven Lab selection regressions pass. Document and codec reviews
are clear; final fixture review, four-engine checks and full unit tests are
pending. No installation or complete Photoshop 4 parity claim is made.

### Explicit ink coverage in Tool Options (candidate)

CMYK and Multichannel Brush, Pencil and Airbrush show an Ink percentage
slider and numeric field: 0% is paper and 100% is full ink. Colored foregrounds
are displayed using the component painter's normalized display-sRGB Rec.709
luma; opening or refreshing the palette does not neutralize the foreground.
Only a valid explicit edit sets an opaque neutral sRGB gray. Opacity stays
independent. The row keeps active drafts and refuses stale document/tool
callbacks; Lab physical-value controls and ordinary tools retain their routes.
Pure endpoint, colored-luma, invalid-input and locale-parser tests are added.
The build and four focused pure tests pass. A real AppKit field-editor
fixture passes 38 checks across CMYK and Multichannel, including preserved
drafts, invalid text, independent opacity and stale callbacks. Independent
production review found no important issue. Latest-head CI and the remaining
engine checks are pending; this has not changed the installed app.


### Physical Lab Levels (candidate)

Levels now has typed physical Lab row/native services and selected-axis
preview/document routing. The shared Levels panel displays L* 0–100 and
a*/b* −128–127, preserves exact untouched normalized settings, and refuses
invalid drafts. Pinned native checks pass 1,576, including XCF/Undo and
progress-time Undo admission; 7,442 optimized/sanitized and 23,064 independent
rational checks pass. Source reviews found and closed native Undo admission
and row alias/alignment gaps. All four engines pass 1,576 native Levels checks and surrounding
conformance/Ink/Lab regressions. All 1,755 Swift tests and 375 pinned actual-app
checks pass, including bound loaded-file replay and Undo. Native, lifecycle,
Recorder and app-fixture source reviews are complete. Four-engine app checks
and latest-head CI remain pending. See [lab-levels.md](lab-levels.md).
