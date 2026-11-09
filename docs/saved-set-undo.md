# Native undo for explicit saved-set edits

Engine-internal slice on top of the weak-identity item-set manager
(`Engine/item-sets.c`, `docs/saved-set-lifetimes.md`). Adds native
Undo/Redo snapshots for the four explicit saved-set commands
CREATE/REPLACE/RENAME/REMOVE. Native stack limits may immediately expire
a new step while the edit remains applied, as with other native commands. No facade slot, no `glims_engine.h` change, API
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

- **One plain undo step per command when retained, never a group.** `gimp_image_undo_push`
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
  name, pattern flag, select method; full weak-definition member list copied into strong refs, including detached-but-alive identities). The
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
  anything mutates: a refused preflight preserves state, history and dirty
  exactly (a push while frozen would still dirty the image —
  `gimpimage-undo.c:375-382` — hence the pre-push check).
- **Native expiry remains a successful edit.** A push may immediately expire
  its new step under native stack limits. The requested edit stays applied
  and dirty and the redo stack follows native push semantics. No borrowed
  Undo pointer is retained, and no post-mutation FAILED result or dirty-state
  rollback is attempted. The original helper branch incorrectly rolled back
  metadata/dirty while leaving redo destroyed; that claim is withdrawn.
- **Full definitions across deletion Undo.** Snapshots copy the manager's
  weak definition into owned refs, including detached-but-alive identities.
  They do not use the exposed live-only native list as the full definition.
  Restore imports those identities back as weak refs, then refreshes native
  lists to attached members only. Rename preserves the full definition, and
  Replace no-op detection compares it, so replacing an apparently empty set
  with an explicit empty definition can clear a hidden deleted member.

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
(REPLACE/RENAME/REMOVE of an absent name), FAILED (frozen). `count == 0` creates an explicit empty set via the
same direct-construction route XCF loading uses — never
`gimp_item_list_named_new(..., NULL)`, which captures the active selection.

## Harness and commands

Same producer-prefix pattern as `docs/saved-set-lifetime-tests.md`:

```sh
python3 scripts/test-saved-set-undo.py all \
    --producer "$PWD/.build/engine-adapters/GIMP_3_2_8" \
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

## Acceptance evidence

The original helper passed 130 pinned checks but missed two important
contracts. Root regressions reproduced five failures: rename while a member
was detached lost its definition across UndoRename/UndoDelete; replacing an
apparently empty exposed set with an explicit empty definition was mistaken
for a no-op; and immediate native Undo expiry returned FAILED while rolling
metadata/dirty back after redo had already been cleared.

The corrected code passes all 150 standalone Undo checks and all 188 existing
lifetime checks on every engine (3.2.8, 3.0.8, 3.2.0 and master), plus native
conformance counts 1,917 / 1,703 / 1,917 / 1,917. The zero-byte/zero-minimum-
level config fixture actually expires the newly pushed step, checks applied
metadata/dirty/redo semantics, and restores the original config. Independent
source review of the Root fix found no important issue; it verified manager
lifetime, synchronous store/import ordering, detached-member filtering and
native pop/free/expiry timing. It did not execute the matrix.

No facade/UI surface is exposed by this slice. XCF keeps storing the resulting
item-set definitions; Undo history itself is not serialized. Pattern definitions
are preserved but are not editable through these fixed-set commands. The
private commands require an adopted image with its live identity manager.
