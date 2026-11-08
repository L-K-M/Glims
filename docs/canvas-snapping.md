# Canvas snap planner (pure model)

Status: implemented as a pure value-only model. No UI, tool controller,
gesture, preference or engine wiring exists; nothing here reads or writes
per-window state.

## Slice

| File | Change |
|---|---|
| `Sources/GlimsKit/Document/CanvasSnapPlanner.swift` | New pure `CanvasSnapPlanner` enum with its own value types (`Target`, `Grid`, `Input`, `Config`, `Anchor`, `AxisMatch`, `Result`) and one entry point, `plan(input:config:canvasScale:)`. |
| `Tests/GlimsKitTests/CanvasSnapPlannerTests.swift` | Focused XCTest coverage; every expected value is hand-computed from the rules below, not derived from the implementation. |
| `docs/canvas-snapping.md` | This document. |

## Contract

`plan` receives the moving layer's rect **already at its proposed
translated position**, in image coordinates, together with the image
bounds, guide positions per axis, an optional grid (spacing/offset per
axis) and the other layers' rects (the caller excludes the moving layer
itself). It returns a `Result`: independent per-axis corrections `dx`/`dy`
plus, per axis, the winning `AxisMatch` (`anchor`, matched `target` kind,
`sourceCoordinate`, `targetCoordinate`). The caller applies `(dx, dy)` to
the translation and draws the indicator line at `targetCoordinate`.

Each axis is planned independently: the moving rect's leading, centre and
trailing coordinate on that axis are compared against every enabled
candidate line on that axis — image min/max edges (`.imageEdge`), image
centre (`.imageCenter`), guides (`.guide`), grid lattice (`.grid`), other
layers' min/max edges (`.layerEdge`) and centres (`.layerCenter`) — and
the pair with the smallest distance wins when that distance is within the
image-space tolerance, inclusive. The correction is
`targetCoordinate - sourceCoordinate`, so applying it lands the anchor
exactly on the line. Non-grid geometry is never rounded to pixels.

The tolerance is configured in **view points** (`Config.viewPointTolerance`,
default 8) and converted to image units by dividing by `canvasScale`
(view points per image unit, e.g. `CanvasGeometry.pointScale`); the scale
must be finite and positive.

### Deterministic tie priority

1. Smallest anchor-to-line distance wins.
2. On equal distance, the earlier anchor in leading, centre, trailing
   order wins.
3. Then the earlier candidate kind in imageEdge, imageCenter, guide, grid,
   layerEdge, layerCenter order.
4. Then input order within a kind (guides and layer rects as given).

Grid half-way ties (`(value - offset) / spacing` exactly `k + 0.5`) round
the lattice index away from zero (`Double.rounded()`'s default rule).

### Grid candidates are O(1) per anchor

For each moving anchor the planner computes the single nearest lattice
line `offset + k * spacing` with `k = round((value - offset) / spacing)`.
It never enumerates lattice lines, and it never loops over `Double`
indices. The line is computed in residual form,
`value - (q - k) * spacing`, so a huge offset does not cancel against
`k * spacing`. A grid candidate is rejected (contributes nothing) when:

- `value - offset` overflows, or the quotient is otherwise non-finite;
- `|k| > 2^53` — beyond 2^53 not every integer index is representable as
  a `Double`, so the index is rejected rather than approximated;
- the resulting line is non-finite.

This keeps huge spans over tiny spacings and extreme offsets safe: the
worst case is "no grid snap", never a garbage line or a hang.

### Invalid input fails closed

If any geometry or configuration value is non-finite or degenerate (rect
not finite or not strictly positive in size, non-finite guide, grid
spacing not finite and strictly positive or non-finite offset, tolerance
negative or non-finite, `canvasScale` not finite and positive, or the
converted image-space tolerance overflowing to infinity), `plan` returns
`Result.none`: zero corrections, no matches. Corrections are therefore
never NaN and never overflow — a matched correction is always bounded by
the finite image-space tolerance.

## Not in this slice

- No snapping gestures, tool-controller integration, menu items or
  keyboard shortcuts.
- No per-window or persisted snapping preferences; the config is passed
  in by the caller each time.
- No overlay drawing; the planner only reports coordinates.
- No clamping of the corrected rect to the image, and no pixel rounding
  of non-grid geometry.

## Verification

`swift build -j 2` and `swift build --build-tests -j 2` compile the model
and the tests. The tests were not executed in this environment (no
`swift test` run); they are compile-checked only and should be run in CI
or locally before relying on them.

Root runtime acceptance: a grid offset of 10^16 and spacing 10 invented a
coincident line at image coordinate 1. The quotient's residual had lost the
low bits of the moving coordinate. The new regression failed in all three
assertions before correction. Candidate lines now use a fused multiply-add
and a fixed seven-index neighborhood around the rounded quotient, avoiding
both cancellation and unbounded enumeration. All 21 planner tests pass.
No canvas integration or on-screen snapping is claimed by this model slice.

## Integrated controls acceptance

Fractional grid candidates now produce only representable whole-pixel move
previews, with inexact axis indicators dropped; release keeps that exact
rectangle. An unavailable capture refuses rather than falling back to a
new target. The integrated focused controls and full pinned app runs pass,
including the imported-target and group-collapse fixes from the layer palette.
The fractional-grid fixture restores its previous Snap To state before later
cancellation checks. This slice covers ordinary layer Move gestures; snapping
for other gestures remains separate work. Independent fix review found no
important remaining issue.
