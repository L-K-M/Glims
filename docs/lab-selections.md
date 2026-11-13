# Native Lab selections

The candidate adds Rectangle, Ellipse and Lasso selections to native Lab
images, with Replace, Add, Subtract and Intersect operations. Select All,
None and Invert use the same native image selection mask. This mask limits
physical Lab Fill and Brush without converting or editing the L*, a* or b*
planes. None means unrestricted editing, not zero coverage.

Shape options include antialiasing, feather and rectangle corner radius.
The existing tool controls and canvas gestures route Lab requests through
typed document services. Native and actual-window behavior is qualified on
all four engines; bundle and hosted qualification are still in progress.

## Native contract

- Additive slots 195/196 expose `image_select_lab_shape` and
  `image_select_lab_command`. They validate native Lab storage, then reuse
  the existing root-mask rasterization and native selection Undo path.
  Ordinary RGB and ink documents refuse these Lab-only calls. The old
  general `select_shape` and `select_command` slots remain blocked for Lab.
- Selection does not require a selected axis and is independent of pixel
  locks on the axes. It preserves axis samples, UUIDs, map/profile metadata,
  names, order, axis selection and file identities. Uninterpreted nonfinite
  samples on an untouched float axis do not prevent mask editing.
- Rectangle and ellipse require two opposite corners. Bounds use floor/ceil
  and must have positive pixel width and height. Lasso polygons accept 3
  through 65,536 points. Every coordinate must be finite within
  ±1,048,576 image pixels. Off-canvas geometry is preserved until native
  rasterization clips it; clipping ellipse bounds first would change shape.
- Settings require the complete known struct prefix. Unaligned borrowed
  settings/points and ignored future settings tails are supported; no input
  is retained after the call. Antialias is exactly 0 or 1. Feather and corner
  radius must be finite in [0,1000] pixels; corner radius applies only to
  rectangles. Invalid arguments refuse before mask or history changes.
- Engine activity, a live stroke, an image filter preview, frozen/disabled
  Undo or an open native Undo group refuse the edit. A refused selection
  leaves the existing stroke usable. Changed selections have one native
  Undo step; successful no-op selections keep native history semantics.
- Native mask bytes and authoritative axis bytes survive XCF Save/reopen.
  Undo/Redo restores the complete mask exactly. Bounds and marching ants
  reflect transitions from Select All to shapes and their inverse.

## Document routing and scope

`EngineSession.supportsLabSelections` requires the complete prefix through
slot 196, both selection functions and typed Lab-axis support. Earlier
adapters keep selection tools and menu actions unavailable; ordinary
selection slots or an upstream version number do not imply this capability.
Creation, physical Fill and Brush retain their separate capability gates.

`ImageDocument` captures the typed shape/options or supported command and
queues it as counted input. It rechecks readiness after admission callbacks
and refuses a live stroke. The general Lab mutation gate stays closed.
Rectangle/Ellipse/Lasso and All/None/Invert have matching tool/menu gates;
ordinary documents retain their existing selection routes. Recorder captures
these shapes and All/None/Invert as explicit Lab-only version 15 commands.
Their root-mask target is independent of axis selection or precision; wrong
document modes refuse before editing. See [lab-recorder.md](lab-recorder.md).

Feather is available as a shape option. This slice does not enable the
separate Feather, Grow, Shrink, Border or Sharpen commands, selection from
alpha, Magic Wand/by-color selection, Quick Mask editing, channel-to-selection,
floating selections, or Stroke Selection. It adds no Lab layers, conversions,
external interchange or other paint tools. See [lab-channel-editing.md](lab-channel-editing.md)
and [lab-brush.md](lab-brush.md) for the existing physical editing scope.

## Verification and remaining qualification

The frozen `Engine/tests/lab-select-tests.c` fixture passes **1,380 checks
on each of GIMP 3.2.8, 3.0.8, 3.2.0 and master** through
`scripts/test-lab-select.py`. It independently captures raw selection and
axis bytes, checks literal hard masks and set operations, fractional
Fill/Brush coverage, exact Undo/Redo, XCF persistence, input boundaries,
readiness refusals, live-handle usability and real RGB/Multichannel/CMYK
wrong-mode refusals. Each run preserves all 177 hashed inputs, including
its external CMYK fixture profile.

The same adapter matrix passes these existing regressions, all with zero
failures:

| Engine | General conformance | Lab admission | Compressed XCF | TIFF import |
| --- | ---: | ---: | ---: | ---: |
| GIMP 3.2.8 | 2,268 | 312 | 34 | 206 |
| GIMP 3.0.8 | 2,054 | 312 | 34 | 206 |
| GIMP 3.2.0 | 2,268 | 312 | 34 | 206 |
| master | 2,268 | 312 | 34 | 206 |

The headless Swift document-service case passes **55 checks on each engine**,
alongside Brush (61), Fill (57), axes (28) and exclusive Close (36). Actual
selection UI passes **179 checks per engine** with U8 and float documents;
U16 is covered by the native and headless cases. Actual Brush UI also passes
90 checks per engine. The UI fixture reproduced a clipped Intersect button;
giving the four mode buttons their own full-width row fixes it without
changing their accessible names or actions. All **1,599 Swift unit tests**
and **130 Python tests** pass. Source and fixture reviews found no important
remaining issue.

Real older slot192/194 adapters each pass six capability-refusal checks on
all four engines, with unchanged selection bounds and Undo information.
Brush availability remains independent of the new selection capability.
The older 3.2.0 runs emit two startup filename-null GLib diagnostics each;
older 3.0.8 emits two startup plug-in wire-EOF warnings each. No assertion
fails. These legacy checks do not replace the raw-mask native oracle.

Native fixture compiles are clean;
GIMP 3.0.8 emits two startup plug-in wire-EOF warnings before its selection
checks, without assertion failures. Those startup diagnostics are retained.

Evidence is recorded in `/tmp/glims-lab-select-tests/final-matrix.json`,
`/tmp/glims-lab-selections/build-matrix.json`, the corresponding adapter and
policy logs, `/tmp/glims-lab-selections/final-headless/results.json`,
`/tmp/glims-lab-selections/ui-matrix.json` and
`/tmp/glims-lab-selections/legacy-prefixes/results.json`.
The detailed native handoff is
`/tmp/glims-lab-selection-native-fixture-handoff.md`.

Bundle/installed-app qualification and hosted CI are still pending for this
slice. Exact Photoshop feather/edge
numerics and complete Photoshop 4 parity are not established by these tests.
