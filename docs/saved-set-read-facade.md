# READ facade for saved sets (slots 133/134)

Additive, READ-ONLY listing of an image's fixed saved sets (stored item
sets) on top of the weak-identity item-set manager
(`Engine/item-sets.c`, `docs/saved-set-lifetimes.md`) and its native undo
(`Engine/item-sets-undo.c`, `docs/saved-set-undo.md`). API version stays 1:
both slots are appended at the end of `GlimsEngineAPI`, so the prefix ABI
is untouched and `struct_size` tells old libraries from new ones. No edit
API, no UI, no selection change.

| File | Role |
|---|---|
| `Sources/CGlimsEngine/include/glims_engine.h` | `GlimsItemSetKind`, `GlimsItemSetInfo`, slots 133/134 appended to the table. |
| `Engine/item-sets.c` | `FixedSet` gains a stable `token`; the manager holds the owning `GlimsEngine*`; `glims_item_sets_list` / `glims_item_sets_members_of` are the read queries. |
| `Engine/item-sets-read.c` | Facade wrappers: image lookup, output validation/reset, dispatch. |
| `Engine/engine.c` | Marshal + table entries; the bridge zeroes `*count` before dispatch (NULL engine / NOT_RUNNING resets outputs). |
| `Engine/engine-private.h` | `GlimsEngine.next_item_set_token` counter; declarations. |
| `Sources/GlimsKit/Engine/EngineSession.swift` | Typed wrapper: `ItemSetKind`, `ItemSet`, `itemSets(_:)`, `itemSetMembers(_:token:)`. |
| `Engine/tests/saved-set-read-tests.c` | Standalone native harness (same linkage pattern as `saved-set-undo-tests.c`); stored sets are created only via engine-internal fixtures, all assertions go through the facade. |
| `scripts/test-saved-set-read.py` | Build/run driver; selects an existing producer prefix, never rebuilds the shared producer. |
| `docs/saved-set-read-facade.md` | This document. |

## Contract

- **Slot 133 `image_item_sets`** lists the FIXED (non-pattern) stored sets
  of the image — layers, channels, paths — kinds in `GlimsItemSetKind`
  order, stored-list order within a kind. Each row: opaque `token`,
  facade `kind` (own uint32 enum, no GType crosses), LIVE attached
  `member_count`, and `display_name[256]` (UTF-8, truncated at a character
  boundary for display only). Fills up to `capacity` rows, `count` gets
  the total; `rows` NULL + capacity 0 is a count-only read.
- **Slot 134 `image_item_set_members`** resolves ONE token within the
  captured image and outputs the CURRENT ATTACHED member item ids (stored
  membership order; deleted/detached weak members skipped; empty set =
  count 0). The token — never a name — is the identity.

## Identity (token) semantics

- Tokens come from a per-engine monotonic `uint64` counter
  (`GlimsEngine.next_item_set_token`), allocated when the manager adopts a
  fixed set. 0 is never issued; at `UINT64_MAX` allocation fails closed
  (the set is listed with token 0, slot 134 refuses it) and no identity is
  ever reused.
- The token lives on the manager's `FixedSet`, so it is **retained through
  quiet live-member replacement** (`rebuild_sets` swaps the exposed native
  object, not the `FixedSet`).
- **Explicit removal or an undoable replacement expires the old token**:
  the `FixedSet` (and its token) is dropped when the set disappears or is
  re-stored as a new native object. A set recreated under the same name
  gets a **fresh token**; an old token is **never retargeted**, and a token
  owned by another image (same or foreign engine) matches no set here and
  is refused NOT_FOUND.
- `glims_item_sets_new` now takes the `GlimsEngine*` (the one adoption site
  in `Engine/image.c` passes it through).

## Read rules

Both slots are plain reads on the engine thread: allowed while the image
is busy (stroke/filter/plug-in — no busy gate), never changing selection,
image, history, dirty flag or pixels; only transient weak-ref gets, no
new strong retention, no leaks. Defensive outputs: `*count` is reset to 0
in the bridge and on every failure; INVALID_ARGUMENT for NULL `count`,
negative `capacity`, token 0; NOT_FOUND for unknown image and unknown/
foreign/stale/expired tokens; NOT_RUNNING (with `*count` 0) for a NULL
engine.

## Verification

- `swift build` / `swift build --build-tests` (Swift wrapper + header).
- Syntax-only compile of all `Engine/*.c` and the harness against all
  four engine refs (`GIMP_3_2_8`, `GIMP_3_2_0`, `master`, `GIMP_3_0_8`)
  with the producer's own `compile.rsp` flags.
- Native build + run of the harness (needs the adapter producer and the
  engine runtime; root-owned):
  `scripts/build-adapter.sh --test GIMP_3_2_8` and
  `python3 scripts/test-saved-set-read.py all --producer "$PWD/_engine/adapter/GIMP_3_2_8" --work "$(mktemp -d /tmp/glims-saved-set-read.XXXXXX)"`.
  The harness covers: stable repeated reads and quiet-rebuild retention,
  foreign/stale tokens, same-name recreation without retarget, empty set
  and partial capacity, all three kinds, deleted-weak-member drop/restore,
  undo expiry, UTF-8 display truncation with token-resolved members, busy
  reads, NULL-engine output reset, and read invariants (no undo/redo/dirty/
  selection change).
