/*
 * saved-set-lifetime-tests.c — deterministic standalone regression harness
 * for GimpItemList stored-layer-set lifetimes (GIMP_3_2_8 engine).
 *
 *   saved-set-lifetime-tests WORK_DIR
 *
 * Test-only file. Like the item-set-lifetime-probe it links the adapter
 * objects and GIMP's gimp-console objects directly (no dlopen, no libgimp),
 * includes Engine/engine-private.h, and runs the whole fixture/test body on
 * the engine thread through one glims_engine_call(). It modifies no
 * production file.
 *
 * Unlike the probe, this harness ASSERTS intended saved-set semantics and is
 * expected to FAIL against the unmodified engine/adapter bookkeeping:
 *
 *   Intended semantics asserted here:
 *   - A fixed set's exposed membership (gimp_item_list_get_items) is exactly
 *     its intended members that are currently attached to the image's live
 *     layer tree. Detached members (removed, awaiting undo) are omitted;
 *     finalized members disappear and are never kept alive by a set.
 *   - Undo restores the SAME live object identity (checked through
 *     independent GWeakRef oracles, not through the set's own weakrefs).
 *   - Removing/re-adding one root item must not change any other set's
 *     membership (no nonmember parking/resurrection).
 *   - Reparenting an attached item keeps it exposed in its set.
 *   - Bookkeeping (store/replace/unlink/no-op) adds no undo step and no
 *     dirty flag beyond the native triggering operation.
 *   - The stored-set list order and pattern definitions survive structural
 *     bookkeeping; XCF round trips preserve names, item type, pattern
 *     definition and attached membership (compared by layer name across the
 *     reopen, never by session ids or pointers).
 *
 *   Known unmodified-engine bugs these tests catch (source-verified in
 *   app/core/gimpitemlist.c, GIMP_3_2_8): gimp_item_list_item_remove() parks
 *   EVERY removed root item in every fixed set's deleted_items without
 *   checking membership (lines ~532-542), and item_add() re-prepends such a
 *   parked item into sets it never belonged to (~510-523); only the root
 *   container is observed (~193-209), so nested removals never prune
 *   descendant members, and detached/finalized raw pointers stay exposed in
 *   get_items.
 *
 * Safety rules (enforced in code):
 *   - get_stored_item_sets() is transfer-none; each lookup reacquires the set
 *     by name AND type after every operation and the borrowed pointer is
 *     never retained across operations (production may replace the native
 *     GimpItemList object at any store).
 *   - gimp_item_list_get_items() is transfer-container with borrowed member
 *     pointers: only the container is freed (g_list_free), never the items.
 *   - Before ANY dereference of a returned raw member, its pointer VALUE is
 *     compared against a freshly obtained current attached flattened live
 *     tree (gimp_image_get_layer_list, transfer container). Pointers not in
 *     the live tree are counted as exposed-detached failures and are never
 *     cast, typechecked or dereferenced.
 *   - Expected identity uses independent GWeakRef oracles (g_weak_ref_get +
 *     immediate unref); the harness holds no strong reference on any item
 *     across phases, so a purge can finalize removed subtrees.
 *   - No private struct layout is mirrored: only public internal Core APIs
 *     are used (gimp_item_list_*, gimp_image_*, gimp_item_* on live pointers,
 *     gimp_undo_stack_get_depth, gimp_image_is_dirty, ...).
 *
 * Member order semantics: native named get_items is documented unordered, so
 * membership is compared as pointer-value multisets (duplicates and losses
 * both fail). The ORDER OF THE STORED-SET LIST itself
 * (gimp_image_get_stored_item_sets, "order of items is relevant") IS
 * compared exactly within a session.
 */
#include "engine-private.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "core/core-enums.h"
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpitemlist.h"
#include "core/gimpobject.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpundostack.h"

int main (int argc, char **argv);

#define MAX_SETS 16
#define MAX_MEMBERS 8

typedef struct
{
  GimpImage   *image;
  GlimsImageID image_id;
  const char  *work;

  /* Borrowed typed pointers, used only while the item is attached (at the
   * moment of an operation). After detach, identity is tracked only via
   * the captured address and the independent weak oracle. */
  GimpLayer *g;    /* image-1 fixture: root group G                     */
  GimpLayer *c;    /* direct root child C                               */
  GimpLayer *g2;   /* nested subgroup G2 inside G                       */
  GimpLayer *gc;   /* grandchild GC inside G2                           */
  GimpLayer *g3;   /* nested-leaf phase: group at root                  */
  GimpLayer *gc2;  /* nested leaf inside G3                             */

  gpointer addr_g, addr_c, addr_g2, addr_gc, addr_g3, addr_gc2;
  GWeakRef wr_g, wr_c, wr_g2, wr_gc, wr_g3, wr_gc2;

  int failures;
} Probe;

static const GlimsEngineAPI *api;

#define CHECK(condition, ...)                     \
  do {                                            \
    if (condition) {                              \
      printf ("ok    ");                          \
    } else {                                      \
      printf ("FAIL  ");                          \
      probe->failures++;                          \
    }                                             \
    printf (__VA_ARGS__);                         \
    printf ("\n");                                \
    fflush (stdout);                              \
  } while (0)

/* Fixture failure inside run_all: the run is meaningless without it; bail
 * out non-zero immediately. */
#define FIXTURE(condition, ...)                   \
  do {                                            \
    if (! (condition)) {                          \
      printf ("FIXTURE-FAIL  ");                  \
      printf (__VA_ARGS__);                       \
      printf ("\n");                              \
      fflush (stdout);                            \
      probe->failures++;                          \
      return GLIMS_STATUS_FAILED;                 \
    }                                             \
  } while (0)

/* Fixture failure inside a helper: record it and return failure; the caller
 * turns the NULL/FALSE into a FIXTURE bail-out. */
#define HARD_FAIL(...)                            \
  do {                                            \
    printf ("FIXTURE-FAIL  ");                    \
    printf (__VA_ARGS__);                         \
    printf ("\n");                                \
    fflush (stdout);                              \
    probe->failures++;                            \
  } while (0)

/* Independent liveness oracle: g_weak_ref_get() is safe on finalized objects
 * (returns NULL); the temporary strong ref is dropped immediately so the
 * harness never keeps an object alive. */
static gboolean
oracle_alive (GWeakRef *wr)
{
  gpointer obj = g_weak_ref_get (wr);

  if (obj != NULL)
    g_object_unref (obj);

  return obj != NULL;
}

typedef struct { gpointer address; GWeakRef *oracle; } ExpectedMember;

/* Reacquire a stored set by name AND type, fresh after every operation.
 * gimp_image_get_stored_item_sets() is transfer-none: the returned set is
 * borrowed and is NOT retained anywhere. */
static GimpItemList *
find_set (GimpImage *image, const char *name, GType item_type)
{
  GList *sets = gimp_image_get_stored_item_sets (image, item_type);
  GList *iter;

  for (iter = sets; iter; iter = iter->next)
    if (g_strcmp0 (gimp_object_get_name (iter->data), name) == 0)
      return iter->data;

  return NULL;
}

/* Freshly obtained current attached flattened live tree: transfer container
 * of borrowed item pointers (gimp_image_get_layer_list ->
 * gimp_item_stack_get_item_list, which prepends into a new list and recurses
 * into children). Caller frees the container only. */
static GList *
live_layers (GimpImage *image)
{
  return gimp_image_get_layer_list (image);
}

typedef struct
{
  gint undo;
  gint redo;
  gint dirty; /* gimp_image_is_dirty(): the public dirty counter != 0 */
} EngineState;

/* Captured independently of the facade's undo_info, immediately around each
 * operation. */
static EngineState
capture_state (GimpImage *image)
{
  EngineState state;

  state.undo  = gimp_undo_stack_get_depth (gimp_image_get_undo_stack (image));
  state.redo  = gimp_undo_stack_get_depth (gimp_image_get_redo_stack (image));
  state.dirty = gimp_image_is_dirty (image);

  return state;
}

/* Bookkeeping-only operations (store/replace/unlink/no-op) must add no undo
 * step, no redo change and no dirty flag. */
static void
check_bookkeeping_quiet (Probe *probe, EngineState before, EngineState after,
                         const char *phase, const char *op)
{
  CHECK (after.undo == before.undo && after.redo == before.redo,
         "[%s] %s: no extra undo/redo from bookkeeping (undo %d->%d, redo %d->%d)",
         phase, op, before.undo, after.undo, before.redo, after.redo);
  CHECK (after.dirty == before.dirty,
         "[%s] %s: dirty unchanged by bookkeeping (%d->%d)",
         phase, op, before.dirty, after.dirty);
}

/* A native triggering operation moves the stacks by exactly its own steps. */
static void
check_stack_delta (Probe *probe, EngineState before, EngineState after,
                   gint d_undo, gint d_redo, const char *phase, const char *op)
{
  CHECK (after.undo - before.undo == d_undo && after.redo - before.redo == d_redo,
         "[%s] %s: undo %d->%d, redo %d->%d (expected delta %d/%d)",
         phase, op, before.undo, after.undo, before.redo, after.redo,
         d_undo, d_redo);
}

/* Snapshot the stored-set list order (names). gimp_image_get_stored_item_sets
 * is transfer-none; names are copied and owned by the caller. */
static guint
snapshot_order (GimpImage *image, const char **names, guint max)
{
  GList *sets = gimp_image_get_stored_item_sets (image, GIMP_TYPE_LAYER);
  GList *iter;
  guint n = 0;

  for (iter = sets; iter && n < max; iter = iter->next)
    names[n++] = g_strdup (gimp_object_get_name (iter->data));

  return n;
}

/* The stored-set list order is relevant; structural bookkeeping must not
 * reorder it. Compared exactly, within one session. */
static void
expect_order (Probe *probe, GimpImage *image,
              const char **names, guint n, const char *phase)
{
  const char *now[MAX_SETS];
  guint n_now = snapshot_order (image, now, MAX_SETS);
  guint i;
  gboolean ok = (n_now == n);

  for (i = 0; ok && i < n; i++)
    ok = g_strcmp0 (now[i], names[i]) == 0;

  CHECK (ok, "[%s] stored-set order preserved (%u sets)", phase, n);
  if (! ok)
    {
      printf ("      expected:");
      for (i = 0; i < n; i++)
        printf (" %s", names[i]);
      printf ("\n      actual:  ");
      for (i = 0; i < n_now; i++)
        printf (" %s", now[i]);
      printf ("\n");
      fflush (stdout);
    }
  for (i = 0; i < n_now; i++) g_free ((gpointer) now[i]);
}

/* Core membership assertion for a fixed set.
 *
 * expected[] holds each intended member address and its explicit independent
 * weak oracle, so reused allocation addresses never redefine identity. A member is expected to be EXPOSED iff its oracle is
 * alive AND its address is in the fresh live tree. The actual get_items
 * members are gated pointer-value-wise against the same fresh live tree
 * before any dereference: pointers not in the live tree are detached or
 * finalized exposures and must not occur (n_detached == 0). Comparison is an
 * exact multiset match: every expected live member exactly once, no extra
 * live member (nonmember resurrection), no duplicates, no lost member. */
static void
expect_set (Probe *probe, GimpImage *image, const char *name,
            ExpectedMember *expected, guint n_expected, const char *phase)
{
  GimpItemList *set = find_set (image, name, GIMP_TYPE_LAYER);
  GList *live = live_layers (image), *wanted = NULL, *actual = NULL;
  GError *error = NULL;
  gboolean ok = set != NULL;
  for (guint i = 0; i < n_expected; i++)
    {
      GObject *object = expected[i].oracle ? g_weak_ref_get (expected[i].oracle) : NULL;
      if (object && object == expected[i].address && g_list_find (live, object))
        wanted = g_list_prepend (wanted, object);
      g_clear_object (&object);
    }
  if (set) actual = gimp_item_list_get_items (set, &error);
  ok = ok && !error && g_list_length (actual) == g_list_length (wanted);
  for (GList *item = actual; ok && item; item = item->next)
    {
      /* Pointer values only; no access to a detached/finalized object. */
      GList *match = g_list_find (wanted, item->data);
      if (!g_list_find (live, item->data) || !match) ok = FALSE;
      else wanted = g_list_delete_link (wanted, match);
    }
  CHECK (ok && !wanted, "[%s] set %s has exact live membership", phase, name);
  g_clear_error (&error);
  g_list_free (wanted); g_list_free (actual); g_list_free (live);
}

/* Pattern set: definition (name, pattern flag, syntax method) preserved, and
 * membership re-evaluated against the fresh live tree (glob on layer names).
 * All exposed members must be live; compared as an exact multiset. */
static void
expect_pattern_set (Probe *probe, GimpImage *image, const char *pattern,
                    GimpSelectMethod method, const char *phase)
{
  GimpItemList *set = find_set (image, pattern, GIMP_TYPE_LAYER); /* borrowed */
  GList *live = live_layers (image);
  GList *items, *iter;
  GError *error = NULL;
  GPatternSpec *spec;
  gpointer expected[MAX_MEMBERS];
  guint n_expected = 0, n_live = 0, n_detached = 0, i;
  gboolean ok;
  GimpSelectMethod actual_method = 0;

  CHECK (set != NULL, "[%s] pattern set \"%s\" reacquired by name+type", phase, pattern);
  if (set == NULL)
    {
      g_list_free (live);
      return;
    }
  CHECK (gimp_item_list_is_pattern (set, &actual_method) == TRUE &&
         actual_method == method &&
         g_strcmp0 (gimp_object_get_name (set), pattern) == 0,
         "[%s] pattern definition preserved: name=\"%s\" is_pattern=TRUE method=%d",
         phase, pattern, (int) method);

  spec = g_pattern_spec_new (pattern);
  for (iter = live; iter && n_expected < MAX_MEMBERS; iter = iter->next)
    {
      if (g_pattern_spec_match_string (spec, gimp_object_get_name (iter->data)))
        expected[n_expected++] = iter->data;
    }
  g_pattern_spec_free (spec);

  items = gimp_item_list_get_items (set, &error);
  CHECK (error == NULL, "[%s] get_items(pattern \"%s\") no error", phase, pattern);
  if (error != NULL)
    g_error_free (error);

  for (iter = items; iter; iter = iter->next)
    {
      if (g_list_find (live, iter->data) != NULL)
        n_live++;
      else
        n_detached++;
    }

  ok = (n_detached == 0) && (n_live == n_expected);
  for (i = 0; ok && i < n_expected; i++)
    {
      guint occ = 0;

      for (iter = items; iter; iter = iter->next)
        if (iter->data == expected[i])
          occ++;
      if (occ != 1)
        ok = FALSE;
    }
  for (iter = items; ok && iter; iter = iter->next)
    {
      gboolean known = FALSE;

      if (g_list_find (live, iter->data) == NULL)
        continue;
      for (i = 0; i < n_expected; i++)
        if (expected[i] == iter->data)
          known = TRUE;
      if (! known)
        ok = FALSE;
    }

  CHECK (ok, "[%s] pattern \"%s\" membership matches live tree: exposed=%u detached-exposed=%u expected=%u",
         phase, pattern, n_live, n_detached, n_expected);

  g_list_free (items);
  g_list_free (live);
}

/* XCF round trip: membership compared by layer NAME (semantic identity
 * appropriate across a reopen), never by native session ids or pointers. */
static void
expect_set_by_names (Probe *probe, GimpImage *image, const char *name,
                     const char **expected_names, guint n_expected,
                     const char *phase)
{
  GimpItemList *set = find_set (image, name, GIMP_TYPE_LAYER); /* borrowed */
  GList *live = live_layers (image);
  GList *items, *iter;
  GError *error = NULL;
  guint n_live = 0, n_detached = 0, i;
  gboolean ok;

  CHECK (set != NULL, "[%s] set \"%s\" found after reopen", phase, name);
  if (set == NULL)
    {
      g_list_free (live);
      return;
    }
  CHECK (gimp_item_list_get_item_type (set) == GIMP_TYPE_LAYER,
         "[%s] reopened set \"%s\" has item type GIMP_TYPE_LAYER", phase, name);

  items = gimp_item_list_get_items (set, &error);
  CHECK (error == NULL, "[%s] get_items(\"%s\") after reopen no error", phase, name);
  if (error != NULL)
    g_error_free (error);

  ok = TRUE;
  for (iter = items; iter; iter = iter->next)
    {
      gpointer p = iter->data;
      const char *member_name;
      guint occ = 0;

      if (g_list_find (live, p) == NULL)
        {
          n_detached++;
          continue; /* never deref an unvalidated member */
        }
      n_live++;
      member_name = gimp_object_get_name (p); /* safe: verified in live tree */
      for (i = 0; i < n_expected; i++)
        if (g_strcmp0 (expected_names[i], member_name) == 0)
          occ++;
      if (occ != 1)
        ok = FALSE; /* unexpected or duplicated member name */
    }
  if (n_detached != 0 || n_live != n_expected)
    ok = FALSE;

  for (i = 0; i < n_expected; i++)
    {
      guint wanted = 0, found = 0;
      for (guint j = 0; j < n_expected; j++)
        wanted += g_strcmp0 (expected_names[i], expected_names[j]) == 0;
      for (iter = items; iter; iter = iter->next)
        if (g_list_find (live, iter->data))
          found += g_strcmp0 (expected_names[i], gimp_object_get_name (iter->data)) == 0;
      if (found != wanted) ok = FALSE;
    }
  CHECK (ok, "[%s] reopened set \"%s\" members by name: got %u, detached-exposed %u, expected %u",
         phase, name, n_live, n_detached, n_expected);

  g_list_free (items);
  g_list_free (live);
}

/* Store one fixed set; named_new copies the passed container (not item
 * refs), so the temp list is freed here; store_item_set consumes the set's
 * reference (transfer full). Returns FALSE on fixture failure. */
static gboolean
store_fixed_set (Probe *probe, GimpImage *image, const char *name, GList *items,
                 const char *phase)
{
  EngineState before = capture_state (image);
  GimpItemList *set = gimp_item_list_named_new (image, GIMP_TYPE_LAYER, name, items);
  EngineState after;

  g_list_free (items);
  if (set == NULL)
    {
      HARD_FAIL ("[%s] named set \"%s\" created", phase, name);
      return FALSE;
    }
  gimp_image_store_item_set (image, set); /* transfer full */
  after = capture_state (image);
  check_bookkeeping_quiet (probe, before, after, phase, "store_item_set");
  CHECK (find_set (image, name, GIMP_TYPE_LAYER) != NULL,
         "[%s] set \"%s\" stored and reacquired", phase, name);
  return TRUE;
}

/* Explicit EMPTY fixed set. gimp_item_list_named_new(..., NULL) would capture
 * the current active selection (or return NULL) — never used here. The same
 * direct-construction route app/xcf/xcf-load.c uses for empty sets
 * (g_object_new with "items", NULL): PROP_ITEMS copies NULL to NULL. */
static gboolean
store_empty_set (Probe *probe, GimpImage *image, const char *name, const char *phase)
{
  EngineState before = capture_state (image);
  GimpItemList *set = g_object_new (GIMP_TYPE_ITEM_LIST,
                                    "image",      image,
                                    "name",       name,
                                    "is-pattern", FALSE,
                                    "item-type",  GIMP_TYPE_LAYER,
                                    "items",      NULL,
                                    NULL);
  EngineState after;

  if (set == NULL)
    {
      HARD_FAIL ("[%s] empty set \"%s\" constructed", phase, name);
      return FALSE;
    }
  gimp_image_store_item_set (image, set); /* transfer full */
  after = capture_state (image);
  check_bookkeeping_quiet (probe, before, after, phase, "store empty set");
  CHECK (find_set (image, name, GIMP_TYPE_LAYER) != NULL,
         "[%s] empty set \"%s\" stored and reacquired", phase, name);
  return TRUE;
}

static gboolean
store_pattern_set (Probe *probe, GimpImage *image, const char *pattern,
                   GimpSelectMethod method, const char *phase)
{
  EngineState before = capture_state (image);
  GimpItemList *set = gimp_item_list_pattern_new (image, GIMP_TYPE_LAYER,
                                                  method, pattern);
  EngineState after;

  if (set == NULL)
    {
      HARD_FAIL ("[%s] pattern set \"%s\" created", phase, pattern);
      return FALSE;
    }
  gimp_image_store_item_set (image, set); /* transfer full */
  after = capture_state (image);
  check_bookkeeping_quiet (probe, before, after, phase, "store pattern set");
  return TRUE;
}

static GimpLayer *
add_layer (Probe *probe, GimpImage *image, GimpLayer *parent, const char *name)
{
  GimpLayer *layer = gimp_layer_new (image, 64, 64,
                                     gimp_image_get_layer_format (image, TRUE),
                                     name, GIMP_OPACITY_OPAQUE,
                                     GIMP_LAYER_MODE_NORMAL);
  GError *error = NULL;

  if (layer == NULL)
    {
      HARD_FAIL ("layer \"%s\" created", name);
      return NULL;
    }
  if (! gimp_image_add_layer (image, layer, parent, -1, TRUE))
    {
      g_object_unref (layer);
      HARD_FAIL ("layer \"%s\" added", name);
      return NULL;
    }
  if (! gimp_item_rename (GIMP_ITEM (layer), name, &error))
    {
      HARD_FAIL ("rename \"%s\": %s", name, error ? error->message : "?");
      if (error != NULL)
        g_error_free (error);
      return layer; /* added; name already set by gimp_layer_new */
    }
  if (error != NULL)
    g_error_free (error);
  return layer;
}

static GimpLayer *
add_group (Probe *probe, GimpImage *image, GimpLayer *parent, const char *name)
{
  GimpLayer *group = gimp_group_layer_new (image);
  GError *error = NULL;

  if (group == NULL)
    {
      HARD_FAIL ("group \"%s\" created", name);
      return NULL;
    }
  if (! gimp_item_rename (GIMP_ITEM (group), name, &error))
    {
      HARD_FAIL ("rename group \"%s\": %s", name, error ? error->message : "?");
      if (error != NULL)
        g_error_free (error);
    }
  else if (error != NULL)
    g_error_free (error);
  if (! gimp_image_add_layer (image, group, parent, -1, TRUE))
    {
      g_object_unref (group);
      HARD_FAIL ("group \"%s\" added", name);
      return NULL;
    }
  return group;
}

static void
arm_oracle (Probe *probe, GWeakRef *wr, gpointer *addr_slot, GimpLayer *layer)
{
  *addr_slot = (gpointer) layer;
  g_weak_ref_init (wr, layer);
}

/* Runs on the engine thread (dispatched by main through glims_engine_call). */
static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  GlimsOpenImage *open;
  GimpImage *image;
  char *error = NULL;
  GlimsStatus status;
  EngineState s0, s1;
  const char *order0[MAX_SETS];
  guint n_order0;
  ExpectedMember exp_g[1], exp_c[1], exp_gc[1], exp_mixed[3], exp_empty[1];
  char path[1024];
  GlimsImageID id2 = 0, id3 = 0, id4 = 0;
  GimpImage *image3, *image4;
  GList *live;
  GList *selected;

  /* ---------- image 1: fixture + structural lifecycle ---------- */

  status = api->image_new (engine, 64, 64, &probe->image_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "image_new: %s", error ? error : "?");
  if (error != NULL)
    {
      api->free_string (error);
      error = NULL;
    }

  open = glims_lookup_image (engine, probe->image_id);
  FIXTURE (open != NULL, "image adopted by the engine");
  image = probe->image = open->image;

  /* Tree: C at root; G at root with subgroup G2 and grandchild GC in G2.
   * add_layer sinks the new ref into the item stack; the harness keeps no
   * strong ref on any item, only addresses + weak oracles. */
  probe->c  = add_layer (probe, image, NULL, "ssl-child");
  probe->g  = add_group (probe, image, NULL, "ssl-group");
  FIXTURE (probe->c != NULL && probe->g != NULL, "root child C and group G built");
  probe->g2 = add_group (probe, image, probe->g, "ssl-inner");
  probe->gc = add_layer (probe, image, probe->g2, "ssl-grandchild");
  FIXTURE (probe->g2 != NULL && probe->gc != NULL, "subgroup G2 and grandchild GC built");
  gimp_image_flush (image);

  arm_oracle (probe, &probe->wr_c,  &probe->addr_c,  probe->c);
  arm_oracle (probe, &probe->wr_g,  &probe->addr_g,  probe->g);
  arm_oracle (probe, &probe->wr_g2, &probe->addr_g2, probe->g2);
  arm_oracle (probe, &probe->wr_gc, &probe->addr_gc, probe->gc);

  exp_g[0] = (ExpectedMember) {probe->addr_g, &probe->wr_g};
  exp_c[0] = (ExpectedMember) {probe->addr_c, &probe->wr_c};
  exp_gc[0] = (ExpectedMember) {probe->addr_gc, &probe->wr_gc};
  exp_mixed[0] = (ExpectedMember) {probe->addr_g, &probe->wr_g};
  exp_mixed[1] = (ExpectedMember) {probe->addr_c, &probe->wr_c};
  exp_mixed[2] = (ExpectedMember) {probe->addr_gc, &probe->wr_gc};
  exp_empty[0] = (ExpectedMember) {NULL, NULL}; /* unused: the empty set expects zero members */

  /* Fixed sets: G-only, C-only, GC-only, mixed, explicit EMPTY, + pattern. */
  FIXTURE (store_fixed_set (probe, image, "ssl-set-g",
                            g_list_prepend (NULL, probe->addr_g), "setup"), "set G-only stored");
  FIXTURE (store_fixed_set (probe, image, "ssl-set-c",
                            g_list_prepend (NULL, probe->addr_c), "setup"), "set C-only stored");
  FIXTURE (store_fixed_set (probe, image, "ssl-set-gc",
                            g_list_prepend (NULL, probe->addr_gc), "setup"), "set GC-only stored");
  FIXTURE (store_fixed_set (probe, image, "ssl-set-mixed",
                            g_list_prepend (g_list_prepend (g_list_prepend (NULL, probe->addr_gc),
                                                            probe->addr_c), probe->addr_g),
                            "setup"), "mixed set stored");
  FIXTURE (store_empty_set (probe, image, "ssl-set-empty", "setup"), "empty set stored");
  FIXTURE (store_pattern_set (probe, image, "ssl-g*", GIMP_SELECT_GLOB_PATTERN, "setup"),
           "pattern set stored");

  n_order0 = snapshot_order (image, order0, MAX_SETS);
  CHECK (n_order0 == 6, "[setup] 6 stored layer sets present (got %u)", n_order0);
  CHECK (find_set (image, "ssl-set-g", GIMP_TYPE_CHANNEL) == NULL,
         "[setup] sets are scoped by item type (no channel set named \"ssl-set-g\")");

  /* The explicit empty set is NOT the named_new(NULL) active-selection
   * fallback: the current selection is non-empty here, the set is empty. */
  selected = gimp_image_get_selected_layers (image); /* borrowed, not freed */
  CHECK (g_list_length (selected) > 0, "[setup] active selection is non-empty (control)");
  {
    GimpItemList *empty_set = find_set (image, "ssl-set-empty", GIMP_TYPE_LAYER);
    GList *items = empty_set != NULL ? gimp_item_list_get_items (empty_set, NULL) : NULL;

    CHECK (empty_set != NULL && g_list_length (items) == 0,
           "[setup] explicit empty set stored with 0 members despite non-empty selection");
    if (items != NULL)
      g_list_free (items);
  }

  /* Phase 0 baseline: everything attached. */
  expect_set (probe, image, "ssl-set-g", exp_g, 1, "baseline");
  expect_set (probe, image, "ssl-set-c", exp_c, 1, "baseline");
  expect_set (probe, image, "ssl-set-gc", exp_gc, 1, "baseline");
  expect_set (probe, image, "ssl-set-mixed", exp_mixed, 3, "baseline");
  expect_set (probe, image, "ssl-set-empty", exp_empty, 0, "baseline");
  expect_pattern_set (probe, image, "ssl-g*", GIMP_SELECT_GLOB_PATTERN, "baseline");
  expect_order (probe, image, order0, n_order0, "baseline");

  /* Phase 1: delete the root group G (the adapter's delete path,
   * Engine/edit.c) with undo. Detached members must be omitted. */
  snprintf (path, sizeof path, "%s/clean-g.xcf", probe->work);
  status = api->image_save (engine, probe->image_id, path, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "save clean g baseline");
  if (error) { api->free_string (error); error = NULL; }
  CHECK (!gimp_image_is_dirty (image), "savepoint starts clean");
  s0 = capture_state (image);
  gimp_image_remove_layer (image, probe->g, TRUE, NULL);
  s1 = capture_state (image);
  check_stack_delta (probe, s0, s1, 1, -s0.redo, "remove G", "gimp_image_remove_layer(G)");
  CHECK (oracle_alive (&probe->wr_g) && oracle_alive (&probe->wr_g2) &&
         oracle_alive (&probe->wr_gc) && oracle_alive (&probe->wr_c),
         "[remove G] undo step keeps the whole subtree alive (oracles)");
  expect_set (probe, image, "ssl-set-g", exp_g, 1, "remove G");
  expect_set (probe, image, "ssl-set-c", exp_c, 1, "remove G");
  expect_set (probe, image, "ssl-set-gc", exp_gc, 1, "remove G");
  expect_set (probe, image, "ssl-set-mixed", exp_mixed, 3, "remove G");
  expect_set (probe, image, "ssl-set-empty", exp_empty, 0, "remove G");
  expect_pattern_set (probe, image, "ssl-g*", GIMP_SELECT_GLOB_PATTERN, "remove G");
  expect_order (probe, image, order0, n_order0, "remove G");

  /* Phase 2: undo — the same live identities come back. */
  s0 = capture_state (image);
  CHECK (gimp_image_undo (image), "[undo] gimp_image_undo() ran");
  CHECK (!gimp_image_is_dirty (image), "one Undo returns to the clean savepoint");
  s1 = capture_state (image);
  check_stack_delta (probe, s0, s1, -1, 1, "undo", "gimp_image_undo()");
  {
    /* Temporary strong refs only for the comparison, dropped immediately:
     * the harness must never keep a removed subtree alive. */
    gpointer pg = g_weak_ref_get (&probe->wr_g);
    gpointer pgc = g_weak_ref_get (&probe->wr_gc);

    CHECK (pg == probe->addr_g && pgc == probe->addr_gc,
           "[undo] same live identity restored (weak oracle resolves to the same address)");
    if (pg != NULL)
      g_object_unref (pg);
    if (pgc != NULL)
      g_object_unref (pgc);
  }
  expect_set (probe, image, "ssl-set-g", exp_g, 1, "undo");
  expect_set (probe, image, "ssl-set-c", exp_c, 1, "undo");
  expect_set (probe, image, "ssl-set-gc", exp_gc, 1, "undo");
  expect_set (probe, image, "ssl-set-mixed", exp_mixed, 3, "undo");
  expect_pattern_set (probe, image, "ssl-g*", GIMP_SELECT_GLOB_PATTERN, "undo");
  expect_order (probe, image, order0, n_order0, "undo");

  /* Phase 3: redo — detached again, omitted again. */
  s0 = capture_state (image);
  CHECK (gimp_image_redo (image), "[redo] gimp_image_redo() ran");
  s1 = capture_state (image);
  check_stack_delta (probe, s0, s1, 1, -1, "redo", "gimp_image_redo()");
  expect_set (probe, image, "ssl-set-g", exp_g, 1, "redo");
  expect_set (probe, image, "ssl-set-c", exp_c, 1, "redo");
  expect_set (probe, image, "ssl-set-gc", exp_gc, 1, "redo");
  expect_set (probe, image, "ssl-set-mixed", exp_mixed, 3, "redo");
  expect_pattern_set (probe, image, "ssl-g*", GIMP_SELECT_GLOB_PATTERN, "redo");
  expect_order (probe, image, order0, n_order0, "redo");

  /* Phase 4: native undo purge. Finalized members must disappear and must
   * not be kept alive by any set (sets hold raw pointers + weakrefs only). */
  gimp_image_undo_free (image);
  s1 = capture_state (image);
  CHECK (s1.undo == 0 && s1.redo == 0, "[purge] undo and redo stacks emptied");
  CHECK (! oracle_alive (&probe->wr_g) && ! oracle_alive (&probe->wr_g2) &&
         ! oracle_alive (&probe->wr_gc),
         "[purge] removed subtree finalized; no set kept it alive");
  CHECK (oracle_alive (&probe->wr_c), "[purge] never-removed C still alive");
  expect_set (probe, image, "ssl-set-g", exp_g, 1, "purge");
  expect_set (probe, image, "ssl-set-c", exp_c, 1, "purge");
  expect_set (probe, image, "ssl-set-gc", exp_gc, 1, "purge");
  expect_set (probe, image, "ssl-set-mixed", exp_mixed, 3, "purge");
  expect_pattern_set (probe, image, "ssl-g*", GIMP_SELECT_GLOB_PATTERN, "purge");
  expect_order (probe, image, order0, n_order0, "purge");

  /* Phase 5: separate nested-leaf delete/undo/redo/purge. GC2 lives inside
   * G3, so its removal signals the parent (G3) container, never the root
   * container the sets observe. */
  probe->g3  = add_group (probe, image, NULL, "ssl-node");
  FIXTURE (probe->g3 != NULL, "group G3 built");
  probe->gc2 = add_layer (probe, image, probe->g3, "ssl-leaf");
  FIXTURE (probe->gc2 != NULL, "nested leaf GC2 built");
  gimp_image_flush (image);
  arm_oracle (probe, &probe->wr_g3, &probe->addr_g3, probe->g3);
  arm_oracle (probe, &probe->wr_gc2, &probe->addr_gc2, probe->gc2);
  {
    ExpectedMember exp_leaf[1] = {{probe->addr_gc2, &probe->wr_gc2}};

    FIXTURE (store_fixed_set (probe, image, "ssl-set-leaf",
                              g_list_prepend (NULL, probe->addr_gc2), "nested setup"),
             "set leaf stored");
    for (guint i = 0; i < n_order0; i++) g_free ((gpointer) order0[i]);
    n_order0 = snapshot_order (image, order0, MAX_SETS); /* grew by one */
    CHECK (n_order0 == 7, "[nested setup] 7 stored sets (got %u)", n_order0);
    expect_set (probe, image, "ssl-set-leaf", exp_leaf, 1, "nested baseline");

    snprintf (path, sizeof path, "%s/clean-gc2.xcf", probe->work);
    status = api->image_save (engine, probe->image_id, path, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "save clean gc2 baseline");
    if (error) { api->free_string (error); error = NULL; }
    CHECK (!gimp_image_is_dirty (image), "savepoint starts clean");
    s0 = capture_state (image);
    gimp_image_remove_layer (image, probe->gc2, TRUE, NULL);
    s1 = capture_state (image);
    check_stack_delta (probe, s0, s1, 1, -s0.redo, "remove GC2", "nested leaf remove");
    CHECK (oracle_alive (&probe->wr_gc2), "[remove GC2] undo keeps the leaf alive");
    expect_set (probe, image, "ssl-set-leaf", exp_leaf, 1, "remove GC2");
    expect_order (probe, image, order0, n_order0, "remove GC2");

    s0 = capture_state (image);
    CHECK (gimp_image_undo (image), "[nested undo] ran");
  CHECK (!gimp_image_is_dirty (image), "one Undo returns to the clean savepoint");
    s1 = capture_state (image);
    check_stack_delta (probe, s0, s1, -1, 1, "nested undo", "gimp_image_undo()");
    {
      gpointer pgc2 = g_weak_ref_get (&probe->wr_gc2);

      CHECK (pgc2 == probe->addr_gc2,
             "[nested undo] leaf restored with the same live identity");
      if (pgc2 != NULL)
        g_object_unref (pgc2);
    }
    expect_set (probe, image, "ssl-set-leaf", exp_leaf, 1, "nested undo");

    s0 = capture_state (image);
    CHECK (gimp_image_redo (image), "[nested redo] ran");
    s1 = capture_state (image);
    check_stack_delta (probe, s0, s1, 1, -1, "nested redo", "gimp_image_redo()");
    expect_set (probe, image, "ssl-set-leaf", exp_leaf, 1, "nested redo");

    gimp_image_undo_free (image);
    s1 = capture_state (image);
    CHECK (s1.undo == 0 && s1.redo == 0, "[nested purge] stacks emptied");
    CHECK (! oracle_alive (&probe->wr_gc2) && oracle_alive (&probe->wr_g3),
           "[nested purge] removed leaf finalized and attached group stays alive");
    expect_set (probe, image, "ssl-set-leaf", exp_leaf, 1, "nested purge");
    expect_order (probe, image, order0, n_order0, "nested purge");
  }

  /* Phase 6: reparent the attached root child C into G3, then undo. C stays
   * attached (inside G3) during the reparent, so its set must keep exposing
   * it; no other set may gain C. */
  snprintf (path, sizeof path, "%s/clean-reparent.xcf", probe->work);
  status = api->image_save (engine, probe->image_id, path, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "save clean reparent baseline");
  if (error) { api->free_string (error); error = NULL; }
  CHECK (!gimp_image_is_dirty (image), "reparent savepoint starts clean");
  s0 = capture_state (image);
  CHECK (gimp_image_reorder_item (image, GIMP_ITEM (probe->c), GIMP_ITEM (probe->g3),
                                  0, TRUE, "reparent-test"),
         "[reparent] gimp_image_reorder_item(C -> G3) ran");
  s1 = capture_state (image);
  check_stack_delta (probe, s0, s1, 1, -s0.redo, "reparent", "reorder C into G3");
  {
    GList *l = live_layers (image);

    CHECK (g_list_find (l, probe->addr_c) != NULL,
           "[reparent] C is attached (nested in G3) after reparent");
    g_list_free (l);
  }
  expect_set (probe, image, "ssl-set-c", exp_c, 1, "reparent");
  {
    ExpectedMember exp_leaf[1] = {{probe->addr_gc2, &probe->wr_gc2}};
    expect_set (probe, image, "ssl-set-leaf", exp_leaf, 1, "reparent");
  }
  expect_order (probe, image, order0, n_order0, "reparent");

  s0 = capture_state (image);
  CHECK (gimp_image_undo (image), "[reparent undo] ran");
  CHECK (!gimp_image_is_dirty (image), "one Undo returns to the clean savepoint");
  s1 = capture_state (image);
  check_stack_delta (probe, s0, s1, -1, 1, "reparent undo", "gimp_image_undo()");
  expect_set (probe, image, "ssl-set-c", exp_c, 1, "reparent undo");
  {
    ExpectedMember exp_leaf[1] = {{probe->addr_gc2, &probe->wr_gc2}};
    expect_set (probe, image, "ssl-set-leaf", exp_leaf, 1, "reparent undo");
  }
  expect_order (probe, image, order0, n_order0, "reparent undo");

  /* Teardown A: close image 1 with all sets still stored (no unlink) — must
   * not crash. */
  status = api->image_close (engine, probe->image_id);
  CHECK (status == GLIMS_STATUS_OK, "[teardown] image 1 closed with sets still stored");
  probe->image = NULL;
  g_weak_ref_clear (&probe->wr_g);
  g_weak_ref_clear (&probe->wr_c);
  g_weak_ref_clear (&probe->wr_g2);
  g_weak_ref_clear (&probe->wr_gc);
  g_weak_ref_clear (&probe->wr_g3);
  g_weak_ref_clear (&probe->wr_gc2);

  for (guint i = 0; i < n_order0; i++) g_free ((gpointer) order0[i]);

  /* ---------- image 2: XCF save/reopen round trip ---------- */

  status = api->image_new (engine, 64, 64, &id2, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "roundtrip image_new: %s", error ? error : "?");
  if (error != NULL)
    {
      api->free_string (error);
      error = NULL;
    }
  open = glims_lookup_image (engine, id2);
  FIXTURE (open != NULL, "roundtrip image adopted");
  {
    GimpImage *rt = open->image;
    GimpLayer *a  = add_layer (probe, rt, NULL, "rt-a");
    GimpLayer *b  = add_layer (probe, rt, NULL, "rt-b");
    GimpLayer *g  = add_group (probe, rt, NULL, "rt-g");
    GimpLayer *gc = (g != NULL) ? add_layer (probe, rt, g, "rt-gc") : NULL;
    GList *ab, *gcl;

    FIXTURE (a != NULL && b != NULL && g != NULL && gc != NULL, "roundtrip tree built");
    gimp_image_flush (rt);
    ab  = g_list_prepend (g_list_prepend (NULL, b), a);
    gcl = g_list_prepend (NULL, gc);
    FIXTURE (store_fixed_set (probe, rt, "rt-set-ab", ab, "roundtrip setup"), "rt-set-ab stored");
    FIXTURE (store_fixed_set (probe, rt, "rt-set-gc", gcl, "roundtrip setup"), "rt-set-gc stored");
    FIXTURE (store_empty_set (probe, rt, "rt-set-empty", "roundtrip setup"), "rt-set-empty stored");
    FIXTURE (store_pattern_set (probe, rt, "rt-*", GIMP_SELECT_GLOB_PATTERN, "roundtrip setup"),
             "rt-* pattern stored");

    snprintf (path, sizeof path, "%s/rt1.xcf", probe->work);
    status = api->image_save (engine, id2, path, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "save rt1.xcf: %s", error ? error : "?");
    if (error != NULL)
      {
        api->free_string (error);
        error = NULL;
      }
  }
  status = api->image_close (engine, id2);
  CHECK (status == GLIMS_STATUS_OK, "[roundtrip] original closed after save");

  snprintf (path, sizeof path, "%s/rt1.xcf", probe->work);
  status = api->image_open (engine, path, &id3, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "reopen rt1.xcf: %s", error ? error : "?");
  if (error != NULL)
    {
      api->free_string (error);
      error = NULL;
    }
  open = glims_lookup_image (engine, id3);
  FIXTURE (open != NULL, "reopened image adopted");
  image3 = open->image;

  {
    const char *exp_ab[2]  = { "rt-a", "rt-b" };
    const char *exp_gc[1]  = { "rt-gc" };
    const char *exp_none[1] = { NULL };

    live = live_layers (image3);
    CHECK (g_list_length (live) == 5, "[reopen rt1] 5 live layers after reopen (got %u)",
           g_list_length (live));
    g_list_free (live);

    expect_set_by_names (probe, image3, "rt-set-ab", exp_ab, 2, "reopen rt1");
    expect_set_by_names (probe, image3, "rt-set-gc", exp_gc, 1, "reopen rt1");
    expect_set_by_names (probe, image3, "rt-set-empty", exp_none, 0, "reopen rt1");
    expect_pattern_set (probe, image3, "rt-*", GIMP_SELECT_GLOB_PATTERN, "reopen rt1");
    CHECK (find_set (image3, "rt-set-ab", GIMP_TYPE_CHANNEL) == NULL,
           "[reopen rt1] item type preserved (layer, not channel)");
  }

  /* Save while rt-g is detached: XCF writes only currently attached members
   * (xcf-save.c PROP_ITEM_SET_ITEM matches live layers by pointer), so the
   * reopened rt-set-gc must exist but be empty. */
  {
    GimpLayer *g = NULL;
    GList *l = live_layers (image3);
    GList *iter;

    for (iter = l; iter; iter = iter->next)
      if (g_strcmp0 (gimp_object_get_name (iter->data), "rt-g") == 0)
        g = iter->data;
    g_list_free (l);
    FIXTURE (g != NULL, "rt-g found in reopened image");
    gimp_image_remove_layer (image3, g, TRUE, NULL);

    snprintf (path, sizeof path, "%s/rt2.xcf", probe->work);
    status = api->image_save (engine, id3, path, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "save rt2.xcf: %s", error ? error : "?");
    if (error != NULL)
      {
        api->free_string (error);
        error = NULL;
      }
  }
  status = api->image_close (engine, id3);
  CHECK (status == GLIMS_STATUS_OK, "[roundtrip] rt1 image closed");

  snprintf (path, sizeof path, "%s/rt2.xcf", probe->work);
  status = api->image_open (engine, path, &id4, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "reopen rt2.xcf: %s", error ? error : "?");
  if (error != NULL)
    {
      api->free_string (error);
      error = NULL;
    }
  open = glims_lookup_image (engine, id4);
  FIXTURE (open != NULL, "rt2 image adopted");
  image4 = open->image;

  {
    const char *exp_ab[2]   = { "rt-a", "rt-b" };
    const char *exp_gc[1]   = { "rt-gc" };
    const char *exp_none[1] = { NULL };

    live = live_layers (image4);
    CHECK (g_list_length (live) == 3, "[reopen rt2] 3 live layers (rt-g subtree detached at save)");
    g_list_free (live);

    expect_set_by_names (probe, image4, "rt-set-ab", exp_ab, 2, "reopen rt2");
    expect_set_by_names (probe, image4, "rt-set-gc", exp_none, 0, "reopen rt2");
    expect_set_by_names (probe, image4, "rt-set-empty", exp_none, 0, "reopen rt2");
    (void) exp_gc;
  }

  /* ---------- no-op and explicit unlink teardown on image 4 ---------- */

  {
    /* Explicit no-op: unlinking a set that was never stored must fail
     * cleanly and change nothing. The ghost set is built from a LIVE layer
     * of image 4 (image 1 is closed; its old addresses must not be used). */
    EngineState before = capture_state (image4);
    GList *l = live_layers (image4);
    GList *ghost_items = g_list_prepend (NULL, l != NULL ? l->data : NULL);
    GimpItemList *ghost;
    gboolean unlinked;

    g_list_free (l);
    FIXTURE (ghost_items != NULL && ghost_items->data != NULL, "ghost member is a live layer");
    ghost = gimp_item_list_named_new (image4, GIMP_TYPE_LAYER, "rt-set-ghost", ghost_items);
    g_list_free (ghost_items); /* named_new copies the container */
    FIXTURE (ghost != NULL, "ghost set constructed for no-op");
    unlinked = gimp_image_unlink_item_set (image4, ghost);
    CHECK (unlinked == FALSE, "[noop] unlink of never-stored set returns FALSE");
    g_object_unref (ghost);
    check_bookkeeping_quiet (probe, before, capture_state (image4), "noop", "unlink ghost");
  }

  {
    /* Replace same-name set with an identical definition: bookkeeping only,
     * no undo/dirty, replaced set moves to the front of the stored list. */
    EngineState before = capture_state (image4);
    GList *l = live_layers (image4);
    GList *items = NULL, *iter;
    GimpItemList *set;
    const char *order_after[MAX_SETS];
    guint n_after;

    for (iter = l; iter; iter = iter->next)
      {
        const char *n = gimp_object_get_name (iter->data);

        if (g_strcmp0 (n, "rt-a") == 0 || g_strcmp0 (n, "rt-b") == 0)
          items = g_list_prepend (items, iter->data);
      }
    g_list_free (l);
    set = gimp_item_list_named_new (image4, GIMP_TYPE_LAYER, "rt-set-ab", items);
    g_list_free (items);
    FIXTURE (set != NULL, "replacement set constructed");
    gimp_image_store_item_set (image4, set); /* replaces, transfer full */
    check_bookkeeping_quiet (probe, before, capture_state (image4), "replace", "store same-name set");

    n_after = snapshot_order (image4, order_after, MAX_SETS);
    CHECK (n_after >= 1 && g_strcmp0 (order_after[0], "rt-set-ab") == 0,
           "[replace] replaced set moved to the front of the stored list");
    for (guint i = 0; i < n_after; i++) g_free ((gpointer) order_after[i]);
    {
      const char *exp_ab[2] = { "rt-a", "rt-b" };
      expect_set_by_names (probe, image4, "rt-set-ab", exp_ab, 2, "replace");
    }
  }

  {
    /* Explicit unlink of every stored set: quiet bookkeeping, then the
     * stored list is empty. */
    const char *names[MAX_SETS] = {
      "rt-set-ab", "rt-set-gc", "rt-set-empty", "rt-*"
    };
    guint i;

    for (i = 0; i < 4; i++)
      {
        EngineState before = capture_state (image4);
        GimpItemList *set = find_set (image4, names[i], GIMP_TYPE_LAYER);

        CHECK (set != NULL, "[unlink] set \"%s\" present before unlink", names[i]);
        if (set != NULL)
          {
            CHECK (gimp_image_unlink_item_set (image4, set) == TRUE,
                   "[unlink] set \"%s\" unlinked", names[i]);
            check_bookkeeping_quiet (probe, before, capture_state (image4),
                                     "unlink", names[i]);
          }
      }
    CHECK (gimp_image_get_stored_item_sets (image4, GIMP_TYPE_LAYER) == NULL,
           "[unlink] stored layer-set list empty after unlinking all");
  }

  /* Teardown B: close after explicit unlinks — must not crash. */
  status = api->image_close (engine, id4);
  CHECK (status == GLIMS_STATUS_OK, "[teardown] image 4 closed after explicit unlinks");

  return probe->failures > 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine *engine = NULL;
  Probe probe;
  char *error = NULL;
  char work[1024], home_dir[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus status;

  if (argc != 2)
    {
      fprintf (stderr, "usage: %s WORK_DIR\n", argv[0]);
      return 2;
    }

  /* Throwaway directories only; the real HOME / XDG_CACHE_HOME / GIMP
   * settings must never be touched. */
  snprintf (work, sizeof work, "%s", argv[1]);
  snprintf (home_dir, sizeof home_dir, "%s/home", work);
  snprintf (user_dir, sizeof user_dir, "%s/user", work);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", work);
  if ((mkdir (work, 0755) < 0 && errno != EEXIST) ||
      (mkdir (home_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (user_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (cache_dir, 0755) < 0 && errno != EEXIST))
    {
      fprintf (stderr, "cannot create work dirs under %s: %s\n", work, strerror (errno));
      return 1;
    }

  memset (&probe, 0, sizeof probe);
  probe.work = work;
  memset (&config, 0, sizeof config);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = NULL;

  /* Static link against the adapter objects: glims_engine_get_api is called
   * directly, no dlopen and no export-only restriction. */
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (api == NULL || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    {
      fprintf (stderr, "glims_engine_get_api(%u) did not serve the facade\n",
               (unsigned) GLIMS_ENGINE_API_VERSION);
      return 1;
    }

  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n", error != NULL ? error : "unknown error");
      if (error != NULL)
        api->free_string (error);
      return 1;
    }
  if (error != NULL)
    {
      api->free_string (error);
      error = NULL;
    }

  printf ("saved-set-lifetime-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  /* The whole fixture/test body runs on the engine thread via one private
   * call (facade calls inside it re-enter glims_engine_call directly). */
  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n", probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return (status == GLIMS_STATUS_OK && probe.failures == 0) ? 0 : 1;
}
