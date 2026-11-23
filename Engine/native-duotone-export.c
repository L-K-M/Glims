/* Export opaque grayscale with its retained, uninterpreted Duotone settings. */
#include "engine-private.h"
#include "duotone-psd-file.h"
#include "stored-pixels.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "core/gimpimage.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimppickable.h"
#include "core/gimpprogress.h"
#include "core/gimpprojection.h"
#include "gegl/gimp-babl.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "core/gimplinklayer.h"
#endif

typedef struct {
  GlimsEngine *engine;
  GlimsStoredRows rows;         /* the frozen copy's projection */
  GlimsProgress *progress;
  guint depth;
  guint64 samples, total;
  gint64 last_service;
  gboolean cancelled, invalid_pixel;
} DuotoneExport;

static void
duotone_cancel (GimpProgress *progress, gpointer data)
{
  (void) progress;
  ((DuotoneExport *) data)->cancelled = TRUE;
}

static bool
duotone_continue (void *data)
{
  DuotoneExport *state = data;
  gint64 now = g_get_monotonic_time ();
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND ||
      state->samples == state->total)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress),
                               (double) state->samples / state->total);
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

static bool
duotone_read (void *data, uint32_t y, uint32_t x, uint32_t count, uint8_t *samples)
{
  DuotoneExport *state = data;
  glims_stored_rows_read (&state->rows, GEGL_RECTANGLE ((gint) x, (gint) y, (gint) count, 1));
  for (uint32_t i = 0; i < count; i++)
    {
      float value;
      if (!glims_stored_rows_opaque_gray (&state->rows, i, &value))
        { state->invalid_pixel = TRUE; return false; }
      uint32_t sample = (uint32_t) floor ((double) value * (state->depth == 8 ? 255.0 : 65535.0) + 0.5);
      if (state->depth == 8) samples[i] = (uint8_t) sample;
      else { samples[i * 2] = (uint8_t) (sample >> 8); samples[i * 2 + 1] = (uint8_t) sample; }
    }
  state->samples += count;
  return true;
}

static gboolean
duotone_has_link_layer (GimpImage *image)
{
#if GIMP_CHECK_VERSION (3, 2, 0)
  GList *layers = gimp_image_get_layer_list (image);
  gboolean found = FALSE;
  for (GList *it = layers; it && !found; it = it->next)
    found = GIMP_IS_LINK_LAYER (it->data);
  g_list_free (layers);
  return found;
#else
  (void) image;
  return FALSE;
#endif
}

GlimsStatus
glims_image_export_duotone_psd (GlimsEngine *engine, GlimsImageID id,
                                const char *path, char **error)
{
  if (error) *error = NULL;
  if (!path || !g_path_is_absolute (path)) return GLIMS_STATUS_INVALID_ARGUMENT;
  const char *extension = strrchr (path, '.');
  if (!extension || g_ascii_strcasecmp (extension, ".psd"))
    { if (error) *error = strdup ("Duotone export requires a .psd filename."); return GLIMS_STATUS_INVALID_ARGUMENT; }
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy || g_hash_table_size (engine->strokes) || g_hash_table_size (engine->filters))
    return GLIMS_STATUS_BUSY;
  if (open->component_document || gimp_image_get_base_type (open->image) != GIMP_GRAY)
    { if (error) *error = strdup ("Duotone PSD export requires an ordinary grayscale document."); return GLIMS_STATUS_UNSUPPORTED; }
  if (duotone_has_link_layer (open->image))
    { if (error) *error = strdup ("Duotone PSD export cannot safely snapshot linked layers. Remove them from a copy before exporting."); return GLIMS_STATUS_UNSUPPORTED; }
  GimpComponentType component = gimp_babl_component_type (gimp_image_get_precision (open->image));
  if (component != GIMP_COMPONENT_TYPE_U8)
    { if (error) *error = strdup ("Duotone PSD export requires 8-bit grayscale. Convert a copy before exporting."); return GLIMS_STATUS_UNSUPPORTED; }
  const GimpParasite *tag = gimp_image_parasite_find (open->image, "psd-duotone-data");
  guint32 metadata_size = 0;
  const void *metadata = tag ? gimp_parasite_get_data (tag, &metadata_size) : NULL;
  if (!metadata || !metadata_size || metadata_size > GLIMS_DUOTONE_PSD_MAX_METADATA)
    { if (error) *error = strdup ("This document has no usable retained Duotone settings."); return GLIMS_STATUS_UNSUPPORTED; }
  const GimpParasite *alternate = gimp_image_parasite_find (open->image, "psd-image-resource-8BIM-042a");
  const GimpParasite *mesa = gimp_image_parasite_find (open->image, "psd-image-resource-MeSa-042a");
  if (alternate && mesa)
    { if (error) *error = strdup ("This document has conflicting Duotone alternate-color resources."); return GLIMS_STATUS_UNSUPPORTED; }
  guint32 alternate_size = 0;
  const void *alternate_data = (alternate || mesa) ? gimp_parasite_get_data (alternate ? alternate : mesa, &alternate_size) : NULL;
  if ((alternate || mesa) && (!alternate_data || !alternate_size || alternate_size > GLIMS_DUOTONE_PSD_MAX_METADATA))
    { if (error) *error = strdup ("This document has unusable Duotone alternate-color data."); return GLIMS_STATUS_UNSUPPORTED; }
  g_autoptr(GBytes) alternate_bytes = alternate_data ? g_bytes_new (alternate_data, alternate_size) : NULL;
  GBytes *bytes = g_bytes_new (metadata, metadata_size);
  GlimsDuotonePsdSpec spec = { .width = (uint32_t) gimp_image_get_width (open->image),
    .height = (uint32_t) gimp_image_get_height (open->image), .depth = 8u,
    .metadata = g_bytes_get_data (bytes, NULL), .metadata_size = metadata_size,
    .alternate = alternate_bytes ? g_bytes_get_data (alternate_bytes, NULL) : NULL,
    .alternate_size = alternate_size, .alternate_mesa = mesa != NULL };
  uint64_t size;
  if (glims_duotone_psd_size (&spec, &size) != GLIMS_DUOTONE_PSD_OK)
    { g_bytes_unref (bytes); if (error) *error = strdup ("Duotone PSD dimensions or output size are unsupported."); return GLIMS_STATUS_UNSUPPORTED; }
  engine->busy++;
  GimpImage *copy = gimp_image_duplicate (open->image);
  if (!copy) { g_bytes_unref (bytes); engine->busy--; return GLIMS_STATUS_FAILED; }
  gimp_pickable_flush (GIMP_PICKABLE (copy));
  GimpProjection *projection = gimp_image_get_projection (copy);
  GeglBuffer *buffer = gimp_pickable_get_buffer (GIMP_PICKABLE (projection));
  gimp_projection_stop_rendering (projection);
  gimp_projection_flush_now (projection, FALSE);
  DuotoneExport state = { .engine = engine, .depth = spec.depth,
                          .total = (guint64) spec.width * spec.height };
  if (!glims_stored_rows_init (&state.rows, buffer, GLIMS_DUOTONE_PSD_CHUNK_PIXELS, GLIMS_STORED_GRAY_VALUES))
    { g_object_unref (copy); g_bytes_unref (bytes); engine->busy--; return GLIMS_STATUS_FAILED; }
  state.progress = glims_progress_new (engine);
  engine->progress = state.progress;
  gulong cancel = g_signal_connect (state.progress, "cancel", G_CALLBACK (duotone_cancel), &state);
  gimp_progress_start (GIMP_PROGRESS (state.progress), TRUE, "Exporting Duotone PSD");
  int os_error = 0;
  GlimsDuotonePsdFileStatus result = glims_duotone_psd_write_file (
    &spec, duotone_read, &state, path, duotone_continue, &state, &os_error);
  g_signal_handler_disconnect (state.progress, cancel);
  gimp_progress_end (GIMP_PROGRESS (state.progress));
  engine->progress = NULL;
  g_object_unref (state.progress);
  glims_stored_rows_clear (&state.rows);
  g_object_unref (copy);
  g_bytes_unref (bytes);
  engine->busy--;
  if (result == GLIMS_DUOTONE_PSD_FILE_OK) return GLIMS_STATUS_OK;
  if (result == GLIMS_DUOTONE_PSD_FILE_CANCELLED) return GLIMS_STATUS_CANCELLED;
  if (error)
    *error = strdup (state.invalid_pixel ? "Duotone export requires fully opaque grayscale pixels with finite values from 0 to 1." :
                     os_error ? g_strerror (os_error) : "Duotone PSD could not be exported. The destination was not replaced.");
  return result == GLIMS_DUOTONE_PSD_FILE_INVALID ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_FAILED;
}
