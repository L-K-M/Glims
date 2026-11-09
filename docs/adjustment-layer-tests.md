# Adjustment-layer tests (slot 130)

Test-only harness for the frozen facade slot **130**, `adjustment_layer_new`.
It touches no production file: the adapter is loaded with `dlopen()` exactly
as the app does, and the runner includes only the public facade header
`Sources/CGlimsEngine/include/glims_engine.h` — no `Engine/` private header,
no link-time dependency, no DYLD shim.

## Files

| Path | Role |
|---|---|
| `Engine/tests/adjustment-layer-tests.c` | C runner (facade-only, `dlopen`). Usage: `glims-adjustment-layer-tests LIBRARY WORK_DIR`. Prints one line per check and a final `N checks, N failures, N skips`; exits non-zero iff failures > 0, so a clean run honestly reports `0 failures`. |
| `scripts/test-adjustment-layer.py` | Launcher: `--ref` (default: pinned set from `scripts/engine.env`), `--adapter-root` (default: `$GLIMS_ADAPTER_ROOT` or `<repo>/_engine/adapter`), `--timeout` (default 600 s). Compiles the runner with `xcrun clang -std=c11 -Wall -Wextra -Werror -I Sources/CGlimsEngine/include` (facade header only) into a temp dir, then runs it with isolated temp `HOME`, `XDG_CACHE_HOME`, `GIMP3_DIRECTORY` and engine user/cache dirs under the temp work dir. Exit: runner status, 124 on timeout. |
| `docs/adjustment-layer-tests.md` | This file. |

Run: `python3 scripts/test-adjustment-layer.py [--ref GIMP_3_2_8] [--adapter-root DIR] [--timeout 600]`
against an adapter built by `scripts/build-adapter.sh`.

## Contract under test

Current facade signature (validated against the working-tree header,
`GLIMS_ENGINE_API_VERSION` 1, `adjustment_layer_new` is the last slot):

```c
GlimsStatus (*adjustment_layer_new) (GlimsEngine *engine, GlimsImageID image,
    GlimsItemID parent, int32_t index, const char *operation, const char *name,
    GlimsItemID *layer, GlimsEffectID *effect, char **error);
```

The runner first checks `api_version` and `struct_size` explicitly and that
`adjustment_layer_new` is present, and that `get_api (version + 1)` returns
NULL. Every state comparison is a full snapshot: composite pixels, layer
ids/parents/depth/kind/mode/filter counts in depth-first order, undo/redo
counts and step names, dirty flag, selected layers, and the native
`engine_version` string.

## Coverage

- **Positive**: white background + `gegl:invert-gamma` → empty pass-through
  group (kind GROUP, mode `pass-through`, `filter_count` 1) with one enabled
  effect readable through `drawable_effects` under the returned ids; composite
  full black. Hidden effect (`effect_change` ENABLED) → background unchanged;
  re-enabled → black. One undo removes the whole group+effect (white, undo
  stack exactly the pre-creation one, stale id NOT_FOUND for the effect
  read); redo restores the same layer/effect ids and black.
- **Generic filter edit** (existing lifecycle, parametric op
  `gegl:brightness-contrast`; the parameterless invert is not force-edited):
  preview refuses `adjustment_layer_new` with BUSY and changes nothing;
  `filter_set_double` to the discovered `brightness` bound previews a darker
  composite; abort pushes no undo; commit is exactly one undo step, removed
  by one `image_undo`.
- **Refusals** (each checks status, outputs reset to 0, and the exact
  unchanged snapshot): NULL/empty/nonexistent operation, empty name,
  non-group parent, out-of-image parent id, dead (created-then-deleted)
  parent, negative and out-of-range index, aux-input op `gegl:displace`
  (UNSUPPORTED when the engine lists it as `GLIMS_FILTER_OP_AUX_INPUT`;
  otherwise an honest `skip`, never a pass), active floating selection,
  open stroke, open filter preview — all BUSY where the contract says so.
- **Nested placement**: group inside a group and a top-level index placement
  land at the exact depth-first positions; one undo removes exactly one
  placement; the selected-layer list is exactly restored on undo; redos
  restore ids and order.
- **XCF**: save, close, reopen — group mode, one `gegl:invert-gamma` effect
  and the black composite survive; images close cleanly and double-close is
  reported.

Oracles are independent contract values (white/black composites, exact id
and order arrays, undo counts), not mirrors of the adapter implementation.

## Verification status and assumptions

- Checked here: Python launcher parses (AST) and `--help` works; line caps
  (C ≤ 500, Python ≤ 200). The native runner is **UNCOMPILED and UNRUN** in
  this change — building/running the adapter is the root's job.
- API assumptions (from the current facade header, not yet exercised):
  slot 130's signature above; blend-mode nick `"pass-through"`;
  `gegl:invert-gamma` and `gegl:brightness-contrast` exist with a numeric
  `brightness` property; `gegl:displace` aux detection via
  `filter_operations`; composite renders are premultiplied RGBA u8 with
  opaque alpha for these fills (channel checks allow ±1).

## Root acceptance

Root corrected ABI footer access, bounded successful snapshots, clean-state
setup, creation Undo/Redo ordering around independent visibility tests, and
editing the actual adjustment effect. The older bridge failed its NULL-engine
output reset once. The original 3.0.8 run then failed two pixel checks while
its stored parameters were correct; adapter-only projection invalidation
fixes those cases. Final general suites and all 95 standalone checks pass on
every supported engine with no skips. Independent source/code-safety reviews
completed; precise upstream cache-cause research timed out without a verdict.

Native `layers-actions.c:1039` disables new groups on indexed images. The
indexed refusal fixture initially failed against the older producer; creation
now returns UNSUPPORTED before mutation and resets outputs. The 95-check
four-engine runs include that whole-state preservation oracle.
