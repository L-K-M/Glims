# EDIT facade for saved sets (slot 135)

Additive, token-addressed editing of an image's fixed saved sets on top of
the READ slots 133/134 (`docs/saved-set-read-facade.md`), the weak-identity
item-set manager (`Engine/item-sets.c`, `docs/saved-set-lifetimes.md`) and
the accepted engine-internal undoable commands
(`Engine/item-sets-undo.c`, `docs/saved-set-undo.md`). API version stays 1:
the slot is appended at the end of `GlimsEngineAPI`, so the prefix ABI is
untouched and `struct_size` tells old libraries from new ones. No UI, no
selection change, no new generic group/dirty machinery — the mutation reuses
the already accepted `glims_item_sets_create/replace/rename/remove`.

| File | Role |
|---|---|
| `Sources/CGlimsEngine/include/glims_engine.h` | `GlimsItemSetEditOp` enum; slot 135 `image_item_set_edit` appended to the table. |
| `Engine/item-sets-edit.c` | New facade entry: argument/field/name/member validation, edit-readiness gate, token resolution, exhaustion preflight, dispatch, `outToken`. Runs on the engine thread. |
| `Engine/item-sets.c` | Appended: `glims_item_sets_token_exhausted`, `glims_item_sets_resolve` (image+kind), `glims_item_sets_token_of`. |
| `Engine/engine.c` | Marshal + `api_image_item_set_edit` (zeroes `*outToken` before dispatch, also on NOT_RUNNING) + table entry. |
| `Engine/engine-private.h` | Declarations. |
| `Sources/GlimsKit/Engine/EngineSession.swift` | Typed wrapper: `ItemSetEdit`, `editItemSet(_:kind:token:name:members:)` with the Swift NUL preflight. |
| `Engine/tests/saved-set-edit-tests.c` | Standalone native harness; fixture sets only via the engine-internal `glims_item_sets_create`, all edit assertions through slot 135. |
| `scripts/test-saved-set-edit.py` | Build/run driver; selects an existing producer prefix, never rebuilds the shared producer. |
| `docs/saved-set-edit-facade.md` | This document. |

## Contract (slot 135 `image_item_set_edit`)

```
GlimsStatus image_item_set_edit (engine, image, operation, kind, token,
                                 name, members, count, outToken, error)
```

- **Ops and identity.** `operation` is a `GlimsItemSetEditOp`
  (CREATE/REPLACE/RENAME/REMOVE), `kind` a `GlimsItemSetKind` — both
  facade-owned enums; unknown values are INVALID_ARGUMENT. CREATE takes
  `token` 0, the full new `name` and the EXPLICIT `members` (`count` 0 with
  `members` NULL is an empty set). REPLACE/RENAME/REMOVE take the CURRENT
  `token` of a set of this image AND kind (as listed by slot 133); the set
  is resolved by token only — never through a name or the display label —
  and its full name is captured internally from the resolved set. Foreign,
  stale or expired tokens are NOT_FOUND and never retargeted.
- **Strict field relevance.** REPLACE: `name` NULL. RENAME: desired full
  `name`, `members` NULL with count 0. REMOVE: `name` NULL, `members` NULL, count 0. Any
  other combination, `count` < 0, or `members` NULL with `count` > 0 is
  INVALID_ARGUMENT.
- **Names** are the FULL name: nonempty valid UTF-8, no control characters,
  at most 255 bytes, as a NUL-terminated C string (an embedded NUL cannot
  cross the C contract; the Swift wrapper preflights it before the RPC).
- **Members** are item ids: each > 0 (0 never means the current selection),
  live, attached to this image, of the set's kind, unique within the list.
- **Write gate and preflight.** The call requires edit readiness
  (`glims_edit_ready`) BEFORE any write: BUSY while a stroke, filter preview
  or plug-in holds the image. Frozen undo stacks refuse FAILED. Token
  exhaustion (the engine counter at UINT64_MAX) is preflighted before ANY
  mutation for the token-minting ops CREATE/REPLACE/RENAME. Every refused
  or failed call preserves state, history and dirty exactly; `outToken` is
  reset to 0 before dispatch and on every failure.
- **Semantics on success.** One atomic native undo step per mutating call
  (the accepted commands), image dirty applied; native stack limits may
  expire the new step immediately — the edit stays applied, as with other
  native commands. No-ops (identical REPLACE members, same-name RENAME)
  return OK with NO undo step and no dirty change. `outToken` receives the
  resulting set's token: fresh after CREATE/REPLACE/RENAME (the old token
  expires with the re-stored set), the current one after a no-op, 0 after
  REMOVE.
- **Errors.** INVALID_ARGUMENT for any malformed request; NOT_FOUND for an
  unknown image or a token this image+kind does not own; BUSY while not
  edit-ready; NOT_RUNNING for a NULL engine (with `outToken` reset to 0).

## Initial compile checks (runtime evidence below)

- `swift build -j2` / `swift build --build-tests` (Swift wrapper + header).
- Syntax-only compile of all `Engine/*.c` and the harness against all four
  engine refs (`GIMP_3_2_8`, `GIMP_3_2_0`, `master`, `GIMP_3_0_8`) with each
  producer's own `compile.rsp` flags.
- Native build + run of the harness (needs the adapter producer and the
  engine runtime; root-owned, NOT run here):
  `scripts/build-adapter.sh --test GIMP_3_2_8` and
  `python3 scripts/test-saved-set-edit.py all --producer "$PWD/_engine/adapter/GIMP_3_2_8" --work "$(mktemp -d /tmp/glims-saved-set-edit-tests.XXXXXX)"`.
  The harness covers: CREATE/REPLACE/RENAME/REMOVE for all three kinds,
  Undo/Redo with token expiry and re-minting, no-op semantics (OK, current
  token, zero delta), every invalid field/name/member class, busy and
  frozen refusal, stale/foreign/same-name non-retarget, token exhaustion
  preflight, close and XCF persistence.

## Root acceptance

Source acceptance fixed a REPLACE result-name use after free and the native
member-array pointer type. Full-definition no-ops are recognized before
identity exhaustion; empty Swift arrays pass a NULL member pointer so strict
RENAME/REMOVE relevance holds across the bridge.

The first runtime exposed test-oracle errors: whole-kind Undo/Redo expires
all recreated set tokens, and an accepted create/cleanup pair changes Undo
by two steps. The harness now reacquires tokens after restoration, uses a
separate existing rename-conflict target, checks refusal state before the
accepted writes, and directly exercises channel/path replace, rename and
remove with Undo/Redo instead of inferring them from layer coverage.

Every engine passes all 146 edit checks; general conformance totals are
1,917 / 1,703 / 1,917 / 1,917. After merging current editor main, all 761
unit tests pass. Root reviewed the token helpers, dispatch, pointer lifetime,
full-definition no-op comparison and Swift empty-array bridge directly.
The requested independent review did not complete: its helper attempted
prohibited nested delegation and was stopped, so no independent approval is
claimed. Controls and combined app/bundle acceptance remain separate.
