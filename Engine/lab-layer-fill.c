#include "lab-layer-fill.h"
#include "lab-layer-paint.h"
#include "lab-layer-storage.h"
#include <string.h>

#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpprogress.h"

static gboolean
engine_stopping (GlimsEngine *engine)
{
  g_mutex_lock (&engine->lock);
  gboolean stopping = engine->stopping;
  g_mutex_unlock (&engine->lock);
  return stopping;
}

typedef struct {
  GlimsEngine *engine;
  GlimsProgress *progress;
  guint64 completed, total;
  gint64 last_service;
  gboolean cancelled;
} FillProgress;

static void
cancel_fill (GimpProgress *progress, gpointer data)
{
  (void)progress;
  ((FillProgress *)data)->cancelled = TRUE;
}

static gboolean
continue_fill (FillProgress *state)
{
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND || state->completed == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress), (double)state->completed / state->total);
      for (guint i = 0; i < 4; i++)
        {
          if (!g_main_context_iteration (NULL, FALSE)) break;
          if (g_get_monotonic_time () - now >= 5 * G_TIME_SPAN_MILLISECOND) break;
        }
      state->last_service = g_get_monotonic_time ();
    }
  return !state->cancelled && !engine_stopping (state->engine);
}

GlimsStatus
glims_lab_layer_fill (GlimsEngine *engine, GimpImage *image, GimpLayer *root,
                      double lightness, double a, double b, double opacity,
                      gboolean *changed, char **error)
{
  if (changed) *changed = FALSE;
  if (error) *error = NULL;
  if (!engine || !engine->gimp || !engine->strokes || !engine->filters ||
      !image || !GIMP_IS_IMAGE (image) || image->gimp != engine->gimp ||
      !root || !GIMP_IS_LAYER (root) || !changed)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  const uint8_t *empty_input[4] = { NULL, NULL, NULL, NULL };
  uint8_t *empty_output[4] = { NULL, NULL, NULL, NULL };
  bool ignored = false;
  if (!glims_lab_layer_paint_row (0, empty_input, NULL, lightness, a, b,
                                  opacity, empty_output, &ignored))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (engine->busy || engine->progress || g_hash_table_size (engine->strokes) || g_hash_table_size (engine->filters) ||
      !gimp_image_undo_is_enabled (image) || gimp_image_get_undo_group_count (image))
    return GLIMS_STATUS_BUSY;
  g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
  if (!storage) return GLIMS_STATUS_FAILED;
  if (glims_lab_layer_storage_read (image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return GLIMS_STATUS_UNSUPPORTED;
  guint index = 0;
  for (; index < storage->map.count; index++)
    if (storage->layers[index].group == root) break;
  if (index == storage->map.count) return GLIMS_STATUS_UNSUPPORTED;
  GList *selected = gimp_image_get_selected_layers (image);
  if (!selected || selected->next || selected->data != root)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (engine_stopping (engine)) return GLIMS_STATUS_CANCELLED;
  if (opacity == 0) return GLIMS_STATUS_OK;

  GeglRectangle region = { 0, 0, 0, 0 };
  if (!gimp_item_mask_intersect (GIMP_ITEM (root), &region.x, &region.y,
                                 &region.width, &region.height))
    return GLIMS_STATUS_OK;
  GimpChannel *selection = gimp_image_get_mask (image);
  if (!selection) return GLIMS_STATUS_FAILED;
  gboolean masked = !gimp_channel_is_empty (selection);
  GeglBuffer *source[4] = { NULL }, *candidate[4] = { NULL }, *mask = NULL, *live_mask = NULL;
  GimpDrawable *planes[4] = { NULL };
  g_autofree GlimsLabLayerStorage *current = NULL;
  GlimsStatus status = GLIMS_STATUS_FAILED;
  FillProgress progress = { .engine = engine, .total = (guint64)region.width * region.height };
  gulong cancel_handler = 0;
  engine->busy++;
  g_object_ref (image);
  g_object_ref (root);
  g_object_ref (selection);
  for (guint role = 0; role < 4; role++)
    {
      planes[role] = g_object_ref (GIMP_DRAWABLE (storage->layers[index].planes[role]));
      GeglBuffer *native = gimp_drawable_get_buffer (planes[role]);
      if (!native) goto done;
      source[role] = g_object_ref (native);
      candidate[role] = gegl_buffer_dup (source[role]);
      if (!candidate[role]) goto done;
    }
  if (masked)
    {
      GeglBuffer *native_mask = gimp_drawable_get_buffer (GIMP_DRAWABLE (selection));
      if (!native_mask) goto done;
      live_mask = g_object_ref (native_mask);
      mask = gegl_buffer_dup (native_mask);
      if (!mask) goto done;
    }
  progress.progress = glims_progress_new (engine);
  if (!progress.progress) goto done;
  engine->progress = progress.progress;
  cancel_handler = g_signal_connect (progress.progress, "cancel", G_CALLBACK (cancel_fill), &progress);
  gimp_progress_start (GIMP_PROGRESS (progress.progress), TRUE, "%s", "Fill Lab Layer");
  gboolean any = FALSE;
  GeglRectangle damage = { 0, 0, 0, 0 };
  uint8_t input[4][GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  uint8_t output[4][GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  float coverage[GLIMS_LAB_LAYER_PAINT_MAX_WIDTH];
  for (gint y = region.y; y < region.y + region.height; y++)
    for (gint x = region.x; x < region.x + region.width; )
      {
        if (!continue_fill (&progress)) { status = GLIMS_STATUS_CANCELLED; goto done; }
        gint count = MIN ((gint)GLIMS_LAB_LAYER_PAINT_MAX_WIDTH, region.x + region.width - x);
        GeglRectangle row = { x, y, count, 1 };
        const uint8_t *in[4]; uint8_t *out[4];
        for (guint role = 0; role < 4; role++)
          {
            gegl_buffer_get (source[role], &row, 1, gegl_buffer_get_format (source[role]),
                             input[role], GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
            in[role] = input[role]; out[role] = output[role];
          }
        if (mask)
          gegl_buffer_get (mask, &row, 1, babl_format ("Y float"), coverage,
                           GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        bool row_changed = false;
        if (!glims_lab_layer_paint_row ((size_t)count, in, mask ? coverage : NULL,
                                        lightness, a, b, opacity, out, &row_changed))
          { status = GLIMS_STATUS_INVALID_ARGUMENT; goto done; }
        if (row_changed)
          {
            for (guint role = 0; role < 4; role++)
              gegl_buffer_set (candidate[role], &row, 0, gegl_buffer_get_format (source[role]),
                               output[role], GEGL_AUTO_ROWSTRIDE);
            if (any) gegl_rectangle_bounding_box (&damage, &damage, &row);
            else damage = row;
            any = TRUE;
          }
        progress.completed += count;
        x += count;
      }
  if (!continue_fill (&progress)) { status = GLIMS_STATUS_CANCELLED; goto done; }
  /* Nested progress callbacks may have requested shutdown or disturbed a
   * target. Validate the original map, root, planes and selection again
   * immediately before the non-yielding Undo/publication transaction. */
  current = g_try_new0 (GlimsLabLayerStorage, 1);
  if (!current) goto done;
  if (glims_lab_layer_storage_read (image, current) != GLIMS_LAB_LAYER_STORAGE_VALID ||
      memcmp (&current->map, &storage->map, sizeof current->map) || index >= current->map.count ||
      current->layers[index].group != root || gimp_image_get_mask (image) != selection ||
      gimp_channel_is_empty (selection) == masked ||
      (masked && gimp_drawable_get_buffer (GIMP_DRAWABLE (selection)) != live_mask))
    { status = GLIMS_STATUS_INVALID_ARGUMENT; goto done; }
  selected = gimp_image_get_selected_layers (image);
  if (!selected || selected->next || selected->data != root)
    { status = GLIMS_STATUS_INVALID_ARGUMENT; goto done; }
  for (guint role = 0; role < 4; role++)
    if (GIMP_DRAWABLE (current->layers[index].planes[role]) != planes[role] ||
        gimp_drawable_get_buffer (planes[role]) != source[role])
      { status = GLIMS_STATUS_INVALID_ARGUMENT; goto done; }
  if (!gimp_image_undo_is_enabled (image) || gimp_image_get_undo_group_count (image))
    { status = GLIMS_STATUS_BUSY; goto done; }
  if (!any) { status = GLIMS_STATUS_OK; goto done; }
  if (!gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_PAINT, "Fill Lab Layer"))
    { status = GLIMS_STATUS_FAILED; goto done; }
  for (guint role = 0; role < 4; role++)
    gimp_drawable_push_undo (planes[role], "Fill Lab Layer", NULL,
                             damage.x, damage.y, damage.width, damage.height);
  for (guint role = 0; role < 4; role++)
    {
      gegl_buffer_copy (candidate[role], &damage, GEGL_ABYSS_NONE, source[role], &damage);
      gimp_drawable_update (planes[role], damage.x, damage.y, damage.width, damage.height);
    }
  if (!gimp_image_undo_group_end (image))
    { if (error) *error = g_strdup ("The Lab fill could not finish its Undo group; pixels may have changed."); goto done; }
  gimp_image_flush (image);
  glims_emit (engine, GLIMS_EVENT_PROJECTION_CHANGED, image, &damage, NULL);
  *changed = TRUE;
  status = GLIMS_STATUS_OK;
done:
  if (progress.progress)
    {
      if (cancel_handler) g_signal_handler_disconnect (progress.progress, cancel_handler);
      gimp_progress_end (GIMP_PROGRESS (progress.progress));
      if (engine->progress == progress.progress) engine->progress = NULL;
      g_object_unref (progress.progress);
    }
  g_clear_object (&live_mask);
  g_clear_object (&mask);
  for (guint role = 0; role < 4; role++)
    {
      g_clear_object (&candidate[role]);
      g_clear_object (&source[role]);
      g_clear_object (&planes[role]);
    }
  engine->busy--;
  g_object_unref (selection);
  g_object_unref (root);
  g_object_unref (image);
  return status;
}
