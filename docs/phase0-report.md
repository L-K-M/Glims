# Phase 0 report: GIMP's engine under a native Mac interface

Date: 2026-11-05. Machine: Mac16,9 (14 cores), macOS 27.0.1, Xcode 27.2.
Plan and criteria: [`plan.md`](plan.md). Commit triage:
[`phase0-triage-3.2.md`](phase0-triage-3.2.md).

## Verdict

**Go.** All six go criteria in `plan.md` hold. Five are measured in full; for
the latency half of criterion 6, Glims was measured against a 60 fps budget,
not side by side with GIMP 3.2.8's own interface (see below).

GIMP's unmodified engine runs in-process behind a small C adapter, a native
AppKit interface edits real images through it, and moving the adapter
between engine versions has so far cost 0, 0 and 15 lines. The ongoing costs
are where the research predicted, not in keeping the adapter compiling:
porting behavior fixes from GIMP's GTK code (28 of 58 editor-relevant
upstream commits between 3.2.0 and 3.2.8) and building native interface for
new engine features (3 of 58).

## What was built

| Part | Size | Notes |
|---|---|---|
| Dependency prefix | 385 MacPorts ports, 8.5 GB | `scripts/bootstrap-deps.sh`; about 2 hours once, minutes after that |
| Engines | 4 sets, about 200 MB each | `scripts/build-engine.sh`; about 3 to 9 minutes per engine |
| Adapter | 1,880 lines of C | `Engine/`; facade v1 in `glims_engine.h` (206 lines); exports one symbol; calls 101 GIMP functions |
| Conformance tests and perf pass | 690 lines of C | `Engine/tests/`; 52 checks |
| Interface | 1,780 lines of Swift | `Sources/GlimsKit`: engine wrapper, tiled canvas, Layers palette, Gaussian Blur dialog, menus, `--engine-smoke-test` |
| Scripts | 1,795 lines | build, update drills, fixtures, interface diff |

The engine runs on its own thread, which owns GLib's main context; the app
calls the facade from any thread. GIMP's nested plug-in loops therefore block
only that thread.

## Go criteria

| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | Zero engine-source patches at every tag; packaging and environment workarounds listed | **Met** | GIMP 3.0.8, 3.2.0, 3.2.8 and master (`32c1ddaa2d`) build unmodified; the build fails if any source tree differs from upstream before or after building. Workarounds: MacPorts instead of Homebrew (gexiv2 bound); typelib repair for 3.0.8 to 3.2.4 (`scripts/fix-typelibs.py`; fixed upstream in 3.2.6, 481bf7a998); the `mypaint-brushes1` port for 3.0.x; the adapter sets `PATH` and `GI_TYPELIB_PATH` for plug-ins |
| 2 | Starting tag to 3.2.8 in 1 agent-day and 50 adapter lines, no facade or Swift change | **Met** | 0 lines; build and tests take about 3 minutes |
| 3 | To master in 3 agent-days, facade changes only additive | **Met** | 0 lines |
| 4 | Optional minor-release drill (3.0.8 and 3.2.0) in 5 agent-days | **Met** | Run in reverse: the adapter, written for 3.2, moved to 3.0.8 across the same interface difference. 15 added lines of `GIMP_CHECK_VERSION` conditionals in one file, one edit round; `interface-diff.py` predicted all three breaks before compiling |
| 5 | All conformance tests pass after each move | **Met** | 52 of 52 checks on all four engines, including the adapter's render of a GIMP-made layered fixture equal to GIMP's own composite (0 of 76,800 pixels differ) and identical pixels and structure after an XCF round trip |
| 6 | Latency on a 24 MP multi-layer file no worse than GIMP 3.2.8; a plug-in call never stalls the interface for more than 100 ms | **Met for stalls; latency within budget, GIMP comparison not measured** | 100 synchronous plug-in calls while the main thread ticked every 10 ms and called the engine on each tick: worst stall 3.5 ms in the final run on any engine, 5.1 ms in any run. Warm panning 1.2 to 7.9 ms per frame and painting 1.8 ms (p95) from pointer sample to pixels, against a 16.7 ms budget. Compositing cost is GIMP's own (same engine code); a side-by-side with GIMP's GTK interface was not run |

## Measurements

Performance pass (`scripts/build-adapter.sh --perf GIMP_3_2_8`): a GIMP-made
6000 × 4000 image with 20 layers in ten blend modes, 1440 × 900 device-pixel
viewport.

| | 100 % | 50 % | 25 % | Fit (22.5 %) |
|---|---|---|---|---|
| First frame of a freshly opened image | 147 ms | 530 ms | 1,689 ms | 1,776 ms |
| Panning into unrendered areas (p95) | 28 ms | 144 ms | 3 ms | 8 ms |
| Panning over rendered areas, per frame (p95) | 1.2 ms | 1.7 ms | 3.4 ms | 7.9 ms |

Opening the image takes about 0.8 s. The canvas draws progressively in
256-pixel tiles from the viewport centre, so a cold zoomed-out view fills in
the way GIMP's display does rather than appearing all at once. Painting:
0.9 ms mean, 1.8 ms p95, 3.1 ms worst from a pointer sample to rendered
pixels. Engine start-up took 7.5 to 11.6 s across runs, each with a new
user directory, so GIMP queried every plug-in; a start with an existing
directory was not timed.

Update drills (the engine update log in `plan.md`):

| From | To | Adapter edits | Facade or Swift edits |
|---|---|---|---|
| 3.2.0 | 3.2.8 | 0 | 0 |
| 3.2.8 | master (3.3.1-dev) | 0 | 0 |
| 3.2.x | 3.0.8 (across a minor release) | 15 added lines, 1 file | 0 |

These figures cover today's adapter, which calls 101 GIMP functions. The
round 2 research counted about 700 functions for a full editor's interface
and measured 11 broken functions at 19 call sites from 3.0.8 to 3.2.0 across
that surface, so expect minor releases to cost proportionally more as the
adapter grows, still days rather than weeks for the bindings.

## Findings

1. **Upstream packaging bug.** GIMP 3.0.8 to 3.2.4 install macOS typelibs that
   point at the dependency prefix (seen at 3.0.8 and 3.2.0), so Python
   plug-ins fail to load in any non-bundled build; fixed upstream in 3.2.6. Repaired in the install tree.
2. **Projection rendering needs engine knowledge.** Reading GIMP's projection
   directly returned empty tiles on first use (its idle chunk renderer holds
   pending work without marking tiles invalid) and transparent areas when
   zoomed out (mipmaps are built from unrendered tiles). Fixed in the adapter
   and guarded by a conformance check that failed on the old code. This is
   the kind of cost that grows with the adapter: behavior, not signatures.
3. **What a host must provide.** GIMP's own smoke test hid these because its
   build environment set them: `PATH` with the engine's `bin` (script
   interpreters), `GI_TYPELIB_PATH` (Python plug-ins), and a backtrace path
   for `errors_init`.
4. **Upstream noise.** GIMP 3.2.0 logs two GLib CRITICALs at start-up
   (`g_file_test`); 3.2.8 and master log none.
5. **Dependency drift for old tags.** MacPorts' `mypaint-brushes` moved to
   2.0 after 3.0.8; the 1.x brushes now come from another port.
6. **Native AppKit sheds GTK-on-macOS fixes.** Ten of the 26 ignored
   upstream commits work around GTK on macOS (shortcuts, Quartz timing,
   monitor scale); Glims needs none of them.

## Not covered, and open risks

- **Interactive plug-ins.** The engine runs with `no_interface` on, so
  plug-ins that draw their own GTK dialogs (G'MIC and similar) cannot show
  them. Turning it off with a `GimpGui` hook table was not tried; that is the
  first experiment for phase 1.
- **Most of an editor.** Selection, transform, text and path tools, editing
  existing filters, tool presets, display color management (monitor
  profiles), and the palette system from `design.md` (tabbed groups,
  docking) do not exist yet.
- **GIMP side-by-side.** Latency was not compared with GIMP 3.2.8's GTK
  interface on this Mac; a manual comparison is the remaining check for
  criterion 6.
- **Distribution.** Bundling the engine and its MacPorts libraries into
  `Glims.app` with relocatable paths, Developer ID signing and notarization
  of the app, GTK3, Python and every plug-in, and third-party notices for all
  of it: none started.
- **CI.** The engine and adapter build only locally (the dependency prefix
  takes hours); GitHub CI builds the app shell.
- **Maintenance.** One maintainer, with agents, for a GPLv3 app tracking an
  engine with no stable internal API.

## Recommendation

Continue to phase 1, in this order:

1. Interactive plug-ins: try `no_interface` off with a `GimpGui` hook table,
   so plug-in dialogs can appear; decide from the result.
2. Bundling and relocation: make `Glims.app` self-contained (engine,
   dependencies, plug-ins) with the third-party notices, still unsigned, so
   it runs on another Mac.
3. The palette system and tool palette in Rigi (`design.md`, section 2).
4. Native tools beyond the paintbrush, porting the triaged behavior fixes as
   each tool lands.
5. A nightly engine matrix (pinned tag, latest stable, master) on a
   self-hosted runner with a prebuilt dependency prefix.
