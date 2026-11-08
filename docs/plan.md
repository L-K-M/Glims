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

- Developer ID signing and notarization for the app, GTK3, Python and every
  plug-in executable; third-party plug-ins probably need library validation
  disabled. Lucerne and the other apps currently ship ad-hoc signed.
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
