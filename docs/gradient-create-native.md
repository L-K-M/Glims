# Internal native two-endpoint gradient creation

One bounded INTERNAL-ONLY slice: `glims_resource_create_gradient()` in
`Engine/resource-gradient-create.c`, declared in `Engine/engine-private.h`.
It is deliberately **not** a facade slot: `Sources/CGlimsEngine/include/
glims_engine.h`, the API table in `Engine/engine.c`, the ABI version and all
Swift/UI code are untouched (slots 136/137 stay reserved to another helper; a
public gradient-create slot is added later by Root). The caller must be on
the engine thread; the test harness reaches it through `glims_engine_call()`.

## What it creates

ONE privately owned, NON-internal `GimpGradient` with exactly ONE segment:

- positions `left = 0.0`, `middle = 0.5`, `right = 1.0`;
- stored segment type `GIMP_GRADIENT_SEGMENT_LINEAR`, coloring
  `GIMP_GRADIENT_SEGMENT_RGB` (these stored fields are not the separate
  `GIMP_GRADIENT_BLEND_*` sampling-space enum; sampling in the tests uses
  `GIMP_GRADIENT_BLEND_RGB_PERCEPTUAL` explicitly);
- BOTH endpoint color types `GIMP_GRADIENT_COLOR_FIXED` — never the
  context-dynamic FG/BG stop types;
- endpoint colors are the captured `GlimsColor` sRGB+alpha values, set with
  `gegl_color_set_rgba_with_space(color, r, g, b, a, NULL)`: NULL space is
  babl's default sRGB for `R'G'B'A float` (gegl-color.c,
  `babl_format_with_space("R'G'B'A float", NULL)`). Plain
  `gegl_color_set_rgba()` stores linear light (`gegl_babl_rgba_linear_float()`)
  and previously caused the .5/.25/.75 -> 188/137/225 misinterpretation.

The gradient is built with `gimp_gradient_new(NULL, name)`. Verified against
all four engine trees (`_engine/src/{GIMP_3_2_8,GIMP_3_2_0,GIMP_3_0_8,master}/
gimp/app/core/gimpgradient.c`): the `context` parameter is unused in all four
(only `name` is checked) and each creates exactly one segment, so NULL is
valid and no global/user context is involved. Endpoint colors are assigned
directly into the new private segment after releasing the constructor's
defaults (`g_clear_object` + transfer), the same rule as `pattern->mask` in
`resource-create.c`; the native `gimp_gradient_segment_set_left/right_color`
setters were inspected and deliberately NOT used because they blend the range
in place (`gimp_gradient_segment_range_blend`) and never take a reference.
`gimp_gradient_finalize()` -> `gimp_gradient_segment_free()` releases both
endpoint colors exactly once when the gradient is released.

## Admission (all before any mutation)

| Input | Rule | Refusal |
|---|---|---|
| `out` | required; zeroed first and on EVERY failure | INVALID_ARGUMENT |
| `engine`, `name`, `left`, `right` | all required (NULL engine/out cannot be dispatched through `glims_engine_call`, so the harness calls the helper directly for those two) | INVALID_ARGUMENT |
| `name` | `glims_valid_resource_name()` (nonempty valid UTF-8, <= 255 bytes, no Cc controls; a C string cannot carry an embedded NUL) | INVALID_ARGUMENT |
| `name` edge | leading/trailing ASCII whitespace refused (the GGR loader `g_strstrip`s the `Name:` line, gimpgradient-load.c) | INVALID_ARGUMENT |
| `left`/`right` | each R/G/B/A finite and inside 0...1 (NaN/Inf/negative/>1 refused) | INVALID_ARGUMENT |
| busy | `engine->busy > 0` or any open stroke/filter hash entry, exactly resource-duplicate's gate | BUSY (out 0, nothing created or persisted) |
| duplicate | exact label already in `gimp->gradient_factory` (`glims_resource_name_taken`) | FAILED, no uniquify |

## Persistence

Reuses the checked pipeline of `Engine/resource-create.c` unchanged, no
refactor or duplication: `glims_resource_staging_begin(factory, ".ggr", ...)`
then `glims_resource_save_and_publish(factory, GIMP_DATA(gradient), name, ...)`
(owns the gradient on every path; checked `gimp_data_save`, no-overwrite
no-fallback promotion to a UUID final file, exact-name publication, positive
current-factory native id into `out` only on success). No
`gimp_data_factory_data_new` convenience. On a staging-begin failure the
private gradient is released before returning.

## Files

- `Engine/resource-gradient-create.c` — the helper (113 production lines).
- `Engine/engine-private.h` — engine-private prototype only.
- `Engine/tests/gradient-create-tests.c` — Core-linked harness (656 lines;
  the required refusal/preservation/fault/verify coverage does not fit in
  500, unlike the 1254-1546-line older harnesses this avoids copying). Usage
  `gradient-create-tests WORK_DIR create|verify`; the engine starts once per
  process and the driver runs the two phases as two separate processes.
- `scripts/test-gradient-create.py` — build/run/all driver against an
  existing producer prefix (`--producer` or `--ref`/`--adapter-root`); the
  helper is compiled into the output dir because the producer predates it
  (a producer that already ships `obj/resource-gradient-create.o` is used
  as-is, no duplicate symbol); links the harness against producer `obj/*.o` +
  `objects.rsp` + `link.rsp`; compiles the reused
  `Engine/tests/resource-create-interpose.c` shim; `--help` exits before
  any work. Never rebuilds/relins the adapter dylib, never compiles other
  Engine or upstream sources, never touches the real HOME.

## Checks actually run for this change (by the implementer)

- `-fsyntax-only` of `Engine/resource-gradient-create.c` with each ref's own
  `compile.rsp` (GIMP_3_2_8, GIMP_3_2_0, GIMP_3_0_8, master): all four pass.
- `-fsyntax-only` of the harness with each ref's own flags: all four pass,
  zero warnings with `-Wall -Wextra`.
- Standalone object compilation of helper + harness and a standalone
  executable link against the existing producer `obj/*.o` + `objects.rsp` +
  `link.rsp` for each of the four refs (outputs under `.build/` or /tmp).
- **Runtime was NOT run** (Root owns the fresh-phase execution): no engine
  start, no harness run, no adapter dylib relink in this change.

## Harness coverage (for Root's run)

Create phase: refusal matrix (NULL/empty/bad-UTF8/256-byte/Cc/edge-space
names, NULL endpoints, NaN/Inf/negative/>1 components, NULL out/engine,
duplicate FAILED, BUSY under an open stroke and under an open filter with
the probe stroke undone and isolated from the baseline), two valid creates
with .25/.5/.75 endpoints, native shape checks (one segment, 0/.5/1,
LINEAR/RGB, FIXED/FIXED, sRGB endpoint values incl. alpha, RGB_PERCEPTUAL
midpoint with independent alpha), static stops sampled under a foreign
PRIVATE context (user context untouched), preservation of user-context
FG/BG, clipboard object/content, open-image pixels/undo/dirty, catalog and
folder counts, armed staging-dir and final-file collisions through the
reused interpose shim (sentinels survive, no owned leftovers, out 0,
catalog quiet). Verify phase (fresh engine process): resolve by name,
identity roundtrip (non-internal), native shape/endpoint/sample checks on
the factory-reloaded gradient, and the saved GGR file's `Name:` line.
Tolerance 1e-5 (float32 endpoint storage; the GGR text round-trip keeps at
least six decimals, so this stays tight while catching any gamma
misinterpretation). Identity crosses process phases by NAME only
(`gradient-create-handoff.txt`), never by session id.

## Known limitations / uncertainties

- The GGR save writes `g_ascii_dtostr` full-precision text and the loader
  reads it back with full precision; 1e-5 tolerates either plus float32
  storage. If a future engine rounds GGR values to six decimals, 1e-5 still
  covers it.
- The harness fault tests require the shim (`DYLD_INSERT_LIBRARIES`); without
  it they print SKIP, not failure.
- Harness is 656 lines, above the 500 target, because the mandated refusal
  matrix, preservation snapshots, fault injection and two-phase reload are
  all required; it stays far below the older 1000+ line harnesses.
