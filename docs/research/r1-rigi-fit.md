<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 1: Rigi fit for an image editor

# Rigi as the UI layer for a GIMP-based raster editor: fit assessment (2026-11-04)

**Bottom line:** Rigi gives a raster editor its look, its palette shell and its preview contract. It has almost none of an image editor's widgets. Its code helps only in a macOS-only AppKit front end. On Linux and Windows, Rigi can only serve as a design spec: a GTK3 CSS theme plus focused GTK patches to GIMP, or a new Qt front end.

**Correction to the brief:** Lucerne's Qt port does not mirror Rigi. It contains no Rigi-style widgets at all, and it was written two months before Rigi existed.

**Path legend.** RIGI = `/Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi`, LUC = `/Volumes/PaseoData/TrueNAS/paseo-home/workspace/Lucerne`, SION = `/Volumes/PaseoData/TrueNAS/paseo-home/workspace/Thalyx` (the local checkout of `github.com/L-K-M/Sion`; its README is titled "Sion"). GIMP figures come from a shallow sparse clone of `gitlab.gnome.org/GNOME/gimp` master at commit `2aef5e7`, 2026-11-03. The clone was deleted after counting.

## 0. Facts found locally

- **State of Rigi.** Version 0.1.0, no tags. Local `main` has 3 commits (2026-10-28/29). Three fix PRs are still open (#4–6: try-on detach guard, activation repaint, focus restore).
  - Library code is about 3,070 lines; the rest of the 4,744 total is the gallery (690) and tests (982).
  - Its only dependencies are AppKit and Foundation (RIGI/Package.swift, RIGI/AGENTS.md).
- **Who uses Rigi:**
  - Lucerne: LUC/Package.swift:46, pinned at `8b569d0`. Seven LucerneKit files import RigiUI.
  - Sion: SION/Package.swift, pinned at `8b569d0`, macOS-only via `#if os(macOS)`.
  - MurtenUtilities: pinned at `dcfc91e`, uses only `StatusBar.swift`. It is a Norton-Utilities-style Mac toolbox.
- **Sion is a canvas app:** "Native macOS diagramming and digital illustration" (SION/README.md).
  - SionKit is 10.5k lines on top of Rigi. It registers inspector, library and history palettes (SION/Sources/SionKit/Inspector/SionPalettes.swift:6-109).
  - It uses `ClassicToolControl` for tools and zoom inside a native `NSToolbar` (SION/Sources/SionKit/Document/SionDocumentWindowController.swift:307-369).
  - Its canvas is a vector `NSView.draw` inside a magnifying `NSScrollView` (SION/Sources/SionKit/Canvas/SionCanvasView.swift, 3,418 lines). That is not a raster tile renderer.
  - Sion's "History" palette lists saved revisions (SionPalettes.swift:649-700), not the undo stack.
- **Lucerne's Qt port** is LUC/linux, 10,153 lines: `src/app` 5,001, `src/core` 3,060, tests 2,092.
  - It uses stock `QToolBar`, `QComboBox`, `QFontComboBox`, `QToolButton` with freedesktop theme icons, `QColorDialog`, a `QDockWidget` navigator and `QStatusBar` (LUC/linux/src/app/MainWindow.cpp:364-460, 563).
  - It has no `QProxyStyle`, no stylesheet chrome, no `QLinearGradient`, no try-on and no tear-off. The string "Rigi" appears nowhere under `linux/`.
  - **Code that mirrors Rigi's controls: 0 lines.**
  - Timeline: 11 of 13 Qt commits landed on 2026-08-23. Rigi was extracted on 2026-10-28 (LUC commit `637bb97`).
  - What the two apps actually share is the `.luce` format spec plus a fixture corpus (LUC/docs/ubuntu-port.md). There is no shared UI contract.

## 1. What Rigi provides today

| Area | Types | File |
|---|---|---|
| Chrome tokens and drawing | `ClassicChrome` (20 pt control height, bezel gradients for normal/on/pressed, muting when the window is inactive, window silhouette), `ClassicText` (engraved labels), `ClassicGlyph` (text, alignment bars, 14 pt image) | RIGI/Sources/RigiUI/ClassicControls.swift:12-225, 821-858 |
| Activation repaint | `ClassicChromeActivation` redraws the whole view tree on main/key change | ClassicControls.swift:134-163 |
| Hand-drawn controls (NSControl or NSView) | `ClassicSegmentedControl` (selectOne / selectAny / momentary), `ClassicPopUp`, `ClassicChooserControl` (`representsOpenPalette` sunken state), `ClassicSizeField` (text field plus preset menu), `ClassicButton`, `ClassicColorWell` (an `NSColorWell` subclass that drives the shared `NSColorPanel`) | ClassicControls.swift:226-820 |
| Native-backed controls | `ClassicToolControl` (`NSSegmentedControl`), `ClassicToolbarButton` (`NSButton`), `ClassicPopUpButton` (`NSPopUpButton`) | RIGI/Sources/RigiUI/ClassicNativeControls.swift, ClassicBarView.swift:51-84 |
| Surfaces | `ClassicBarView` (.toolbar / .panel), `ClassicPanelView`, `ClassicInsetBox` (white well), `ClassicRuleView`, `EtchedSeparatorView`, `ClassicWindow` (private `_cornerMask` silhouette) | ClassicBarView.swift:14-49, ClassicControls.swift:724-951 |
| Metrics | `ClassicMetrics`: toolbar 34, status bar 22, spacing 9/10/8 | ClassicBarView.swift:4-10 |
| Status bar | Engraved message plus a momentary −/100%/+ zoom cluster with callbacks. No hover-help API, no coordinates or units | RIGI/Sources/RigiUI/StatusBarView.swift |
| Picker | `PickerItem` (id, title, dimmed, separator), `PickerListView`: filter field, one-column text table at 24 pt rows, per-row specimen `NSFont`, arrow/Return/Esc keys, optional edit well, flat drag-reorder | RIGI/Sources/RigiUI/PickerListView.swift |
| Try-on | `TryOnPopover`: transient `NSPopover` with `onPreview` / `onDetach` / `onFinish(Outcome.commit\|.cancel)` and a `TearOffPalette` seam | RIGI/Sources/RigiUI/TryOnPopover.swift |
| Palettes | `PaletteKind`, `PaletteDefinition` (fixed or resizable with a minimum, frame autosave), `PaletteContent` (`retarget(to: Target?)`, present/dismiss hooks), `Palette` (popover → panel lifecycle), `PaletteCenter` (one per kind; retargets on main-window, close and app-activate events) | RIGI/Sources/RigiUI/Palettes/PaletteTypes.swift, Palette.swift, PaletteCenter.swift |
| Palette window | `ClassicPaletteWindow`: borderless, non-activating, `.floating` level, `hidesOnDeactivate`, pinned to Aqua, optional palette-local undo manager. `PaletteChromeView` has a 16 pt title bar and close dot. Resize bands and keep-on-screen constraint | RIGI/Sources/RigiUI/Palettes/ClassicPalette.swift:12-61, PalettePanel.swift |
| Spec and QA | Interface guidelines (popover vs palette vs dialog, tear-off contract, try-on/undo table), integration guide, verification checklist; gallery with smoke test and screenshot | RIGI/docs/*.md, RIGI/Sources/RigiGallery/* |

**Things Rigi does not have at all:** slider or scrub field, numeric stepper with units, tree or outline list, thumbnail grid, tab control, collapsible sections, dialog shell (OK/Cancel/Reset/Preview), docking, dark theme, a canvas of any kind.

**Accessibility debt.** Lucerne's review (LUC/ANALYSIS.md, "Custom controls are unreachable by keyboard…") found the hand-drawn controls mouse-only, with no accessibility roles. Only the palette close button sets an accessibility label (ClassicPalette.swift:204-206).

**Light only.** There are 26 hard-coded `calibratedWhite` colors, 2 Aqua pins and no `effectiveAppearance` checks. RIGI/docs/verification.md item 7 says outright "Rigi stays Aqua".

## 2. Gaps for an image editor

Key: **Reuse** = usable as-is. **Extend** = add a generic piece to Rigi. **App** = specific to the image editor. Sizes are rough Swift line counts.

| Need | Rigi today | Verdict | Size |
|---|---|---|---|
| Tool palette (grouped tools, flyouts, FG/BG at the bottom) | `ClassicToolControl` / `ClassicSegmentedControl` are a single horizontal row. GIMP has had tool groups since [2.10.18](https://gimp.org/news/2020/02/24/gimp-2-10-18-released) | Extend: `ClassicToolGrid` plus a group button with corner triangle, long-press or right-click flyout, shortcut tooltips. App: about 66 tool definitions and an icon set (art effort) | 500–800 Rigi; icons separate |
| Tool options bar | `ClassicBarView`, popups, `ClassicSizeField`. No slider or spin | Extend: `ClassicSliderField` (GIMP-SpinScale style: label inside, drag to scrub, type to enter), number field with units and arrow keys, a form builder driven by properties. App: per-tool option sets | 800–1.2k Rigi; 4–8k app |
| Layers palette (thumbnails, eye/lock/chain, inline rename, drag reorder into groups, masks, filter badges, mode and opacity header, bottom button bar) | Only the palette host, `ClassicPopUpButton`, the inset well. `PickerListView` reorder is flat and text-only | Extend: list-well styling, bottom button bar, slider. App: outline view, async thumbnails, mask and filter-stack rows (GIMP 3 non-destructive filters) | 300 Rigi; 2–3k app |
| Channels / Paths | – | App, reusing the Layers infrastructure | 0.6–1k each |
| Color: FG/BG swap/reset, color editor (wheel, RGB/HSV/LCh/CMYK, hex), swatches | `ClassicColorWell` opens the system `NSColorPanel`, which is not GEGL/babl color-managed and has no soft-proof or high bit depth | Extend: FG/BG widget (generic). App: color editor bridged to `GeglColor`, swatch grid | 200 Rigi; 2–3k app |
| Brush / pattern / gradient / font / preset pickers | `TryOnPopover` plus `PickerListView` with font specimens only | Extend: `PickerItem` gets an image provider and a grid mode (`NSCollectionView`), tag filter, a slot for quick size/hardness sliders; keep the try-on contract. App: rendering resources to images | 700–1k Rigi; 1–2k app |
| Gradient editor | Only hosting | App: stop bar, midpoints, per-stop color and opacity | 1–1.5k |
| Histogram / Curves / Levels with live preview | No dialog shell | Extend: `ClassicFilterDialog` frame (presets popup, Preview checkbox, Split toggle, Reset/Cancel/OK, progress). App: histogram, curves and levels views | 400 Rigi; 2–3k app |
| Filter dialogs generated from parameter specs | Nothing | Extend (toolkit-neutral): a `ParameterSpec` model turned into Rigi forms (range with ui-min/max/gamma, enum, bool, color, seed, unit, point). App: a GParamSpec bridge plus custom on-canvas handles. GIMP uses `gimppropgui-generic.c` plus 21 custom per-operation GUIs (6.8k lines of C in `app/propgui`) | 1.5–2.5k Rigi; 2–3k app |
| Canvas host (rulers, guides, zoom/scroll/rotate, tiled rendering) | Not Rigi's job. Only the status bar zoom cluster | App: a Metal/`CAMetalLayer`-backed view in a scroll view; tile cache fed from GEGL projection mipmaps; async chunked updates; display color management; overlays (marching ants, guides, grid, handles, brush outline); tablet pressure and tilt; rulers (`NSRulerView` or custom). GIMP's `app/display` is 69.1k lines of C; Sion's vector canvas, which is not tiled, is 3.4k | 8–15k app; status bar extension 200 Rigi |
| Navigator | – | App, hosted in a palette | 400–600 |
| Undo history palette | Sion's History palette shows revisions, not undo | App: list over `GimpUndoStack` with thumbnails | 400 |
| Dark / gray / light | Aqua only, literal colors | Extend: turn `ClassicChrome` into token sets resolved by appearance or an explicit theme; gallery matrix. Product decision, effort M+ in LUC/ANALYSIS.md. Image editors expect neutral gray or dark; GIMP 3.2 ships Dark/Gray/Light plus System ([3.2 notes](https://www.gimp.org/release-notes/gimp-3.2.html)) | 500–800 churn |
| Docked panel columns, tab groups, collapse to icons, workspaces, Tab hides palettes | Floating panel or popover only; `closeAll()` | Extend: add a `.docked` presentation, a dock column container, tabbed stacks, layout persistence. This is the defining 2010 pro-app pattern (Photoshop CS4/CS5 era) and GIMP's single-window mode | 1.5–3k Rigi |
| Keyboard and accessibility on the hand-drawn controls | Missing | Extend (required for a pro app) | 300–600 |
| Menus, actions, shortcuts editor, preferences, New/Export dialogs | – | App. GIMP's `app/actions` alone is 40.2k lines of C | 10–20k |

**Totals:**

- **Rigi extensions:** about 6–10k lines, which is 2–3× today's library. A raster editor would become the main force shaping Rigi's API.
- **App-specific front end:** roughly 50–80k lines of Swift plus a GObject bridge of 5–10k.
- **For comparison, GIMP's GTK UI layer is about 467k lines of C:**

| GIMP directory | Lines of C |
|---|---|
| `app/widgets` | 158.7k |
| `app/tools` | 81.7k |
| `app/display` | 69.1k |
| `libgimpwidgets` | 59.3k |
| `app/dialogs` | 40.4k |
| `app/actions` | 40.2k |
| `app/gui` | 8.0k |
| `app/propgui` | 6.8k |
| `app/menus` | 2.6k |

## 3. How well Rigi's contracts fit

### Try-on and undo contract vs. GEGL filter preview

GIMP's `GimpDrawableFilter` is the counterpart:

- `gimp_drawable_filter_new` / `_apply`
- `_set_preview` and `_set_preview_split` (gimpdrawablefilter.c:1106, 1127)
- `_commit(filter, non_destructive, progress, cancellable)` (:1567)
- `_abort` (:1630)
- Undo is pushed only on commit: `gimp_image_undo_push_filter_add` and `_filter_modified` (gimpfiltertool.c:1286, 1377)

| Rigi event (RIGI/docs/interface-guidelines.md, "Try-on and undo") | GEGL/GIMP equivalent | Fit |
|---|---|---|
| Open: capture one baseline | Create the filter and apply it. The baseline is the unfiltered drawable as a graph node, so no pixel snapshot is needed (cheaper than Lucerne's `textStorage.copy()`, LUC/Sources/LucerneKit/Document/EditorController.swift:609-621) | Good |
| Browse without undo | Set node properties or swap the operation, then re-render asynchronously and progressively (mipmap level) | Good, but Rigi's `onPreview` is synchronous; the editor must handle "still rendering" |
| Return: commit | `commit(non_destructive: true)` adds the filter to the layer's filter stack (GIMP 3 non-destructive editing) | Good. Commit can be slow, show progress and be cancelled, but `Outcome` has no "commit failed or cancelled" path |
| Esc: restore | `abort` | Good |
| Click-away keeps the preview | A transient `NSPopover` closes on any outside click. Filters need canvas interaction during preview (dragging the split line, center or point handles, picking colors), so a stray click would commit an expensive full-resolution render | **Mismatch for filters.** Use Rigi's own "Dialog/sheet" category with explicit OK/Cancel, Preview and Split. Keep try-on for cheap list choices: blend mode, brush or preset, LUT or filter preset, gradient preset, text font |
| At most 1 undo per session, 0 if cancelled | Same as GIMP | Exact |
| Finish one preview before starting another; handle target changes | GIMP allows one active filter tool and halts it on image or display change | Good. The app must connect palette retargeting to halting the preview |
| Re-editing an existing filter | Baseline = the old parameters; commit = `filter_modified` | Good |
| Continuous drags (curves, levels, opacity) | Not list browsing. Lucerne already routes color-well drags through try-on with a settle timer (LUC/Sources/LucerneKit/Views/ToolbarView.swift:54-58, 312-315) | Pattern exists but each app re-implements it. A toolkit-neutral `PreviewSession` state machine (idle / previewing / rendering / committing) would be worth adding to Rigi |
| Preview toggle and split view | Not a Rigi concept | Extend (dialog footer) |

### PaletteCenter (one palette per kind, follows the front document) vs. a multi-image editor

- **Good matches:**
  - GIMP's dock windows follow the active image by default (`auto_follow_active = TRUE`, app/widgets/gimpdockwindow.c:115, 280).
  - Most of its dockables are singletons: layers, channels, paths, undo history, histogram, navigation, tool options, color and so on (app/dialogs/dialogs.c).
  - Palettes tied to global context (brushes, colors, tool options) work if the `target` closure returns an app-context object.
  - `hidesOnDeactivate` and non-activating panels match classic Mac palettes.
- **Mismatches:**
  1. The front document is inferred from `NSWindow` main-window notifications (PaletteCenter.swift:53-84). Tabbed single-window mode and multiple views of one image need manual `frontDocumentDidChange()` calls and image-level identity. The API exists, so this is minor.
  2. There is no per-palette "lock to this image" and no second instance of a kind; GIMP allows both. Minor.
  3. **Presentation is only `.popover` or `.panel`** (PaletteTypes.swift:73-76). There is no docking, tabbing, collapsing or workspace layouts. With 20+ dockables this is the main structural gap.
  4. Retargeting runs synchronously on the main thread and only for palettes on screen. Changing the active layer inside the same image is the content's own job. Thumbnails must be generated asynchronously.
  5. Two content instances per kind (popover and panel; `precondition` at Palette.swift:227-241). Heavy palettes must share their model.
  6. Two palette systems coexist, `TearOffPalette` and `PaletteCenter` (the gallery uses both). Consolidate before building on them.

### Wider architectural mismatches

- **The seam in GIMP exists but is internal.** `app/core`, `app/gegl`, `app/operations` and `app/paint` include no `gtk.h` at all; 453 files in widgets, display and tools do. `gimp-console` builds without a GUI (app/meson.build, app/gimpconsoleapp.c). But `app/` is not a stable library: no public API, GObject in C, driven by the GLib main loop. `libgimp` is the out-of-process plug-in API and is unsuitable as a front-end binding.
- **Tools are coupled to GTK.** 40 of 116 `app/tools/*.c` files include the display shell and 100 include `widgets/`. Tool interaction must be rewritten. The paint cores in `app/paint` are reusable.
- **Plug-in dialogs would stay GTK.** They run in separate processes using `libgimpui`. On macOS, an AppKit front end would show GTK windows from every plug-in.
- **Bridging.** Swift needs a hand-written GObject layer (signals, refcounting, properties) over C.
- **Licensing is fine.** Rigi is Unlicense and can be combined with GPLv3; the fork as a whole is GPLv3.

## 4. Cross-platform options

| Option | What Rigi contributes | Pros | Cons / risk |
|---|---|---|---|
| **A. macOS-only AppKit front end** (Rigi plus GIMP `app/core` linked in-process, or Rigi plus GEGL/babl directly) | The actual code: chrome, palettes, try-on; Sion is the precedent for a canvas app | Most native result; Rigi gets used as-is plus the extensions above | Leaves out most GIMP users (Linux and Windows). Mac competition is strong, and [Affinity is now free](https://petapixel.com/2025/10/30/all-new-all-in-one-affinity-app-for-creative-pros-is-available-now-for-free) on macOS and Windows. Still needs the GObject bridge and a tools rewrite. Plug-in dialogs look mismatched. GIMP's internals keep changing (3.2 added link, vector and channel-filter features). Realistically a new app of 60–90k lines |
| **B. Qt front end "following Rigi guidelines"** | Only the guidelines (RIGI/docs/interface-guidelines.md). A RigiQt layer (`QProxyStyle`, about 15 custom widgets, a palette manager on `QDockWidget`/`Qt::Tool`) would be new work, about 4–8k lines of C++ | One codebase for Linux, Windows and macOS. Calling C/GObject from C++ is natural. Krita shows a Qt raster editor is viable | Most expensive option: rewrites the GTK UI (about 467k lines of C as reference; 60–100k lines of C++ realistically). GLib main-loop integration with Qt must be verified per platform; this is my inference, not checked. **Lucerne's evidence cuts against the premise:** its agent-built Qt port was fast because it used stock Qt widgets, it carried zero Rigi look, and it shares only the file format and fixtures |
| **C. GTK3 CSS theme plus icon theme imitating Rigi, plus focused GTK patches** | The guidelines as a token spec: 20 px controls, gradient bezels, engraved text, inset wells, grouping | Cheapest, and works on all three platforms. GIMP 3 themes are CSS (themes/Default: 1,325 lines; user themes load from the config dir, per this [forum thread](https://forum.manjaro.org/t/gimp-not-matching-color-theme/186293)). [GTK3 CSS](https://docs.gtk.org/gtk3/css-properties.html) supports linear-gradient, box-shadow, text-shadow, border-radius and min-height. I expect plug-in dialogs pick up the theme too, but I did not verify that. GIMP already has [on-canvas preview with split view](https://developer.gimp.org/resource/writing-a-filter/), tool-group flyouts, dock auto-follow and non-destructive filters. Can be upstreamed or kept as a small patch queue, which is less exposure to fork drift than a full UI rewrite | CSS cannot move widgets or add behavior: no try-on popovers, tear-off or new layouts. Those need C patches in `app/widgets`. An icon set (SVG) is a separate art job. The result looks like Rigi but is not Rigi |

**Recommendation:**

- Start with **C**: theme, icons, and workflow patches written in GTK. Use Rigi's guidelines and its try-on/undo table as the spec. Usability problems are mostly about information architecture and defaults, not the toolkit.
- Build **A** only as a Mac-native companion on GEGL/babl if a native Mac app is the actual goal.
- **B** only makes sense if the goal is a new cross-platform front end the size of Krita. Lucerne's Qt port does not support the idea that "the same guidelines" give the same look for free.

## Key files

- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/README.md
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/docs/interface-guidelines.md
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/docs/integration.md
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/Sources/RigiUI/ClassicControls.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/Sources/RigiUI/TryOnPopover.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/Sources/RigiUI/PickerListView.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/Sources/RigiUI/Palettes/PaletteCenter.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/Sources/RigiUI/Palettes/Palette.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/Sources/RigiUI/Palettes/PaletteTypes.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Rigi/Sources/RigiUI/Palettes/ClassicPalette.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Lucerne/linux/src/app/MainWindow.cpp
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Lucerne/docs/ubuntu-port.md
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Lucerne/ANALYSIS.md
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Lucerne/Sources/LucerneKit/Document/EditorController.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Thalyx/README.md
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Thalyx/Sources/SionKit/Inspector/SionPalettes.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Thalyx/Sources/SionKit/Canvas/SionCanvasView.swift
- /Volumes/PaseoData/TrueNAS/paseo-home/workspace/MurtenUtilities/Package.swift

**Sources:**
- [GIMP 3.2 release notes](https://www.gimp.org/release-notes/gimp-3.2.html)
- [Phoronix: GIMP 3.2 released](https://www.phoronix.com/news/GIMP-3.2-Released)
- [GIMP 2.10.18 (tool groups)](https://gimp.org/news/2020/02/24/gimp-2-10-18-released)
- [GIMP: writing a filter (on-canvas preview, split view)](https://developer.gimp.org/resource/writing-a-filter/)
- [GIMP 3.2 GEGL Operation manual page](https://docs.gimp.org/3.2/fi/gimp-tool-gegl.html)
- [GTK3 CSS properties](https://docs.gtk.org/gtk3/css-properties.html)
- [GIMP 3 user theme location](https://forum.manjaro.org/t/gimp-not-matching-color-theme/186293)
- [GIMP Default theme common.css (Debian)](https://sources.debian.org/src/gimp/3.2.0-1/themes/Default/common.css)
- [PetaPixel: Affinity free](https://petapixel.com/2025/10/30/all-new-all-in-one-affinity-app-for-creative-pros-is-available-now-for-free)
- [AppleInsider: Affinity free](https://appleinsider.com/articles/25/10/30/affinitys-entire-suite-goes-completely-free-on-mac-with-new-all-in-one-app)
- GIMP source tree: https://gitlab.gnome.org/GNOME/gimp (master `2aef5e7`)
