# Editor completion targets

The current brief is broader than the earlier implementation plan: open in
five seconds, provide at least Photoshop 4 level editing functionality, and
make the whole editor fast, usable and attractive. Notarization is excluded
by the user. This checklist remains open; the earlier verification totals do
not establish these targets.

## Startup

- [ ] A fresh Glims user directory reaches a rendered, editable document with
      tools and commands available within five seconds of ordinary macOS launch.
- [ ] Repeat with existing preferences and after moving the application.
- [ ] Missing, changed or invalid caches preserve commands, custom plug-ins,
      fonts and normal editing behavior.
- [ ] The final packaged application passes the isolated bundle check with
      development inputs inaccessible.

Measure from the launch request, without waiting for the Launch Services
completion callback before observing the window. A small headless engine
probe is useful diagnosis, but cannot establish application startup time.
Report fresh-user and cached results separately; fresh user data does not
mean the operating system's disk caches were flushed.

The current startup investigation identified plug-in discovery and font
catalog construction as major costs. The current candidate seeds a validated command registry and prepares native
font caches in a small helper. CoreText supplies downloaded font directories,
avoiding recursive scans of unrelated macOS Assets data. Normal launches on
this Mac measured 2.98 seconds with fresh Glims data, 1.56 seconds cached,
and 3.87 seconds after relocating the app with fresh Glims data. Corrupt
command-cache recovery and incompatible registry fallback remain slower
(about eleven seconds), because they query the plug-ins again. Final
isolated-bundle and engine-matrix qualification is still pending.

## Functional baseline

Compare actual workflows, including their result, cancellation, Undo/Redo and
saved-document persistence. A visible menu entry or an engine capability
alone does not establish a usable feature.

- [ ] Painting and retouching: brush, pencil, airbrush, eraser, clone, blur,
      sharpen, dodge/burn, sponge, fills, gradients and reusable resources.
- [ ] Selections, alpha channels, masks, paths and component-channel editing.
- [ ] Layers, blending, clipping and adjustment layers, with independent
      control over Levels, Curves, Color Balance and Hue/Saturation.
- [ ] Scale, rotate, skew, distort and perspective transforms with usable
      canvas handles, typed controls, preview, apply and cancel.
- [ ] RGB, grayscale, indexed, bitmap, CMYK, Lab, multichannel and duotone
      workflows, including print separations where applicable.
- [ ] Text, guides, grids, rulers, navigation and histogram inspection.
- [ ] Native layered save/reopen, common interchange formats, PSD fidelity,
      page setup, printing, acquisition and exports.
- [ ] Record, edit, save and replay actions across documents and batches.

The source audit confirmed these gaps in the previous main revision:

| Area | Confirmed gap | Current work |
| --- | --- | --- |
| Adjustment layers | Creation offers only seven generic operations | Add the four dedicated tonal adjustments and verify group effects |
| Actions | Recorder excludes filters, text, layer structure, mode changes and free transforms; replay is per image | Expand command capture and batch workflow |
| Transform | Canvas session handles only scale, move and rotation | Add missing transforms and numeric controls |
| Color modes | Facade and conversion menus expose RGB, grayscale and indexed | Design additional editable color models and faithful persistence |

Levels and Curves already work as editable, non-destructive layer effects.
Compose and Decompose plug-ins also exist in the dynamic Components menu;
their presence must not be mistaken for missing channel operations or for
verified print-production parity.

Historical references include Adobe's [file-format specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/),
which identifies Photoshop 4 adjustment data. That evolving specification
also documents later features; it is not by itself an exhaustive Photoshop 4
workflow list. The historical 4.0 PDF could not be retrieved during this audit.

## Responsiveness and presentation

- [ ] Measure representative painting, panning, zooming, transforms and
      adjustments on small documents and the existing 24 MP layered fixture.
- [ ] Long operations keep viewing and cancellation responsive; failures
      preserve the image and explain how to recover.
- [ ] Verify full workflows by mouse and keyboard, including multiple
      documents, palette targeting, shortcut editing and file dialogs.
- [ ] Review the complete workspace at normal and small screen sizes in all
      three appearances; fix overlap, clipping, unreadable controls and
      implementation jargon in user-facing labels.
- [ ] Exercise accessible names, focus, keyboard navigation and system
      accessibility settings. Keep physical hardware checks explicitly scoped.

Use the established classic, neutral Rigi design. Completion requires both
behavioral verification and a coherent visible interface, not another count
of passing tests.
