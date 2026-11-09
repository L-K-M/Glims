/*
 * saved-set-undo-tests.c — deterministic standalone harness for the
 * adapter-owned native undo steps of explicit saved-set edits
 * (CREATE/REPLACE/RENAME/REMOVE, Engine/item-sets-undo.c).
 *
 *   saved-set-undo-tests WORK_DIR
 *
 * Test-only file. Like saved-set-lifetime-tests.c it links the adapter
 * objects and GIMP's gimp-console objects directly (no dlopen, no libgimp),
 * includes Engine/engine-private.h, and runs the whole fixture/test body on
 * the engine thread through one glims_engine_call(). It modifies no
 * production file.
 *
 * Asserted semantics:
 *   - Each mutating command is exactly ONE undo step (a plain GimpUndo, not
 *     a group), nukes the redo stack, and marks the image dirty; one Undo
 *     restores the previous stored-set list (definitions, order, member
 *     identity) and returns to the clean savepoint; Redo reapplies.
 *   - No-op calls (identical REPLACE, same-name RENAME) return OK with zero
 *     undo/redo/dirty delta and no mutation.
 *   - Refused calls (duplicate CREATE, missing REPLACE/RENAME/REMOVE target,
 *     invalid members, frozen undo stack) return an error status with zero
 *     undo/redo/dirty delta and leave the stored sets untouched.
 *   - Pattern definitions and the stored-set list order survive every
 *     command and every Undo/Redo.
 *   - Member identity across Undo/Redo is the same live object (independent
 *     GWeakRef oracles); a member detached by a layer deletion stays weakly
 *     known and is re-exposed when its deletion is undone; after
 *     gimp_image_undo_free() a detached member is finalized and no set
 *     exposes it (the manager rebuilds on the undo events).
 *
 * Safety rules (same as saved-set-lifetime-tests.c): stored sets are
 * reacquired by name AND type after every operation and never retained;
 * get_items() members are gated pointer-value-wise against a fresh live
 * tree before any dereference; expected identity uses independent weak
 * oracles; no private struct layout is mirrored.
 */
#include "engine-private.h"

#include <errno.h>
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

#include "config/gimpcoreconfig.h"

int main (int argc, char **argv);

#define MAX_SETS 16

typedef struct
{
  GimpImage   *image;
  GlimsImageID image_id;
  const char  *work;

  GimpLayer *c;    /* root child C            */
  GimpLayer *g;    /* root group G            */
  GimpLayer *g2;   /* subgroup G2 inside G    */
  GimpLayer *gc;   /* grandchild GC inside G2 */

  gpointer addr_c, addr_g, addr_g2, addr_gc;
  GWeakRef wr_c, wr_g, wr_g2, wr_gc;

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

static gboolean
oracle_alive (GWeakRef *wr)
{
  gpointer obj = g_weak_ref_get (wr);

  if (obj != NULL)
    g_object_unref (obj);

  return obj != NULL;
}

static gpointer
oracle_addr (GWeakRef *wr)
{
  gpointer obj = g_weak_ref_get (wr);

  if (obj != NULL)
    g_object_unref (obj);

  return obj;
}

typedef struct { gpointer address; GWeakRef *oracle; } ExpectedMember;

static GimpItemList *
find_set (GimpImage *image, const char *name, GType item_type)
{
  for (GList *iter = gimp_image_get_stored_item_sets (image, item_type); iter; iter = iter->next)
    if (g_strcmp0 (gimp_object_get_name (iter->data), name) == 0)
      return iter->data;
  return NULL;
}

static GList *
live_layers (GimpImage *image)
{
  return gimp_image_get_layer_list (image);
}

typedef struct
{
  gint undo;
  gint redo;
  gint dirty;
} EngineState;

static EngineState
capture_state (GimpImage *image)
{
  EngineState state;

  state.undo  = gimp_undo_stack_get_depth (gimp_image_get_undo_stack (image));
  state.redo  = gimp_undo_stack_get_depth (gimp_image_get_redo_stack (image));
  state.dirty = gimp_image_is_dirty (image);

  return state;
}

static void
check_delta (Probe *probe, EngineState before, EngineState after,
             gint d_undo, gint d_redo, const char *phase, const char *op)
{
  CHECK (after.undo - before.undo == d_undo && after.redo - before.redo == d_redo,
         "[%s] %s: undo %d->%d, redo %d->%d (expected delta %d/%d)",
         phase, op, before.undo, after.undo, before.redo, after.redo, d_undo, d_redo);
}

static void
check_quiet (Probe *probe, EngineState before, EngineState after,
             const char *phase, const char *op)
{
  CHECK (after.undo == before.undo && after.redo == before.redo && after.dirty == before.dirty,
         "[%s] %s: no undo/redo/dirty change (undo %d->%d, redo %d->%d, dirty %d->%d)",
         phase, op, before.undo, after.undo, before.redo, after.redo, before.dirty, after.dirty);
}

/* The pushed step is a plain undo, never a group. */
static void
check_not_group (Probe *probe, GimpImage *image, const char *phase)
{
  GimpUndo *top = gimp_undo_stack_peek (gimp_image_get_undo_stack (image));

  CHECK (top != NULL && ! GIMP_IS_UNDO_STACK (top),
         "[%s] top of undo stack is a plain undo, not a group", phase);
}

static guint
snapshot_order (GimpImage *image, const char **names, guint max)
{
  guint n = 0;

  for (GList *iter = gimp_image_get_stored_item_sets (image, GIMP_TYPE_LAYER);
       iter && n < max; iter = iter->next)
    names[n++] = g_strdup (gimp_object_get_name (iter->data));

  return n;
}

static void
expect_order (Probe *probe, GimpImage *image,
              const char **names, guint n, const char *phase)
{
  const char *now[MAX_SETS];
  guint n_now = snapshot_order (image, now, MAX_SETS);
  gboolean ok = (n_now == n);

  for (guint i = 0; ok && i < n; i++)
    ok = g_strcmp0 (now[i], names[i]) == 0;

  CHECK (ok, "[%s] stored-set order preserved (%u sets)", phase, n);
  if (! ok)
    {
      printf ("      expected:");
      for (guint i = 0; i < n; i++)
        printf (" %s", names[i]);
      printf ("\n      actual:  ");
      for (guint i = 0; i < n_now; i++)
        printf (" %s", now[i]);
      printf ("\n");
      fflush (stdout);
    }
  for (guint i = 0; i < n_now; i++)
    g_free ((gpointer) now[i]);
}

static void
free_order (const char **names, guint n)
{
  for (guint i = 0; i < n; i++)
    g_free ((gpointer) names[i]);
}

/* Exact live membership, same gating rules as the lifetime harness. */
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
  if (set)
    actual = gimp_item_list_get_items (set, &error);
  ok = ok && ! error && g_list_length (actual) == g_list_length (wanted);
  for (GList *item = actual; ok && item; item = item->next)
    {
      GList *match = g_list_find (wanted, item->data);
      if (! g_list_find (live, item->data) || ! match)
        ok = FALSE;
      else
        wanted = g_list_delete_link (wanted, match);
    }
  CHECK (ok && ! wanted, "[%s] set \"%s\" has exact live membership (%u expected)",
         phase, name, n_expected);
  g_clear_error (&error);
  g_list_free (wanted);
  g_list_free (actual);
  g_list_free (live);
}

static void
expect_absent (Probe *probe, GimpImage *image, const char *name, const char *phase)
{
  CHECK (find_set (image, name, GIMP_TYPE_LAYER) == NULL,
         "[%s] set \"%s\" is absent", phase, name);
}

static void
expect_pattern (Probe *probe, GimpImage *image, const char *pattern,
                GimpSelectMethod method, const char *phase)
{
  GimpItemList *set = find_set (image, pattern, GIMP_TYPE_LAYER);
  GimpSelectMethod actual = 0;

  CHECK (set != NULL && gimp_item_list_is_pattern (set, &actual) && actual == method,
         "[%s] pattern set \"%s\" preserved (method %d)", phase, pattern, (int) method);
}

static GimpLayer *
add_layer (Probe *probe, GimpImage *image, GimpLayer *parent, const char *name)
{
  GimpLayer *layer;
  (void) probe;

  layer = gimp_layer_new (image, 64, 64,
                                     gimp_image_get_layer_format (image, TRUE),
                                     name, GIMP_OPACITY_OPAQUE,
                                     GIMP_LAYER_MODE_NORMAL);

  if (layer == NULL)
    return NULL;
  if (! gimp_image_add_layer (image, layer, parent, -1, TRUE))
    {
      g_object_unref (layer);
      return NULL;
    }
  return layer;
}

static GimpLayer *
add_group (Probe *probe, GimpImage *image, GimpLayer *parent, const char *name)
{
  GimpLayer *group;
  (void) probe;

  group = gimp_group_layer_new (image);

  if (group == NULL)
    return NULL;
  gimp_object_set_name (GIMP_OBJECT (group), name);
  if (! gimp_image_add_layer (image, group, parent, -1, TRUE))
    {
      g_object_unref (group);
      return NULL;
    }
  return group;
}

static void
arm_oracle (Probe *probe, GWeakRef *wr, gpointer *addr_slot, GimpLayer *layer)
{
  (void) probe;
  *addr_slot = (gpointer) layer;
  g_weak_ref_init (wr, layer);
}

/* Independent regressions for hidden definitions and native stack expiry. */
static GlimsStatus
root_regressions (GlimsEngine *engine, Probe *probe)
{
  GlimsImageID id = 0;
  char *error = NULL;
  GlimsStatus result = api->image_new (engine, 64, 64, &id, &error);
  FIXTURE (result == GLIMS_STATUS_OK, "[root setup] image created");
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GimpLayer *member = add_layer (probe, image, NULL, "detached-original");
  FIXTURE (member != NULL, "[root setup] member attached");
  GWeakRef weak;
  g_weak_ref_init (&weak, member);
  ExpectedMember expected = { member, &weak };
  GimpItem *items[] = { GIMP_ITEM (member) };
  result = glims_item_sets_create (image, GIMP_TYPE_LAYER, "S", items, 1, &error);
  FIXTURE (result == GLIMS_STATUS_OK, "[root setup] definition created");
  gimp_image_remove_layer (image, member, TRUE, NULL);
  CHECK (oracle_alive (&weak), "[root detached] deletion Undo owns original member");
  expect_set (probe, image, "S", &expected, 1, "root detached hidden");
  result = glims_item_sets_rename (image, GIMP_TYPE_LAYER, "S", "R", &error);
  CHECK (result == GLIMS_STATUS_OK, "[root rename] rename with a detached member succeeds");
  CHECK (gimp_image_undo (image), "[root rename] Undo rename");
  expect_set (probe, image, "S", &expected, 1, "root rename undone, still detached");
  CHECK (gimp_image_undo (image), "[root rename] Undo original member deletion");
  CHECK (oracle_addr (&weak) == expected.address, "[root rename] original object identity restored");
  expect_set (probe, image, "S", &expected, 1, "root definition after Undo rename/delete");

  CHECK (gimp_image_redo (image), "[root replace] detach original member again");
  EngineState before = capture_state (image);
  result = glims_item_sets_replace (image, GIMP_TYPE_LAYER, "S", NULL, 0, &error);
  EngineState after = capture_state (image);
  CHECK (result == GLIMS_STATUS_OK && after.undo == before.undo + 1 && after.redo == 0,
         "[root replace] explicit empty definition changes a hidden nonempty definition");
  if (after.undo == before.undo + 1)
    {
      CHECK (gimp_image_undo (image), "[root replace] Undo empty definition");
      CHECK (gimp_image_undo (image), "[root replace] Undo member deletion");
      expect_set (probe, image, "S", &expected, 1, "root full definition after empty replace");
    }
  if (error) { api->free_string (error); error = NULL; }
  CHECK (api->image_close (engine, id) == GLIMS_STATUS_OK, "[root detached] fixture closes");
  g_weak_ref_clear (&weak);

  /* Both public config limits accept zero. Native free_space expires the
   * new top inside gimp_image_undo_push, after it has dirtied the image. */
  result = api->image_new (engine, 16, 16, &id, &error);
  FIXTURE (result == GLIMS_STATUS_OK, "[root expiry setup] image created");
  image = glims_lookup_image (engine, id)->image;
  char path[1024];
  snprintf (path, sizeof path, "%s/root-expiry-clean.xcf", probe->work);
  result = api->image_save (engine, id, path, &error);
  FIXTURE (result == GLIMS_STATUS_OK, "[root expiry setup] clean savepoint");
  result = glims_item_sets_create (image, GIMP_TYPE_LAYER, "redo-seed", NULL, 0, &error);
  FIXTURE (result == GLIMS_STATUS_OK && gimp_image_undo (image), "[root expiry setup] redo exists");
  gint previous_levels = 0;
  guint64 previous_size = 0;
  g_object_get (engine->gimp->config, "undo-levels", &previous_levels,
                "undo-size", &previous_size, NULL);
  g_object_set (engine->gimp->config, "undo-levels", 0,
                "undo-size", (guint64) 0, NULL);
  before = capture_state (image);
  CHECK (before.redo > 0 && !gimp_image_is_dirty (image),
         "[root expiry setup] zero limits preserve clean baseline and redo until push");
  result = glims_item_sets_create (image, GIMP_TYPE_LAYER, "expired-edit", NULL, 0, &error);
  after = capture_state (image);
  g_object_set (engine->gimp->config, "undo-levels", previous_levels,
                "undo-size", previous_size, NULL);
  CHECK (result == GLIMS_STATUS_OK && error == NULL,
         "[root expiry] applied edit succeeds even when its native Undo expires");
  CHECK (find_set (image, "expired-edit", GIMP_TYPE_LAYER) != NULL,
         "[root expiry] requested definition remains applied");
  CHECK (gimp_image_is_dirty (image), "[root expiry] applied edit stays dirty");
  CHECK (after.undo == 0 && after.redo == 0,
         "[root expiry] new Undo really expired and native push cleared redo");
  if (error) { api->free_string (error); error = NULL; }
  CHECK (api->image_close (engine, id) == GLIMS_STATUS_OK, "[root expiry] fixture closes");
  return GLIMS_STATUS_OK;
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  GlimsOpenImage *open;
  GimpImage *image;
  char *error = NULL;
  GlimsStatus status;
  EngineState s0, s1;
  char path[1024];
  const char *order0[MAX_SETS];
  guint n_order0;
  ExpectedMember exp_gc[1], exp_g_gc[2], exp_c[1], exp_gc2[2];
  GimpItem *members_g_gc[2], *members_c[1], *members_g[1], *members_gc[1];

  status = api->image_new (engine, 64, 64, &probe->image_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "image_new: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }

  open = glims_lookup_image (engine, probe->image_id);
  FIXTURE (open != NULL, "image adopted");
  image = probe->image = open->image;

  probe->c  = add_layer (probe, image, NULL, "u-child");
  probe->g  = add_group (probe, image, NULL, "u-group");
  probe->g2 = add_group (probe, image, probe->g, "u-inner");
  probe->gc = add_layer (probe, image, probe->g2, "u-grandchild");
  FIXTURE (probe->c && probe->g && probe->g2 && probe->gc, "fixture tree built");
  gimp_image_flush (image);

  arm_oracle (probe, &probe->wr_c,  &probe->addr_c,  probe->c);
  arm_oracle (probe, &probe->wr_g,  &probe->addr_g,  probe->g);
  arm_oracle (probe, &probe->wr_g2, &probe->addr_g2, probe->g2);
  arm_oracle (probe, &probe->wr_gc, &probe->addr_gc, probe->gc);

  exp_gc[0]   = (ExpectedMember) {probe->addr_gc, &probe->wr_gc};
  exp_g_gc[0] = (ExpectedMember) {probe->addr_g,  &probe->wr_g};
  exp_g_gc[1] = (ExpectedMember) {probe->addr_gc, &probe->wr_gc};
  exp_c[0]    = (ExpectedMember) {probe->addr_c,  &probe->wr_c};
  exp_gc2[0]  = (ExpectedMember) {probe->addr_g,  &probe->wr_g};
  exp_gc2[1]  = (ExpectedMember) {probe->addr_gc, &probe->wr_gc};

  members_g_gc[0] = GIMP_ITEM (probe->g);
  members_g_gc[1] = GIMP_ITEM (probe->gc);
  members_c[0]    = GIMP_ITEM (probe->c);
  members_g[0]    = GIMP_ITEM (probe->g);
  members_gc[0]   = GIMP_ITEM (probe->gc);

  /* Clean savepoint for the dirty assertions. */
  snprintf (path, sizeof path, "%s/undo-clean.xcf", probe->work);
  status = api->image_save (engine, probe->image_id, path, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "save clean baseline: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  CHECK (! gimp_image_is_dirty (image), "[setup] savepoint starts clean");

  /* ---------- Phase A: CREATE / Undo / Redo ---------- */

  s0 = capture_state (image);
  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-sel", members_g_gc, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[create] CREATE u-sel {G,GC}: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  s1 = capture_state (image);
  check_delta (probe, s0, s1, 1, -s0.redo, "create", "glims_item_sets_create");
  check_not_group (probe, image, "create");
  CHECK (gimp_image_is_dirty (image), "[create] image dirty after the command");
  expect_set (probe, image, "u-sel", exp_g_gc, 2, "create");
  n_order0 = snapshot_order (image, order0, MAX_SETS);
  CHECK (n_order0 == 1 && g_strcmp0 (order0[0], "u-sel") == 0, "[create] u-sel is the only stored set");

  s0 = capture_state (image);
  CHECK (gimp_image_undo (image), "[create undo] ran");
  s1 = capture_state (image);
  check_delta (probe, s0, s1, -1, 1, "create undo", "gimp_image_undo()");
  CHECK (! gimp_image_is_dirty (image), "[create undo] back to the clean savepoint");
  expect_absent (probe, image, "u-sel", "create undo");

  s0 = capture_state (image);
  CHECK (gimp_image_redo (image), "[create redo] ran");
  s1 = capture_state (image);
  check_delta (probe, s0, s1, 1, -1, "create redo", "gimp_image_redo()");
  CHECK (gimp_image_is_dirty (image), "[create redo] dirty again");
  expect_set (probe, image, "u-sel", exp_g_gc, 2, "create redo");
  {
    gpointer pg = oracle_addr (&probe->wr_g);
    gpointer pgc = oracle_addr (&probe->wr_gc);
    CHECK (pg == probe->addr_g && pgc == probe->addr_gc,
           "[create redo] members restored with the same live identity");
  }
  expect_order (probe, image, order0, n_order0, "create redo");

  /* ---------- Phase B: REPLACE (+ no-op) ---------- */

  s0 = capture_state (image);
  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-rep", members_c, 1, &error);
  CHECK (status == GLIMS_STATUS_OK, "[replace setup] CREATE u-rep {C}");
  if (error) { api->free_string (error); error = NULL; }
  s1 = capture_state (image);
  check_delta (probe, s0, s1, 1, -s0.redo, "replace setup", "create u-rep");

  s0 = capture_state (image);
  status = glims_item_sets_replace (image, GIMP_TYPE_LAYER, "u-rep", members_g_gc, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[replace] REPLACE u-rep {G,GC}: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  s1 = capture_state (image);
  check_delta (probe, s0, s1, 1, -s0.redo, "replace", "glims_item_sets_replace");
  expect_set (probe, image, "u-rep", exp_g_gc, 2, "replace");

  s0 = capture_state (image);
  status = glims_item_sets_replace (image, GIMP_TYPE_LAYER, "u-rep", members_g_gc, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[replace noop] identical REPLACE returns OK");
  if (error) { api->free_string (error); error = NULL; }
  check_quiet (probe, s0, capture_state (image), "replace noop", "identical replace");

  s0 = capture_state (image);
  CHECK (gimp_image_undo (image), "[replace undo] ran");
  s1 = capture_state (image);
  check_delta (probe, s0, s1, -1, 1, "replace undo", "gimp_image_undo()");
  expect_set (probe, image, "u-rep", exp_c, 1, "replace undo");

  s0 = capture_state (image);
  CHECK (gimp_image_redo (image), "[replace redo] ran");
  expect_set (probe, image, "u-rep", exp_g_gc, 2, "replace redo");
  check_delta (probe, s0, capture_state (image), 1, -1, "replace redo", "gimp_image_redo()");

  /* ---------- Phase C: RENAME (+ no-op + conflict) ---------- */

  {
    const char *order_before[MAX_SETS];
    guint n_before = snapshot_order (image, order_before, MAX_SETS);

    s0 = capture_state (image);
    status = glims_item_sets_rename (image, GIMP_TYPE_LAYER, "u-rep", "u-renamed", &error);
    CHECK (status == GLIMS_STATUS_OK, "[rename] RENAME u-rep -> u-renamed: %s", error ? error : "ok");
    if (error) { api->free_string (error); error = NULL; }
    s1 = capture_state (image);
    check_delta (probe, s0, s1, 1, -s0.redo, "rename", "glims_item_sets_rename");
    expect_absent (probe, image, "u-rep", "rename");
    expect_set (probe, image, "u-renamed", exp_g_gc, 2, "rename");
    {
      const char *order_now[MAX_SETS];
      guint n_now = snapshot_order (image, order_now, MAX_SETS);
      CHECK (n_now == n_before && g_strcmp0 (order_now[0], "u-renamed") == 0,
             "[rename] renamed set moved to the front, count kept");
      free_order (order_now, n_now);
    }

    s0 = capture_state (image);
    status = glims_item_sets_rename (image, GIMP_TYPE_LAYER, "u-renamed", "u-renamed", &error);
    CHECK (status == GLIMS_STATUS_OK, "[rename noop] same-name RENAME returns OK");
    if (error) { api->free_string (error); error = NULL; }
    check_quiet (probe, s0, capture_state (image), "rename noop", "same-name rename");

    s0 = capture_state (image);
    status = glims_item_sets_rename (image, GIMP_TYPE_LAYER, "u-renamed", "u-sel", &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[rename conflict] RENAME onto existing name refused (%d)", status);
    if (error) { api->free_string (error); error = NULL; }
    check_quiet (probe, s0, capture_state (image), "rename conflict", "rename onto u-sel");
    expect_set (probe, image, "u-renamed", exp_g_gc, 2, "rename conflict");
    expect_set (probe, image, "u-sel", exp_g_gc, 2, "rename conflict");

    s0 = capture_state (image);
    CHECK (gimp_image_undo (image), "[rename undo] ran");
    s1 = capture_state (image);
    check_delta (probe, s0, s1, -1, 1, "rename undo", "gimp_image_undo()");
    expect_set (probe, image, "u-rep", exp_g_gc, 2, "rename undo");
    expect_absent (probe, image, "u-renamed", "rename undo");
    expect_order (probe, image, order_before, n_before, "rename undo"); /* original position */
    free_order (order_before, n_before);

    s0 = capture_state (image);
    CHECK (gimp_image_redo (image), "[rename redo] ran");
    expect_set (probe, image, "u-renamed", exp_g_gc, 2, "rename redo");
    expect_absent (probe, image, "u-rep", "rename redo");
    check_delta (probe, s0, capture_state (image), 1, -1, "rename redo", "gimp_image_redo()");
  }

  /* ---------- Phase D: REMOVE (+ missing target) ---------- */

  s0 = capture_state (image);
  status = glims_item_sets_remove (image, GIMP_TYPE_LAYER, "u-renamed", &error);
  CHECK (status == GLIMS_STATUS_OK, "[remove] REMOVE u-renamed: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  s1 = capture_state (image);
  check_delta (probe, s0, s1, 1, -s0.redo, "remove", "glims_item_sets_remove");
  expect_absent (probe, image, "u-renamed", "remove");

  s0 = capture_state (image);
  status = glims_item_sets_remove (image, GIMP_TYPE_LAYER, "u-ghost", &error);
  CHECK (status == GLIMS_STATUS_NOT_FOUND, "[remove missing] REMOVE of absent set is NOT_FOUND (%d)", status);
  if (error) { api->free_string (error); error = NULL; }
  check_quiet (probe, s0, capture_state (image), "remove missing", "remove u-ghost");

  s0 = capture_state (image);
  CHECK (gimp_image_undo (image), "[remove undo] ran");
  s1 = capture_state (image);
  check_delta (probe, s0, s1, -1, 1, "remove undo", "gimp_image_undo()");
  expect_set (probe, image, "u-renamed", exp_g_gc, 2, "remove undo");
  {
    gpointer pg = oracle_addr (&probe->wr_g);
    CHECK (pg == probe->addr_g, "[remove undo] member identity restored");
  }

  s0 = capture_state (image);
  CHECK (gimp_image_redo (image), "[remove redo] ran");
  expect_absent (probe, image, "u-renamed", "remove redo");
  check_delta (probe, s0, capture_state (image), 1, -1, "remove redo", "gimp_image_redo()");

  /* ---------- Phase E: duplicate CREATE, invalid members, frozen ---------- */

  s0 = capture_state (image);
  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-sel", members_c, 1, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[create dup] duplicate CREATE refused (%d)", status);
  if (error) { api->free_string (error); error = NULL; }
  check_quiet (probe, s0, capture_state (image), "create dup", "create u-sel again");
  expect_set (probe, image, "u-sel", exp_g_gc, 2, "create dup");

  s0 = capture_state (image);
  status = glims_item_sets_create (image, GIMP_TYPE_CHANNEL, "u-chan", members_g, 1, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[create kind] layer member in a channel set refused (%d)", status);
  if (error) { api->free_string (error); error = NULL; }
  check_quiet (probe, s0, capture_state (image), "create kind", "wrong-kind member");

  {
    GimpLayer *temp = gimp_layer_new (image, 8, 8, gimp_image_get_layer_format (image, TRUE),
                                      "u-temp", GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL);
    GimpItem *bad[1] = { GIMP_ITEM (temp) };
    s0 = capture_state (image);
    status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-bad", bad, 1, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[create detached] unattached member refused (%d)", status);
    if (error) { api->free_string (error); error = NULL; }
    check_quiet (probe, s0, capture_state (image), "create detached", "unattached member");
    g_object_unref (temp);
  }

  {
    GlimsImageID id2 = 0;
    GimpImage *image2;
    GimpLayer *foreign;
    GimpItem *bad[1];

    status = api->image_new (engine, 32, 32, &id2, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "second image for the foreign-member check");
    if (error) { api->free_string (error); error = NULL; }
    open = glims_lookup_image (engine, id2);
    FIXTURE (open != NULL, "second image adopted");
    image2 = open->image;
    foreign = add_layer (probe, image2, NULL, "u-foreign");
    FIXTURE (foreign != NULL, "foreign layer built");
    bad[0] = GIMP_ITEM (foreign);
    s0 = capture_state (image);
    status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-foreign-set", bad, 1, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[create foreign] member of another image refused (%d)", status);
    if (error) { api->free_string (error); error = NULL; }
    check_quiet (probe, s0, capture_state (image), "create foreign", "foreign member");
    status = api->image_close (engine, id2);
    CHECK (status == GLIMS_STATUS_OK, "[teardown] second image closed");
  }

  {
    s0 = capture_state (image);
    gimp_image_undo_freeze (image);
    status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-frozen", members_c, 1, &error);
    CHECK (status == GLIMS_STATUS_FAILED, "[frozen] CREATE while frozen refused (%d)", status);
    if (error) { api->free_string (error); error = NULL; }
    check_quiet (probe, s0, capture_state (image), "frozen", "frozen create");
    expect_absent (probe, image, "u-frozen", "frozen");
    status = glims_item_sets_remove (image, GIMP_TYPE_LAYER, "u-sel", &error);
    CHECK (status == GLIMS_STATUS_FAILED, "[frozen] REMOVE while frozen refused (%d)", status);
    if (error) { api->free_string (error); error = NULL; }
    check_quiet (probe, s0, capture_state (image), "frozen", "frozen remove");
    expect_set (probe, image, "u-sel", exp_g_gc, 2, "frozen");
    gimp_image_undo_thaw (image);

    s0 = capture_state (image);
    status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-frozen", members_c, 1, &error);
    CHECK (status == GLIMS_STATUS_OK, "[thawed] CREATE after thaw works");
    if (error) { api->free_string (error); error = NULL; }
    check_delta (probe, s0, capture_state (image), 1, -s0.redo, "thawed", "create after thaw");
    expect_set (probe, image, "u-frozen", exp_c, 1, "thawed");
    s0 = capture_state (image);
    CHECK (gimp_image_undo (image), "[thawed undo] ran");
    expect_absent (probe, image, "u-frozen", "thawed undo");
    check_delta (probe, s0, capture_state (image), -1, 1, "thawed undo", "gimp_image_undo()");
  }

  /* ---------- Phase F: pattern + order preservation across commands ---------- */

  {
    GimpItemList *pat = gimp_item_list_pattern_new (image, GIMP_TYPE_LAYER,
                                                    GIMP_SELECT_GLOB_PATTERN, "u-*");
    EngineState before = capture_state (image);
    gimp_image_store_item_set (image, pat); /* quiet bookkeeping */
    check_quiet (probe, before, capture_state (image), "pattern setup", "store pattern");
  }
  {
    const char *order_created[MAX_SETS];
    guint n_created;

    {
      GimpItemList *pat = gimp_item_list_pattern_new (image, GIMP_TYPE_LAYER,
                                                      GIMP_SELECT_GLOB_PATTERN, "u-*");
      EngineState before = capture_state (image);
      gimp_image_store_item_set (image, pat); /* quiet bookkeeping */
      check_quiet (probe, before, capture_state (image), "pattern setup", "store pattern");
    }

    s0 = capture_state (image);
    status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-pat-test", members_gc, 1, &error);
    CHECK (status == GLIMS_STATUS_OK, "[pattern] CREATE u-pat-test");
    if (error) { api->free_string (error); error = NULL; }
    check_delta (probe, s0, capture_state (image), 1, -s0.redo, "pattern", "create");
    expect_pattern (probe, image, "u-*", GIMP_SELECT_GLOB_PATTERN, "pattern");
    expect_set (probe, image, "u-pat-test", exp_gc, 1, "pattern");
    n_created = snapshot_order (image, order_created, MAX_SETS);

    s0 = capture_state (image);
    CHECK (gimp_image_undo (image), "[pattern undo] ran");
    expect_pattern (probe, image, "u-*", GIMP_SELECT_GLOB_PATTERN, "pattern undo");
    expect_absent (probe, image, "u-pat-test", "pattern undo");
    check_delta (probe, s0, capture_state (image), -1, 1, "pattern undo", "gimp_image_undo()");

    s0 = capture_state (image);
    CHECK (gimp_image_redo (image), "[pattern redo] ran");
    expect_pattern (probe, image, "u-*", GIMP_SELECT_GLOB_PATTERN, "pattern redo");
    expect_set (probe, image, "u-pat-test", exp_gc, 1, "pattern redo");
    expect_order (probe, image, order_created, n_created, "pattern redo");
    free_order (order_created, n_created);

    s0 = capture_state (image);
    CHECK (gimp_image_undo (image), "[pattern cleanup undo] ran");
    check_delta (probe, s0, capture_state (image), -1, 1, "pattern cleanup", "gimp_image_undo()");
  }

  /* ---------- Phase G: empty set, undo after layer deleted, purge ---------- */

  s0 = capture_state (image);
  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-empty", NULL, 0, &error);
  CHECK (status == GLIMS_STATUS_OK, "[empty] CREATE empty u-empty");
  if (error) { api->free_string (error); error = NULL; }
  check_delta (probe, s0, capture_state (image), 1, -s0.redo, "empty", "create empty");
  expect_set (probe, image, "u-empty", NULL, 0, "empty");
  s0 = capture_state (image);
  CHECK (gimp_image_undo (image), "[empty undo] ran");
  expect_absent (probe, image, "u-empty", "empty undo");
  check_delta (probe, s0, capture_state (image), -1, 1, "empty undo", "gimp_image_undo()");
  CHECK (gimp_image_redo (image), "[empty redo] ran");
  expect_set (probe, image, "u-empty", NULL, 0, "empty redo");
  CHECK (gimp_image_undo (image), "[empty undo 2] ran");
  expect_absent (probe, image, "u-empty", "empty undo 2");

  /* Set containing G; delete G; the set must track the live tree and keep
   * G weakly known across the deletion's Undo. */
  s0 = capture_state (image);
  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "u-del", members_g, 1, &error);
  CHECK (status == GLIMS_STATUS_OK, "[del] CREATE u-del {G}");
  if (error) { api->free_string (error); error = NULL; }
  check_delta (probe, s0, capture_state (image), 1, -s0.redo, "del", "create u-del");
  expect_set (probe, image, "u-del", (ExpectedMember[1]) {{probe->addr_g, &probe->wr_g}}, 1, "del");

  s0 = capture_state (image);
  gimp_image_remove_layer (image, probe->g, TRUE, NULL);
  s1 = capture_state (image);
  check_delta (probe, s0, s1, 1, -s0.redo, "del", "gimp_image_remove_layer(G)");
  CHECK (oracle_alive (&probe->wr_g), "[del] deletion undo keeps G alive");
  expect_set (probe, image, "u-del", (ExpectedMember[1]) {{probe->addr_g, &probe->wr_g}}, 1, "del detached");

  s0 = capture_state (image);
  CHECK (gimp_image_undo (image), "[del undo] deletion undone");
  s1 = capture_state (image);
  check_delta (probe, s0, s1, -1, 1, "del undo", "gimp_image_undo()");
  {
    gpointer pg = oracle_addr (&probe->wr_g);
    CHECK (pg == probe->addr_g, "[del undo] same live identity restored");
  }
  expect_set (probe, image, "u-del", (ExpectedMember[1]) {{probe->addr_g, &probe->wr_g}}, 1, "del undo");

  /* Redo the deletion: G detached again; the set must not expose the
   * detached member, but must keep it weakly known for the next Undo. */
  s0 = capture_state (image);
  CHECK (gimp_image_redo (image), "[del redo] deletion redone");
  check_delta (probe, s0, capture_state (image), 1, -1, "del redo", "gimp_image_redo()");
  expect_set (probe, image, "u-del", (ExpectedMember[1]) {{probe->addr_g, &probe->wr_g}}, 1, "del redo detached");

  /* Purge: the removed subtree is finalized; no set exposes it. */
  gimp_image_undo_free (image);
  s1 = capture_state (image);
  CHECK (s1.undo == 0 && s1.redo == 0, "[purge] stacks emptied");
  CHECK (! oracle_alive (&probe->wr_g) && ! oracle_alive (&probe->wr_g2) && ! oracle_alive (&probe->wr_gc),
         "[purge] removed subtree finalized; no undo snapshot kept it alive beyond the stack");
  CHECK (oracle_alive (&probe->wr_c), "[purge] never-removed C still alive");
  expect_set (probe, image, "u-del", (ExpectedMember[1]) {{probe->addr_g, &probe->wr_g}}, 1, "purge");
  expect_set (probe, image, "u-sel", exp_g_gc, 2, "purge");
  expect_pattern (probe, image, "u-*", GIMP_SELECT_GLOB_PATTERN, "purge");

  root_regressions (engine, probe);

  /* Teardown: close with sets still stored — must not crash. */
  status = api->image_close (engine, probe->image_id);
  CHECK (status == GLIMS_STATUS_OK, "[teardown] image closed with sets stored");
  probe->image = NULL;
  g_weak_ref_clear (&probe->wr_c);
  g_weak_ref_clear (&probe->wr_g);
  g_weak_ref_clear (&probe->wr_g2);
  g_weak_ref_clear (&probe->wr_gc);
  free_order (order0, n_order0);

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

  printf ("saved-set-undo-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n", probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return (status == GLIMS_STATUS_OK && probe.failures == 0) ? 0 : 1;
}
