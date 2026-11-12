/* Native ink output never goes through GIMP's RGB PSD export image.
 * All native acquisition and reads stay on the serialized engine thread. */
#include "engine-private.h"
#include "plate-storage.h"
#include "cmyk-psd-file.h"

#include <string.h>
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpprogress.h"

typedef struct {
  GlimsEngine *engine;
  GeglBuffer *planes[4];
  GlimsProgress *progress;
  guint64 samples, total_samples;
  gint64 last_service;
  gboolean cancelled;
} NativeCmykExport;

static void
cancel_export (GimpProgress *progress, gpointer data)
{
  NativeCmykExport *state = data;
  state->cancelled = TRUE;
}

static bool
continue_export (void *data)
{
  NativeCmykExport *state = data;
  gint64 now = g_get_monotonic_time ();

  /* A bounded dispatch budget keeps cancellation and read RPCs deliverable.
   * An individual native read or filesystem operation can still block; this
   * is a polling target, not a hard wall-clock latency guarantee. At the end
   * always service queued cancellation before the transaction publishes. */
  if (now - state->last_service >= 10 * G_TIME_SPAN_MILLISECOND ||
      state->samples == state->total_samples)
    {
      gimp_progress_set_value (GIMP_PROGRESS (state->progress),
                                (double) state->samples / state->total_samples);
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
read_ink (void *data, uint32_t channel, uint32_t y, uint32_t x,
          uint32_t count, void *samples)
{
  NativeCmykExport *state = data;
  GeglBuffer *plane = state->planes[channel];
  /* The validated scalar storage format is used unchanged. Integer values
   * are ink intensity, not gamma-encoded grayscale or CMYK percentages. */
  gegl_buffer_get (plane, GEGL_RECTANGLE (x, y, count, 1), 1.0,
                    gegl_buffer_get_format (plane), samples,
                    GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  state->samples += count;
  return true;
}

GlimsStatus
glims_image_export_native_cmyk_psd (GlimsEngine *engine, GlimsImageID id,
                                    const char *path, char **error)
{
  if (error) *error = NULL;
  if (!path || !g_path_is_absolute (path))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  const char *extension = strrchr (path, '.');
  if (!extension || g_ascii_strcasecmp (extension, ".psd"))
    {
      if (error) *error = g_strdup ("Native CMYK export requires a .psd filename.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  GlimsOpenImage *open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy || g_hash_table_size (engine->strokes) ||
      g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;

  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open (open, &storage) ||
      storage.map.mode != GLIMS_PLATE_MODE_CMYK || storage.map.count != 4)
    {
      if (error) *error = g_strdup ("This export requires a native CMYK document.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (storage.map.storage != GLIMS_PLATE_STORAGE_U8 &&
      storage.map.storage != GLIMS_PLATE_STORAGE_U16)
    {
      if (error) *error = g_strdup ("Native CMYK PSD export supports 8-bit and 16-bit ink channels. Save XCF to retain float precision.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  GlimsCmykPsdSpec spec = {
    storage.map.width, storage.map.height,
    storage.map.storage == GLIMS_PLATE_STORAGE_U8 ? 8 : 16,
    storage.profile, storage.profile_size
  };
  uint64_t file_size;
  if (glims_cmyk_psd_size (&spec, &file_size) != GLIMS_CMYK_PSD_OK)
    {
      if (error) *error = g_strdup ("PSD requires dimensions no larger than 30000 pixels and a file smaller than 2 GiB.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* Copy-on-write snapshots own their tiles across nested dispatch. Never
   * use the borrowed storage/open pointers after the first yield. Preview
   * visibility does not remove a source ink from the file. */
  NativeCmykExport state = { .engine = engine,
    .total_samples = (guint64) spec.width * spec.height * 4 };
  GBytes *profile = g_bytes_ref (open->component_cmyk_profile);
  spec.icc = g_bytes_get_data (profile, &spec.icc_size);
  engine->busy++;
  for (guint i = 0; i < 4; i++)
    state.planes[i] = gegl_buffer_dup (gimp_drawable_get_buffer (GIMP_DRAWABLE (storage.planes[i])));

  state.progress = glims_progress_new (engine);
  engine->progress = state.progress;
  gulong cancel_handler = g_signal_connect (state.progress, "cancel",
                                             G_CALLBACK (cancel_export), &state);
  gimp_progress_start (GIMP_PROGRESS (state.progress), TRUE, "Exporting native CMYK PSD");
  int os_error = 0;
  GlimsCmykPsdFileStatus result = glims_cmyk_psd_write_file (
    &spec, read_ink, &state, path, continue_export, &state, &os_error);

  g_signal_handler_disconnect (state.progress, cancel_handler);
  gimp_progress_end (GIMP_PROGRESS (state.progress));
  engine->progress = NULL;
  g_object_unref (state.progress);
  for (guint i = 0; i < 4; i++) g_object_unref (state.planes[i]);
  g_bytes_unref (profile);
  engine->busy--;

  if (result == GLIMS_CMYK_PSD_FILE_OK) return GLIMS_STATUS_OK;
  if (result == GLIMS_CMYK_PSD_FILE_CANCELLED) return GLIMS_STATUS_CANCELLED;
  if (error)
    *error = os_error ? g_strdup_printf ("The CMYK PSD could not be exported: %s", g_strerror (os_error))
                     : g_strdup ("The CMYK PSD could not be exported. The destination was not replaced.");
  return result == GLIMS_CMYK_PSD_FILE_INVALID ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_FAILED;
}
