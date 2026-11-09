/*
 * item-select-tests.c — deterministic standalone harness for the batch
 * item-selection facade slots 136/137: image_select_items (ordered,
 * transient whole-list write of the selected layers/channels/paths) and
 * image_selected_items (borrowed-order plain read).
 *
 *   item-select-tests WORK_DIR
 *
 * Test-only file. Same linkage pattern as saved-set-read-tests.c: it links
 * the adapter objects and GIMP's gimp-console objects directly (no dlopen,
 * no libgimp), includes Engine/engine-private.h, and runs the whole body on
 * the engine thread through one glims_engine_call(). The fixture is built
 * ONLY through engine-internal/native calls (gimp_image_add_layer and
 * friends, api->image_new); every assertion about the selection goes
 * through the facade slots under test OR through a FRESH native
 * gimp_image_get_selected_layers/_channels/_paths call as the independent
 * oracle — never through a cached facade read or a mirrored struct layout.
 *
 * Asserted semantics:
 *   - All three kinds: selecting an actual 2-item list per kind applies
 *     exactly, in the caller's order, verified by read-back against a
 *     fresh native getter.
 *   - Order is preserved verbatim (first id = active item); a pure
 *     reorder of the same members is forced (clear-then-apply) and lands
 *     in the new order; an identical request is a no-op emitting no
 *     LAYERS_CHANGED/CHANNELS_CHANGED event; count 0 clears per kind —
 *     channels through gimp_image_unset_selected_channels, which also
 *     restores the layer stack the channel selection replaced.
 *   - Unknown kind/image, NULL items with count > 0, negative count,
 *     id 0, duplicate ids, more ids than the image has, stale, foreign
 *     and wrong-kind ids (including the selection mask as a "channel")
 *     are all refused BEFORE any mutation: the native selection is
 *     unchanged after every refusal. Select is BUSY-gated (a stroke
 *     refuses it, the getter still works); a floating selection refuses
 *     layer changes (except exactly [floating]) and NON-EMPTY channel
 *     lists with FAILED — never anchoring — while allowing an empty
 *     channel list and path selection.
 *   - The getter resets *count to 0 on every failure including a NULL
 *     engine (NOT_RUNNING), supports count-only and partial-capacity
 *     reads, and copies ids out of the borrowed native list immediately.
 *   - Multi-layer selection reuses the native mask policy: the edit-mask
 *     flag of selected layers with masks is cleared when the selection
 *     grows past one, without touching mask data. Selects and reads are
 *     transient: no undo/redo depth, no dirty flag and no pixel change.
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
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimplayermask.h"
#include "core/gimpobject.h"
#include "core/gimpundostack.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimppath.h"
#else
#include "vectors/gimppath.h"
#endif

int main (int argc, char **argv);

typedef struct
{
  GimpImage   *image;
  GlimsImageID image_id;
  GimpImage   *other;
  GlimsImageID other_id;
  GlimsItemID  foreign;          /* a layer id of `other` */

  GimpLayer *a, *b, *c;
  GimpChannel *ch1, *ch2;
  GimpPath  *p1, *p2;

  int failures;
  int layers_events;
  int channels_events;
} Probe;

static const GlimsEngineAPI *api;
static GlimsEngine *engine_global;

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
on_event (void *context, const GlimsEvent *event)
{
  Probe *probe = context;

  if (event->kind == GLIMS_EVENT_LAYERS_CHANGED)
    probe->layers_events++;
  else if (event->kind == GLIMS_EVENT_CHANNELS_CHANGED)
    probe->channels_events++;
}

/* ---- internal fixture only --------------------------------------------- */

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

static GlimsBrushSettings
brush_for (double size)
{
  GlimsBrushSettings brush = { .struct_size = sizeof (GlimsBrushSettings), .size = size,
                               .opacity = 1.0, .tool = GLIMS_PAINT_PAINTBRUSH,
                               .hardness = -1.0, .rate = -1.0, .flow = -1.0, .exposure = -1.0 };
  return brush;
}

/* ---- facade slots under test ------------------------------------------- */

static GlimsStatus
sel_items (GlimsImageID image, uint32_t kind, const GlimsItemID *items, int32_t count, char **error)
{
  return api->image_select_items (engine_global, image, kind, items, count, error);
}

static GlimsStatus
selected_items (GlimsImageID image, uint32_t kind, GlimsItemID *out, int32_t capacity, int32_t *count)
{
  return api->image_selected_items (engine_global, image, kind, out, capacity, count);
}

/* ---- fresh native oracle (never a facade mirror) ------------------------ */

static int
native_selected (GimpImage *image, uint32_t kind, GlimsItemID *ids, int max)
{
  GList *sel, *iter;
  int    n = 0;

  switch (kind)
    {
    case GLIMS_ITEM_SET_LAYER:   sel = gimp_image_get_selected_layers (image);   break;
    case GLIMS_ITEM_SET_CHANNEL: sel = gimp_image_get_selected_channels (image); break;
    default:                     sel = gimp_image_get_selected_paths (image);    break;
    }
  /* Borrowed item-tree list: never freed here. */
  for (iter = sel; iter && n < max; iter = iter->next)
    ids[n++] = gimp_item_get_id (GIMP_ITEM (iter->data));
  return (int) g_list_length (sel);
}

/* The facade read and a FRESH native read must both equal `expected`. */
static void
check_selection (Probe *probe, uint32_t kind, const GlimsItemID *expected, int32_t expected_count,
                 const char *phase)
{
  GlimsItemID ids[8];
  GlimsItemID nat[8];
  int32_t     count = -1;
  int         ncount;
  GlimsStatus st;

  st = selected_items (probe->image_id, kind, ids, 8, &count);
  ncount = native_selected (probe->image, kind, nat, 8);
  CHECK (st == GLIMS_STATUS_OK && count == expected_count && ncount == expected_count,
         "[%s] kind %u: facade count %d, native count %d, expected %d",
         phase, kind, count, ncount, expected_count);
  CHECK (count == expected_count && ncount == expected_count &&
         memcmp (ids, expected, (size_t) expected_count * sizeof (GlimsItemID)) == 0 &&
         memcmp (nat, expected, (size_t) expected_count * sizeof (GlimsItemID)) == 0,
         "[%s] kind %u: exact ids in exact order (facade == fresh native oracle)",
         phase, kind);
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  Probe *probe = data;
  GimpImage *image;
  char *error = NULL;
  GlimsStatus status;
  GlimsItemID id_a, id_b, id_c, id_ch1, id_ch2, id_p1, id_p2;
  GlimsItemID two[2], one[1], fs_id = 0;
  GlimsItemID out[8];
  GlimsFloatingState fs = { .struct_size = sizeof (GlimsFloatingState) };
  GlimsStrokeID stroke = 0;
  GlimsBrushSettings brush;
  GlimsStrokePoint point = { 8, 8, 1.0, 0.0, 0.0, 0 };
  EngineState s0;
  uint8_t pixels_before[16 * 16 * 4], pixels_after[16 * 16 * 4];
  int32_t count = -1;
  int i;

  engine_global = engine;

  /* ---------- fixture (internal/native only) ---------------------------- */

  status = api->image_new (engine, 64, 64, &probe->image_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "image_new: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  image = probe->image = glims_lookup_image (engine, probe->image_id)->image;

  status = api->image_new (engine, 32, 32, &probe->other_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "second image_new: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  probe->other = glims_lookup_image (engine, probe->other_id)->image;

  probe->a   = add_layer (image, "a");
  probe->b   = add_layer (image, "b");
  probe->c   = add_layer (image, "c");
  probe->ch1 = add_channel (image, "ch1");
  probe->ch2 = add_channel (image, "ch2");
  probe->p1  = add_path (image, "p1");
  probe->p2  = add_path (image, "p2");
  {
    GimpLayer *foreign = add_layer (probe->other, "foreign");
    FIXTURE (probe->a && probe->b && probe->c && probe->ch1 && probe->ch2 &&
             probe->p1 && probe->p2 && foreign, "fixture items built");
    probe->foreign = gimp_item_get_id (GIMP_ITEM (foreign));
  }
  gimp_image_flush (image);

  id_a  = gimp_item_get_id (GIMP_ITEM (probe->a));
  id_b  = gimp_item_get_id (GIMP_ITEM (probe->b));
  id_c  = gimp_item_get_id (GIMP_ITEM (probe->c));
  id_ch1 = gimp_item_get_id (GIMP_ITEM (probe->ch1));
  id_ch2 = gimp_item_get_id (GIMP_ITEM (probe->ch2));
  id_p1  = gimp_item_get_id (GIMP_ITEM (probe->p1));
  id_p2  = gimp_item_get_id (GIMP_ITEM (probe->p2));

  /* ---------- Phase 1: an actual 2-item selection per kind, in order ---- */

  two[0] = id_a; two[1] = id_b;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[2 items] select layers [a,b]: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_LAYER, two, 2, "2 items layers");

  two[0] = id_ch1; two[1] = id_ch2;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[2 items] select channels [ch1,ch2]: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_CHANNEL, two, 2, "2 items channels");
  {
    GlimsItemID nat[4];
    int n = native_selected (image, GLIMS_ITEM_SET_LAYER, nat, 4);
    CHECK (n == 0, "[cross-kind] selecting channels cleared the selected layers (native: %d)", n);
  }

  two[0] = id_p1; two[1] = id_p2;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_PATH, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[2 items] select paths [p1,p2]: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_PATH, two, 2, "2 items paths");

  /* ---------- Phase 2: order kept verbatim ------------------------------ */

  two[0] = id_b; two[1] = id_a;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[order] select layers [b,a]: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_LAYER, two, 2, "order [b,a]");

  /* ---------- Phase 3: pure reorder is forced (clear-then-apply) -------- */

  two[0] = id_a; two[1] = id_b;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[reorder] select layers [a,b] over [b,a]: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_LAYER, two, 2, "reorder layers -> [a,b]");

  two[0] = id_ch1; two[1] = id_ch2;
  sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, two, 2, NULL);
  two[0] = id_ch2; two[1] = id_ch1;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[reorder] select channels [ch2,ch1]: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_CHANNEL, two, 2, "reorder channels -> [ch2,ch1]");

  two[0] = id_p2; two[1] = id_p1;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_PATH, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[reorder] select paths [p2,p1]: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_PATH, two, 2, "reorder paths -> [p2,p1]");

  /* ---------- Phase 4: identical request is a no-op, no event ----------- */

  two[0] = id_a; two[1] = id_b;
  sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, NULL);
  probe->layers_events = 0;
  probe->channels_events = 0;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK && probe->layers_events == 0,
         "[noop] identical layer request: OK with no LAYERS_CHANGED event (events %d)",
         probe->layers_events);
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_LAYER, two, 2, "noop layers");

  two[0] = id_ch2; two[1] = id_ch1;
  sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, two, 2, NULL);
  probe->channels_events = 0;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK && probe->channels_events == 0,
         "[noop] identical channel request: OK with no CHANNELS_CHANGED event (events %d)",
         probe->channels_events);
  if (error) { api->free_string (error); error = NULL; }

  /* ---------- Phase 5: empty per kind ------------------------------------ */

  EngineState before_empty_state = capture_state (image);
  GlimsItemID before_empty[16] = {0}; int32_t before_empty_count = 0;
  api->image_selected_items (engine, probe->image_id, GLIMS_ITEM_SET_LAYER, before_empty, 16, &before_empty_count);
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, NULL, 0, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[empty] the batch endpoint refuses an empty layer list");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_LAYER, before_empty, before_empty_count, "empty layer refusal retains selection");
  EngineState after_empty_state = capture_state (image);
  CHECK (before_empty_state.undo == after_empty_state.undo && before_empty_state.redo == after_empty_state.redo
         && before_empty_state.dirty == after_empty_state.dirty, "[empty] layer refusal preserves Undo and dirty");

  one[0] = id_a;
  sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, one, 1, NULL);
  one[0] = id_ch1;
  sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, one, 1, NULL);
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, NULL, 0, &error);
  CHECK (status == GLIMS_STATUS_OK, "[empty] clear channels via unset: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_CHANNEL, NULL, 0, "empty channels");
  {
    GlimsItemID nat[4];
    int n = native_selected (image, GLIMS_ITEM_SET_LAYER, nat, 4);
    CHECK (n == 1 && nat[0] == id_a,
           "[empty] channel clear restored the replaced layer stack (native layers: %d, first %d)",
           n, n > 0 ? nat[0] : 0);
  }

  status = sel_items (probe->image_id, GLIMS_ITEM_SET_PATH, NULL, 0, &error);
  CHECK (status == GLIMS_STATUS_OK, "[empty] clear paths: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_PATH, NULL, 0, "empty paths");

  /* ---------- Phase 6: refusals, all before any mutation ----------------- */

  two[0] = id_a; two[1] = id_b;
  sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, NULL);

#define EXPECT_REFUSAL(label, expected_status, kind, items, n)                 \
  do {                                                                         \
    GlimsItemID nat_before[3][8] = {{0}}, nat_after[3][8] = {{0}};               \
    int lengths_before[3], lengths_after[3];                                    \
    for (int k=0; k<3; k++)                                                     \
      lengths_before[k]=native_selected (image, (uint32_t)k+1, nat_before[k], 8); \
    error = NULL;                                                              \
    status = sel_items (probe->image_id, (kind), (items), (n), &error);           \
    for (int k=0; k<3; k++)                                                     \
      lengths_after[k]=native_selected (image, (uint32_t)k+1, nat_after[k], 8);   \
    CHECK (status == (expected_status) &&                                       \
           memcmp(lengths_before,lengths_after,sizeof lengths_before)==0 &&     \
           memcmp(nat_before,nat_after,sizeof nat_before)==0,                   \
           "[%s] refused with status %d, all three selections untouched", label, status); \
    if (error) { api->free_string (error); error = NULL; }                       \
  } while (0)

  EXPECT_REFUSAL ("unknown kind 0", GLIMS_STATUS_INVALID_ARGUMENT, 0, two, 2);
  EXPECT_REFUSAL ("unknown kind 99", GLIMS_STATUS_INVALID_ARGUMENT, 99, two, 2);
  {
    error = NULL;
    status = api->image_select_items (engine, 424242, GLIMS_ITEM_SET_LAYER, two, 2, &error);
    CHECK (status == GLIMS_STATUS_NOT_FOUND, "[unknown image] select on image 424242: NOT_FOUND");
    if (error) { api->free_string (error); error = NULL; }
    count = -1;
    status = api->image_selected_items (engine, 424242, GLIMS_ITEM_SET_LAYER, out, 8, &count);
    CHECK (status == GLIMS_STATUS_NOT_FOUND && count == 0,
           "[unknown image] getter NOT_FOUND with count reset to 0");
  }
  EXPECT_REFUSAL ("NULL items, count 2", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_LAYER, NULL, 2);
  EXPECT_REFUSAL ("negative count", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_LAYER, two, -1);
  {
    GlimsItemID negative[1] = {-1};
    for (uint32_t k=GLIMS_ITEM_SET_LAYER; k<=GLIMS_ITEM_SET_PATH; k++)
      EXPECT_REFUSAL ("negative id", GLIMS_STATUS_INVALID_ARGUMENT, k, negative, 1);
  }
  {
    GlimsItemID with_zero[2] = { id_a, 0 };
    EXPECT_REFUSAL ("id 0", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_LAYER, with_zero, 2);
  }
  {
    GlimsItemID dup[2] = { id_a, id_a };
    EXPECT_REFUSAL ("duplicate ids", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_LAYER, dup, 2);
  }
  {
    GlimsItemID too_many[5] = { id_a, id_b, id_c, id_a, id_b };
    EXPECT_REFUSAL ("more ids than layers", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_LAYER, too_many, 5);
  }
  {
    GlimsItemID wrong[1] = { id_ch1 };
    EXPECT_REFUSAL ("channel id for LAYER", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_LAYER, wrong, 1);
  }
  {
    GlimsItemID wrong[1] = { id_p1 };
    EXPECT_REFUSAL ("path id for LAYER", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_LAYER, wrong, 1);
  }
  {
    GlimsItemID wrong[1] = { id_a };
    EXPECT_REFUSAL ("layer id for CHANNEL", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_CHANNEL, wrong, 1);
  }
  {
    GlimsItemID mask_id = gimp_item_get_id (GIMP_ITEM (gimp_image_get_mask (image)));
    GlimsItemID wrong[1] = { mask_id };
    EXPECT_REFUSAL ("selection mask as CHANNEL", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_CHANNEL, wrong, 1);
  }
  {
    GlimsItemID wrong[1] = { id_ch1 };
    EXPECT_REFUSAL ("channel id for PATH", GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_ITEM_SET_PATH, wrong, 1);
  }
  {
    GlimsItemID wrong[1] = { probe->foreign };
    EXPECT_REFUSAL ("foreign image id", GLIMS_STATUS_NOT_FOUND, GLIMS_ITEM_SET_LAYER, wrong, 1);
  }
  {
    GlimsItemID wrong[1] = { 987654 };
    EXPECT_REFUSAL ("stale unknown id", GLIMS_STATUS_NOT_FOUND, GLIMS_ITEM_SET_LAYER, wrong, 1);
  }

  /* ---------- Phase 7: stale after a real removal ------------------------- */

  {
    GlimsItemID dead = id_c;
    gimp_image_remove_layer (image, probe->c, TRUE, NULL);
    gimp_image_flush (image);
    one[0] = dead;
    error = NULL;
    status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, one, 1, &error);
    CHECK (status == GLIMS_STATUS_NOT_FOUND,
           "[stale] detached layer id refused NOT_FOUND (status %d)", status);
    if (error) { api->free_string (error); error = NULL; }
  }

  /* ---------- Phase 8: getter argument and count-reset contract ---------- */

  count = -1;
  status = selected_items (probe->image_id, 99, out, 8, &count);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && count == 0,
         "[getter] unknown kind INVALID_ARGUMENT, count reset to 0");
  count = -1;
  status = selected_items (probe->image_id, GLIMS_ITEM_SET_LAYER, out, -1, &count);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && count == 0,
         "[getter] negative capacity INVALID_ARGUMENT, count reset to 0");
  count = -1;
  status = selected_items (probe->image_id, GLIMS_ITEM_SET_LAYER, NULL, 8, &count);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && count == 0,
         "[getter] NULL out with capacity > 0 INVALID_ARGUMENT, count reset to 0");
  count = -1;
  status = api->image_selected_items (engine, probe->image_id, GLIMS_ITEM_SET_LAYER, out, 8, NULL);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT,
         "[getter] NULL count INVALID_ARGUMENT");
  count = -1;
  status = api->image_selected_items (NULL, probe->image_id, GLIMS_ITEM_SET_LAYER, out, 8, &count);
  CHECK (status == GLIMS_STATUS_NOT_RUNNING && count == 0,
         "[getter] NULL engine NOT_RUNNING, count reset to 0");

  two[0] = id_a; two[1] = id_b;
  sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, NULL);
  count = -1;
  status = selected_items (probe->image_id, GLIMS_ITEM_SET_LAYER, NULL, 0, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2, "[getter] count-only read reports 2");
  count = -1;
  status = selected_items (probe->image_id, GLIMS_ITEM_SET_LAYER, out, 1, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2 && out[0] == id_a,
         "[getter] partial capacity fills 1, reports total 2");
  count = -1;
  status = selected_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, NULL, 1, &count);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && count == 0,
         "[getter] NULL output with positive capacity refuses and resets count");

  /* ---------- Phase 9: busy gate on select, plain read on getter --------- */

  brush = brush_for (8.0);
  status = api->stroke_begin (engine, probe->image_id, id_a, &brush, &point, &stroke, &error);
  FIXTURE (status == GLIMS_STATUS_OK && stroke != 0, "stroke_begin: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  error = NULL;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
  CHECK (status == GLIMS_STATUS_BUSY, "[busy] select while a stroke holds the image: BUSY (status %d)", status);
  if (error) { api->free_string (error); error = NULL; }
  count = -1;
  status = selected_items (probe->image_id, GLIMS_ITEM_SET_LAYER, out, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 2 && out[0] == id_a && out[1] == id_b,
         "[busy] getter still a plain read during the stroke");
  one[0] = id_b;
  error = NULL;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_PATH, one, 1, &error);
  CHECK (status == GLIMS_STATUS_BUSY, "[busy] path select also BUSY (status %d)", status);
  if (error) { api->free_string (error); error = NULL; }
  api->stroke_end (engine, stroke);
  two[0] = id_b; two[1] = id_a;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
  CHECK (status == GLIMS_STATUS_OK, "[busy] select works again after stroke_end: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_LAYER, two, 2, "after busy");

  /* ---------- Phase 10: floating selection policy ------------------------- */

  CHECK (api->select_command (engine, probe->image_id, GLIMS_SELECT_ALL, 0, NULL) == GLIMS_STATUS_OK,
         "[fs] select all");
  status = api->selection_float (engine, probe->image_id, id_a, GLIMS_FLOAT_COPY, &fs_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK && fs_id != 0, "[fs] float: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  CHECK (api->image_floating_selection (engine, probe->image_id, &fs) == GLIMS_STATUS_OK && fs.active &&
         fs.floating == fs_id, "[fs] a floating selection is active");

  two[0] = id_a; two[1] = id_b;
  error = NULL;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
  CHECK (status == GLIMS_STATUS_FAILED && error != NULL,
         "[fs] layer change refused FAILED with a reason (status %d)", status);
  if (error) { api->free_string (error); error = NULL; }
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, NULL, 0, &error);
  CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT, "[fs] empty layer input is invalid without resolving the floating selection (status %d)", status);
  if (error) { api->free_string (error); error = NULL; }
  CHECK (api->image_floating_selection (engine, probe->image_id, &fs) == GLIMS_STATUS_OK && fs.active,
         "[fs] refusals never anchored the floating selection");
  one[0] = fs_id;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, one, 1, &error);
  CHECK (status == GLIMS_STATUS_OK, "[fs] the identical [floating] list is accepted as a no-op");
  if (error) { api->free_string (error); error = NULL; }

  one[0] = id_ch1;
  error = NULL;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, one, 1, &error);
  CHECK (status == GLIMS_STATUS_FAILED && error != NULL,
         "[fs] NON-EMPTY channel list refused FAILED with an explicit reason (status %d)", status);
  if (error) { api->free_string (error); error = NULL; }
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, NULL, 0, &error);
  CHECK (status == GLIMS_STATUS_OK, "[fs] EMPTY channel list allowed under FS: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_CHANNEL, NULL, 0, "fs empty channels");

  one[0] = id_p1;
  status = sel_items (probe->image_id, GLIMS_ITEM_SET_PATH, one, 1, &error);
  CHECK (status == GLIMS_STATUS_OK, "[fs] path selection allowed under FS: %s", error ? error : "ok");
  if (error) { api->free_string (error); error = NULL; }
  check_selection (probe, GLIMS_ITEM_SET_PATH, one, 1, "fs paths");

  count = -1;
  status = selected_items (probe->image_id, GLIMS_ITEM_SET_LAYER, out, 8, &count);
  CHECK (status == GLIMS_STATUS_OK && count == 1 && out[0] == fs_id,
         "[fs] getter works under FS (selected layer is the floating one)");
  CHECK (api->image_floating_selection (engine, probe->image_id, &fs) == GLIMS_STATUS_OK && fs.active,
         "[fs] still not anchored after all channel/path calls");

  CHECK (api->floating_command (engine, probe->image_id, fs_id, GLIMS_FLOATING_DISCARD, NULL, NULL) == GLIMS_STATUS_OK,
         "[fs] discard the floating selection");
  CHECK (api->image_floating_selection (engine, probe->image_id, &fs) == GLIMS_STATUS_OK && ! fs.active,
         "[fs] discarded (removed, not anchored)");
  CHECK (api->select_command (engine, probe->image_id, GLIMS_SELECT_NONE, 0, NULL) == GLIMS_STATUS_OK,
         "[fs] clear the selection mask");

  /* ---------- Phase 11: mask policy reused, transient invariants ---------- */

  {
    GlimsItemID mask = 0, mask2 = 0;
    CHECK (api->layer_mask_add (engine, probe->image_id, id_a, GLIMS_MASK_BLACK, true, &mask, NULL) == GLIMS_STATUS_OK &&
           api->layer_mask_add (engine, probe->image_id, id_b, GLIMS_MASK_BLACK, true, &mask2, NULL) == GLIMS_STATUS_OK,
           "[mask] masks added with edit-mask on for a and b");
    CHECK (gimp_layer_get_edit_mask (probe->a) && gimp_layer_get_edit_mask (probe->b),
           "[mask] edit-mask on before selection change");
    EXPECT_REFUSAL ("layer mask is not an image channel", GLIMS_STATUS_INVALID_ARGUMENT,
                    GLIMS_ITEM_SET_CHANNEL, &mask, 1);

    s0 = capture_state (image);
    status = api->image_render (engine, probe->image_id, 1.0, (GlimsRect) { 0, 0, 16, 16 },
                                pixels_before, 16 * 4);
    FIXTURE (status == GLIMS_STATUS_OK, "[mask] render before");

    one[0] = id_a;
    sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, one, 1, NULL);
    CHECK (gimp_layer_get_edit_mask (probe->a), "[mask] single-layer selection keeps edit-mask");

    two[0] = id_a; two[1] = id_b;
    status = sel_items (probe->image_id, GLIMS_ITEM_SET_LAYER, two, 2, &error);
    CHECK (status == GLIMS_STATUS_OK, "[mask] select [a,b]: %s", error ? error : "ok");
    if (error) { api->free_string (error); error = NULL; }
    CHECK (! gimp_layer_get_edit_mask (probe->a) && ! gimp_layer_get_edit_mask (probe->b),
           "[mask] multi-layer selection cleared edit-mask on both (native policy reused)");
    CHECK (gimp_layer_get_mask (probe->a) != NULL && gimp_layer_get_mask (probe->b) != NULL &&
           gimp_layer_get_apply_mask (probe->a) && gimp_layer_get_apply_mask (probe->b),
           "[mask] mask data, enabled flag untouched");

    status = api->image_render (engine, probe->image_id, 1.0, (GlimsRect) { 0, 0, 16, 16 },
                                pixels_after, 16 * 4);
    CHECK (status == GLIMS_STATUS_OK && memcmp (pixels_before, pixels_after, sizeof pixels_before) == 0,
           "[invariants] selects changed no pixels");
    {
      EngineState s1 = capture_state (image);
      CHECK (s1.undo == s0.undo && s1.redo == s0.redo && s1.dirty == s0.dirty,
             "[invariants] selects changed no undo/redo/dirty (undo %d->%d, dirty %d->%d)",
             s0.undo, s1.undo, s0.dirty, s1.dirty);
    }
  }

  /* ---------- Phase 12: read invariants ----------------------------------- */

  {
    GlimsItemID nat_before[8] = {0};
    int n_before = native_selected (image, GLIMS_ITEM_SET_LAYER, nat_before, 8);

    s0 = capture_state (image);
    for (i = 0; i < 3; i++)
      {
        count = -1;
        selected_items (probe->image_id, GLIMS_ITEM_SET_LAYER, out, 8, &count);
        selected_items (probe->image_id, GLIMS_ITEM_SET_CHANNEL, out, 8, &count);
        selected_items (probe->image_id, GLIMS_ITEM_SET_PATH, out, 8, &count);
      }
    {
      EngineState s1 = capture_state (image);
      GlimsItemID nat_after[8] = {0};
      int n_after = native_selected (image, GLIMS_ITEM_SET_LAYER, nat_after, 8);
      CHECK (s1.undo == s0.undo && s1.redo == s0.redo && s1.dirty == s0.dirty,
             "[read invariants] reads changed no undo/redo/dirty");
      CHECK (n_after == n_before && memcmp (nat_after, nat_before, sizeof nat_before) == 0,
             "[read invariants] reads changed no selection");
    }
  }

  /* Quick Mask is an actual attached channel while enabled. It is distinct
   * from the image selection mask and per-layer masks refused above. */
  {
    GlimsImageID quick_image = 0;
    GlimsQuickMaskState quick = {0};
    status = api->image_new (engine, 8, 8, &quick_image, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "[quick mask] image created");
    if (error) { api->free_string(error); error=NULL; }
    status = api->image_set_quick_mask (engine, quick_image, true, &error);
    CHECK (status == GLIMS_STATUS_OK, "[quick mask] fixture enabled");
    if (error) { api->free_string(error); error=NULL; }
    CHECK (api->image_quick_mask(engine,quick_image,&quick)==GLIMS_STATUS_OK && quick.enabled && quick.channel>0,
           "[quick mask] enabled mask exposes its attached channel ID");
    EngineState quick_before = capture_state(glims_lookup_image(engine,quick_image)->image);
    status = sel_items(quick_image,GLIMS_ITEM_SET_CHANNEL,&quick.channel,1,&error);
    CHECK (status==GLIMS_STATUS_OK,"[quick mask] the attached channel is selectable");
    if (error) { api->free_string(error); error=NULL; }
    count=-1;
    CHECK (selected_items(quick_image,GLIMS_ITEM_SET_CHANNEL,out,8,&count)==GLIMS_STATUS_OK
           && count==1 && out[0]==quick.channel,"[quick mask] exact channel readback");
    EngineState quick_after = capture_state(glims_lookup_image(engine,quick_image)->image);
    CHECK (quick_before.undo==quick_after.undo && quick_before.redo==quick_after.redo
           && quick_before.dirty==quick_after.dirty,"[quick mask] selection changes no Undo or dirty state");
    CHECK (api->image_close(engine,quick_image)==GLIMS_STATUS_OK,"[quick mask] fixture closes");
  }

  /* ---------- teardown ---------------------------------------------------- */

  CHECK (api->image_close (engine, probe->image_id) == GLIMS_STATUS_OK, "[teardown] image closed");
  CHECK (api->image_close (engine, probe->other_id) == GLIMS_STATUS_OK, "[teardown] second image closed");

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
  memset (&config, 0, sizeof config);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = on_event;
  config.event_context   = &probe;

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

  printf ("item-select-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n", probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return (status == GLIMS_STATUS_OK && probe.failures == 0) ? 0 : 1;
}
