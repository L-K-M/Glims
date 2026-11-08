# Layer multiselection (native + typed session)

Status: implemented at the facade and adapter level only. No Document or
UI wiring exists.

## Slice

| File | Change |
|---|---|
| `Sources/CGlimsEngine/include/glims_engine.h` | Footer slots **122** `image_select_layers` and **123** `image_selected_layers`, appended after `selection_float` (slot 121). All prefix fields are untouched and `GLIMS_ENGINE_API_VERSION` stays 1 — the change is purely additive (append-only within a version). No GIMP types cross the boundary: the layer ids are the facade's `GlimsItemID`, input arrays take `size_t count` (as `select_shape`/`stroke_continue` do), the read follows the `rows`/`capacity`/`count` convention of `image_layers`/`image_open_layers`. |
| `Engine/edit.c` | New `glims_image_selected_layers()` and `glims_image_select_layers()`, next to `glims_layer_select`. |
| `Engine/engine-private.h` | Their declarations. |
| `Engine/engine.c` | `MARSHAL (image_select_layers, ...)`, `MARSHAL (image_selected_layers, ...)`, `api_image_select_layers`, `api_image_selected_layers`, and the two table entries after `.selection_float`. |
| `Sources/GlimsKit/Engine/EngineSession.swift` | `selectedLayers(_:) throws -> [Int32]` and `selectLayers(_:image:)` typed wrappers only, next to `selectLayer`. No Document/UI code. |
| `Engine/tests/engine-tests.c` | New `test_layer_multiselection()`, registered in `main` after `test_selection_float`; a `layers_events` counter in `on_event` counts `GLIMS_EVENT_LAYERS_CHANGED`. |

## Native behavior relied on (verified identical in all four engine trees: GIMP_3_0_8 / 3_2_0 / 3_2_8 / master)

- `gimp_image_get_selected_layers (image)` returns
  `gimp_item_tree_get_selected_items (private->layers)` — the item tree's
  **borrowed** `selected_items` list. The adapter never frees it
  (the owned variant, `gimp_image_get_selected_drawables`, is not used).
- `gimp_image_set_selected_layers (image, layers)` **copies** the passed
  list (`g_list_copy`, order preserved) and hands the copy to
  `gimp_item_tree_set_selected_items`, which stores it verbatim as
  `selected_items` when the selection changes (`g_object_notify
  "selected-items"`). So the core preserves the caller's exact order —
  the read-back equals the input order, first id first, and the first id
  is the active layer (`selected_layers->data`, what `find_layer (0)`
  and the invalidation of the previous active layer use). The adapter
  therefore frees its own input list exactly once after the call.
- An identical set is detected (same length, every element found) and
  the call is a no-op: no notify, no event. A changed selection emits
  `notify::selected-items` → the image's `selected-layers-changed` →
  the adapter's existing handler → one `GLIMS_EVENT_LAYERS_CHANGED`.
  No undo is pushed, the image is not marked dirty, no pixels and no
  selection-mask data change; the only other native effect is
  `gimp_drawable_invalidate_boundary` on the previous active layer (a
  boundary-cache invalidation, not a pixel change).
- **Floating-selection gate**: with a floating selection active, the
  native setter silently returns unless the request is exactly
  `[floating_sel]` ("Make sure the floating_sel always is the active
  layer"). The adapter checks this before the native call and refuses
  anything else with FAILED — the FS is never anchored — while the
  identical `[FS]` list passes through and is a no-op (the FS is already
  the selection). An empty request is refused the same way, since the
  core does not permit clearing the selection under a FS; without a FS
  the empty list clears the selection (the core permits it).
- **edit-mask flag**: when the selection actually changes to more than
  one layer, the native setter calls `gimp_layer_set_edit_mask (layer,
  FALSE)` on every selected layer that has a mask ("We cannot edit
  masks with multiple selected layers") — the same thing the engine's
  own layer dock does on a ctrl-click multi-selection. This is genuine
  native behavior and is kept, not fought. What it is and is not:
  - it clears the transient *edit* flag only (`GlimsMaskState.editing`);
    the mask's **pixel data**, and its enabled/showing flags, are never
    touched, and no undo step or dirty flag follows
    (`gimp_layer_set_edit_mask` just sets the field and emits the
    layer's `edit-mask-changed`; the adapter maps no facade event to it —
    the only facade event is `LAYERS_CHANGED`);
  - the flag is edit state, not pixels, but note XCF does persist it
    (xcf-save writes it, xcf-load reads it), so a saved file can carry
    "editing" from before a save — it is still not mask pixel data.
  The conformance test pins both sides: after a single→multi change the
  editing flag reads false while the mask thumbnail is byte-identical
  and `enabled` is unchanged.

## Preflight and statuses (`image_select_layers`)

Order in `glims_image_select_layers`, all validation before any mutation,
so every refusal leaves the current selection, the history and the FS
untouched (atomic):

1. Unknown image: NOT_FOUND.
2. `layers` NULL with `count` > 0: INVALID_ARGUMENT. `count` 0 clears.
3. Per id, in order: id 0 → INVALID_ARGUMENT; a repeated id →
   INVALID_ARGUMENT (GHashTable); an id that resolves to no item, to an
   item of another image, or to a detached item (e.g. one only the undo
   stack holds) → NOT_FOUND; an id that resolves to an attached
   mask/channel/path of this image but is not a `GimpLayer` →
   INVALID_ARGUMENT. Layer groups pass — they are layers.
4. Floating selection active and the request is not exactly `[FS]` →
   FAILED with an error (the native silent refusal made explicit).
5. Native `gimp_image_set_selected_layers` with the order-preserving
   list, then the adapter's own list freed once. Postcondition: the
   borrowed read-back must equal the requested list exactly, in order;
   a mismatch (only possible through the native FS silent-refusal path)
   is reported as FAILED, never as success.

Readiness is `layer_select`'s exactly: NOT_FOUND for an unknown image
and **no BUSY gate** — the write may run while a stroke, a filter
session or a plug-in holds the image. `image_selected_layers` is a plain
read, allowed at any time (busy included): NOT_FOUND for an unknown
image, INVALID_ARGUMENT for a missing `count` or negative `capacity`,
`ids` NULL with `capacity` 0 counts only.

## Tests

`test_layer_multiselection()` (facade only) covers, on a 64x48 fixture
with top-level `b`/`background`, a group and the nested child `a`:

- read validation (unknown image, NULL count, negative capacity),
  count-only and partial-capacity reads;
- exact ordered write `[a, group, b]` (not tree order): read-back order,
  `selected` row flags, LAYERS_CHANGED emitted; identical request is a
  no-op with no event; reordered set is a real change whose order sticks;
- transient guarantees: no undo step, dirty flag unchanged, rendered
  pixels byte-identical;
- empty list clears the selection (no FS active); no row selected after;
- atomic refusals: NULL list with count 1, duplicate id, id 0, unknown
  id, deleted id, foreign id (another image), mask id, channel id,
  unknown image — selection and undo depth unchanged after all;
- genuine edit-mask behavior: multi-selection clears `editing` on the
  masked layer, mask thumbnail bytes unchanged, `enabled` kept, no undo;
- FS gate: float a selection off `a`, then an alternate selection and an
  empty clear are FAILED (no undo, FS still active, never anchored),
  `[FS]` is accepted as a no-op, and after `floating_command` DISCARD
  the multi-selection works again;
- busy: during an open stroke the read works, `layer_select` is not
  BUSY-gated, and `image_select_layers` has the same readiness.

## Checks run

`swift build -j2` and `swift build --build-tests -j2` (Swift compile of
the header and the wrappers); `clang -fsyntax-only` with each engine
set's own `compile.rsp` flags (GIMP_3_0_8, GIMP_3_2_0, GIMP_3_2_8,
master) over the changed adapter sources, and `-std=c11 -O2 -Wall
-Wextra -Werror` syntax check of the test file. Not run here: the native
adapter build/link, the conformance suite itself, and the app's
`--engine-smoke-test` — no engine runtime in this environment; the test
above must be run with `scripts/build-adapter.sh --test` on a built
engine set.

Root runtime checkpoint: the draft returned FAILED for invalid arguments
whose contract specifies INVALID_ARGUMENT and omitted the missing-layer
message. Those failures are reproduced and corrected. A new same-members,
reverse-order regression also failed: Core compares membership and ignores
an order-only change. The adapter now clears the transient selection only
for that case before applying the requested order. It validates the whole
request first, rejects counts larger than the image's flattened layer tree
before allocation, and never frees Core's borrowed selected-layer list.

The initial fixture assumed New Layer always inserted at the tree's front;
it now explicitly places that layer before checking tree order. Native
multi-selection exits mask-edit mode as Core intends; it does not change
mask pixels. Read/write selection remains transient and follows the existing
layer_select readiness policy, including during a preview/stroke.

All four native suites pass: 1,777 / 1,563 / 1,777 / 1,777 checks on 3.2.8 /
3.0.8 / 3.2.0 / master. Runtime UI adoption remains separate.
