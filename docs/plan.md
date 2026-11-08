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
