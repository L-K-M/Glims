/*
 * saved-set-read-tests.c — deterministic standalone harness for the
 * READ-ONLY facade slots 133/134: image_item_sets (list fixed saved sets)
 * and image_item_set_members (current attached member ids of one token).
 *
 *   saved-set-read-tests WORK_DIR
 *
 * Test-only file. Same linkage pattern as saved-set-undo-tests.c: it links
 * the adapter objects and GIMP's gimp-console objects directly (no dlopen,
 * no libgimp), includes Engine/engine-private.h, and runs the whole body on
 * the engine thread through one glims_engine_call(). Stored sets are
 * created ONLY through engine-internal fixtures (glims_item_sets_create /
 * _remove, direct GimpItemList construction for a pattern, layer/undo
 * edits); every assertion about saved sets goes through the facade slots
 * under test. No private struct layout is mirrored.
 *
 * Asserted semantics:
 *   - Slot 133 lists the FIXED sets of all three kinds (patterns never
 *     listed), each with a nonzero unique token, its facade kind, its LIVE
 *     attached member count and a display-truncated UTF-8 name; repeated
 *     reads are stable, and a quiet live-member rebuild (a layer add)
 *     retains the same tokens.
 *   - Slot 134 resolves only within the captured image+token: current
 *     attached ids only, partial capacity fills min(capacity, total) and
 *     reports the total in count, count-only reads work, an empty set
 *     reports 0, token 0 / NULL count / negative capacity are
 *     INVALID_ARGUMENT, unknown image or unknown/foreign/stale/expired
 *     token are NOT_FOUND, a NULL engine is NOT_RUNNING with the count
 *     reset to 0.
 *   - A deleted (detached) weak member drops out of the live count and the
 *     member read, and comes back on Undo, with the token unchanged.
 *   - Explicit removal and Undo-replacement EXPIRE the old token for good;
 *     recreating a set under the same name gets a fresh token and the old
 *     token is never retargeted.
 *   - A long multi-byte name truncates for display only, on a character
 *     boundary, and its token still resolves the members (name != identity).
 *   - The reads are quiet: allowed while a stroke holds the image busy
 *     (mutations refuse BUSY there), and they change no undo/redo depth,
 *     no dirty flag and no selection.
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
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimppath.h"
#else
#include "vectors/gimppath.h"
#endif

int main (int argc, char **argv);

#define MAX_ROWS 32

typedef struct
{
  GimpImage   *image;
  GlimsImageID image_id;
  const char  *work;

  GimpLayer *a, *b, *c, *d;
  GimpChannel *chan;
  GimpPath  *path;

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
check_quiet (Probe *probe, GimpImage *image, EngineState before, const char *phase)
{
  EngineState after = capture_state (image);

  CHECK (after.undo == before.undo && after.redo == before.redo && after.dirty == before.dirty,
         "[%s] reads changed no undo/redo/dirty (undo %d->%d, redo %d->%d, dirty %d->%d)",
         phase, before.undo, after.undo, before.redo, after.redo, before.dirty, after.dirty);
}

static GimpLayer *
add_layer (GimpImage *image, const char *name)
{
  GimpLayer *layer = gimp_layer_new (image, 64, 64,
                                     gimp_image_get_layer_format (image, TRUE),
                                     name, GIMP_OPACITY_OPAQUE,
                                     GIMP_LAYER_MODE_NORMAL);

  if (! layer)
    return NULL;
  if (! gimp_image_add_layer (image, layer, NULL, -1, TRUE))
    {
      g_object_unref (layer);
      return NULL;
    }
  return layer;
}

/* Same route as channels.c's Select > Save to Channel. */
static GimpChannel *
add_channel (GimpImage *image, const char *name)
{
  GimpChannel *channel = GIMP_CHANNEL (gimp_item_duplicate (GIMP_ITEM (gimp_image_get_mask (image)),
                                                            GIMP_TYPE_CHANNEL));

  gimp_item_set_visible (GIMP_ITEM (channel), FALSE, FALSE);
  gimp_object_set_name (GIMP_OBJECT (channel), name);
  if (! gimp_image_add_channel (image, channel, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
    {
      g_object_unref (channel);
      return NULL;
    }
  return channel;
}

static GimpPath *
add_path (GimpImage *image, const char *name)
{
  GimpPath *path = gimp_path_new (image, name);

  if (! gimp_image_add_path (image, path, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE))
    {
      g_object_unref (path);
      return NULL;
    }
  return path;
}

/* A pattern definition: computed, must never be listed by slot 133. */
static void
store_pattern (GimpImage *image, const char *name)
{
  GimpItemList *set = g_object_new (GIMP_TYPE_ITEM_LIST,
                                    "image",         image,
                                    "name",          name,
                                    "is-pattern",    TRUE,
                                    "select-method", GIMP_SELECT_PLAIN_TEXT,
                                    "item-type",     GIMP_TYPE_LAYER,
                                    NULL);

  gimp_image_store_item_set (image, set); /* transfer full */
}

/* ---- facade reads under test ------------------------------------------- */

static GlimsEngine *engine_global;

static GlimsStatus
list_sets (Probe *probe, GlimsImageID image, GlimsItemSetInfo *rows,
           int32_t capacity, int32_t *count)
{
  (void) probe;
  return api->image_item_sets (engine_global, image, rows, capacity, count);
}

static GlimsStatus
members_of (Probe *probe, GlimsImageID image, uint64_t token,
            GlimsItemID *out, int32_t capacity, int32_t *count)
{
  (void) probe;
  return api->image_item_set_members (engine_global, image, token, out, capacity, count);
}

static int
find_row (const GlimsItemSetInfo *rows, int32_t count, const char *name)
{
  for (int32_t i = 0; i < count; i++)
    if (strcmp (rows[i].display_name, name) == 0)
      return i;
  return -1;
}

static GlimsBrushSettings
brush_for (double size)
{
  GlimsBrushSettings brush = { .struct_size = sizeof (GlimsBrushSettings), .size = size,
                               .opacity = 1.0, .tool = GLIMS_PAINT_PAINTBRUSH,
                               .hardness = -1.0, .rate = -1.0, .flow = -1.0, .exposure = -1.0 };
  return brush;
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  GimpImage *image;
  GlimsItemSetInfo rows[MAX_ROWS];
  GlimsItemID ids[8];
  int32_t count = -1;
  char *error = NULL;
  GlimsStatus status;
  EngineState s0;
  uint64_t token_layers = 0, token_chan = 0, token_path = 0, token_empty = 0,
           token_long = 0, token_foreign = 0, old_layers_token = 0, token_undo = 0;
  GimpItem *members_ab[2], *members_c[1], *members_ch[1], *members_p[1], *members_a[1];
  char long_name[512];
  int i;

  engine_global = engine;

  status = api->image_new (engine, 64, 64, &probe->image_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "image_new: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  image = probe->image = glims_lookup_image (engine, probe->image_id)->image;

  probe->a = add_layer (image, "r-a");
  probe->b = add_layer (image, "r-b");
  probe->c = add_layer (image, "r-c");
  probe->chan = add_channel (image, "r-chan");
  probe->path = add_path (image, "r-path");
  FIXTURE (probe->a && probe->b && probe->c && probe->chan && probe->path, "fixture items built");
  gimp_image_flush (image);

  members_ab[0] = GIMP_ITEM (probe->a);
  members_ab[1] = GIMP_ITEM (probe->b);
  members_c[0]  = GIMP_ITEM (probe->c);
  members_ch[0] = GIMP_ITEM (probe->chan);
  members_p[0]  = GIMP_ITEM (probe->path);
  members_a[0]  = GIMP_ITEM (probe->a);

  /* Long multi-byte name: 200 x "é" = 400 UTF-8 bytes, truncated to 255
   * display bytes on a character boundary; the token still resolves. */
  for (i = 0; i < 200; i++)
    memcpy (long_name + 2 * i, "\xc3\xa9", 2);
  long_name[400] = '\0';

  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "r-layers", members_ab, 2, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "create r-layers: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "r-empty", NULL, 0, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "create r-empty");
  if (error) { api->free_string (error); error = NULL; }
  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, long_name, members_c, 1, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "create long-named set");
  if (error) { api->free_string (error); error = NULL; }
  status = glims_item_sets_create (image, GIMP_TYPE_CHANNEL, "r-chan-set", members_ch, 1, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "create r-chan-set");
  if (error) { api->free_string (error); error = NULL; }
  status = glims_item_sets_create (image, GIMP_TYPE_PATH, "r-path-set", members_p, 1, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "create r-path-set");
  if (error) { api->free_string (error); error = NULL; }
  store_pattern (image, "r-pattern");

  /* ---------- Phase 1: list all kinds, patterns excluded ---------------- */

  s0 = capture_state (image);
  status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 5, "[list] 5 fixed sets listed, pattern excluded (count %d)", count);
  {
    int32_t idx_layers = find_row (rows, count, "r-layers");
    int32_t idx_empty  = find_row (rows, count, "r-empty");
    int32_t idx_chan   = find_row (rows, count, "r-chan-set");
    int32_t idx_path   = find_row (rows, count, "r-path-set");
    int32_t idx_long   = -1;
    gboolean unique = TRUE;
    for (int32_t i = 0; i < count; i++)
      {
        if (rows[i].token == 0) unique = FALSE;
        for (int32_t j = i + 1; j < count; j++)
          if (rows[i].token == rows[j].token) unique = FALSE;
      }
    for (int32_t i = 0; i < count; i++)
      if (strncmp (rows[i].display_name, long_name, 100) == 0)
        idx_long = i;
    CHECK (idx_layers >= 0 && idx_empty >= 0 && idx_chan >= 0 && idx_path >= 0 && idx_long >= 0,
           "[list] all named sets present");
    CHECK (unique, "[list] tokens nonzero and unique");
    CHECK (idx_layers >= 0 && rows[idx_layers].kind == GLIMS_ITEM_SET_LAYER &&
           idx_empty >= 0 && rows[idx_empty].kind == GLIMS_ITEM_SET_LAYER &&
           idx_long >= 0 && rows[idx_long].kind == GLIMS_ITEM_SET_LAYER &&
           idx_chan >= 0 && rows[idx_chan].kind == GLIMS_ITEM_SET_CHANNEL &&
           idx_path >= 0 && rows[idx_path].kind == GLIMS_ITEM_SET_PATH,
           "[list] facade kinds reported (layer/channel/path)");
    /* Kinds grouped in GlimsItemSetKind order: layers, then channels, then paths. */
    CHECK (idx_layers < idx_chan && idx_empty < idx_chan && idx_long < idx_chan && idx_chan < idx_path,
           "[list] kinds grouped in layer/channel/path order");
    CHECK (idx_layers >= 0 && rows[idx_layers].member_count == 2 &&
           idx_empty >= 0 && rows[idx_empty].member_count == 0 &&
           idx_chan >= 0 && rows[idx_chan].member_count == 1 &&
           idx_path >= 0 && rows[idx_path].member_count == 1,
           "[list] live member counts reported");
    if (idx_layers >= 0) token_layers = rows[idx_layers].token;
    if (idx_empty >= 0)  token_empty  = rows[idx_empty].token;
    if (idx_chan >= 0)   token_chan   = rows[idx_chan].token;
    if (idx_path >= 0)   token_path   = rows[idx_path].token;
    if (idx_long >= 0)   token_long   = rows[idx_long].token;
  }
  check_quiet (probe, image, s0, "list");

  /* ---------- Phase 2: stable reads across a quiet rebuild ------------- */

  {
    GlimsItemSetInfo rows2[MAX_ROWS];
    int32_t count2 = -1;
    status = list_sets (probe, probe->image_id, rows2, MAX_ROWS, &count2);
    CHECK (status == GLIMS_STATUS_OK && count2 == count, "[stable] repeated read same count");
    CHECK (count2 > 0 && find_row (rows2, count2, "r-layers") >= 0 &&
           rows2[find_row (rows2, count2, "r-layers")].token == token_layers,
           "[stable] repeated read same token");

    /* A layer add fires the container watch: a quiet live-member rebuild
     * of the exposed lists; tokens must be retained. */
    probe->d = add_layer (image, "r-d");
    FIXTURE (probe->d != NULL, "rebuild-triggering layer added");
    s0 = capture_state (image);
    status = list_sets (probe, probe->image_id, rows2, MAX_ROWS, &count2);
    CHECK (status == GLIMS_STATUS_OK && count2 == count, "[rebuild] count unchanged after quiet rebuild");
    CHECK (count2 > 0 && find_row (rows2, count2, "r-layers") >= 0 &&
           rows2[find_row (rows2, count2, "r-layers")].token == token_layers &&
           rows2[find_row (rows2, count2, "r-layers")].member_count == 2,
           "[rebuild] token and live count retained through quiet rebuild");
    check_quiet (probe, image, s0, "rebuild read");
  }

  /* ---------- Phase 3: members, capacities, argument handling ----------- */

  s0 = capture_state (image);
  count = -1;
  status = members_of (probe, probe->image_id, token_layers, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2 &&
         ((ids[0] == gimp_item_get_id (GIMP_ITEM (probe->a)) &&
           ids[1] == gimp_item_get_id (GIMP_ITEM (probe->b))) ||
          (ids[0] == gimp_item_get_id (GIMP_ITEM (probe->b)) &&
           ids[1] == gimp_item_get_id (GIMP_ITEM (probe->a)))),
         "[members] current attached ids of the token (count %d)", count);

  count = -1;
  status = members_of (probe, probe->image_id, token_layers, ids, 1, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2,
         "[members partial] capacity 1 still reports total 2 (count %d)", count);

  count = -1;
  status = members_of (probe, probe->image_id, token_layers, NULL, 0, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2, "[members count-only] NULL array, capacity 0 (count %d)", count);

  count = -1;
  status = members_of (probe, probe->image_id, token_empty, NULL, 0, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 0, "[members empty] empty set reports 0");

  count = -1;
  status = members_of (probe, probe->image_id, 0, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && count == 0, "[members] token 0 refused INVALID_ARGUMENT");

  count = -1;
  status = members_of (probe, probe->image_id, 424242, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0, "[members] unknown token NOT_FOUND");

  status = members_of (probe, probe->image_id, token_layers, ids, 8, NULL);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[members] NULL count refused");

  count = -1;
  status = members_of (probe, probe->image_id, token_layers, ids, -1, &count);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && count == 0, "[members] negative capacity refused");

  count = -1;
  status = list_sets (probe, 9999, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0, "[list] unknown image NOT_FOUND");

  count = -1;
  status = members_of (probe, 9999, token_layers, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0, "[members] unknown image NOT_FOUND");

  count = 77;
  status = api->image_item_sets (NULL, probe->image_id, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_NOT_RUNNING && count == 0, "[null engine] NOT_RUNNING, count reset to 0");
  count = 77;
  status = api->image_item_set_members (NULL, probe->image_id, token_layers, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_RUNNING && count == 0, "[null engine members] NOT_RUNNING, count reset to 0");

  count = -1;
  status = list_sets (probe, probe->image_id, NULL, 0, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 5, "[list count-only] NULL rows, capacity 0 (count %d)", count);
  check_quiet (probe, image, s0, "members phase");

  /* ---------- Phase 4: reads allowed while a stroke holds the image ------ */

  {
    GlimsBrushSettings brush = brush_for (9.0);
    GlimsStrokePoint first = { 8, 8, 1.0, 0.0, 0.0, 0 };
    GlimsStrokeID stroke = 0;

    status = api->stroke_begin (engine, probe->image_id,
                                gimp_item_get_id (GIMP_ITEM (probe->a)),
                                &brush, &first, &stroke, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "stroke begins: %s", error ? error : "?");
    if (error) { api->free_string (error); error = NULL; }

    CHECK (api->image_undo (engine, probe->image_id) == GLIMS_STATUS_BUSY,
           "[busy] image really busy while the stroke is open");

    count = -1;
    status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
    CHECK (status == GLIMS_STATUS_OK && count == 5, "[busy read] list allowed while busy");
    count = -1;
    status = members_of (probe, probe->image_id, token_layers, ids, 8, &count);
    CHECK (status == GLIMS_STATUS_OK && count == 2, "[busy read] members allowed while busy");

    status = api->stroke_end (engine, stroke);
    CHECK (status == GLIMS_STATUS_OK, "stroke ends");
  }

  /* ---------- Phase 5: deleted weak member drops out, Undo restores ------ */

  gimp_image_remove_layer (image, probe->b, TRUE, NULL);
  count = -1;
  status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
  {
    int32_t idx = find_row (rows, count, "r-layers");
    CHECK (status == GLIMS_STATUS_OK && idx >= 0 && rows[idx].token == token_layers &&
           rows[idx].member_count == 1,
           "[deleted member] live count drops to 1, token unchanged");
  }
  count = -1;
  status = members_of (probe, probe->image_id, token_layers, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 1 &&
         ids[0] == gimp_item_get_id (GIMP_ITEM (probe->a)),
         "[deleted member] detached weak member skipped in the read");

  CHECK (api->image_undo (engine, probe->image_id) == GLIMS_STATUS_OK, "[deleted member] undo runs");
  count = -1;
  status = members_of (probe, probe->image_id, token_layers, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2, "[deleted member] undo restores the live member");

  /* ---------- Phase 6: foreign image token refused ----------------------- */

  {
    GlimsImageID id2 = 0;
    GimpImage *image2;
    GimpLayer *foreign;
    GimpItem *foreign_members[1];
    GlimsItemSetInfo rows2[MAX_ROWS];
    int32_t count2 = -1, idx;

    status = api->image_new (engine, 32, 32, &id2, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "second image created");
    if (error) { api->free_string (error); error = NULL; }
    image2 = glims_lookup_image (engine, id2)->image;
    foreign = add_layer (image2, "r-foreign-layer");
    FIXTURE (foreign != NULL, "foreign layer built");
    foreign_members[0] = GIMP_ITEM (foreign);
    status = glims_item_sets_create (image2, GIMP_TYPE_LAYER, "r-foreign", foreign_members, 1, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "foreign set created");
    if (error) { api->free_string (error); error = NULL; }

    status = list_sets (probe, id2, rows2, MAX_ROWS, &count2);
    CHECK (status == GLIMS_STATUS_OK && count2 == 1, "[foreign] second image lists its own set");
    idx = find_row (rows2, count2, "r-foreign");
    CHECK (idx >= 0 && rows2[idx].token != 0 && rows2[idx].token != token_layers,
           "[foreign] per-engine tokens distinct across images");
    if (idx >= 0) token_foreign = rows2[idx].token;

    count = -1;
    status = members_of (probe, probe->image_id, token_foreign, ids, 8, &count);
    CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0,
           "[foreign] another image's token refused on this image");
    count = -1;
    status = members_of (probe, id2, token_layers, ids, 8, &count);
    CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0,
           "[foreign] reverse direction refused too");
    CHECK (api->image_close (engine, id2) == GLIMS_STATUS_OK, "[foreign] second image closed");
  }

  /* ---------- Phase 7: removal expires, same-name recreation retargets nothing ---------- */

  old_layers_token = token_layers;
  status = glims_item_sets_remove (image, GIMP_TYPE_LAYER, "r-layers", &error);
  FIXTURE (status == GLIMS_STATUS_OK, "remove r-layers: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }

  count = -1;
  status = members_of (probe, probe->image_id, old_layers_token, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0, "[stale] removed set's token expired (NOT_FOUND)");
  count = -1;
  status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_OK && find_row (rows, count, "r-layers") < 0,
         "[stale] removed set no longer listed");

  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "r-layers", members_c, 1, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "recreate same-named set");
  if (error) { api->free_string (error); error = NULL; }
  count = -1;
  status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
  {
    int32_t idx = find_row (rows, count, "r-layers");
    CHECK (status == GLIMS_STATUS_OK && idx >= 0 && rows[idx].token != 0 &&
           rows[idx].token != old_layers_token && rows[idx].member_count == 1,
           "[recreate] same name gets a FRESH token");
    if (idx >= 0) token_layers = rows[idx].token;
  }
  count = -1;
  status = members_of (probe, probe->image_id, old_layers_token, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND, "[recreate] old token never retargeted to the new set");
  count = -1;
  status = members_of (probe, probe->image_id, token_layers, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 1 &&
         ids[0] == gimp_item_get_id (GIMP_ITEM (probe->c)),
         "[recreate] new token resolves the new members");

  /* ---------- Phase 8: Undo replacement expires the old token ----------- */

  status = glims_item_sets_create (image, GIMP_TYPE_LAYER, "r-undo", members_a, 1, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "create r-undo");
  if (error) { api->free_string (error); error = NULL; }
  count = -1;
  status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
  {
    int32_t idx = find_row (rows, count, "r-undo");
    CHECK (status == GLIMS_STATUS_OK && idx >= 0, "[undo expiry] r-undo listed");
    if (idx >= 0) token_undo = rows[idx].token;
  }
  CHECK (api->image_undo (engine, probe->image_id) == GLIMS_STATUS_OK, "[undo expiry] undo runs");
  count = -1;
  status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
  CHECK (status == GLIMS_STATUS_OK && find_row (rows, count, "r-undo") < 0,
         "[undo expiry] undone set gone from the list");
  count = -1;
  status = members_of (probe, probe->image_id, token_undo, ids, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0, "[undo expiry] old token expired by the Undo");

  /* ---------- Phase 9: display truncation is display-only ---------------- */

  count = -1;
  status = list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
  {
    int32_t idx = -1;
    size_t len;
    for (int32_t i = 0; i < count; i++)
      if (strncmp (rows[i].display_name, long_name, 100) == 0)
        idx = i;
    CHECK (idx >= 0, "[truncation] long-named set listed");
    if (idx >= 0)
      {
        len = strlen (rows[idx].display_name);
        CHECK (len <= 255 && g_utf8_validate (rows[idx].display_name, -1, NULL) &&
               (len == 0 || ((unsigned char) rows[idx].display_name[len - 1] & 0xC0) != 0x80),
               "[truncation] display name bounded, valid UTF-8, char-boundary truncated (%zu bytes)", len);
        CHECK (rows[idx].token == token_long, "[truncation] same set keeps its token");
        count = -1;
        status = members_of (probe, probe->image_id, token_long, ids, 8, &count);
        CHECK (status == GLIMS_STATUS_OK && count == 1 &&
               ids[0] == gimp_item_get_id (GIMP_ITEM (probe->c)),
               "[truncation] TOKEN (not the truncated name) resolves the members");
      }
  }

  /* ---------- Phase 10: read invariants ---------------------------------- */

  {
    GList *selected_before = gimp_image_get_selected_layers (image);
    guint n_selected = g_list_length (selected_before);

    s0 = capture_state (image);
    count = -1;
    list_sets (probe, probe->image_id, rows, MAX_ROWS, &count);
    members_of (probe, probe->image_id, token_layers, ids, 8, &count);
    members_of (probe, probe->image_id, token_chan, ids, 8, &count);
    members_of (probe, probe->image_id, token_path, ids, 8, &count);
    check_quiet (probe, image, s0, "read invariants");
    {
      GList *selected_after = gimp_image_get_selected_layers (image);
      CHECK (g_list_length (selected_after) == n_selected, "[invariants] selection unchanged by reads");
      g_list_free (selected_after);
    }
    g_list_free (selected_before);
  }

  /* ---------- teardown ---------------------------------------------------- */

  CHECK (api->image_close (engine, probe->image_id) == GLIMS_STATUS_OK, "[teardown] image closed");

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

  printf ("saved-set-read-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n", probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return (status == GLIMS_STATUS_OK && probe.failures == 0) ? 0 : 1;
}
