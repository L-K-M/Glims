# Native undo for explicit saved-set edits

Engine-internal slice on top of the weak-identity item-set manager
(`Engine/item-sets.c`, `docs/saved-set-lifetimes.md`). Adds atomic native
Undo/Redo snapshots for the four explicit saved-set commands
CREATE/REPLACE/RENAME/REMOVE. No facade slot, no `glims_engine.h` change, API
version stays 1 and the prefix ABI is untouched: the commands are declared in
`Engine/engine-private.h` and live in `Engine/item-sets-undo.c`.

| File | Role |
|---|---|
| `Engine/item-sets-undo.c` | Owned before/after snapshots, the adapter-owned `GimpUndo` subtype, and the four commands. |
| `Engine/item-sets.c` | The manager additionally rebuilds its live-only replacements on the image's `undo-event` (UNDO/REDO/EXPIRED/FREE), so restored or expired definitions never expose detached/finalized members. |
| `Engine/tests/saved-set-undo-tests.c` | Standalone native harness (same linkage pattern as `saved-set-lifetime-tests.c`). |
| `scripts/test-saved-set-undo.py` | Build/run driver; selects an existing producer prefix, never rebuilds the shared producer. |
| `docs/saved-set-undo.md` | This document. |

## Design (source-backed against `_engine/src/*/gimp/app/core`)

- **One plain undo step per command, never a group.** `gimp_image_undo_push`
  accepts any `GimpUndo` subtype (`gimpimage-undo.c:369-371`), so the subtype
  is `GlimsItemSetsUndo` (derives `GIMP_TYPE_UNDO`, `pop`/`free` vfuncs chain
  the parent, per the `GimpGuideUndo`/`GimpImageUndo` pattern). Empty groups
  are not used: a begin/end pair is not an inert transaction
  (`gimpimage-undo.c:309-349` creates, pushes and purges immediately).
- **Internal image-metadata category, custom subtype.** The push uses
  `GIMP_UNDO_IMAGE_METADATA` with `GIMP_DIRTY_IMAGE_META` — the category
  GIMP's own metadata/grid/guide undos use. Source-checked safe on all four
  engine sets: the only code switching on that category is inside
  `GimpImageUndo` itself (`gimpimageundo.c`), `gimp_undo_is_weak` does not
  list it (the step is a strong undo), `gimp_undo_type_to_name` is generic,
  and nothing outside `gimpimageundo.c` casts stack entries to
  `GIMP_IS_IMAGE_UNDO`. Raw enum values never cross the facade.
- **Owned before/after snapshots.** Each snapshot is a deep copy of the
  image's whole stored-set list of the affected kind (stored-list order;
  name, pattern flag, select method; member list with strong refs). The
  strong member refs are what Undo explicitly requires: a popped step can
  restore the same live identity even while the member's own deletion undo
  is pending. The snapshots are construct-only pointer properties, so they
  exist before the push can expire the new undo (`gimp_image_undo_push` may
  free a just-pushed step when the stack is over its limits). The manager
  itself stays weak: `FixedSet` members remain `GWeakRef`s; only the undo's
  snapshots own refs, released in the `free` signal on expiry/purge.
- **Pop restores through the public quiet API.** `pop` (UNDO → before,
  REDO → after) unlinks the kind's current stored sets and re-stores the
  snapshot in reverse (store prepends). `gimp_image_store_item_set` /
  `gimp_image_unlink_item_set` add no undo step and no dirty flag; the
  `gimp_undo_pop` wrapper balances dirty from the dirty mask, so one Undo
  returns to the clean savepoint. The returned `GimpUndo*` is borrowed and
  never retained (stack owns it; it can be expired at any time).
- **Preflight before mutation.** Argument validation (kind, name, member
  type/image/attached/duplicates), no-op detection (identical REPLACE,
  same-name RENAME → OK with zero delta), duplicate-name and missing-target
  errors, and the frozen check `gimp_image_undo_is_enabled()` all run before
  anything mutates: a refused command preserves state, history and dirty
  exactly (a push while frozen would still dirty the image —
  `gimpimage-undo.c:375-382` — hence the pre-push check).
- **Immediate-purge rollback.** If the push returns NULL after construction
  (only reachable when frozen was preflighted and `free_space` purged the new
  top), the command restores the kept before-snapshot and reverts the dirty
  mark, returning FAILED. The redo stack the push nuked is not restored
  (engine contract). Not exercised by the harness: the undo limits are far
  above one small step.

## Manager hook

`glims_item_sets_new` now also connects the image's `undo-event` signal. On
UNDO/REDO (a saved-set pop restores definitions; a layer undo detaches or
reattaches members) and on UNDO_EXPIRED/REDO_EXPIRED/UNDO_FREE (snapshots
release their strong refs, members may finalize) the manager runs the
existing quiet `rebuild_sets`: exposed membership is again exactly the live
members, detached-but-alive members stay weakly known for Undo, finalized
members drop out and are never exposed.

## Commands (engine thread only)

```c
GlimsStatus glims_item_sets_create  (GimpImage *, GType kind, const char *name,
                                     GimpItem *const *members, size_t count, char **error);
GlimsStatus glims_item_sets_replace (GimpImage *, GType kind, const char *name,
                                     GimpItem *const *members, size_t count, char **error);
GlimsStatus glims_item_sets_rename  (GimpImage *, GType kind, const char *name,
                                     const char *new_name, char **error);
GlimsStatus glims_item_sets_remove  (GimpImage *, GType kind, const char *name, char **error);
```

`kind` is `GIMP_TYPE_LAYER`/`GIMP_TYPE_CHANNEL`/`GIMP_TYPE_PATH`. Commands
target fixed (non-pattern) sets; pattern definitions are preserved by the
snapshots untouched. Statuses: OK (mutated with one undo step, or a true
no-op), INVALID_ARGUMENT (bad kind/name/members, duplicate name), NOT_FOUND
(REPLACE/RENAME/REMOVE of an absent name), FAILED (frozen, or the
immediate-purge rollback). `count == 0` creates an explicit empty set via the
same direct-construction route XCF loading uses — never
`gimp_item_list_named_new(..., NULL)`, which captures the active selection.

## Harness and commands

Same producer-prefix pattern as `docs/saved-set-lifetime-tests.md`:

```sh
python3 scripts/test-saved-set-undo.py \
    --producer "$PWD/.build/engine-adapters/GIMP_3_2_8" all \
    --work "$(mktemp -d /tmp/glims-saved-set-undo.XXXXXX)"
```

The harness asserts, per phase: exact undo/redo stack deltas (+1 with redo
nuked per command, -1/+1 and +1/-1 around Undo/Redo, zero for no-ops and
refusals), the top step is a plain undo (not a group), dirty transitions
against a clean XCF savepoint, exact live membership with independent weak
oracles, stored-set order and pattern preservation, member identity across
Undo/Redo, the frozen refusal, the error preflights, deletion/purge
interaction (detached omitted, weakly known, finalized never exposed), and a
crash-free close with sets stored.

## What was and was not checked

- Source-only verification against all four engine trees (`_engine/src/`)
  of every API used: `gimp_image_undo_push` varargs (pointer properties via
  `gimp_properties_append_valist`/`G_VALUE_COLLECT`), the freeze getter,
  store/unlink/get_stored_item_sets semantics and signal, `GimpItemList`
  construct properties (`items` is `g_list_copy` of borrowed pointers),
  the undo-event signal, and the category-safety greps above.
- `clang -fsyntax-only` with each engine set's own gimp-console flags
  (`_engine/adapter/<ref>/compile.rsp`) passes for `Engine/item-sets.c`,
  `Engine/item-sets-undo.c`, the other `engine-private.h` consumers, and the
  harness on GIMP_3_2_8, GIMP_3_2_0, GIMP_3_0_8 and master.
- Run under the native grant (private root only, pinned ref GIMP_3_2_8):
  `GLIMS_ADAPTER_ROOT=$PWD/.build/engine-adapters scripts/build-adapter.sh
  --test GIMP_3_2_8` — adapter built, dylib exports only
  `glims_engine_get_api`, conformance PASSED with 1917 checks, 0 failures,
  0 GLib CRITICALs. `scripts/test-saved-set-undo.py all --producer
  $PWD/.build/engine-adapters/GIMP_3_2_8` — PASSED, 130 checks, 0 failures.
  Regression control `scripts/test-saved-set-lifetimes.py all` against the
  same private producer — PASSED, 188 checks, 0 failures.
- Not run: the other engine sets (the grant named the pinned ref only), the
  app/engine smoke (no facade or Swift change, so `swift build` was not
  needed), and the immediate-purge rollback path (undo limits are far above
  one small step; the branch is code-reviewed and documented instead).
- Out of scope (unchanged): facade slots, Swift/UI, XCF persistence of the
  new steps (XCF stores item sets as before), and any plug-in-visible
  surface.
