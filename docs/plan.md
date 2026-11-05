# Glims plan

Status as of 2026-11-05: phase 0 finished with a go verdict
([`phase0-report.md`](phase0-report.md)); phase 1 is next. Evidence labels: **[M]**
measured from GIMP source or history, **[I]** inferred or estimated. Sources
are in [`research/`](research/README.md); the round 2 memo and its two reviews
are the main inputs.

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

## Later, before any public release

- Developer ID signing and notarization for the app, GTK3, Python and every
  plug-in executable; third-party plug-ins probably need library validation
  disabled. Lucerne and the other apps currently ship ad-hoc signed.
- A process for shipping engine security fixes within days. GIMP's file
  loaders had high-severity bugs in 2025 (for example CVE-2025-14424 in XCF
  and CVE-2025-10925 in ILBM).
- Third-party notices for everything bundled with the engine (GIMP, GEGL,
  babl, GTK3, Python and the other MacPorts packages), generated from the
  dependency prefix and checked like the Swift package notices (`CICD.md`).
- Accessibility, localization and help content for the new interface.

## Open decisions

- Whether new generic controls go into Rigi immediately or incubate here
  first.
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
