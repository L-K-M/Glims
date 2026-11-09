/*
 * layer-duplicate-prepare-tests.c — deterministic standalone harness for
 * Engine/layer-duplicate-prepare.c.
 *
 *   layer-duplicate-prepare-tests WORK_DIR
 *
 * Native core only: links the adapter objects and GIMP's gimp-console
 * objects directly, includes Engine/engine-private.h, and runs the whole
 * body on the engine thread through one glims_engine_call(). No GUI.
 */
#include "engine-private.h"
#include "layer-duplicate-prepare.h"

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "core/core-enums.h"
#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpdrawable-fill.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimpundostack.h"

#include "gegl-buffer.h"
#include "babl/babl.h"

int main (int argc, char **argv);

static const GlimsEngineAPI *api;
static int failures;

#define CHECK(cond, ...)                                           \
  do {                                                             \
    if (cond)                                                      \
      printf ("ok    ");                                           \
    else                                                           \
      {                                                            \
        printf ("FAIL  ");                                         \
        failures++;                                                \
      }                                                            \
    printf (__VA_ARGS__);                                          \
    printf ("\n");                                                 \
    fflush (stdout);                                               \
  } while (0)

#define FIXTURE(cond, ...)                                         \
  do {                                                             \
    if (!(cond))                                                   \
      {                                                            \
        printf ("FIXTURE-FAIL  ");                                 \
        printf (__VA_ARGS__);                                      \
        printf ("\n");                                             \
        fflush (stdout);                                           \
        failures++;                                                \
        return GLIMS_STATUS_FAILED;                                \
      }                                                            \
  } while (0)

static void
on_event (void *context, const GlimsEvent *event)
{
  (void) context;
  (void) event;
}

static void
paint_layer (Gimp *gimp, GimpLayer *layer, double r, double g, double b)
{
  GimpContext *ctx = gimp_context_new (gimp, "layer-duplicate-prepare-test",
                                       gimp_get_user_context (gimp));
  GeglColor *color = gegl_color_new (NULL);

  gegl_color_set_rgba_with_space (color, r, g, b, 1.0, NULL);
  gimp_context_set_foreground (ctx, color);
  g_object_unref (color);
  gimp_drawable_fill (GIMP_DRAWABLE (layer), ctx, GIMP_FILL_FOREGROUND);
  g_object_unref (ctx);
}

static void
layer_pixel (GimpLayer *layer, unsigned char out[4])
{
  GeglBuffer *buffer = gimp_drawable_get_buffer (GIMP_DRAWABLE (layer));
  const Babl *format = babl_format ("R'G'B'A u8");

  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, 1, 1), 1.0, format, out,
                   GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
}

/* Independent full-image fingerprint, captured around EVERY planner call.
 * Includes native tree/parent/index, names, all layer pixels and properties,
 * selected IDs and public image/Undo facts. Detached clone IDs never enter it. */
static char *
fingerprint (GlimsEngine *engine, GlimsImageID id)
{
  GimpImage *image = glims_lookup_image (engine, id)->image;
  GlimsImageInfo info = {0}; GlimsUndoInfo undo = {0};
  GList *layers = gimp_image_get_layer_list (image), *iter;
  GString *value = g_string_new (NULL);
  api->image_info (engine, id, &info); api->image_undo_info (engine, id, &undo);
  g_string_append_len (value, (const char *) &info, sizeof info);
  g_string_append_len (value, (const char *) &undo, sizeof undo);
  for (iter = layers; iter; iter = iter->next) {
    GimpLayer *layer = iter->data, *parent = gimp_layer_get_parent (layer);
    GimpItem *item = GIMP_ITEM (layer);
    gint width = gimp_item_get_width (item), height = gimp_item_get_height (item), x, y;
    gsize size = (gsize) width * height * 4;
    guchar *pixels = g_malloc (size);
    char *hash;
    gimp_item_get_offset (item, &x, &y);
    gegl_buffer_get (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), GEGL_RECTANGLE (0, 0, width, height),
                     1, babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, pixels, size);
    g_string_append_printf (value, "%d/%d/%d:%s:%d,%d,%d,%d:%.17g:%d,%d,%d,%d:%s;",
      gimp_item_get_id (item), parent ? gimp_item_get_id (GIMP_ITEM (parent)) : 0,
      gimp_item_get_index (item), gimp_object_get_name (layer), width, height, x, y,
      gimp_layer_get_opacity (layer), gimp_item_get_visible (item), gimp_item_get_lock_content (item),
      gimp_item_get_lock_position (item), gimp_layer_get_lock_alpha (layer), hash);
    g_free (hash); g_free (pixels);
  }
  g_list_free (layers);
  g_string_append (value, "selected:");
  for (iter = gimp_image_get_selected_layers (image); iter; iter = iter->next)
    g_string_append_printf (value, "%d,", gimp_item_get_id (GIMP_ITEM (iter->data)));
  /* Hash the binary prefix as well as the textual tree; binary structs can
   * contain NUL bytes and must never be compared using strcmp. */
  {
    char *hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) value->str, value->len);
    g_string_free (value, TRUE);
    return hash;
  }
}

static char *
layer_digest (GimpLayer *layer)
{
  gint width = gimp_item_get_width (GIMP_ITEM (layer)), height = gimp_item_get_height (GIMP_ITEM (layer));
  gsize size = (gsize) width * height * 4;
  guchar *pixels = g_malloc (size);
  char *hash;
  gegl_buffer_get (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), GEGL_RECTANGLE (0, 0, width, height),
                   1, babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  hash = g_compute_checksum_for_data (G_CHECKSUM_SHA256, pixels, size);
  g_free (pixels);
  return hash;
}

static GlimsStatus
checked_prepare (GlimsEngine *engine, GlimsImageID id, const GlimsItemID *ids, size_t count,
                 GlimsLayerDuplicatePlan **out, char **error)
{
  char *before = fingerprint (engine, id), *after;
  GlimsStatus result = glims_layer_duplicate_prepare (engine, id, ids, count, out, error);
  after = fingerprint (engine, id);
  CHECK (!strcmp (before, after), "planner status %d preserves full native image/tree/selection/pixels/history", result);
  if (result != GLIMS_STATUS_OK) CHECK (!out || !*out, "every refusal zeros its owned-plan output");
  g_free (before); g_free (after);
  return result;
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer data)
{
  GlimsImageID image_id = 0;
  GlimsImageID other_id = 0;
  GimpImage *image = NULL;
  GimpImage *other = NULL;
  char *error = NULL;
  GlimsStatus status;
  GimpLayer *group = NULL;
  GimpLayer *layer_a = NULL;
  GimpLayer *layer_c = NULL;
  GimpLayer *other_layer = NULL;
  GlimsItemID id_a, id_c, id_g;
  GlimsItemID foreign_id = 0;
  unsigned char known_a[4], known_c[4];
  GList *orig_layers = NULL;
  GList *orig_selected = NULL;
  gint orig_layer_count = 0;
  gint orig_selected_count = 0;
  GlimsItemID orig_layer_ids[32];
  GlimsItemID orig_selected_ids[32];
  GlimsImageInfo info_before = {0}, info_after = {0};
  GlimsUndoInfo undo_before = {0}, undo_after = {0};
  gboolean dirty_before;
  int i;
  GlimsItemID sources[3];
  GlimsLayerDuplicatePlan *plan = NULL;
  GWeakRef copy_refs[2];
  int weak_count = 0;
  char *initial_fingerprint = NULL;

  (void) data;

  status = api->image_new (engine, 64, 64, &image_id, &error);
  FIXTURE (status == GLIMS_STATUS_OK, "image_new: %s", error ? error : "?");
  if (error) { api->free_string (error); error = NULL; }
  image = glims_lookup_image (engine, image_id)->image;

  group = gimp_group_layer_new (image);
  FIXTURE (group != NULL && gimp_image_add_layer (image, group, NULL, -1, TRUE),
           "group layer");
  gimp_object_set_name (GIMP_OBJECT (group), "G");

  layer_a = gimp_layer_new (image, 32, 32,
                            gimp_image_get_layer_format (image, TRUE),
                            "A", GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL);
  FIXTURE (layer_a != NULL &&
           gimp_image_add_layer (image, layer_a, group, -1, TRUE),
           "layer A");
  paint_layer (engine->gimp, layer_a, 1.0, 0.0, 0.0);
  gimp_item_set_offset (GIMP_ITEM (layer_a), 4, 6);
  gimp_layer_set_opacity (layer_a, 0.75, FALSE);
  gimp_item_set_lock_content (GIMP_ITEM (layer_a), TRUE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (layer_a), FALSE, FALSE);
  gimp_layer_set_lock_alpha (layer_a, TRUE, FALSE);

  layer_c = gimp_layer_new (image, 16, 16,
                            gimp_image_get_layer_format (image, TRUE),
                            "C", GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL);
  FIXTURE (layer_c != NULL &&
           gimp_image_add_layer (image, layer_c, NULL, -1, TRUE),
           "layer C");
  paint_layer (engine->gimp, layer_c, 0.0, 0.0, 1.0);
  gimp_item_set_offset (GIMP_ITEM (layer_c), 10, 12);
  gimp_layer_set_opacity (layer_c, 0.5, FALSE);
  gimp_item_set_lock_content (GIMP_ITEM (layer_c), FALSE, FALSE);
  gimp_item_set_lock_position (GIMP_ITEM (layer_c), TRUE, FALSE);
  gimp_layer_set_lock_alpha (layer_c, FALSE, FALSE);

  gimp_image_flush (image);

  id_a = gimp_item_get_id (GIMP_ITEM (layer_a));
  id_c = gimp_item_get_id (GIMP_ITEM (layer_c));
  id_g = gimp_item_get_id (GIMP_ITEM (group));

  layer_pixel (layer_a, known_a);
  layer_pixel (layer_c, known_c);

  /* Capture original tree. */
  orig_layers = gimp_image_get_layer_list (image);
  orig_layer_count = (gint) g_list_length (orig_layers);
  for (i = 0; i < orig_layer_count && i < 32; i++)
    orig_layer_ids[i] = gimp_item_get_id (GIMP_ITEM (g_list_nth_data (orig_layers, i)));
  orig_selected = gimp_image_get_selected_layers (image);
  orig_selected_count = (gint) g_list_length (orig_selected);
  for (i = 0; i < orig_selected_count && i < 32; i++)
    orig_selected_ids[i] = gimp_item_get_id (GIMP_ITEM (g_list_nth_data (orig_selected, i)));

  api->image_info (engine, image_id, &info_before);
  api->image_undo_info (engine, image_id, &undo_before);
  dirty_before = gimp_image_is_dirty (image);

  CHECK (known_a[0] == 255 && known_a[1] == 0 && known_a[2] == 0 && known_a[3] == 255 &&
         known_c[0] == 0 && known_c[1] == 0 && known_c[2] == 255 && known_c[3] == 255,
         "independent source colors are opaque red and blue");

  initial_fingerprint = fingerprint (engine, image_id);
  /* Valid prepare: reverse input order [C, A]. */
  sources[0] = id_c;
  sources[1] = id_a;
  status = checked_prepare (engine, image_id, sources, 2, &plan, &error);
  CHECK (status == GLIMS_STATUS_OK && plan != NULL,
         "valid prepare returns OK with a plan");
  if (error) { api->free_string (error); error = NULL; }

  CHECK (plan != NULL && plan->sources != NULL && plan->copies != NULL &&
         plan->sources->len == 2 && plan->copies->len == 2,
         "plan has two sources and two copies");

  if (plan && plan->sources && plan->copies && plan->sources->len == 2 && plan->copies->len == 2)
    {
      for (i = 0; i < 2; i++)
        {
          GimpLayer *src = GIMP_LAYER (g_ptr_array_index (plan->sources, i));
          CHECK (gimp_item_get_id (GIMP_ITEM (src)) == sources[i],
                 "source %d matches input order", i);
        }

      for (i = 0; i < 2; i++)
        {
          GimpLayer *src = GIMP_LAYER (g_ptr_array_index (plan->sources, i));
          GimpLayer *copy = GIMP_LAYER (g_ptr_array_index (plan->copies, i));
          unsigned char src_px[4], copy_px[4];
          gint sx, sy, cx, cy;
          char *source_hash = layer_digest (src), *copy_hash = layer_digest (copy);
          CHECK (!strcmp (source_hash, copy_hash), "copy %d preserves every native layer pixel", i);
          g_free (source_hash); g_free (copy_hash);

          CHECK (copy != src, "copy %d is a new object", i);
          CHECK (gimp_item_get_id (GIMP_ITEM (copy)) != gimp_item_get_id (GIMP_ITEM (src)),
                 "copy %d has a new id", i);
          CHECK (!gimp_item_is_attached (GIMP_ITEM (copy)),
                 "copy %d is unattached", i);
          CHECK (gimp_item_get_image (GIMP_ITEM (copy)) == image,
                 "copy %d belongs to the same image", i);
          CHECK (G_OBJECT_TYPE (copy) == G_OBJECT_TYPE (src),
                 "copy %d has the exact source type", i);

          layer_pixel (src, src_px);
          layer_pixel (copy, copy_px);
          CHECK (memcmp (src_px, copy_px, 4) == 0,
                 "copy %d pixels match its source", i);

          gimp_item_get_offset (GIMP_ITEM (src), &sx, &sy);
          gimp_item_get_offset (GIMP_ITEM (copy), &cx, &cy);
          CHECK (sx == cx && sy == cy, "copy %d offsets match its source", i);

          CHECK (fabs (gimp_layer_get_opacity (src) - gimp_layer_get_opacity (copy)) < 1e-9,
                 "copy %d opacity matches its source", i);

          CHECK (gimp_item_get_lock_content (GIMP_ITEM (src)) ==
                 gimp_item_get_lock_content (GIMP_ITEM (copy)) &&
                 gimp_item_get_lock_position (GIMP_ITEM (src)) ==
                 gimp_item_get_lock_position (GIMP_ITEM (copy)) &&
                 gimp_layer_get_lock_alpha (src) == gimp_layer_get_lock_alpha (copy),
                 "copy %d locks match its source", i);

          g_weak_ref_init (&copy_refs[i], copy);
          weak_count++;
        }
    }

  /* State unchanged before free. */
  {
    GList *now = gimp_image_get_layer_list (image);
    CHECK ((gint) g_list_length (now) == orig_layer_count,
           "layer count unchanged before free");
    for (i = 0; i < orig_layer_count && i < 32; i++)
      CHECK (gimp_item_get_id (GIMP_ITEM (g_list_nth_data (now, i))) == orig_layer_ids[i],
             "layer order unchanged before free (%d)", i);
    g_list_free (now);
  }
  api->image_info (engine, image_id, &info_after);
  CHECK (memcmp (&info_before, &info_after, sizeof info_before) == 0,
         "image info unchanged before free");
  api->image_undo_info (engine, image_id, &undo_after);
  CHECK (memcmp (&undo_before, &undo_after, sizeof undo_before) == 0,
         "undo info unchanged before free");
  CHECK (dirty_before == gimp_image_is_dirty (image), "dirty unchanged before free");

  /* Free the plan and verify clones finalize. */
  glims_layer_duplicate_plan_free (plan);
  plan = NULL;

  for (i = 0; i < weak_count; i++)
    {
      gpointer alive = g_weak_ref_get (&copy_refs[i]);

      CHECK (alive == NULL, "copy %d finalized after plan_free", i);
      if (alive)
        g_object_unref (alive);
      g_weak_ref_clear (&copy_refs[i]);
    }

  {
    char *after_free = fingerprint (engine, image_id);
    CHECK (!strcmp (initial_fingerprint, after_free), "freeing the complete plan preserves every original pixel, property, tree, selection and history fact");
    g_free (initial_fingerprint); g_free (after_free);
  }
  /* State unchanged after free. */
  {
    GList *now = gimp_image_get_layer_list (image);
    CHECK ((gint) g_list_length (now) == orig_layer_count,
           "layer count unchanged after free");
    for (i = 0; i < orig_layer_count && i < 32; i++)
      CHECK (gimp_item_get_id (GIMP_ITEM (g_list_nth_data (now, i))) == orig_layer_ids[i],
             "layer order unchanged after free (%d)", i);
    g_list_free (now);
  }
  {
    GList *now = gimp_image_get_selected_layers (image);
    CHECK ((gint) g_list_length (now) == orig_selected_count,
           "selection count unchanged after free");
    for (i = 0; i < orig_selected_count && i < 32; i++)
      CHECK (gimp_item_get_id (GIMP_ITEM (g_list_nth_data (now, i))) == orig_selected_ids[i],
             "selection unchanged after free (%d)", i);
  }
  api->image_info (engine, image_id, &info_after);
  CHECK (memcmp (&info_before, &info_after, sizeof info_before) == 0,
         "image info unchanged after free");
  api->image_undo_info (engine, image_id, &undo_after);
  CHECK (memcmp (&undo_before, &undo_after, sizeof undo_before) == 0,
         "undo info unchanged after free");
  CHECK (dirty_before == gimp_image_is_dirty (image), "dirty unchanged after free");

  {
    unsigned char now_a[4], now_c[4];

    layer_pixel (layer_a, now_a);
    layer_pixel (layer_c, now_c);
    CHECK (memcmp (now_a, known_a, 4) == 0, "layer A pixels unchanged");
    CHECK (memcmp (now_c, known_c, 4) == 0, "layer C pixels unchanged");
  }

  /* Error cases. */
  {
    GlimsLayerDuplicatePlan *outp = NULL;

    status = checked_prepare (engine, image_id, NULL, 1, NULL, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT,
           "NULL out is INVALID");
    if (error) { api->free_string (error); error = NULL; }

    status = checked_prepare (engine, image_id, sources, 0, &outp, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && outp == NULL,
           "count 0 is INVALID");
    if (error) { api->free_string (error); error = NULL; }

    {
      status = checked_prepare (engine, image_id, (const GlimsItemID *) 1, 257, &outp, &error);
      CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && outp == NULL,
             "count > 256 is INVALID");
      if (error) { api->free_string (error); error = NULL; }
    }

    status = checked_prepare (engine, image_id, NULL, 1, &outp, &error);
    CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && outp == NULL,
           "NULL sources with count > 0 is INVALID");
    if (error) { api->free_string (error); error = NULL; }

    {
      GlimsItemID zero[1] = { 0 };
      status = checked_prepare (engine, image_id, zero, 1, &outp, &error);
      CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && outp == NULL,
             "id 0 is INVALID");
      if (error) { api->free_string (error); error = NULL; }
    }

    {
      GlimsItemID dup[2] = { id_a, id_a };
      status = checked_prepare (engine, image_id, dup, 2, &outp, &error);
      CHECK (status == GLIMS_STATUS_INVALID_ARGUMENT && outp == NULL,
             "duplicate positive ids are INVALID");
      if (error) { api->free_string (error); error = NULL; }
    }

    {
      GlimsItemID middle[] = { id_a, gimp_item_get_id (GIMP_ITEM (gimp_image_get_mask (image))), id_c };
      status = checked_prepare (engine, image_id, middle, 3, &outp, &error);
      CHECK (status == GLIMS_STATUS_NOT_FOUND && !outp, "an actual native non-layer channel in the middle refuses");
      g_clear_pointer (&error, g_free);
      engine->busy++;
      status = checked_prepare (engine, image_id, sources, 2, &outp, &error);
      engine->busy--;
      CHECK (status == GLIMS_STATUS_BUSY && !outp, "engine-exclusive work refuses the complete batch");
      g_clear_pointer (&error, g_free);
    }

    /* Group source: UNSUPPORTED. */
    {
      GlimsItemID grp[1] = { id_g };
      status = checked_prepare (engine, image_id, grp, 1, &outp, &error);
      CHECK (status == GLIMS_STATUS_UNSUPPORTED && outp == NULL,
             "group source is UNSUPPORTED");
      if (error) { api->free_string (error); error = NULL; }
    }

    /* Group in the middle: UNSUPPORTED. */
    {
      GlimsItemID mid[3] = { id_a, id_g, id_c };
      status = checked_prepare (engine, image_id, mid, 3, &outp, &error);
      CHECK (status == GLIMS_STATUS_UNSUPPORTED && outp == NULL,
             "group in the middle is UNSUPPORTED");
      if (error) { api->free_string (error); error = NULL; }
    }

    /* Unknown positive (non-layer) id: NOT_FOUND. */
    {
      GlimsItemID mid[3] = { id_a, 999999, id_c };
      status = checked_prepare (engine, image_id, mid, 3, &outp, &error);
      CHECK (status == GLIMS_STATUS_NOT_FOUND && outp == NULL,
             "unknown id in the middle is NOT_FOUND");
      if (error) { api->free_string (error); error = NULL; }
    }

    /* Foreign id from another image. */
    status = api->image_new (engine, 16, 16, &other_id, &error);
    FIXTURE (status == GLIMS_STATUS_OK, "other image_new: %s", error ? error : "?");
    if (error) { api->free_string (error); error = NULL; }
    other = glims_lookup_image (engine, other_id)->image;
    other_layer = gimp_layer_new (other, 8, 8,
                                 gimp_image_get_layer_format (other, TRUE),
                                 "Foreign", GIMP_OPACITY_OPAQUE,
                                 GIMP_LAYER_MODE_NORMAL);
    FIXTURE (other_layer != NULL &&
             gimp_image_add_layer (other, other_layer, NULL, -1, TRUE),
             "foreign layer");
    foreign_id = gimp_item_get_id (GIMP_ITEM (other_layer));
    gimp_image_flush (other);

    {
      GlimsItemID fsrc[1] = { foreign_id };
      status = checked_prepare (engine, image_id, fsrc, 1, &outp, &error);
      CHECK (status == GLIMS_STATUS_NOT_FOUND && outp == NULL,
             "foreign id is NOT_FOUND");
      if (error) { api->free_string (error); error = NULL; }
    }

    /* Dead id after closing the other image. */
    status = api->image_close (engine, other_id);
    CHECK (status == GLIMS_STATUS_OK, "close other image");
    other_id = 0;
    other = NULL;
    {
      GlimsItemID dsrc[1] = { foreign_id };
      status = checked_prepare (engine, image_id, dsrc, 1, &outp, &error);
      CHECK (status == GLIMS_STATUS_NOT_FOUND && outp == NULL,
             "dead id is NOT_FOUND");
      if (error) { api->free_string (error); error = NULL; }
    }

    /* Undo freeze/disable -> BUSY. */
    {
      GlimsItemID s[1] = { id_a };
      GlimsLayerDuplicatePlan *p = NULL;

      gimp_image_undo_freeze (image);
      status = checked_prepare (engine, image_id, s, 1, &p, &error);
      CHECK (status == GLIMS_STATUS_BUSY && p == NULL,
             "frozen undo is BUSY");
      if (error) { api->free_string (error); error = NULL; }
      gimp_image_undo_thaw (image);

      gimp_image_undo_disable (image);
      status = checked_prepare (engine, image_id, s, 1, &p, &error);
      CHECK (status == GLIMS_STATUS_BUSY && p == NULL,
             "disabled undo is BUSY");
      if (error) { api->free_string (error); error = NULL; }
      gimp_image_undo_thaw (image);
    }

    /* Engine busy via an open stroke. */
    {
      GlimsBrushSettings brush = { .struct_size = sizeof (GlimsBrushSettings),
                                    .size = 4.0, .opacity = 1.0,
                                    .tool = GLIMS_PAINT_PAINTBRUSH,
                                    .hardness = -1.0, .rate = -1.0,
                                    .flow = -1.0, .exposure = -1.0 };
      GlimsStrokePoint first = { 2, 2, 1.0, 0.0, 0.0, 0 };
      GlimsStrokeID stroke = 0;
      GlimsItemID s[1] = { id_a };
      GlimsLayerDuplicatePlan *p = NULL;

      status = api->stroke_begin (engine, image_id, id_c, &brush, &first, &stroke, &error);
      if (status == GLIMS_STATUS_OK)
        {
          status = checked_prepare (engine, image_id, s, 1, &p, &error);
          CHECK (status == GLIMS_STATUS_BUSY && p == NULL,
                 "open stroke is BUSY");
          if (error) { api->free_string (error); error = NULL; }
          api->stroke_end (engine, stroke);
        }
      else
        {
          CHECK (0, "stroke begin for busy check (%s)", error ? error : "");
          if (error) { api->free_string (error); error = NULL; }
        }
    }

    /* Engine busy via a filter preview. */
    {
      GlimsFilterID filter = 0;
      GlimsItemID s[1] = { id_a };
      GlimsLayerDuplicatePlan *p = NULL;

      status = api->filter_begin (engine, image_id, id_c, "gegl:gaussian-blur", &filter, &error);
      if (status == GLIMS_STATUS_OK)
        {
          status = checked_prepare (engine, image_id, s, 1, &p, &error);
          CHECK (status == GLIMS_STATUS_BUSY && p == NULL,
                 "filter preview is BUSY");
          if (error) { api->free_string (error); error = NULL; }
          api->filter_abort (engine, filter);
        }
      else
        {
          CHECK (0, "a real filter preview must start: %s", error ? error : "none");
          if (error) { api->free_string (error); error = NULL; }
        }
    }
  }

  /* Floating selection: not exercised (no facade/core helper in this harness). */

  api->image_close (engine, image_id);
  image_id = 0;
  image = NULL;

  g_list_free (orig_layers);
  orig_layers = NULL;

  return failures != 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine *engine = NULL;
  char work[1024], home_dir[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus status;
  char *error = NULL;

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

  memset (&config, 0, sizeof config);
  config.struct_size = sizeof config;
  config.user_directory = user_dir;
  config.cache_directory = cache_dir;
  config.on_event = on_event;

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

  printf ("layer-duplicate-prepare-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, NULL);
  /* run_all uses data? We passed NULL; but run_all signature data. It doesn't use data. Fine. */
  /* Actually run_all ignores data. */

  api->stop (engine);
  printf ("%s: %d failure%s\n", failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          failures, failures == 1 ? "" : "s");
  return (status == GLIMS_STATUS_OK && failures == 0) ? 0 : 1;
}
