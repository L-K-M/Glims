# Glims completion ledger

The user requested a complete editor on 2026-11-07 after the ordinary build
opened a disabled placeholder. This ledger distinguishes working features
from the remaining design in `design.md`. Compilation alone does not close
an item. Work proceeds in reviewable slices with engine and on-screen checks.

## Current slice: make the existing editor usable

- [x] Ordinary builds bundle the pinned engine; missing prerequisites fail
      before packaging. Hosted CI explicitly builds only the interface.
- [x] Real first-window drawing requests tiles without a zoom interaction.
- [x] New Image asks for pixel dimensions; Finder opens wait for startup.
- [x] Save, Save As and native/imported file identity behave consistently.
- [ ] Closing and quitting protect unsaved work and drain queued operations.
- [ ] Cut, Copy, Copy Merged, Paste, Paste in Place and Clear use the system
      clipboard, honor selection alpha and preserve undo.
- [ ] Fit Image, Open Recent, repeat export and basic file command validation.
- [ ] A bundled app passes engine checks with development trees inaccessible,
      and actual pointer/keyboard editing, save, reopen and export work.

## Remaining implementation from the design

- [ ] Layers: groups, masks and mask targets, thumbnails, inline rename,
      drag reorder, multi-selection, locks, fit/trim and rasterization policy.
- [ ] Channels and saved selections; Quick Mask with paintable overlay.
- [ ] History palette and image snapshots.
- [ ] Filter discovery and native property forms; editable, reorderable
      non-destructive filter stacks; adjustments and adjustment groups.
- [ ] Place images as layers and GIMP 3.2 link layers.
- [ ] Path fill, vector layers and multi-anchor editing.
- [ ] Brushes, patterns and gradients: resource choosers and presets.
- [ ] Color management: accurate image mode/precision/profile state,
      conversion/assignment and soft proofing.
- [ ] Canvas navigation: rulers, guides, grid, snapping, rotation and
      consistent modifier/trackpad behavior; initial fit avoids palettes.
- [ ] Complete menu coverage, keyboard settings, preferences and persistence.
- [ ] Save a Copy, Revert, Paste as New Image, print and metadata.
- [ ] Recorder and semantic command replay.
- [ ] Accessibility and help content, English UI copy audit.
- [ ] Public distribution checks from `plan.md`: complete corresponding
      sources, remaining license texts, signing/notarization and update process.

## Evidence

Initial inspection: tools, engine-backed layers, selections, transformations,
text, paths, Gaussian Blur and plug-in commands already existed. The ordinary
build omitted the engine. The old smoke test forced synchronous rendering,
masking an independent gray-first-canvas bug. Neither normal Save nor a dirty
close/quit prompt nor clipboard editing existed.

2026-11-07 baseline: the existing engine bundle passed 198 adapter checks and
87 interface checks with the development engine/dependency trees denied.
A new first-draw check then failed on the baseline; a real window reproduced
it and a zoom command made the canvas appear. New Image dimension tests were
observed failing before implementation and pass after it. Packaging preflight
checks cover default, explicit engine, shell-only and invalid combinations.

The expanded engine smoke now passes 96 checks, including automatic first
draw, save/reopen of queued input, export dirty-state preservation, ordinary
Save, close Cancel, failed Save on close and teardown after queued work.
The unit suite currently passes 60 checks. Quit still needs an on-screen
check and independent lifecycle review before this slice is closed.
