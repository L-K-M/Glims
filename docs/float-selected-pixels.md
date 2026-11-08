# Float Selected Pixels (native + typed session)

Status: implemented at the facade and adapter level only. No Document or
UI wiring exists; see "Unrun UI" below.

## Slice

| File | Change |
|---|---|
| `Sources/CGlimsEngine/include/glims_engine.h` | New `GlimsFloatMode` enum (`GLIMS_FLOAT_MOVE = 1`, `GLIMS_FLOAT_COPY = 2`, facade-owned uint32 values; the native `cut_image` boolean never crosses the boundary) and new footer slot **121** `selection_float`, appended after `floating_command` (slot 120). All old ABI fields are untouched and `GLIMS_ENGINE_API_VERSION` stays 1 — the change is purely additive (append-only within a version). |
| `Engine/floating.c` | New `glims_selection_float()`, driven through the GUI-free `gimp_selection_float (GIMP_SELECTION (gimp_image_get_mask (image)), drawables, context, cut, 0, 0, &gerror)`. |
| `Engine/engine-private.h` | Declaration of `glims_selection_float`. |
| `Engine/engine.c` | `MARSHAL (selection_float, ...)`, `api_selection_float`, table entry `.selection_float = api_selection_float` after `.floating_command`. |
| `Sources/GlimsKit/Engine/EngineSession.swift` | Own `FloatMode: UInt32` enum and `floatSelection(_:image:target:mode:) throws -> Int32` wrapper only. No Document/UI code. |
| `Engine/tests/engine-tests.c` | New `test_selection_float()`, registered in `main` after `test_floating_selection`. |

## Native behavior relied on

`gimp_selection_float` (app/core/gimpselection.c, lines 851-944, identical
signature in all four engine trees GIMP_3_0_8 / 3_2_0 / 3_2_8 / master) does,
in one `GIMP_UNDO_GROUP_FS_FLOAT` group ("Float Selection"): the native
`gimp_selection_extract` (cut for MOVE, copy for COPY), clears the image
selection (`gimp_channel_clear`), creates the floating layer from the
extracted buffer in the target's own format/profile and the
selection-intersection bounds, sets offset `x1+off_x, y1+off_y`, and
attaches it with `floating_sel_attach`. The returned `GimpLayer *` is
image-owned — the adapter never unrefs it. Offsets are 0: the FS lands on
the extracted region and the existing `layer_move` moves it once the
selection is cleared.

## Preflight (all before any mutation; refusals change no pixels, push no
undo, clear no selection and leave the floating state alone)

Order in `glims_selection_float`:

1. Unknown image: NOT_FOUND.
2. Readiness (`glims_edit_ready`): BUSY while a stroke, filter session or
   plug-in holds the image.
3. Unknown `mode`: INVALID_ARGUMENT.
4. Existing floating selection: FAILED — `floating_sel_attach` would
   silently anchor it inside the "Float Selection" undo group.
5. Target admission, same as `image_paste_into`:
   - `target` 0 means the image's selected drawable, but only when
     **exactly one** drawable is selected; zero or several are refused
     (FAILED). An explicit id must name an attached drawable of this
     image; stale/foreign/detached ids are NOT_FOUND.
   - The selection mask itself is refused (FAILED); layer groups are
     refused (FAILED); a channel target must be in the image's channel
     list (saved channels and the Quick Mask's channel), otherwise FAILED.
   - A genuine editable text/link/vector layer target reports
     REQUIRES_RASTERIZE via the exported `glims_layer_editable_source_kind`
     — never an implicit rasterization.
6. Locks, MOVE only: content lock (PIXELS) always, plus the ALPHA lock when
   the target has an alpha channel — the cut punches through alpha, the
   same policy as `image_clear` and the eraser (`gimp_drawable_has_alpha`).
   LOCKED, also for an ancestor group's locks (`glims_check_item_locks`).
   COPY is non-destructive and checks no locks beyond readiness.
7. Selection: empty mask is FAILED; a selection disjoint from the target
   (`gimp_item_mask_intersect` empty) is FAILED — the same region test the
   core applies inside the undo group.

Cleanup on every path: the temporary `GList` is freed with `g_list_free`,
the private per-call `GimpContext` (inheriting the user context, never
mutated) is unreffed, and the `GError` goes through `glims_fail`.

## Tests

`test_selection_float()` (facade only) covers, on a known-RGBA 32x32
fixture (pixel (x,y) = (x*8, y*8, 64, 255), one alpha layer, nothing
below):

- unknown image / invalid mode (99) / stale and foreign target ids;
- empty selection, group target, disjoint selection — each FAILED with no
  undo and no floating-selection side effect;
- PIXELS lock: MOVE LOCKED, COPY still succeeds (non-destructive);
  ALPHA lock on the alpha layer: MOVE LOCKED;
- genuine editable text target: REQUIRES_RASTERIZE (font taken from the
  `fonts` list, never hardcoded), rasterized instance accepted;
- BUSY during an open stroke and during an open filter session;
- MOVE happy path with target 0: one undo step, floating state
  (floating id, target, kind layer), selection cleared, FS row at the
  selection bounds (4,4,8,8) with offset 0, preview composites exactly
  like the original;
- undo restores pixels + selection and removes the FS, redo brings the
  same id back;
- `layer_move` moves the FS to (12,12) after the selection was cleared:
  the content shows at (13,13) outside the original mask and the MOVE
  hole renders transparent at (5,5);
- discard keeps the hole and removes the moved content; COPY leaves the
  target intact and to-layer detaches with the same id; anchor merges
  and restores the exact original composite;
- a second float while one is active is FAILED with the active FS
  untouched;
- mask target attaches with kind layer-mask, saved-channel target with
  kind channel.

## Checks

Allowed and run for this change (see the commit message for the exact
results):

- `swift build -j2` and `swift build --build-tests -j2`.
- Lockfree C syntax checks (`-fsyntax-only`, no `_engine/.lock`, no
  outputs) with the existing input flags (`_engine/adapter/<ref>/compile.rsp`
  plus the `-I`/`-D` flags of `scripts/build-adapter.sh`) for all four
  engine refs over `Engine/*.c`; the test C with
  `clang -std=c11 -O2 -Wall -Wextra -Werror -fsyntax-only`.

Not run here (not allowed for this slice): the native adapter build,
relink, conformance-test run, engine matrix and app smoke test. The
existing floating-selection suite was last run by the root on all four
engine sets (all passed, 1650/1436 checks per root) — that run is not
claimed as this change's. The new `test_selection_float` has not been
executed against a live engine in this session.

## Unrun UI

Nothing in `Sources/GlimsKit/Document`, menus, tools or palettes calls
`floatSelection`; there is no Float menu item or shortcut yet. The typed
session wrapper is the only consumer-level entry point.

## Known gaps

- The "exactly one selected drawable" refusal for `target` 0 is enforced
  in the adapter, but today's facade cannot multi-select drawables
  (`layer_select`/`channel_command` select exactly one), so the
  multiple-selected case is defensive and untested at runtime.
- A feathered selection floats with its soft mask as-is; no claim is made
  about reconstructing a feathered cut edge.
