# saved-set-lifetime-tests

Deterministic standalone regression harness for `GimpItemList` stored-set
lifetimes on the pinned `GIMP_3_2_8` engine. Three test-only files, no
production changes:

| File | Role |
|---|---|
| `Engine/tests/saved-set-lifetime-tests.c` | Native harness: links adapter objects + GIMP gimp-console objects, includes `Engine/engine-private.h`, runs the whole fixture/test body on the engine thread via one `glims_engine_call()`. No libgimp linkage, no private struct mirroring. |
| `scripts/test-saved-set-lifetimes.py` | Build/run driver. Selects an existing producer prefix; uses the producer's exact `compile.rsp`/`objects.rsp`/`link.rsp` args; never rebuilds the shared producer. |
| `docs/saved-set-lifetime-tests.md` | This document. |

## What the harness asserts (intended semantics)

Fixture on image 1: root child `C` (`ssl-child`), root group `G`
(`ssl-group`) containing subgroup `G2` (`ssl-inner`) containing grandchild
`GC` (`ssl-grandchild`). Stored layer sets: `ssl-set-g` {G}, `ssl-set-c` {C},
`ssl-set-gc` {GC}, `ssl-set-mixed` {G,C,GC}, an explicit EMPTY set
`ssl-set-empty` (built with `g_object_new(..., "items", NULL, NULL)` — the
same route `app/xcf/xcf-load.c` uses — never `named_new(..., NULL)`, which
would capture the active selection), and a glob pattern set `ssl-g*`. Every
member also has an independent `GWeakRef` oracle; the harness holds no strong
reference on any item across phases.

After EVERY operation each set is reacquired by name AND item type from
`gimp_image_get_stored_item_sets()` (transfer-none; borrowed pointer never
retained — production may replace the native `GimpItemList` object).
`gimp_item_list_get_items()` results are treated as transfer-container with
borrowed members (container freed, items never freed). Before ANY dereference
of a returned raw member, its pointer VALUE is compared against a freshly
obtained current attached flattened live tree (`gimp_image_get_layer_list`,
transfer container, recurses into groups). Unvalidated members are never
cast, typechecked or dereferenced; they are counted as
"detached-exposed" failures. Expected membership = intended members whose
weak oracle is alive AND whose address is in the live tree; actual membership
is compared as an exact pointer-value multiset (catches nonmember
resurrection, duplicates, lost members, detached/finalized members exposed).
Member order within a set is unordered per the native gtk-doc, so it is
compared as a set; the ORDER OF THE STORED-SET LIST itself is compared
exactly within a session.

Phases:

1. Baseline membership of all six sets; empty set is empty while the active
   selection is non-empty (control against the `named_new(NULL)` fallback);
   type scoping (no channel set with the same name).
2. Root group delete `gimp_image_remove_layer(G, push_undo=TRUE)`, Undo,
   Redo, then native undo purge `gimp_image_undo_free()`: detached members
   omitted; the SAME live identity (weak-oracle address equality) restores on
   Undo; after purge the removed subtree is finalized (oracles dead — no set
   or harness kept it alive) and no finalized member stays exposed.
3. Separate nested-leaf delete/Undo/Redo/purge: `GC2` inside group `G3`;
   removal signals only the parent container, never the root container the
   sets observe.
4. Reparent `C` from root into `G3` via `gimp_image_reorder_item()` and its
   Undo: an attached member stays exposed; no other set gains it.
5. XCF save/reopen round trip (facade `image_save`/`image_open` on `.xcf`):
   names, item type, pattern definition (name + `GimpSelectMethod`) and
   membership compared by layer NAME across the reopen — never by native
   session ids or pointers. A second save is made while `rt-g` is detached;
   XCF writes only currently attached members (`xcf-save.c` PROP_ITEM_SET_ITEM
   matches live layers by pointer), so the reopened `rt-set-gc` must exist
   but be empty.
6. Bookkeeping must add no EXTRA undo/dirty beyond the native triggering
   operation. State is captured independently and immediately around each
   operation with the public Core APIs (`gimp_image_get_undo_stack()` /
   `gimp_image_get_redo_stack()` + `gimp_undo_stack_get_depth()`,
   `gimp_image_is_dirty()`): store/replace/unlink/no-op assert zero delta;
   remove/reorder assert exactly +1 undo step with the redo stack nuked
   (one native undo group); undo/redo assert exactly -1/+1 and +1/-1; purge
   asserts both stacks emptied.
7. Explicit no-op (unlink of a never-stored set returns FALSE, zero delta),
   same-name replace (zero delta, replaced set moves to the front), explicit
   unlink of every set (zero delta each), and two close teardowns: image 1
   closed with all sets still stored, image 4 closed after explicit unlinks.
   Both must finish without crash. No memory-leak claim is made: the only
   liveness observables are the weak oracles.

## Expected baseline failures on the unmodified engine/adapter

These checks are designed to FAIL against the current native bookkeeping
(source-verified in `app/core/gimpitemlist.c`, GIMP_3_2_8) and to pass once
the adapter's weak-membership manager owns set membership:

- After root group remove/redo: `ssl-set-gc` and `ssl-set-mixed` still expose
  the detached `GC`/`G` raw pointers (`get_items` returns them; they are not
  in the live tree) — only the root container is observed
  (`gimp_item_list_constructed`, ~lines 193-209), so nested removals never
  prune descendants.
- After remove + Undo: `ssl-set-c` resurrects `G` as a member —
  `gimp_item_list_item_remove()` parks EVERY removed root item in every
  fixed set's `deleted_items` without checking membership (~532-542), and
  `gimp_item_list_item_add()` re-prepends a parked item into sets it never
  belonged to (~510-523).
- After reparent-away: `ssl-set-c` loses the still-attached `C` (root
  "remove" prunes it even though `C` merely moved into `G3`); after the
  reparent Undo, `ssl-set-leaf` gains `C` (nonmember resurrection).
- After purge: `ssl-set-gc`/`ssl-set-mixed`/`ssl-set-leaf` still expose
  finalized members (dangling raw pointers) instead of dropping them.

Checks expected to PASS even on the unmodified engine (controls): pattern-set
dynamic evaluation against the live tree, stored-set order across structural
bookkeeping, undo/redo stack deltas, zero-delta store/unlink/no-op
bookkeeping, XCF round trip of attached membership, close teardowns.

## Commands (run by the owner of the runtime decision)

Producer prefix: any directory with `obj/`, `compile.rsp`, `objects.rsp`,
`link.rsp` as written by `scripts/build-adapter.sh` (e.g.
`$GLIMS_ADAPTER_ROOT/GIMP_3_2_8`, default `<checkout>/_engine/adapter/GIMP_3_2_8`).
The producer objects must match this checkout's `Engine/`.

```sh
cd /Volumes/PaseoData/TrueNAS/paseo-home/workspace/Glims-wt-saved-set-lifetimes

# build only (compile + link; uses the producer's exact rsp args):
python3 scripts/test-saved-set-lifetimes.py \
    --producer "$PWD/.build/engine-adapters/GIMP_3_2_8" build
# binary: .build/saved-set-lifetime-tests/saved-set-lifetime-tests

# run with throwaway engine state (never the real HOME / ~/.cache / GIMP settings):
WORK=$(mktemp -d /tmp/glims-saved-set-tests.XXXXXX)
python3 scripts/test-saved-set-lifetimes.py run --binary \
    "$PWD/.build/saved-set-lifetime-tests/saved-set-lifetime-tests" --work "$WORK"

# or both:
python3 scripts/test-saved-set-lifetimes.py \
    --producer "$PWD/.build/engine-adapters/GIMP_3_2_8" all --work "$WORK"
```

Equivalent manual commands (what the script runs):

```sh
PRODUCER=$PWD/.build/engine-adapters/GIMP_3_2_8
OUT=$PWD/.build/saved-set-lifetime-tests
mkdir -p "$OUT"
xcrun clang @"$PRODUCER/compile.rsp" \
    -I"$PWD/Sources/CGlimsEngine/include" -I"$PWD/Engine" \
    -std=c11 -O2 -Wall -Wextra -Werror=implicit-function-declaration \
    -c Engine/tests/saved-set-lifetime-tests.c -o "$OUT/saved-set-lifetime-tests.o"
xcrun clang++ -o "$OUT/saved-set-lifetime-tests" \
    "$OUT/saved-set-lifetime-tests.o" "$PRODUCER"/obj/*.o \
    @"$PRODUCER/objects.rsp" @"$PRODUCER/link.rsp"

WORK=$(mktemp -d /tmp/glims-saved-set-tests.XXXXXX)
env HOME="$WORK/home" XDG_CACHE_HOME="$WORK/cache" GIMP3_DIRECTORY="$WORK/user" \
    "$OUT/saved-set-lifetime-tests" "$WORK"
```

The binary creates `WORK/{home,user,cache}` itself and uses `user/`/`cache/`
as the engine's directories via `GlimsEngineConfig`. Exit status: 0 = all
checks passed, 1 = fixture failure or any failed check, 2 = usage error.

## What was and was not checked

- Source-only (verified against `_engine/src/GIMP_3_2_8/gimp` in the shared
  engine tree, every name/prototype used): `gimp_item_list_named_new` /
  `pattern_new` / `get_items` (transfer container, unordered) /
  `get_item_type` / `is_pattern` / `add`; `gimp_image_store_item_set`
  (transfer full, replaces same name+type+kind), `unlink_item_set`,
  `get_stored_item_sets` (transfer none, order relevant);
  `gimp_image_get_layer_list` (fresh flattened container via
  `gimp_item_stack_get_item_list`), `gimp_image_get_selected_layers`
  (borrowed), `gimp_image_remove_layer`, `gimp_image_reorder_item`,
  `gimp_image_add_layer`, `gimp_image_undo`/`redo`/`undo_free`,
  `gimp_image_get_undo_stack`/`get_redo_stack`, `gimp_undo_stack_get_depth`,
  `gimp_image_is_dirty`, `gimp_image_dirty` mask enum, XCF save/load of item
  sets (`xcf-save.c` PROP_ITEM_SET/PROP_ITEM_SET_ITEM, `xcf-load.c`).
  The harness itself does NOT mirror `GimpItemListPrivate` or any other
  private layout; it uses public internal Core APIs only.
- Compiled but NOT executed here: the harness and script were prepared for
  the root owner to build and run. `scripts/test-saved-set-lifetimes.py --help`
  and `python3 -m py_compile` were run; no compiler and no native harness were
  invoked in this slice. No test results are claimed.
- Not executed / not claimed: any runtime behavior, pass/fail of the
  assertions above, leak freedom (only weak-oracle liveness is asserted), and
  behavior on other engine sets.

## Producer assumptions and unresolved limits

- The producer prefix's `obj/*.o` must be built from THIS checkout's `Engine/`
  at the same commit (as `build-adapter.sh` does), and `objects.rsp` must
  already exclude `main.c.o` (the harness supplies `main`).
- The harness calls facade `image_save`/`image_open` from inside the single
  engine-thread `glims_engine_call`; `glims_engine_call` re-enters directly
  on the engine thread and file procedures nest a loop there, the same path
  plug-in calls take. Assumed, not yet executed.
- Address reuse after finalization is a theoretical ambiguity when matching
  raw pointers by value; mitigated by gating every member against a fresh
  live tree before any dereference and by clearing weakrefs at finalize, but
  not provably eliminated (noted in the research as well).
- `gimp_image_is_dirty()` is boolean (`dirty != 0`); dirty assertions are
  therefore unchanged-vs-changed around each operation, captured immediately
  before/after — not a counter comparison.
- XCF cannot represent detached members; the harness asserts they are absent
  after reopen, which is the semantic identity appropriate across a reopen.
- No saved-set facade, UI or Undo implementation is part of this slice; the
  harness tests native semantics the future adapter manager must own.
