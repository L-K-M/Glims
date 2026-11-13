# Editor completion targets

The current brief is broader than the earlier implementation plan: open in
five seconds, provide at least Photoshop 4 level editing functionality, and
make the whole editor fast, usable and attractive. Notarization is excluded
by the user. This checklist remains open; the earlier verification totals do
not establish these targets.

## Startup

- [x] On the qualification Mac, a fresh Glims user directory reaches a rendered, editable document with
      tools and commands available within five seconds of ordinary macOS launch.
- [x] Repeat with the newly written preferences and after moving the application on the same Mac.
- [ ] Missing, changed or invalid caches preserve commands, custom plug-ins,
      fonts and normal editing behavior.
- [x] The integrated startup application passes the isolated bundle check with
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
this Mac measured 2.70 seconds with fresh Glims data, 1.72 seconds cached,
and 4.09 seconds after relocating the app with fresh Glims data. Corrupt
command-cache recovery and incompatible registry fallback remain slower
(about eleven seconds), because they query the plug-ins again. The integrated
bundle passes 1,917 native and 3,310 app checks with development trees denied;
all four engine sets pass the adapter suite. The cache-fidelity script passes
fresh/warm/relocated catalog comparisons, corrupt cache recovery, user-font
installation/removal and missing-helper fallback. Arbitrary custom plug-in
changes, other Macs and old preference collections remain unqualified.

An experimental missing-cache recovery reuses the bundled command registry
when the default user cache is absent and the language matches. In isolated
engine checks on this Mac, recovery fell from 10.4 to 0.94 seconds; with a
test user plug-in it fell from 11.0 to 1.30 seconds, with the same command
catalog. One ordinary launch showed a document window 1.51 seconds after a
cache deletion. Corrupt caches, changed languages and incompatible packaged
registries still require slower discovery; this does not close the target.

The corrupt-cache recovery prototype preserves an unusable selected registry
and uses a private bundled registry for that launch; native discovery still
checks user plug-ins. A missing selected registry is created exclusively.
On this Mac's engine probe, corrupt, truncated, alternate and symlinked cache
recovery measured about one second. Default-cache recovery preserved a user
plug-in across two concurrent launches. A single earlier candidate opened a document
window in 1.52 seconds; this follow-on has not been qualified for release.
Language changes, incompatible bundled registries and temporary paths that
GIMP cannot resolve unchanged still use the slower native scan, so the
five-second target remains open for those cases.

The real-locale regression `scripts/test-startup-real-locales.py APP` sets
the process's macOS preferred language as well as its gettext locale. In a
disposable cloned bundle it discovers an injected bundled plug-in in French,
uses that seed in French, and confirms that a German launch discovers the
German label rather than accepting the French seed. A deliberately mislabelled
seed reproduces the stale French label as a negative control. On this Mac,
the discovery probes took 12.12 and 10.31 seconds respectively; they are
engine probes, not ordinary app launch timings. An earlier diagnostic that
set only `LANGUAGE` did not change macOS's preferred-language list and must
not be used as evidence of cross-language cache fidelity. The slow fallback
remains open.


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
| Adjustment layers | The four dedicated tonal adjustments were missing from creation | Closed in PR #200, including native group effects and XCF checks |
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
