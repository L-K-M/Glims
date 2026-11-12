/* Numeric ink edits stage a complete result before native Undo/publication.
 * No RGB color conversion or native background-color Clear is involved. */
#include "engine-private.h"
#include "plate-storage.h"
#include "component-scalar.h"

#include <math.h>
#include <string.h>
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimpprogress.h"

typedef struct {
  GlimsEngine *engine;
  GlimsProgress *progress;
  guint64 completed, total;
  gint64 last_service;
  gboolean cancelled;
} InkEditProgress;

static void
cancel_edit (GimpProgress *progress, gpointer data)
{
  ((InkEditProgress *) data)->cancelled = TRUE;
}

static gboolean
continue_edit (InkEditProgress *state)
{
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND ||
      state->completed == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress),
                                (double) state->completed / state->total);
      for (guint i = 0; i < 4; i++)
        {
          if (!g_main_context_iteration (NULL, FALSE)) break;
          if (g_get_monotonic_time () - now >= 5 * G_TIME_SPAN_MILLISECOND) break;
        }
      state->last_service = g_get_monotonic_time ();
    }
  g_mutex_lock (&state->engine->lock);
  gboolean stopping = state->engine->stopping;
  g_mutex_unlock (&state->engine->lock);
  return !state->cancelled && !stopping;
}

static GimpDrawable *
selected_ink (GlimsOpenImage *open, GlimsItemID id, const GlimsPlateStorage *storage)
{
  GList *selected = gimp_image_get_selected_channels (open->image);
  if (!id || !selected || selected->next) return NULL;
  for (guint i = 0; i < storage->map.count; i++)
    if (selected->data == storage->planes[i] &&
        gimp_item_get_id (GIMP_ITEM (storage->planes[i])) == id)
      return GIMP_DRAWABLE (storage->planes[i]);
  return NULL;
}

GlimsStatus
glims_image_edit_ink (GlimsEngine *engine, GlimsImageID id, GlimsItemID channel,
                      uint32_t operation, double intensity, double opacity, char **error)
{
  if (error) *error = NULL;
  if (!channel || operation > GLIMS_INK_EDIT_INVERT ||
      !isfinite (intensity) || intensity < 0 || intensity > 1 ||
      !isfinite (opacity) || opacity < 0 || opacity > 1 ||
      (operation == GLIMS_INK_EDIT_CLEAR && (intensity != 1 || opacity != 1)) ||
      (operation == GLIMS_INK_EDIT_INVERT && (intensity != 0 || opacity != 1)))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;

  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open (open, &storage))
    {
      if (error) *error = g_strdup ("Select a native ink document for this command.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  GimpDrawable *target = selected_ink (open, channel, &storage);
  if (!target)
    {
      if (error) *error = g_strdup ("The selected ink changed. Select one ink channel and try again.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (opacity == 0) return GLIMS_STATUS_OK;

  GlimsComponentScalarFormat format;
  switch (storage.map.storage)
    {
    case GLIMS_PLATE_STORAGE_U8: format = GLIMS_COMPONENT_SCALAR_U8; break;
    case GLIMS_PLATE_STORAGE_U16: format = GLIMS_COMPONENT_SCALAR_U16; break;
    case GLIMS_PLATE_STORAGE_FLOAT: format = GLIMS_COMPONENT_SCALAR_FLOAT; break;
    default: return GLIMS_STATUS_UNSUPPORTED;
    }

  GeglRectangle region;
  if (!gimp_item_mask_intersect (GIMP_ITEM (target), &region.x, &region.y,
                                  &region.width, &region.height))
    return GLIMS_STATUS_OK;
  GimpChannel *selection = gimp_image_get_mask (open->image);
  gboolean masked = !gimp_channel_is_empty (selection);
  const char *title = operation == GLIMS_INK_EDIT_FILL ? "Fill Ink" :
                      operation == GLIMS_INK_EDIT_CLEAR ? "Clear Ink" : "Invert Ink";

  /* Own every native object used after dispatch. Busy gates other edits;
   * the candidate and selection snapshot contain no borrowed storage state. */
  engine->busy++;
  GimpImage *image = g_object_ref (open->image);
  g_object_ref (target);
  GeglBuffer *source = g_object_ref (gimp_drawable_get_buffer (target));
  GeglBuffer *candidate = gegl_buffer_dup (source);
  GeglBuffer *mask = masked ? gegl_buffer_dup (gimp_drawable_get_buffer (GIMP_DRAWABLE (selection))) : NULL;
  const Babl *native_format = gegl_buffer_get_format (source);
  InkEditProgress state = { .engine = engine,
    .total = (guint64) region.width * region.height };
  state.progress = glims_progress_new (engine);
  engine->progress = state.progress;
  gulong cancel_handler = g_signal_connect (state.progress, "cancel", G_CALLBACK (cancel_edit), &state);
  gimp_progress_start (GIMP_PROGRESS (state.progress), TRUE, "%s", title);

  /* At most 4096 samples per scalar/selection read. Staged GEGL tiles use
   * copy-on-write and its existing cache/spill policy; no whole-image malloc. */
  uint32_t input[4096], output[4096];
  float coverage[4096];
  gboolean changed = FALSE;
  GeglRectangle damage = { 0, 0, 0, 0 };
  for (gint y = region.y; y < region.y + region.height; y++)
    for (gint x = region.x; x < region.x + region.width; )
      {
        if (!continue_edit (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
        gint count = MIN (4096, region.x + region.width - x);
        GeglRectangle row = { x, y, count, 1 };
        gegl_buffer_get (source, &row, 1, native_format, input,
                          GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        if (mask)
          gegl_buffer_get (mask, &row, 1, babl_format ("Y float"), coverage,
                            GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
        bool row_changed = false;
        if (!glims_component_scalar_row (format,
              operation == GLIMS_INK_EDIT_INVERT ? GLIMS_COMPONENT_SCALAR_INVERT : GLIMS_COMPONENT_SCALAR_FILL,
              intensity, opacity, count, input, mask ? coverage : NULL, output, &row_changed))
          {
            if (error) *error = g_strdup ("The selected ink or selection contains nonfinite or invalid samples. No pixels were changed.");
            status = GLIMS_STATUS_INVALID_ARGUMENT;
            goto finish;
          }
        if (row_changed)
          {
            gegl_buffer_set (candidate, &row, 0, native_format, output, GEGL_AUTO_ROWSTRIDE);
            if (changed) gegl_rectangle_bounding_box (&damage, &damage, &row);
            else damage = row;
            changed = TRUE;
          }
        state.completed += count;
        x += count;
      }

  if (!continue_edit (&state)) { status = GLIMS_STATUS_CANCELLED; goto finish; }
  if (changed)
    {
      /* Re-resolve after nested dispatch, then publish without yielding.
       * The existing native drawable Undo snapshots exact scalar bytes before
       * the copy. Selection is already applied once in the candidate. */
      GlimsOpenImage *current = glims_lookup_image (engine, id);
      GlimsPlateStorage current_storage;
      if (!current || current->image != image ||
          !glims_plate_storage_read_open (current, &current_storage) ||
          selected_ink (current, channel, &current_storage) != target ||
          gimp_drawable_get_buffer (target) != source)
        {
          if (error) *error = g_strdup ("The selected ink changed before the edit could finish.");
          status = GLIMS_STATUS_INVALID_ARGUMENT;
          goto finish;
        }
      status = glims_check_item_locks (GIMP_ITEM (target), GLIMS_LOCK_PIXELS, error);
      if (status != GLIMS_STATUS_OK) goto finish;
      gimp_drawable_push_undo (target, title, NULL, damage.x, damage.y, damage.width, damage.height);
      gegl_buffer_copy (candidate, &damage, GEGL_ABYSS_NONE, source, &damage);
      gimp_drawable_update (target, damage.x, damage.y, damage.width, damage.height);
      gimp_image_flush (image);
    }
  status = GLIMS_STATUS_OK;

finish:
  g_signal_handler_disconnect (state.progress, cancel_handler);
  gimp_progress_end (GIMP_PROGRESS (state.progress));
  engine->progress = NULL;
  g_object_unref (state.progress);
  g_clear_object (&mask);
  g_object_unref (candidate);
  g_object_unref (source);
  g_object_unref (target);
  g_object_unref (image);
  engine->busy--;
  return status;
}
