<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 2: Architecture memo

# Decision memo: a classic native UI on the GIMP engine (2026-11-04)

**Sources and labels.** This memo draws on three research reports: api-churn (AC), engine-hosting (EH) and classic-design (CD). [M] means measured from source or git history; [I] means inferred. I checked one disputed point myself; see "Disagreements".

## 1. The core tension

A different UI, not a theme, means replacing all of GIMP's GTK code: canvas, tools, tool options, filter dialogs and text editing. Only GIMP's internal `app/` code is rich enough to drive a live canvas, and GIMP promises no stability for it. Its versioning policy covers only the public libraries (https://developer.gimp.org/core/maintainer/versioning/).

| Measure | Value |
|---|---|
| Internal functions GIMP's own UI calls (3.2.8) | 1,360 functions. 699 of them are in files a classic editor needs (3,044 references). Plus 27 GimpGui hooks and 744 `gimp->` field accesses [M, AC] |
| Broken call sites per micro release | Median 0, mean about 8, worst 57 (3.0.6). Zero in 5 of 8 intervals [M, AC] |
| Broken by the 3.0.8→3.2.0 minor release | 11 functions and 19 call sites. 34 `#include` lines moved (`app/vectors`→`app/path`). The text-layer model was replaced (GimpRasterizable) [M, AC] |
| Breaks the compiler cannot see, 3.0.0→master | 1 signal gained an argument; 5 properties were renamed or removed (AC's summary says 4 but lists 5) [M, AC] |
| Public libgimp | 0 removals and 0 signature changes in every interval [M, AC] |
| Patches to GIMP needed to host its engine | **0**. The structure is measured; the build procedure is inferred [EH] |
| UI-behaviour fixes to port by hand | 0–39 per micro release (typically 5–25), about 101 per minor [M, AC] |

The code that binds to the engine can be nearly free to update. Tool and palette behaviour cannot, because GIMP fixes it in GTK code you will have thrown away. The stable public API never churns, but it cannot drive a canvas.

## 2. Architectures, ranked

| Rank | Architecture | Patches | Update cost | UX control | Performance risk |
|---|---|---|---|---|---|
| **1** | **In-process adapter over the internal core.** Build GIMP unmodified and link the static libraries upstream already builds for `gimp-console` (`app/meson.build:95-110`) | 0 | Micro: hours to 1 day. Minor: 2–5 days to compile, 1–3 weeks to match behaviour [I, AC] | Full: native canvas, pen pressure, live previews | Low: same data paths as GIMP's own UI |
| 2 | **Hybrid:** the UI previews and draws locally with GEGL and commits through libgimp | 0 | Low to moderate, plus a second renderer to keep consistent | Medium. GIMP's brush engine goes unused, layer modes are internal, text rendering drifts | Medium–high: doubled memory, stale mirror copies |
| 3 | **Out-of-process:** a libgimp 3 extension serves the UI over a socket | 0 | About zero | Low. No reads of the composited image, no change events, no undo list. Undo/redo exist only on master | Very high: one blocking round trip per 128 px tile, about 4,500 messages per 24 MP read [I, EH] |
| 4 | **Patched GIMP fork** that rebuilds the GTK UI | Large, in every GUI directory | High. The 264 UI-only and 43 mixed commits since 3.2.8 would all collide with your patches [M, AC]. GIMP's genAI ban rules out upstreaming them | Limited by GTK3 | Low |

The fork fails both goals, and option 3 fails the UI goal. Option 2 gives up rendering fidelity to make updates easier, but option 1 already makes most updates cheap.

## 3. Recommendation: option 1, built so updates stay cheap

**Zero-patch rule.**
- The GIMP checkout stays byte-identical. A clean `git status` is a CI gate.
- Every change in behaviour goes through hooks GIMP already has [M, EH]:
  - `no_interface=FALSE`;
  - `(module-path "")`, so GTK modules never load;
  - tool infos registered on the `"initialize"` signal, and the `gimp->gui` vtable filled on `"restore"`;
  - your own `GimpDisplay` subclass and `GimpProgress` implementation;
  - overriding PDB procedures as the escape hatch (`pdb/gimppdb.c:240-255`).
- The app compiles GIMP's own startup files with `-DGIMP_CONSOLE_COMPILATION -DGIMP_APP_GLUE_COMPILATION`. It reads the list of libraries to link from `meson introspect` instead of hard-coding it.
- Never load `libgimp` into the app process: it defines the same type and function names as the engine.

**A thin C adapter is the only code that touches GIMP internals.**
- It uses neither AppKit nor GTK. It exports a versioned C API built on opaque handles:
  - documents, the layer tree and the undo stack;
  - tile reads of the composited image;
  - strokes (begin, motion, end) with pressure;
  - filter sessions (new, preview, commit, abort);
  - text markup;
  - change callbacks.
- The Swift/Rigi UI sees only that API.
- Differences between GIMP versions are handled with `GIMP_*_VERSION` conditionals inside the adapter.
- At startup the adapter checks each signal's argument count (`g_signal_query`) and each property name (`g_object_class_find_property`). This catches the breaks the compiler misses.
- Before every build, CI runs AC's interface-diff scripts against the functions the adapter actually calls.

**Conformance tests:**
- rendering compared with saved reference images ("goldens") of sample XCF files at several zooms;
- XCF round-trips, watching for XCF version bumps on master;
- replays of recorded pressure strokes for every paint tool;
- filter undo: commit adds exactly one undo step, cancel adds none, and temporary filters never reach the XCF;
- editing, rasterizing and reverting text layers;
- colour picking;
- non-interactive PNG, JPEG, TIFF and PSD import and export.

**CI:** nightly builds against master, the latest stable tag (3.2.8) and the pinned release. Ship only on stable tags. A red master build is an early warning, not a blocker.

**Agent fix loop.**
- When CI goes red, an agent receives:
  - the list of breaks;
  - the upstream commits behind them;
  - GIMP's own UI edits from the same commits. These usually sit in the same commit [AC], so they work as a template.
- The agent edits only the adapter and reruns the conformance tests. A human reviews the diff.
- A second agent sorts each release's editor-relevant UI commits into port, ignore or new feature.

**What "trivial" will and will not mean** [I]:
- **Stable micro releases** are usually a rebuild with no adapter edits. Sometimes a few edits are needed: 3.2.8 changed `gimp_image_pick_color` the day before the tag. A 3.0.6-style silent change is caught by the startup checks, not the compiler. Expect 5–25 UI-behaviour commits to review.
- **Minor releases** take days of adapter work, 1–3 weeks to port behaviour, and new native UI for new engine features. 3.2 added link layers, vector layers and non-destructive filters on groups. That part is never trivial.
- **Model changes** alter what the adapter's API means, not just whether it compiles. Examples are the GimpRasterizable text model, and file-backed buffers and HiDPI `scale_factor` on master.

**Licence and name.** Linking the engine makes the app GPLv3+, which Rigi's Unlicense allows. Keep "GIMP" (a registered trademark) out of the product name.

## 4. Design direction

**Principles** [CD]:
- One click or one key per tool, with flyouts of at most 5 tools.
- The image gets at least 70% of a 1440×900 screen.
- State is always visible, e.g. a title like `name.xcf @ 50% (RGB/16 · sRGB)`.
- The menu bar is complete, and each setting has exactly one home.
- Every slider has a numeric field.
- Adjustments are modeless, previewed and cancelable: OK makes one undo step.
- Layouts are stable and persist across launches.
- Text and values are 11 pt or larger, and modifier keys mean the same thing everywhere.
- Save writes only XCF; Export writes every other format.
- The chrome is grayscale.

Drop the era's single undo, modal dialogs and cryptic "Doc:" readout. Add Retina rendering, tablet support, VoiceOver and dark or neutral colour schemes.

**Rigi extensions** [I, CD]: about 3.5–5k new lines, roughly doubling RigiUI. CD measured RigiUI at 3,072 lines; earlier research gave about 4.7k for the whole Rigi package.

| Extension | Lines |
|---|---|
| Tabbed palette groups (drag tabs between groups) | 1,000–1,400 |
| Two-column tool grid with flyout triangles | 500–700 |
| Snapping and docking palettes | 400–600 |
| Light, gray and dark schemes (amends Rigi's light-Aqua-only rule) | 400–700 |
| Saved workspaces | 300–400 |
| Slider with numeric field | 250 |
| Status strip with zoom field and info pop-up | 250 |
| Foreground/background colour pair | 150 |
| Collapse a palette to its tabs | 150 |
| Per-palette flyout menu | 100 |
| Tab key hides and restores all palettes | 100 |
| Icon button strip | 80 |

The app itself adds roughly 8–12k lines for the canvas, 3–5k for the Options palette and 1.5–2.5k for layer rows.

**GIMP concepts the UI can hide or reshape without patches** [CD]:
- Layer boundaries are hidden, and paint tools grow the layer by default.
- Floating selections appear only for Paste Into and anchor automatically.
- An adjustment layer is a pass-through group holding a filter.
- Saved layer sets replace a link column.
- A History palette is built from the undo stack.
- The filter menu is built from GEGL and the plug-in procedures.
- Tool groups come from GIMP's tool list (3.2.8: 22 slots, 44 tools).

**These would need patches, so leave them out:**
- truly unbounded layers;
- a layer-link column;
- native versions of plug-ins' own custom dialogs, which stay GTK3 windows.

## 5. Spike: 2–3 weeks of agent work

- **Week 1:**
  - Build `GIMP_3_2_0` unmodified on macOS.
  - First adapter, startup modelled on `app/tests/tests.c:68-82`. It should open an XCF, read tiles of the composited image, expose the layer tree and undo, run a pressure stroke and one filter session, and export PNG through the plug-in.
  - A minimal Rigi window with canvas, zoom strip and Layers palette.
  - First conformance tests, with reference images recorded on 3.2.0.
- **Week 2:**
  - Move the adapter to 3.2.8, then to master.
  - Optionally move a second adapter from 3.0.8 to 3.2.0 to measure a real minor release (directory move, new text-layer model).
  - Log every edit: lines and files changed, agent-hours, and whether the compiler or the startup checks caught it.
- **Week 3:**
  - Triage the 48 editor-relevant UI commits from 3.2.0 to 3.2.8.
  - Test a plug-in's nested GLib loop under Cocoa.
  - Performance pass.

**Go only if all of these hold** (my proposed thresholds):
1. Zero patches to GIMP at every tag.
2. 3.2.0→3.2.8 takes at most 1 agent-day and 50 adapter lines, with no change to the adapter API or the Swift code.
3. The move to master takes at most 3 agent-days, and any API change only adds things.
4. The optional 3.0.8→3.2.0 leg takes at most 5 agent-days.
5. All conformance tests pass after each move, and no break gets past both the compiler and the startup checks.
6. Pan and zoom run at 60 fps on a 24 MP image, stroke latency stays under 16 ms, and Cocoa never stalls more than 100 ms during a plug-in call.

**No-go:** any patch is needed, a micro release forces an adapter API change, or the GLib/CFRunLoop integration proves unworkable. Then keep option 3 for automation only and rethink the plan.

## Disagreements

- **3.2.8→master removals:** EH counts 32 engine-wide; AC counts 8. AC showed that whitespace realignment produces false positives. Both agree that 6–7 functions changed among those GIMP's UI calls.
- **Changes inside the 3.2 series:** I confirmed EH's examples with `git diff GIMP_3_2_0 GIMP_3_2_8` in `/tmp/gimp-fork-research/hist/gimp-hist.git`:
  - `MAX_CHANNELS` went from 4 to 5;
  - `GIMP_UNDO_GROUP_VECTOR` was inserted mid-enum;
  - `gimp_drawable_get_active_components` was removed.

  None of these matters when rebuilding from source, but the adapter must never store raw enum numbers.
