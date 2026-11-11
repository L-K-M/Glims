# Glims interface design

Status: draft direction from the 2026-11-04 research
([`research/r2-classic-design.md`](research/r2-classic-design.md)). Implementation
status and verification are tracked in [`completion.md`](completion.md).
Evidence labels: **[M]** measured from source, **[I]** inferred or
estimated. GIMP references are to master 2aef5e7 unless the 3.2.8 tag is
named; Rigi references are to the Rigi repo.

The brief: the design sensibilities of mid-1990s professional image editors,
with a clean tool palette and draggable palettes, an uncluttered and clearly
readable interface, and no copying of any existing application's icons, names
or trade dress.

## 1. Design principles (checkable rules)

| # | Rule | Check |
|---|---|---|
| 1 | **One click or one key.** Every tool has a visible slot or a single-letter key. Group members are reached with Shift+key or a one-level flyout of at most 5 items. | Script the tool registry: every tool has a key and a depth of 1 or less. |
| 2 | **The image wins.** The default workspace leaves at least 70% of a 1440×900 screen to documents. New and opened documents "fit" inside the area outside the palette columns. | No palette overlaps a new document's frame by default. |
| 3 | **State is always visible.** Tool, foreground and background colors, the active layer or mask target, zoom, mode, bit depth, profile and unsaved state are visible without opening anything. Example title: `name.xcf @ 50% (RGB/16 · sRGB)`. | Screenshot review. |
| 4 | **The menu bar is complete.** Every palette button, flyout item and context-menu item also exists in the menu bar, with its shortcut shown. | Diff the command registries. |
| 5 | **One home per setting.** Layer opacity lives only in Layers. Paint opacity lives only in Options. Palettes always show the front document. | No duplicate bindings, and the Rigi retarget contract holds. |
| 6 | **A number beside every slider.** Every continuous control has a typed field with units, arrow-key steps and drag-scrubbing on its label. | Control audit. |
| 7 | **Modeless, previewed, cancelable.** Adjustments preview on the canvas, and panning and zooming keep working during the preview. OK makes exactly one undo step; Escape makes none. Exception: a plug-in's own GTK dialog is modal for editing, because the engine serves other calls from a nested loop while it runs; viewing keeps working. | Undo-stack test for each filter. |
| 8 | **Stable, persistent layout.** Inapplicable controls are disabled, not hidden or reflowed. Palettes never resize under the pointer. Layout survives relaunch. Tab hides and restores everything. "Reset Workspace" exists. | UI tests. |
| 9 | **Readable.** System font, at least 11 pt for values and list rows, about 10.5 pt engraved titles (Rigi already uses 10.5, `PaletteChromeView.drawTitle`). Each icon has a tooltip with name and key, plus an accessibility label. | VoiceOver pass. |
| 10 | **Modifiers mean the same thing everywhere** (see section 4). The status strip shows which modifiers matter right now. | Per-tool modifier table test. |
| 11 | **One obvious way to save.** Save writes only the layered native file. Export writes everything else. Cmd-S never flattens. The title bar and the close prompt say which file is current. | Save/export matrix test. |
| 12 | **Neutral restraint.** Chrome is grayscale. Saturated color appears only in the image, the color controls and the single selection/focus accent. | Pixel audit of the chrome. |

## 2. Window and palette model mapped to Rigi

Rigi today is 3,072 lines of RigiUI source **[M]**. A palette is a popover that tears off into a single-kind floating panel (`Palettes/Palette.swift`). There is one palette per kind, retargeted to the front document (`Palettes/PaletteCenter.swift`). Panels are non-activating and hide when the app deactivates (`Palettes/ClassicPalette.swift`). They have a 16 pt title bar with a close dot, resize bands on the sides and bottom, frame autosave and clamping to the screen (`Palettes/PalettePanel.swift`). In this editor most palettes would open straight to panels (`Palette.showPanel()` already does this), and popovers would be kept for choosers.

| Element | Behavior | Rigi today | Plan | Size [I] |
|---|---|---|---|---|
| **Tool palette** | 2 columns of 24 pt cells. A corner triangle marks a group. Press-and-hold or click-drag opens the flyout; Option-click cycles. GIMP 3.2.8's default `etc/toolrc` has 22 top-level slots, 11 groups and 44 tools **[M]**. Master adds a Shape tool (45 tools, `etc/toolrc`), which is not in 3.2.8. | `ClassicSegmentedControl` / `ClassicToolControl` only lay out in one row | **Extend Rigi**: `ClassicToolGrid`. The app supplies descriptors and icons. Accessibility role is a radio group. | 500–700 |
| Color swatches | Overlapping foreground/background squares with swap and reset hit areas | `ClassicColorWell` (single well, `ClassicControls.swift`) | **Extend Rigi**: `ClassicColorPair` | 150 |
| Mode buttons | Quick mask on/off; screen modes (window, full screen with menu, full screen bare) | Segmented controls exist | App wires them to the existing control | 50 |
| **Options palette** | Contents change with the active tool. Brush, gradient and pattern choosers are popovers that tear off. | `PaletteContent.retarget`, `TryOnPopover`, `PickerListView`, popover tear-off | **App-specific**. The target is the front document plus the active tool. Add `PaletteCenter.contextDidChange()` (it can alias `frontDocumentDidChange`). | App: 3–5k |
| **Tabbed groups** | Several kinds share one panel as tabs. Dragging a tab moves it to another group or out into a new one. | Missing: each `Palette` owns its own `PalettePanel`, and the chrome draws one title | **Extend Rigi**: a `PaletteGroup` host with a tab strip. Each kind lives in exactly one group, which keeps the one-per-kind invariant. | 1,000–1,400 |
| Flyout menu | A triangle in the tab strip opens a per-palette menu | Missing | **Extend Rigi**: add `var paletteMenu: NSMenu?` to `PaletteContent` | 100 |
| Snap and dock | Magnetic edges to `visibleFrame` and to other groups. Groups stack into columns that move together, and document "fit" avoids those columns. | Only screen clamping (`PalettePanel.constrained`) | **Extend Rigi** | 400–600 |
| Collapse | Double-click the title bar to shrink to the tab strip | Missing | **Extend Rigi** | 150 |
| Tab hides all | Tab hides all palettes; Shift-Tab hides all except tools. Inactive while a text field has focus. | `closeAll()` closes palettes and loses state | **Extend Rigi**: `hideAll()` / `restoreAll()` | 100 |
| Workspaces | Named layouts (groups, order, frames, collapsed state, per display). Re-clamped when displays change. | Per-panel `frameAutosaveName` only | **Extend Rigi**: Codable layout | 300–400 |
| Button strip | New, duplicate, mask, delete buttons at the palette foot | `ClassicBarView(style: .panel)` | Add a small icon-button style | 80 |
| Slider field | Label, slider and field, or a field with a pop-up slider. Used for opacity, RGB values and brush size. | Missing (`ClassicSizeField` is text plus presets) | **Extend Rigi**: `ClassicValueSlider` | 250 |
| Layer rows | Eye, lock, thumbnail, mask thumbnail, filter badge, inline rename, drag reorder, group disclosure | `ClassicInsetBox` well | **App-specific** `NSOutlineView` | App: 1.5–2.5k |
| **Document window** | Classic silhouette; title `name @ zoom (mode)`; rulers; neutral canvas surround | `ClassicWindow` | Canvas and rulers are **app-specific**. GIMP's own `app/display` is 63k lines in 90 files **[M]**. | App: 8–12k |
| Status strip | Hint text on the left; zoom field; an info pop-up (dimensions, memory, profile, precision, timing); progress with cancel | `StatusBarView`: a message plus a −/%/+ stepper | **Extend Rigi**: editable zoom field, accessory slots, progress. Keep Rigi's "message left, zoom right" convention. | 250 |
| Appearance | Neutral gray or dark scheme | Fixed `calibratedWhite` colors in `ClassicChrome`; `.aqua` pinned at `ClassicPalette.swift:51` and `TryOnPopover.swift:73` **[M]** | **Extend Rigi**: scheme tokens, inverted engraving, an amended guideline | 400–700 touched |

**Rigi total:** about 3.5–5k new lines, roughly doubling RigiUI **[I]**. Everything stays generic: no document model and no GIMP types.

## 3. GIMP 3.2 concepts and how the classic UI shows them

The 3.2 features below come from the release notes (https://www.gimp.org/release-notes/gimp-3.2.html) **[M]**. File presence is confirmed in the GIMP_3_2_8 tag: `gimplinklayer.c`, `app/path/gimpvectorlayer.c`, `gimpdrawablefilter.c` **[M]**.

| Concept | What the user sees | Engine impact |
|---|---|---|
| Layer size vs canvas | The layer boundary is hidden by default (a View toggle shows it). Paint tools default to "expand layer" (`expand_use`, `app/paint/gimppaintoptions.h:106`). New layers are canvas-sized. Layer > Fit to Canvas / Trim uses `layers-resize-to-image` and `layers-crop-to-content`. Fill or filter outside a layer offers "Fit layer first". | Front-end policy. *Truly unbounded layers would need an engine patch, so don't promise them.* |
| Floating selections | In GIMP 3, plain Paste already makes a new layer unless a mask is selected (`edit-actions.c` maps `edit-paste` to `NEW_LAYER_OR_FLOATING`; `edit-commands.c` ~L389–410) **[M]**. Paste Into and moving selected pixels show a temporary "Floating" row with Anchor and New Layer buttons. An idle floating selection survives choosing Move, paint or selection tools. Anchoring is interaction-specific; other target picks can be refused until it is resolved. See [`floating-tool-policy.md`](floating-tool-policy.md) for the measured native rules and pending front-end interactions. | Front-end |
| Save vs Export | Save and Save As write XCF only. Export… (Shift-Cmd-E) picks the format. "Export to name.png" or "Overwrite name.png" (Cmd-E) reuse GIMP's `file-export` / `file-overwrite` logic (`file-actions.c:168,293`). Exporting never marks the document clean. | Front-end |
| Tool options | One Options palette with presets. Non-paint tool options must be rebuilt, because every `*options*.c` includes gtk.h. | Front-end (rebuild) |
| Non-destructive filters | A filter sub-row under the layer with eye, edit, reorder and merge. Filters on groups and on unrasterized text, link and vector layers are forced non-destructive (`filters-actions.c:888`). Filter dialogs are non-modal, with forms generated from GEGL properties. The 22 custom `app/propgui` files **[M]** need native versions or the generic form. Commit and undo must be rewritten, because they live in `gimpfiltertool.c`. | Front-end (rebuild) |
| Adjustment layers | "New Adjustment Layer" creates an empty pass-through group with a filter, which the 3.2 notes call adjustment-layer-like. | Front-end |
| Layer groups and masks | Folder rows. A mask thumbnail sits beside the layer; clicking it targets the mask, shown with a highlight ring. Option-click views the mask. "Edit Mask Immediately" is a preference. | Front-end |
| Text, link and vector layers | A badge on the row; double-click edits it. Destructive edits need Rasterize, so the user gets a prompt with Rasterize, Revert Rasterize or Cancel. Text editing must be rebuilt natively (GIMP uses GtkTextBuffer) while round-tripping GimpText Pango markup. Link layers come from File > Place (`file-open-as-link-layers`). | Front-end (text editing is heavy) |
| Layer linking | GIMP 3 has no item linking: `gimpitem.h` has no `get_linked`, and `PROP_LINKED` survives only as legacy XCF ID 9 **[M]**. Show no link column. Use multi-select plus saved "Layer Sets" (`PROP_ITEM_SET` = 40). | Front-end. Adding a link column back would need a patch, so don't. |
| Paths | A Paths palette with stroke, fill, to-selection and to-vector-layer. The pen tool must be rebuilt (`gimppathtool.c` is GTK); the path model is core (`app/path`). | Front-end |
| Channels | Component channels with eye and active toggles, plus saved selections. Filters can apply to channels in 3.2. | Front-end |
| Quick mask | A mode button and the Q key. Core: `gimpimage-quick-mask.c`. | Front-end |
| Undo history | A History palette built from the core undo stack. "Snapshot" duplicates the image. The memory limit is GIMP's `undo_size` (`gimpcoreconfig.h:84`). | Front-end |
| Color management | Image > Color Profile > Assign/Convert (core). The display transform must be native: GIMP's version is GTK-bound (`gimpdisplayshell-profile.c`). Options are `libgimpcolor/gimpcolortransform.c` (lcms, no GTK) or ColorSync. Includes soft-proofing. | Front-end |
| Filter menu and plug-ins | Built dynamically from GEGL entries (135 in `filters-actions.c` **[M]**) and PDB menu paths. Plug-ins with standard procedure dialogs can run NONINTERACTIVE behind a native form generated from their argument specs. Plug-ins with custom GTK UIs still open GTK3 windows: they float over Glims, hide when Glims is inactive, use GIMP's light theme, and report progress and Cancel to the status strip. Engine menu paths map by name: Filters to Filter (merged with native categories), Colors to Image ▸ Adjust, Image, Layer, Select, File and Edit to the same menus, anything else to Filter ▸ Other; bracketed path parts are sections. | *Making arbitrary plug-in dialogs native would mean patching libgimpui, so don't. Accept the GTK fallback.* |
| Scripting | Script-Fu and Python plug-ins work unchanged through the PDB. A "Recorder" palette logs the front-end's own semantic commands and replays them. | Front-end |

**Patch-needing items, all avoided:** unbounded layers, a layer-link column, and native UIs for custom plug-in dialogs. Nothing else in this plan changes engine behavior **[I]**.

## 4. Menu bar and keyboard model

| Menu | Key items |
|---|---|
| App | About, Preferences… (Cmd-,), Keyboard Shortcuts…, Hide, Quit |
| File | New… N, Open… O, Open Recent, Open as Layers…, Place (link layer)…, Close W, Close All, Save S, Save As… Shift-S, Save a Copy…, Revert, Export… Shift-E, Export/Overwrite "name.png" E, Print… P |
| Edit | Undo Z, Redo Shift-Z, Cut, Copy, Copy Merged Shift-C, Paste V, Paste in Place Shift-V, Paste Into, Paste as New Image, Clear, Fill…, Stroke Selection…, New Brush/Pattern from Selection |
| Image | Mode, Precision, Color Profile (Assign/Convert/Soft-Proof), Adjust ▸ (GIMP's Colors menu: Levels, Curves, Hue-Saturation, Color Balance, Threshold, Invert…), Image Size…, Canvas Size…, Crop to Selection, Rotate/Flip, Guides, Metadata |
| Layer | New ▸ (Layer, Group, Adjustment, Text, Vector), Duplicate, Delete, Mask ▸, Filters on Layer ▸, Rasterize / Revert Rasterize, Arrange ▸, Merge Down, Flatten, Fit to Canvas, Trim, Lock ▸ (Pixels, Position, Transparency) |
| Select | All A, Deselect D, Inverse Shift-I, Float, By Color, Grow/Shrink/Feather/Border, Save to Channel, Load from Channel, Quick Mask |
| Filter | Last Filter, Recently Used, then dynamic categories (Blur, Enhance, Distort, Light & Shadow, Noise, Edge, Generic, Artistic, Map, Render, Web, Script-Fu, Python) |
| View | Zoom In/Out, Fit (Cmd-0), Actual Pixels (Cmd-1), Rotate View, Rulers, Guides, Grid, Snap, Layer Boundary, Selection Edges, Canvas Surround Color, Display Proof |
| Window | Palettes by name, Workspaces ▸ (Save, Reset, list), Arrange, documents |
| Help | Search, Manual (links to GIMP docs) |

**Keyboard model**
- Tools use unmodified single letters (the tooltip shows "Brush (B)"). Shift+letter cycles within the group, and holding the letter switches tools temporarily ("spring-loaded"). Letters go to text whenever a text field or the text tool has focus.
- Space = temporary Hand. Option with a paint tool = temporary Color Picker. Cmd = temporary Move. Arrows nudge 1 px; Shift-arrow nudges 10 px.
- Selection modifiers are two-phase. Before the drag: Shift adds, Option subtracts, Shift-Option intersects. During the drag: Shift constrains and Option draws from the center.
- Other keys: D default colors, X swap colors, Q quick mask, F cycles screen modes, Tab / Shift-Tab hide palettes, [ ] brush size, Shift-[ ] hardness, digits 1–0 set opacity. Return and Escape are tool-specific: Return applies a pending Crop or Transform and Escape cancels it; with the Text tool a plain Return inserts a newline, while Command-Return, Escape or a click outside finishes and applies the text; with the Path tool Return or Escape ends the current subpath.
- Respect macOS reservations: Cmd-H, Cmd-M, Cmd-Space, Cmd-` and Cmd-Q keep their system meanings, so Curves and similar items get other shortcuts.
- Trackpad: pinch zooms, two fingers pan, rotate rotates the view. Option-scroll zooms.

## 5. What not to carry over, and modern requirements

**Drop from that era:**
- A single undo level (replace with full history).
- Modal adjustment dialogs (replace with modeless, non-destructive ones).
- 9 pt bitmap fonts and 1-bit icons.
- Palettes that cover the document on small screens.
- The cryptic "Doc: 900K/900K" readout. Keep the readout pop-up, but fill it with useful choices.
- A locked "Background" layer. GIMP has none; don't invent one.
- Mandatory floating selections.
- Preferences that need a restart or memory-partition settings.
- Pinstripe decoration and window-shade sounds.
- Hidden Option-click features with no on-screen hint.
- Any Adobe icons, names or trade dress. Use GIMP or neutral names, for example "Lock Transparency".

**Modern requirements to honor:**

| Area | Requirement |
|---|---|
| Retina | The canvas renders in device pixels, and "Actual Pixels" means one image pixel per device pixel. Icons are vector at all scales. |
| Large images | Tiled, mipmapped rendering from the GIMP projection, off the main thread. Cancellable progress in the status strip. Nested GLib loops from plug-in calls must not stall Cocoa event handling **[I]**. |
| Tablets | Map NSEvent pressure, tilt, rotation and tangential pressure onto GimpCoords (`pressure`, `xtilt`, `ytilt`, `wheel`, `velocity`, `direction`; `app/core/core-types.h:282–297` **[M]**). Use coalesced events. The pen's eraser end selects the eraser automatically. |
| Accessibility | VoiceOver labels on every tool and row. Full Keyboard Access into palettes. Honor Reduce Motion (no flyout animation) and Increase Contrast. Eye and lock states are told apart by shape, not color alone. |
| Appearance | Rigi's grays are neutral `calibratedWhite` values, but bright light chrome around an image still skews tone judgement **[I]**. Make the canvas surround a selectable neutral gray, defaulting to mid or dark gray (GIMP has the same idea under View > Padding Color). Ship three Rigi schemes: Classic Light, Neutral Gray and Dark. This needs the tokenization above and an amendment to the Rigi guideline that mandates light Aqua. |
| Spaces, displays, modes | Palettes already follow full screen and Spaces (`collectionBehavior` in `ClassicPalette.swift`). Workspaces re-clamp when displays change. |
| High bit depth | The title bar and Info palette show precision. Pickers offer percent and float readouts. |
| Recovery | GIMP 3.2 may not have autosave; I did not check this. If it doesn't, the front-end can periodically "Save a Copy" to a recovery folder **[I]**. |

## 6. Open design decisions

- **Save and Export.** The draft keeps GIMP's split (Save writes the layered
  native file, Export writes other formats) with clear labels. A single Save As
  with a format pop-up is equally possible: it is front-end policy and needs no
  engine change.
- **Appearance schemes.** Neutral gray and dark schemes require amending
  Rigi's light-Aqua rule and tokenizing `ClassicChrome`.
- **Native file format.** XCF for now. GIMP is discussing a successor format;
  follow it through the engine rather than inventing one.
- **Tool presets.** Whether Glims reads GIMP's tool presets and `toolrc`, which
  requires registering tool-option types with GIMP's names and properties.
